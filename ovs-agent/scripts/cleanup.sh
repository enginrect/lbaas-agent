#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "[ERROR] line ${LINENO}: ${BASH_COMMAND}" >&2' ERR

# =========================
# Configurable environment
# =========================
SERVICE_UNIT="${SERVICE_UNIT:-lbaas_ovs_agent}"   # systemd unit name (underscored)
APP_DIR="${APP_DIR:-/opt/lbaasovsagent}"          # installation root
VENV_DIR="${VENV_DIR:-$APP_DIR/venv}"             # venv path
ENTRY_BIN="${ENTRY_BIN:-lbaas-ovs-agent}"         # console script installed into the venv
RUN_USER="${RUN_USER:-lbaasovsagent}"             # dedicated service user

# Behavior flags (can be overridden by CLI args)
YES=0                 # non-interactive mode
DRY=0                 # dry-run (print actions only)
PURGE_USER=0          # delete service user (not recommended unless dedicated)
KEEP_SRC=0            # keep $APP_DIR/src and remove only venv/build artifacts
VACUUM_JOURNAL=""     # e.g., "2weeks" or "500M" (optional)

usage() {
  cat <<EOF
Usage: $(basename "$0") [--yes] [--dry-run] [--purge-user] [--keep-src] [--vacuum-journal=<N|time>] [-h|--help]

Options:
  --yes                   Proceed without confirmation.
  --dry-run               Show what would be done, but don't do it.
  --purge-user            Remove the service user '${RUN_USER}' (use with care).
  --keep-src              Keep ${APP_DIR}/src and remove only venv and build artifacts.
  --vacuum-journal=VAL    Run 'journalctl --vacuum-time=VAL' (or fallback to --vacuum-size).
  -h, --help              Show this help.

Environment overrides:
  SERVICE_UNIT, APP_DIR, VENV_DIR, ENTRY_BIN, RUN_USER
EOF
}

# -------------------------
# Parse CLI arguments
# -------------------------
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

# -------------------------
# Helpers
# -------------------------
need_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "Please run as root." >&2
    exit 1
  fi
}

confirm() {
  [[ $YES -eq 1 ]] && return 0
  read -rp "$1 [y/N] " ans
  [[ "${ans:-}" =~ ^[Yy]$ ]]
}

run() {
  echo "+ $*"
  [[ $DRY -eq 1 ]] || eval "$@"
}

# -------------------------
# Start
# -------------------------
need_root

echo "Plan:"
echo "  - stop/disable systemd unit: ${SERVICE_UNIT}"
echo "  - reset failed state (before removing unit file)"
echo "  - remove unit file: /etc/systemd/system/${SERVICE_UNIT}.service"
echo "  - daemon-reload"
echo "  - kill leftovers: ${VENV_DIR}/bin/${ENTRY_BIN}, uvicorn app.lbaas_ovs_agent:app"
echo "  - remove venv: ${VENV_DIR}"
echo "  - remove app dir: ${APP_DIR} (keep src? ${KEEP_SRC})"
echo "  - purge user? ${PURGE_USER} (${RUN_USER})"
#[[ -n "$VACUUM_JOURNAL" ]] && echo "  - vacuum journald: ${VACUUM_JOURNAL}"
echo

confirm "Proceed to cleanup?" || { echo "Aborted."; exit 0; }

# 1) Stop/disable the unit first
run "systemctl disable --now ${SERVICE_UNIT} || true"

# 2) Reset failed state BEFORE removing the unit file
#    (avoids 'not loaded' warning later)
run "systemctl reset-failed ${SERVICE_UNIT} 2>/dev/null || true"

# 3) Remove the unit file and reload daemon
run "rm -f /etc/systemd/system/${SERVICE_UNIT}.service"
run "systemctl daemon-reload"

# 4) Terminate any leftover processes (ignore if none)
run "pkill -f '${VENV_DIR}/bin/${ENTRY_BIN}' || true"
run "pkill -f 'uvicorn .*app\\.lbaas_ovs_agent:app' || true"
run "sleep 0.5"
# Show what is (still) running, if anything
run "pgrep -af '${ENTRY_BIN}|app\\.lbaas_ovs_agent:app' || true"

# 5) Remove files/directories
if [[ $KEEP_SRC -eq 1 ]]; then
  # Keep source; drop venv and common build artifacts
  run "rm -rf '${VENV_DIR}'"
  run "rm -rf '${APP_DIR}/dist' '${APP_DIR}/build' 2>/dev/null || true"
else
  run "rm -rf '${APP_DIR}'"
fi

## 6) (Optional) Journald vacuum
#if [[ -n "$VACUUM_JOURNAL" ]]; then
#  # Try time-based vacuum; if it fails, try size-based
#  run "journalctl --vacuum-time='${VACUUM_JOURNAL}' 2>/dev/null || journalctl --vacuum-size='${VACUUM_JOURNAL}' 2>/dev/null || true"
#fi

# 7) (Optional) Remove service user
if [[ $PURGE_USER -eq 1 ]]; then
  if id "${RUN_USER}" >/dev/null 2>&1; then
    # User has no home/mail by design; no -r required
    run "userdel '${RUN_USER}' || true"
  fi
fi

echo "Cleanup done."