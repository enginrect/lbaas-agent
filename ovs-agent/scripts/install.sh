#!/usr/bin/env bash
set -euo pipefail

# ---- 설정 (필요 시 환경변수로 덮어쓰기 가능) ----
REPO_URL="${REPO_URL:-https://github.com/enginrect/lbaas-agent.git}"

APP_DIR="${APP_DIR:-/opt/lbaasovsagent}"
SRC_ROOT="${SRC_ROOT:-$APP_DIR/src}"
VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"

SERVICE_UNIT="${SERVICE_UNIT:-lbaas_ovs_agent}"  # systemd 유닛 이름(언더스코어)
ENTRY_BIN="${ENTRY_BIN:-lbaas-ovs-agent}"        # wheel 설치로 생성되는 콘솔 스크립트(하이픈)

# ---- 의존 패키지 (없으면 설치) ----
if ! command -v git >/dev/null 2>&1 || ! python3 -m venv -h >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y git python3-venv python3-pip
fi

# ---- 운영 사용자/디렉토리 ----
id lbaasovsagent >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin lbaasovsagent
usermod -aG docker lbaasovsagent || true
mkdir -p "$APP_DIR"
chown -R lbaasovsagent:lbaasovsagent "$APP_DIR"

# ---- 코드 가져오기/업데이트 ----
if [ ! -d "$SRC_ROOT/.git" ]; then
  sudo -u lbaasovsagent git clone "$REPO_URL" "$SRC_ROOT"
else
  sudo -u lbaasovsagent git -C "$SRC_ROOT" fetch --all --prune
  # 기본 브랜치 최신으로 동기화
  DEFAULT_REF="$(sudo -u lbaasovsagent git -C "$SRC_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD | sed 's|^origin/||' || echo main)"
  sudo -u lbaasovsagent git -C "$SRC_ROOT" checkout -q "$DEFAULT_REF" || true
  sudo -u lbaasovsagent git -C "$SRC_ROOT" reset --hard "origin/$DEFAULT_REF"
fi

# ---- 빌드 대상 디렉토리 탐색 (pyproject.toml 있는 곳) ----
PKG_DIR=""
if [ -f "$SRC_ROOT/pyproject.toml" ]; then
  PKG_DIR="$SRC_ROOT"
elif [ -f "$SRC_ROOT/ovs-agent/pyproject.toml" ]; then
  PKG_DIR="$SRC_ROOT/ovs-agent"
else
  CANDIDATE="$(find "$SRC_ROOT" -maxdepth 3 -type f -name pyproject.toml | head -n1 || true)"
  if [ -n "${CANDIDATE:-}" ]; then
    PKG_DIR="$(dirname "$CANDIDATE")"
  fi
fi
if [ -z "$PKG_DIR" ]; then
  echo "ERROR: pyproject.toml not found under $SRC_ROOT" >&2
  exit 1
fi

# ---- venv + build + install ----
if [ ! -d "$VENV_DIR" ]; then
  sudo -u lbaasovsagent python3 -m venv "$VENV_DIR"
fi
sudo -u lbaasovsagent "$VENV_DIR/bin/pip" install --upgrade pip build
sudo -u lbaasovsagent "$VENV_DIR/bin/python" -m build "$PKG_DIR"
sudo -u lbaasovsagent "$VENV_DIR/bin/pip" install --upgrade "$PKG_DIR/dist/"*.whl

# ---- systemd 유닛 생성 (콘솔 스크립트 실행) ----
cat >/etc/systemd/system/${SERVICE_UNIT}.service <<EOF
[Unit]
Description=LBaaS OVS Agent (wheel)
After=network.target docker.service
Requires=docker.service

[Service]
User=lbaasovsagent
Group=lbaasovsagent
WorkingDirectory=$APP_DIR
ExecStart=$VENV_DIR/bin/$ENTRY_BIN
Restart=always
RestartSec=2
Environment=PYTHONUNBUFFERED=1
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=$APP_DIR
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF

# ---- 기동 ----
systemctl daemon-reload
systemctl enable --now ${SERVICE_UNIT}
systemctl status ${SERVICE_UNIT} --no-pager

echo "OK: ${SERVICE_UNIT} installed and started."