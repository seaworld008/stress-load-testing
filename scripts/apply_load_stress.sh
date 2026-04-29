#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/servers.yaml}"
LOAD_SCRIPT="${LOCAL_STRESS_SCRIPT:-${SCRIPT_DIR}/load_stress.sh}"
DEPLOY_SCRIPT="${SCRIPT_DIR}/deploy_load_stress.sh"
MODE="dry-run"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  apply_load_stress.sh [--dry-run|--apply] [--config <yaml>]

Options:
  --dry-run        Validate the inventory and print the schedule. This is the default.
  --apply          Deploy the managed script and replace the managed cron entry.
  --config <yaml>  Inventory file. Default: scripts/servers.yaml.
  -h, --help       Show this help message.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        MODE="dry-run"
        shift
        ;;
      --apply)
        MODE="apply"
        shift
        ;;
      --config)
        [[ $# -ge 2 ]] || fail "--config requires a file path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

main() {
  parse_args "$@"

  [[ -f "$CONFIG_FILE" ]] || fail "config file not found: ${CONFIG_FILE}"
  [[ -f "$LOAD_SCRIPT" ]] || fail "load script not found: ${LOAD_SCRIPT}"
  [[ -x "$DEPLOY_SCRIPT" ]] || chmod 700 "$DEPLOY_SCRIPT"
  [[ -x "$LOAD_SCRIPT" ]] || chmod 700 "$LOAD_SCRIPT"

  if [[ "$MODE" == "dry-run" ]]; then
    log "running dry-run with ${CONFIG_FILE}"
    exec "$DEPLOY_SCRIPT" --config "$CONFIG_FILE" --script "$LOAD_SCRIPT" --dry-run
  fi

  log "applying load-stress deployment with ${CONFIG_FILE}"
  exec "$DEPLOY_SCRIPT" --config "$CONFIG_FILE" --script "$LOAD_SCRIPT"
}

main "$@"
