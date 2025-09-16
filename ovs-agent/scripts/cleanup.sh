#!/usr/bin/env bash
set -Eeuo pipefail
SERVICE_NAME="${SERVICE_NAME:-lbaas-ovs-agent-go}"
APP_NAME="${APP_NAME:-lbaas-ovs-agent}"
APP_USER="${APP_USER:-lbaasovsagent}"
APP_DIR="${APP_DIR:-/opt/${APP_NAME}}"
ENV_FILE="${ENV_FILE:-/etc/default/${SERVICE_NAME}}"

YES=0
PURGE_USER=0
KEEP_SRC=0

usage() {
  cat <<EOF
Usage: $0 [--yes] [--purge-user] [--keep-src]
  --yes         Non-interactive
  --purge-user  Delete system user (${APP_USER})
  --keep-src    Keep ${APP_DIR}/src, remove only binaries & service
EOF
}

for arg in "$@"; do
  case "$arg" in
    --yes) YES=1;;
    --purge-user) PURGE_USER=1;;
    --keep-src) KEEP_SRC=1;;
    -h|--help) usage; exit 0;;
  esac
done

echo "==> Stopping service"
systemctl stop "${SERVICE_NAME}" 2>/dev/null || true
systemctl disable "${SERVICE_NAME}" 2>/dev/null || true

echo "==> Removing unit"
rm -f "/etc/systemd/system/${SERVICE_NAME}.service"
systemctl daemon-reload

echo "==> Removing env file"
rm -f "${ENV_FILE}"

if [[ $KEEP_SRC -eq 1 ]]; then
  echo "==> Removing binaries only"
  rm -rf "${APP_DIR}/bin"
else
  echo "==> Removing app dir ${APP_DIR}"
  rm -rf "${APP_DIR}"
fi

if [[ $PURGE_USER -eq 1 ]]; then
  echo "==> Removing user ${APP_USER}"
  id "${APP_USER}" >/dev/null 2>&1 && userdel "${APP_USER}" || true
fi

echo "Cleanup done."
