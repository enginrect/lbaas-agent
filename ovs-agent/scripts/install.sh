#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# ---- configurable env (override as needed) ----
REPO_URL="${REPO_URL:-https://github.com/ThakiCloud/lbaas-agent.git}"

APP_DIR="${APP_DIR:-/opt/lbaasovsagent}"
SRC_ROOT="${SRC_ROOT:-$APP_DIR/src}"
VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"

SERVICE_UNIT="${SERVICE_UNIT:-lbaas_ovs_agent}"   # systemd unit name (underscored)
ENTRY_BIN="${ENTRY_BIN:-lbaas-ovs-agent}"         # console script installed from the wheel

RUN_USER="${RUN_USER:-lbaasovsagent}"

# Optional: bind externally without rebuilding (falls back to ENTRY_BIN if unset)
# e.g. BIND_HOST=0.0.0.0 BIND_PORT=9406 ./install.sh
BIND_HOST="${BIND_HOST:-}"
BIND_PORT="${BIND_PORT:-}"

# Optional: pin to a branch/tag/commit (default = origin/HEAD)
GIT_REF="${GIT_REF:-}"

# ---- dependencies (Debian/Ubuntu) ----
if command -v apt-get >/dev/null 2>&1; then
  if ! command -v git >/dev/null 2>&1 || ! python3 -m venv -h >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y git python3-venv python3-pip
  fi
fi

# ---- system user & directories ----
id "${RUN_USER}" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "${RUN_USER}"
# Add to docker group if present (ignore if not installed)
getent group docker >/dev/null 2>&1 && usermod -aG docker "${RUN_USER}" || true

mkdir -p "${APP_DIR}"
chown -R "${RUN_USER}:${RUN_USER}" "${APP_DIR}"

# ---- clone or update source ----
if [ ! -d "${SRC_ROOT}/.git" ]; then
  sudo -u "${RUN_USER}" git clone "${REPO_URL}" "${SRC_ROOT}"
else
  sudo -u "${RUN_USER}" git -C "${SRC_ROOT}" fetch --all --prune
fi

# Determine default ref (origin/HEAD) if none specified
if [ -z "${GIT_REF}" ]; then
  DEFAULT_REF="$(sudo -u "${RUN_USER}" git -C "${SRC_ROOT}" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"
  GIT_REF="${DEFAULT_REF:-main}"
fi

# Checkout & hard reset to chosen ref
sudo -u "${RUN_USER}" git -C "${SRC_ROOT}" checkout -q "${GIT_REF}" || true
sudo -u "${RUN_USER}" git -C "${SRC_ROOT}" reset --hard "origin/${GIT_REF}"

# ---- locate package root (where pyproject.toml lives) ----
PKG_DIR=""
if [ -f "${SRC_ROOT}/pyproject.toml" ]; then
  PKG_DIR="${SRC_ROOT}"
elif [ -f "${SRC_ROOT}/ovs-agent/pyproject.toml" ]; then
  PKG_DIR="${SRC_ROOT}/ovs-agent"
else
  CANDIDATE="$(find "${SRC_ROOT}" -maxdepth 3 -type f -name pyproject.toml | head -n1 || true)"
  if [ -n "${CANDIDATE:-}" ]; then
    PKG_DIR="$(dirname "${CANDIDATE}")"
  fi
fi
if [ -z "${PKG_DIR}" ]; then
  echo "ERROR: pyproject.toml not found under ${SRC_ROOT}" >&2
  exit 1
fi

# ---- venv + build + install ----
if [ ! -d "${VENV_DIR}" ]; then
  sudo -u "${RUN_USER}" python3 -m venv "${VENV_DIR}"
fi

sudo -u "${RUN_USER}" "${VENV_DIR}/bin/pip" install --upgrade pip build wheel
sudo -u "${RUN_USER}" "${VENV_DIR}/bin/python" -m build "${PKG_DIR}"
sudo -u "${RUN_USER}" "${VENV_DIR}/bin/pip" install --upgrade "${PKG_DIR}/dist/"*.whl

# ---- systemd unit ----
UNIT_PATH="/etc/systemd/system/${SERVICE_UNIT}.service"

# Choose ExecStart:
# - If BIND_HOST and BIND_PORT are set: run uvicorn directly (bind externally)
# - Else: run the console script (ENTRY_BIN)
if [ -n "${BIND_HOST}" ] && [ -n "${BIND_PORT}" ]; then
  EXECSTART="${VENV_DIR}/bin/uvicorn app.lbaas_ovs_agent:app --host ${BIND_HOST} --port ${BIND_PORT}"
else
  EXECSTART="${VENV_DIR}/bin/${ENTRY_BIN}"
fi

cat >"${UNIT_PATH}" <<EOF
[Unit]
Description=LBaaS OVS Agent (wheel)
After=network.target docker.service
Requires=docker.service

[Service]
User=${RUN_USER}
Group=${RUN_USER}
WorkingDirectory=${APP_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PATH=${VENV_DIR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Suppress docker config warning if HOME-less service user
Environment=DOCKER_CONFIG=/nonexistent
ExecStart=${EXECSTART}
Restart=always
RestartSec=2

# Hardening (adjust if needed)
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

# ---- enable & start ----
systemctl daemon-reload
systemctl enable --now "${SERVICE_UNIT}"
systemctl status "${SERVICE_UNIT}" --no-pager || true

echo
echo "OK: ${SERVICE_UNIT} installed and started."
if [ -n "${BIND_HOST}" ] && [ -n "${BIND_PORT}" ]; then
  echo "Listening on ${BIND_HOST}:${BIND_PORT}"
  echo "Try: curl -s http://${BIND_HOST}:${BIND_PORT}/healthz"
else
  echo "Using console entry script (${ENTRY_BIN})."
  echo "Default bind is whatever your app uses internally (e.g., 127.0.0.1:9406)."
fi