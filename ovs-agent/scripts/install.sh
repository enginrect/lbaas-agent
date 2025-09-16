#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# Configurable
APP_NAME="lbaas-ovs-agent"
SERVICE_NAME="lbaas-ovs-agent-go"
APP_USER="lbaasovsagent"
APP_DIR="/opt/${APP_NAME}"
BIN_DIR="${APP_DIR}/bin"
SRC_DIR="${APP_DIR}/src"
ENV_FILE="/etc/default/${SERVICE_NAME}"

# Build options
GO_BIN="${GO_BIN:-go}"   # path to go (needs Go 1.25)
BIND_ADDR="${BIND_ADDR:-0.0.0.0:9406}"

echo "==> Installing ${APP_NAME} (Go) to ${APP_DIR}"

# 1) create user if missing
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd --system --home "${APP_DIR}" --shell /usr/sbin/nologin "${APP_USER}"
fi

# 2) layout
mkdir -p "${BIN_DIR}" "${SRC_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_DIR}"

# 3) copy source (assumes script is run from the project root)
SRC_FROM="$(cd "$(dirname "$0")"/.. && pwd)"
rsync -a --delete "${SRC_FROM}/" "${SRC_DIR}/" --exclude .git --exclude scripts --exclude systemd

# 4) build
cd "${SRC_DIR}"
echo "==> Building with ${GO_BIN}"
${GO_BIN} version
${GO_BIN} mod download
${GO_BIN} build -o "${BIN_DIR}/${APP_NAME}" ./cmd/lbaas-ovs-agent

# 5) env file
cat >"${ENV_FILE}" <<EOF
# OVN Southbound endpoint (default tcp:127.0.0.1:6642)
OVN_SB_ENDPOINT="${OVN_SB_ENDPOINT:-}"
# OVS container name (default openvswitch_vswitchd)
OVS_CONTAINER="${OVS_CONTAINER:-}"
EOF

# 6) systemd unit
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
cat >"${UNIT_PATH}" <<'UNIT'
[Unit]
Description=LBaaS OVS Agent (Go)
Wants=network-online.target
After=network-online.target docker.service

[Service]
EnvironmentFile=-/etc/default/lbaas-ovs-agent-go
User=lbaasovsagent
Group=lbaasovsagent
ExecStart=/opt/lbaas-ovs-agent/bin/lbaas-ovs-agent -bind ${BIND_ADDR}
Restart=on-failure
RestartSec=2s
AmbientCapabilities=CAP_NET_ADMIN
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"
systemctl status "${SERVICE_NAME}" --no-pager || true

echo "OK: ${SERVICE_NAME} installed and started at ${BIND_ADDR}."
echo "Try: curl -s http://${BIND_ADDR}/healthz || true"
