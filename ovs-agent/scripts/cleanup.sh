#!/usr/bin/env bash
set -euo pipefail

# ===== default variables (override via env if needed) =====
SERVICE_UNIT="${SERVICE_UNIT:-lbaas_ovs_agent}"   # systemd unit name (underscored)
APP_DIR="${APP_DIR:-/opt/lbaasovsagent}"          # installation dir
VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"             # venv dir
ENTRY_BIN="${ENTRY_BIN:-lbaas-ovs-agent}"         # console script name (hyphenated)
RUN_USER="${RUN_USER:-lbaasovsagent}"             # execution user

YES=0
DRY=0
PURGE_USER=0
KEEP_SRC=0
VACUUM_JOURNAL=""     # e.g. --vacuum-journal=2weeks

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--dry-run] [--purge-user] [--keep-src] [--vacuum-journal=<N|time>]

Options:
  --yes                 Non-interactive mode (no confirmation)
  --dry-run             Print the plan without performing actions
  --purge-user          Remove system user '${RUN_USER}' (not recommended; OK if it's a dedicated account)
  --keep-src            Keep ${APP_DIR}/src and remove only venv/unit
  --vacuum-journal=...  Vacuum journald logs (e.g., 2weeks, 500M)
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

need_root() { if [[ $EUID -ne 0 ]]; then echo "Please run as root."; exit 1; fi; }
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
echo "  - remove app dir: ${APP_DIR} (keep src? ${KEEP_SRC})"
echo "  - purge user? ${PURGE_USER} (${RUN_USER})"
#[[ -n "$VACUUM_JOURNAL" ]] && echo "  - vacuum journal: $VACUUM_JOURNAL"
echo

confirm "Proceed to cleanup?" || { echo "Aborted."; exit 0; }

# 1) Stop/disable service & remove unit
run "systemctl disable --now ${SERVICE_UNIT} || true"
run "rm -f /etc/systemd/system/${SERVICE_UNIT}.service"
run "systemctl daemon-reload"
run "systemctl reset-failed ${SERVICE_UNIT} || true"

# 2) Terminate leftover processes (ignore if none)
run "pkill -f '${VENV_DIR}/bin/${ENTRY_BIN}' || true"
run "pkill -f 'uvicorn .*app\\.lbaas_ovs_agent:app' || true"
run "sleep 0.5"
run "pgrep -af '${ENTRY_BIN}|app\\.lbaas_ovs_agent:app' || true"

# 3) Remove files/directories
if [[ $KEEP_SRC -eq 1 ]]; then
  run "rm -rf '${VENV_DIR}'"
  run "rm -rf '${APP_DIR}/dist' '${APP_DIR}/build' || true"
else
  run "rm -rf '${APP_DIR}'"
fi

# 4) (optional) journald vacuum
#if [[ -n "$VACUUM_JOURNAL" ]]; then
#  run "journalctl --vacuum-time='${VACUUM_JOURNAL}' || journalctl --vacuum-size='${VACUUM_JOURNAL}' || true"
#fi

# 5) (optional) remove user
if [[ $PURGE_USER -eq 1 ]]; then
  id "${RUN_USER}" >/dev/null 2>&1 && run "userdel '${RUN_USER}' || true"
fi

echo "Cleanup done."