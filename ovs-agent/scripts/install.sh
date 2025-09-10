#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/enginrect/lbaas-agent.git}"
APP_DIR="/opt/lbaasovsagent"
VENV_DIR="$APP_DIR/venv"
SERVICE="lbaas-ovs-agent"

# 1) 운영 사용자/디렉토리
id lbaasovsagent >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin lbaasovsagent
usermod -aG docker lbaasovsagent || true
mkdir -p "$APP_DIR"
chown -R lbaasovsagent:lbaasovsagent "$APP_DIR"

# 2) 코드 가져오기/업데이트
if [ ! -d "$SRC_ROOT/.git" ]; then
  sudo -u lbaasovsagent git clone "$REPO_URL" "$SRC_ROOT"
else
  sudo -u lbaasovsagent git -C "$SRC_ROOT" pull --ff-only
fi

# 3) 빌드 대상 디렉토리 찾아내기 (pyproject.toml 탐색)
PKG_DIR=""
if [ -f "$SRC_ROOT/pyproject.toml" ]; then
  PKG_DIR="$SRC_ROOT"
elif [ -f "$SRC_ROOT/ovs-agent/pyproject.toml" ]; then
  PKG_DIR="$SRC_ROOT/ovs-agent"
else
  # 마지막으로 2단계 내려가서 탐색
  CANDIDATE="$(find "$SRC_ROOT" -maxdepth 3 -type f -name pyproject.toml | head -n1 || true)"
  if [ -n "${CANDIDATE:-}" ]; then
    PKG_DIR="$(dirname "$CANDIDATE")"
  fi
fi
if [ -z "$PKG_DIR" ]; then
  echo "ERROR: pyproject.toml not found under $SRC_ROOT" >&2
  exit 1
fi

# 4) venv + build + install
if [ ! -d "$VENV_DIR" ]; then
  sudo -u lbaasovsagent python3 -m venv "$VENV_DIR"
fi
sudo -u lbaasovsagent "$VENV_DIR/bin/pip" install --upgrade pip build
sudo -u lbaasovsagent "$VENV_DIR/bin/python" -m build "$PKG_DIR"
sudo -u lbaasovsagent "$VENV_DIR/bin/pip" install --upgrade "$PKG_DIR/dist/"*.whl

# 5) systemd 유닛(자동 생성; 레포 유닛 대신 이걸 써도 됨)
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

# 6) 기동
systemctl daemon-reload
systemctl enable --now ${SERVICE_UNIT}
systemctl status ${SERVICE_UNIT} --no-pager

echo "OK: ${SERVICE_UNIT} installed and started."