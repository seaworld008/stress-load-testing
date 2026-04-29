#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/servers.yaml}"
LOCAL_STRESS_SCRIPT="${LOCAL_STRESS_SCRIPT:-${SCRIPT_DIR}/load_stress.sh}"
REMOTE_SCRIPT_DIR="/root/scripts"
REMOTE_SCRIPT_PATH="${REMOTE_SCRIPT_DIR}/load_stress.sh"
REMOTE_LOG_PATH="/var/log/load_stress.log"
WINDOW_START_HOUR=1
WINDOW_END_HOUR=3
SLOT_MINUTES=15
MAX_PARALLEL_PER_SLOT=2
DRY_RUN=0

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
  deploy_load_stress.sh [--config <yaml>] [--script <load_stress.sh>] [--dry-run]

Options:
  --config <yaml>   YAML inventory file. Default: ./servers.yaml beside this script.
  --script <path>   Local load_stress.sh to upload. Default: ./load_stress.sh beside this script.
  --dry-run         Print the computed actions without connecting to servers.
  -h, --help        Show this help message.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -ge 2 ]] || fail "--config requires a file path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --script)
        [[ $# -ge 2 ]] || fail "--script requires a file path"
        LOCAL_STRESS_SCRIPT="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
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

detect_package_manager() {
  local manager
  for manager in apt-get dnf yum zypper apk; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s\n' "$manager"
      return 0
    fi
  done
  return 1
}

install_system_package() {
  local package="$1"
  local manager
  manager="$(detect_package_manager)" || fail "cannot install ${package}: no supported package manager found"

  log "installing ${package} with ${manager}"
  case "$manager" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
      ;;
    dnf)
      dnf install -y "$package"
      ;;
    yum)
      yum install -y "$package"
      ;;
    zypper)
      zypper --non-interactive install "$package"
      ;;
    apk)
      apk add --no-cache "$package"
      ;;
    *)
      fail "unsupported package manager: ${manager}"
      ;;
  esac
}

openssh_client_package_name() {
  local manager
  manager="$(detect_package_manager)" || fail "cannot determine openssh client package name"

  case "$manager" in
    apt-get)
      printf 'openssh-client\n'
      ;;
    dnf|yum)
      printf 'openssh-clients\n'
      ;;
    zypper|apk)
      printf 'openssh\n'
      ;;
    *)
      fail "unsupported package manager: ${manager}"
      ;;
  esac
}

ensure_local_dependency() {
  local binary="$1"
  local package_name="${2:-$1}"

  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi

  install_system_package "$package_name"
  command -v "$binary" >/dev/null 2>&1 || fail "required command not found after install attempt: ${binary}"
}

ensure_openssh_clients() {
  if command -v ssh >/dev/null 2>&1 && command -v scp >/dev/null 2>&1; then
    return 0
  fi

  install_system_package "$(openssh_client_package_name)"
  command -v ssh >/dev/null 2>&1 || fail "ssh is still unavailable after install attempt"
  command -v scp >/dev/null 2>&1 || fail "scp is still unavailable after install attempt"
}

python_yaml_available() {
  python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
}

ensure_python_yaml() {
  python_yaml_available && return 0

  local manager
  manager="$(detect_package_manager)" || fail "python3 yaml module is missing and no package manager is available"

  case "$manager" in
    apt-get)
      install_system_package python3-yaml
      ;;
    dnf|yum)
      install_system_package python3-PyYAML
      ;;
    zypper)
      install_system_package python3-PyYAML
      ;;
    apk)
      install_system_package py3-yaml
      ;;
    *)
      fail "cannot install PyYAML automatically with package manager ${manager}"
      ;;
  esac

  python_yaml_available && return 0

  if command -v pip3 >/dev/null 2>&1; then
    log "falling back to pip3 install --user PyYAML"
    pip3 install --user PyYAML >/dev/null
  else
    fail "PyYAML is unavailable and pip3 is not installed"
  fi

  python_yaml_available
}

check_yaml_dependencies() {
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse YAML"
  python_yaml_available || fail "python3 PyYAML is required to parse YAML"
}

prepare_yaml_dependencies() {
  ensure_local_dependency python3
  ensure_python_yaml || fail "failed to prepare python yaml support"
}

prepare_remote_dependencies() {
  ensure_openssh_clients
}

validate_inputs() {
  [[ -f "$CONFIG_FILE" ]] || fail "config file not found: ${CONFIG_FILE}"
  [[ -f "$LOCAL_STRESS_SCRIPT" ]] || fail "local stress script not found: ${LOCAL_STRESS_SCRIPT}"
}

parse_inventory() {
  python3 - "$CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

import yaml

config_path = Path(sys.argv[1])
data = yaml.safe_load(config_path.read_text(encoding="utf-8")) or {}
defaults = data.get("defaults") or {}
servers = data.get("servers") or []

if not isinstance(defaults, dict):
    raise SystemExit("defaults must be a mapping")
if not isinstance(servers, list):
    raise SystemExit("servers must be a list")

normalized = []
for idx, server in enumerate(servers, start=1):
    if not isinstance(server, dict):
        raise SystemExit(f"servers[{idx}] must be a mapping")

    merged = dict(defaults)
    merged.update(server)

    enabled = merged.get("enabled", True)
    if isinstance(enabled, str):
        enabled_text = enabled.strip().lower()
        if enabled_text in {"1", "true", "yes", "on"}:
            enabled = True
        elif enabled_text in {"0", "false", "no", "off"}:
            enabled = False
        else:
            raise SystemExit(f"servers[{idx}] has invalid enabled value: {enabled}")
    else:
        enabled = bool(enabled)

    merged["enabled"] = enabled
    merged["name"] = str(merged.get("name") or merged.get("host") or f"server-{idx}")

    host = merged.get("host")
    user = merged.get("user")
    password = merged.get("password")
    port = merged.get("port", 22)

    if not host:
        raise SystemExit(f"servers[{idx}] missing required field: host")
    if not user:
        raise SystemExit(f"server {host} missing required field: user")
    try:
        port = int(port)
    except Exception as exc:
        raise SystemExit(f"server {host} has invalid port: {port}") from exc

    merged["host"] = str(host)
    merged["user"] = str(user)
    merged["password"] = "" if password is None else str(password)
    merged["port"] = port
    normalized.append(merged)

print(json.dumps(normalized, ensure_ascii=False))
PY
}

schedule_time_for_index() {
  local server_index="$1"
  local slot_index start_offset total_minutes hour minute

  slot_index=$(( server_index / MAX_PARALLEL_PER_SLOT ))
  start_offset=$(( slot_index * SLOT_MINUTES ))
  total_minutes=$(( WINDOW_START_HOUR * 60 + start_offset ))
  hour=$(( total_minutes / 60 ))
  minute=$(( total_minutes % 60 ))

  printf '%02d %02d\n' "$minute" "$hour"
}

run_remote_command() {
  local password="$1"
  local port="$2"
  local user="$3"
  local host="$4"
  local command="$5"

  if [[ -n "$password" ]]; then
    SSHPASS="$password" sshpass -e ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -p "$port" \
      "${user}@${host}" \
      "$command"
  else
    ssh \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -p "$port" \
      "${user}@${host}" \
      "$command"
  fi
}

copy_remote_file() {
  local password="$1"
  local port="$2"
  local user="$3"
  local host="$4"
  local source_file="$5"
  local dest_file="$6"

  if [[ -n "$password" ]]; then
    SSHPASS="$password" sshpass -e scp \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -P "$port" \
      "$source_file" \
      "${user}@${host}:${dest_file}"
  else
    scp \
      -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null \
      -o ConnectTimeout=10 \
      -P "$port" \
      "$source_file" \
      "${user}@${host}:${dest_file}"
  fi
}

configure_remote_cron() {
  local password="$1"
  local port="$2"
  local user="$3"
  local host="$4"
  local cron_minute="$5"
  local cron_hour="$6"
  local cron_line="${cron_minute} ${cron_hour} * * * ${REMOTE_SCRIPT_PATH} >> ${REMOTE_LOG_PATH} 2>&1"
  local escaped_cron_line

  escaped_cron_line="$(printf '%q' "$cron_line")"
  run_remote_command "$password" "$port" "$user" "$host" \
    "tmp_file=\$(mktemp) && (crontab -l 2>/dev/null | grep -vF '${REMOTE_SCRIPT_PATH}' || true; printf '%s\n' ${escaped_cron_line}) > \"\$tmp_file\" && crontab \"\$tmp_file\" && rm -f \"\$tmp_file\""
}

deploy_one_server() {
  local name="$1"
  local host="$2"
  local user="$3"
  local password="$4"
  local port="$5"
  local cron_minute="$6"
  local cron_hour="$7"

  log "deploying to ${name} (${user}@${host}:${port}) with schedule ${cron_hour}:${cron_minute}"

  if (( DRY_RUN == 1 )); then
    return 0
  fi

  run_remote_command "$password" "$port" "$user" "$host" "mkdir -p '${REMOTE_SCRIPT_DIR}'"
  copy_remote_file "$password" "$port" "$user" "$host" "$LOCAL_STRESS_SCRIPT" "$REMOTE_SCRIPT_PATH"
  run_remote_command "$password" "$port" "$user" "$host" "chmod 700 '${REMOTE_SCRIPT_PATH}'"
  configure_remote_cron "$password" "$port" "$user" "$host" "$cron_minute" "$cron_hour"
}

main() {
  parse_args "$@"
  validate_inputs

  if (( DRY_RUN == 1 )); then
    check_yaml_dependencies
  else
    prepare_yaml_dependencies
  fi

  local inventory_json
  inventory_json="$(parse_inventory)" || fail "failed to parse inventory"

  mapfile -t server_rows < <(
    python3 - <<'PY' "$inventory_json"
import json
import sys

servers = json.loads(sys.argv[1])
enabled = [server for server in servers if server.get("enabled", True)]
print(len(enabled))
for server in enabled:
    print("\x1f".join([
        server["name"],
        server["host"],
        server["user"],
        server["password"],
        str(server["port"]),
    ]))
PY
  )

  [[ ${#server_rows[@]} -ge 1 ]] || fail "no enabled servers found in ${CONFIG_FILE}"

  local enabled_count="${server_rows[0]}"
  local max_slots total_window_minutes max_supported
  total_window_minutes=$(( (WINDOW_END_HOUR - WINDOW_START_HOUR) * 60 ))
  max_slots=$(( total_window_minutes / SLOT_MINUTES ))
  max_supported=$(( max_slots * MAX_PARALLEL_PER_SLOT ))

  if (( enabled_count > max_supported )); then
    fail "enabled server count ${enabled_count} exceeds max supported ${max_supported} for the ${WINDOW_START_HOUR}:00-${WINDOW_END_HOUR}:00 window with ${MAX_PARALLEL_PER_SLOT} servers per ${SLOT_MINUTES}-minute slot"
  fi

  if (( DRY_RUN == 0 )); then
    prepare_remote_dependencies

    if python3 - <<'PY' "$inventory_json"; then
import json
import sys

servers = json.loads(sys.argv[1])
raise SystemExit(0 if any(server.get("enabled", True) and server.get("password") for server in servers) else 1)
PY
      ensure_local_dependency sshpass
    fi
  fi

  local index row name host user password port cron_minute cron_hour
  for (( index = 1; index < ${#server_rows[@]}; index++ )); do
    IFS=$'\x1f' read -r name host user password port <<<"${server_rows[index]}"
    read -r cron_minute cron_hour < <(schedule_time_for_index $(( index - 1 )))
    deploy_one_server "$name" "$host" "$user" "$password" "$port" "$cron_minute" "$cron_hour"
  done

  log "processed ${enabled_count} enabled server(s)"
}

main "$@"
