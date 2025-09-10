#!/usr/bin/env bash
set -euo pipefail

# ===== 기본 변수 (환경변수로 오버라이드 가능) =====
SERVICE_UNIT="${SERVICE_UNIT:-lbaas_ovs_agent}"     # systemd unit name (언더스코어)
APP_DIR="${APP_DIR:-/opt/lbaasovsagent}"           # 설치 루트
VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"              # venv 경로
ENTRY_BIN="${ENTRY_BIN:-lbaas-ovs-agent}"          # 콘솔 스크립트 이름 (하이픈)
RUN_USER="${RUN_USER:-lbaasovsagent}"              # 실행 유저

YES=0
DRY=0
PURGE_USER=0
KEEP_SRC=0
VACUUM_JOURNAL=""     # 예: --vacuum-journal=2weeks

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--dry-run] [--purge-user] [--keep-src] [--vacuum-journal=<N|time>]

Options:
  --yes                 비대화형 진행(확인 없이 진행)
  --dry-run             실제 삭제 대신 수행 계획만 출력
  --purge-user          시스템 사용자 '${RUN_USER}' 삭제(권장 X, 전용 계정만 썼다면 OK)
  --keep-src            ${APP_DIR}/src 는 남기고, venv/유닛만 제거
  --vacuum-journal=...  journald 로그 정리 (예: 2weeks, 500M 등)
Env overrides:
  SERVICE_UNIT, APP_DIR, VENV_DIR, ENTRY_BIN, RUN_USER
EOF
}

for a in "$@"; do
  case "$a" in
    --yes) YES=1;;
    --dry-run) DRY=1;;
    --purge-user) PURGE_USER=1;;
    --keep-src) KEEP_SRC=1;;
    --vacuum-journal=*) VACUUM_JOURNAL="${a#*=}";;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $a"; usage; exit 1;;
  esac
done

need_root() { if [[ $EUID -ne 0 ]]; then echo "Run as root."; exit 1; fi; }
confirm() {
  [[ $YES -eq 1 ]] && return 0
  read -rp "$1 [y/N] " ans
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}
run() {
  echo "+ $*"
  [[ $DRY -eq 1 ]] || eval "$@"
}

need_root

echo "Plan:"
echo "  - stop/disable systemd unit: ${SERVICE_UNIT}"
echo "  - remove unit file: /etc/systemd/system/${SERVICE_UNIT}.service"
echo "  - kill leftovers: ${VENV_DIR}/bin/${ENTRY_BIN}, uvicorn app.lbaas_ovs_agent:app"
echo "  - remove venv: ${VENV_DIR}"
echo "  - remove app dir: ${APP_DIR} (src kept? ${KEEP_SRC})"
echo "  - purge user? ${PURGE_USER} (${RUN_USER})"
#[[ -n "$VACUUM_JOURNAL" ]] && echo "  - vacuum journal: $VACUUM_JOURNAL"
echo

confirm "Proceed to cleanup?" || { echo "Aborted."; exit 0; }

# 1) 서비스 중단/비활성화 & 유닛 제거
run "systemctl disable --now ${SERVICE_UNIT} || true"
run "rm -f /etc/systemd/system/${SERVICE_UNIT}.service"
run "systemctl daemon-reload"
run "systemctl reset-failed ${SERVICE_UNIT} || true"

# 2) 잔여 프로세스 종료(있어도/없어도 통과)
run "pkill -f '${VENV_DIR}/bin/${ENTRY_BIN}' || true"
run "pkill -f 'uvicorn .*app\\.lbaas_ovs_agent:app' || true"
run "sleep 0.5"
run "pgrep -af '${ENTRY_BIN}|app\\.lbaas_ovs_agent:app' || true"

# 3) 파일/디렉토리 제거
if [[ $KEEP_SRC -eq 1 ]]; then
  run "rm -rf '${VENV_DIR}'"
  run "rm -rf '${APP_DIR}/dist' '${APP_DIR}/build' || true"
else
  run "rm -rf '${APP_DIR}'"
fi

# 4) (옵션) journald 정리
#if [[ -n "$VACUUM_JOURNAL" ]]; then
#  run "journalctl --vacuum-time='${VACUUM_JOURNAL}' || journalctl --vacuum-size='${VACUUM_JOURNAL}' || true"
#fi

# 5) (옵션) 사용자 제거
if [[ $PURGE_USER -eq 1 ]]; then
  # 홈 디렉토리/메일스POOL 없으면 -r 없이도 OK
  id "${RUN_USER}" >/dev/null 2>&1 && run "userdel '${RUN_USER}' || true"
fi

echo "Cleanup done."