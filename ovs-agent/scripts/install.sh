#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/<ORG>/<REPO>.git}"  # <- 여길 실제 주소로
APP_DIR="/opt/lbaasovsagent"
VENV_DIR="$APP_DIR/venv"
SERVICE="lbaas-ovs-agent"

# 의존 패키지
sudo apt-get update -y
sudo apt-get install -y python3-venv python3-pip git

# 운영 사용자
id lbaasovsagent >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin lbaasovsagent
sudo usermod -aG docker lbaasovsagent

# 코드 가져오기/업데이트
if [ ! -d "$APP_DIR/src" ]; then
  sudo mkdir -p "$APP_DIR"
  sudo chown -R lbaasovsagent:lbaasovsagent "$APP_DIR"
  sudo -u lbaasovsagent git clone "$REPO_URL" "$APP_DIR/src"
else
  sudo -u lbaasovsagent git -C "$APP_DIR/src" pull --ff-only
fi

# venv + 빌드/설치
if [ ! -d "$VENV_DIR" ]; then
  sudo -u lbaasovsagent python3 -m venv "$VENV_DIR"
fi
sudo -u lbaasovsagent "$VENV_DIR/bin/pip" install --upgrade pip build
sudo -u lbaasovsagent "$VENV_DIR/bin/python" -m build "$APP_DIR/src"
sudo -u lbaasovsagent "$VENV_DIR/bin/pip" install --upgrade "$APP_DIR/src/dist/"*.whl

# systemd 유닛
sudo tee /etc/systemd/system/${SERVICE}.service >/dev/null <<EOF
[Unit]
Description=LBaaS OVS Agent (wheel)
After=network.target docker.service
Requires=docker.service

[Service]
User=lbaasovsagent
Group=lbaasovsagent
ExecStart=${VENV_DIR}/bin/lbaas-ovs-agent
Restart=always
RestartSec=2
Environment="PYTHONUNBUFFERED=1"
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${APP_DIR}
RestrictAddressFamilies=AF_UNIX AF_INET AF_INET6
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now ${SERVICE}
sudo systemctl status ${SERVICE} --no-pager
echo "OK: ${SERVICE} installed and started."