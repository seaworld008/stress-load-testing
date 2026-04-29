#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${CONFIG_FILE:-${SCRIPT_DIR}/servers.yaml}"
LOCAL_STRESS_SCRIPT="${LOCAL_STRESS_SCRIPT:-${SCRIPT_DIR}/load_stress.sh}"
REMOTE_SCRIPT_DIR="/root/scripts"
REMOTE_SCRIPT_PATH="${REMOTE_SCRIPT_DIR}/load_stress.sh"
REMOTE_LOG_PATH="/var/log/load_stress.log"
WINDOW_START="01:00"
WINDOW_END="03:00"
WINDOW_START_MINUTES=60
WINDOW_END_MINUTES=180
SLOT_MINUTES=15
MAX_PARALLEL_PER_SLOT=2
DURATION_SECONDS=900
CPU_DIVISOR=2
VM_WORKERS=1
VM_PERCENT=15
VM_MIN_MB=256
VM_MAX_MB=8192
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

prepare_remote_dependencies() {
  ensure_openssh_clients
}

validate_inputs() {
  [[ -f "$CONFIG_FILE" ]] || fail "config file not found: ${CONFIG_FILE}"
  [[ -f "$LOCAL_STRESS_SCRIPT" ]] || fail "local stress script not found: ${LOCAL_STRESS_SCRIPT}"
}

parse_config() {
  awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }

    function scalar(value) {
      value = trim(value)
      if (value == "\"\"") {
        return ""
      }
      if (value ~ /^".*"$/ || value ~ /^\047.*\047$/) {
        value = substr(value, 2, length(value) - 2)
      }
      return value
    }

    function bool_value(value, server_index) {
      value = tolower(scalar(value))
      if (value == "" || value == "1" || value == "true" || value == "yes" || value == "on") {
        return "true"
      }
      if (value == "0" || value == "false" || value == "no" || value == "off") {
        return "false"
      }
      printf "servers[%d] has invalid enabled value: %s\n", server_index, value > "/dev/stderr"
      exit 1
    }

    function emit_setting(key, value) {
      printf "setting\037%s\037%s\n", key, value
    }

    function reset_server() {
      name = ""
      host = ""
      user = default_user
      port = default_port
      password = default_password
      enabled = default_enabled
    }

    function emit_server() {
      if (!in_server) {
        return
      }

      if (host == "") {
        printf "servers[%d] missing required field: host\n", server_index > "/dev/stderr"
        exit 1
      }
      if (user == "") {
        printf "server %s missing required field: user\n", host > "/dev/stderr"
        exit 1
      }
      if (port !~ /^[0-9]+$/) {
        printf "server %s has invalid port: %s\n", host, port > "/dev/stderr"
        exit 1
      }

      if (name == "") {
        name = host
      }

      if (enabled == "true") {
        printf "server\037%s\037%s\037%s\037%s\037%s\n", name, host, user, password, port
      }
    }

    BEGIN {
      section = ""
      in_server = 0
      server_index = 0
      default_user = "root"
      default_port = "22"
      default_password = ""
      default_enabled = "true"
    }

    /^[[:space:]]*($|#)/ {
      next
    }

    /^[^[:space:]][^:]*:[[:space:]]*$/ {
      key = trim(substr($0, 1, index($0, ":") - 1))
      if (key == "settings" || key == "defaults" || key == "servers") {
        if (key == "servers") {
          emit_server()
          in_server = 0
        }
        section = key
      }
      next
    }

    section == "settings" && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ {
      key = trim(substr($0, 1, index($0, ":") - 1))
      value = scalar(substr($0, index($0, ":") + 1))
      emit_setting(key, value)
      next
    }

    section == "defaults" && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ {
      key = trim(substr($0, 1, index($0, ":") - 1))
      value = scalar(substr($0, index($0, ":") + 1))

      if (key == "user") {
        default_user = value
      } else if (key == "port") {
        default_port = value
      } else if (key == "password") {
        default_password = value
      } else if (key == "enabled") {
        default_enabled = bool_value(value, 0)
      }
      next
    }

    section == "servers" && /^[[:space:]]*-[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*:/ {
      emit_server()
      server_index++
      in_server = 1
      reset_server()

      line = $0
      sub(/^[[:space:]]*-[[:space:]]*/, "", line)
      key = trim(substr(line, 1, index(line, ":") - 1))
      value = scalar(substr(line, index(line, ":") + 1))

      if (key == "name") {
        name = value
      } else if (key == "host") {
        host = value
      } else if (key == "user") {
        user = value
      } else if (key == "port") {
        port = value
      } else if (key == "password") {
        password = value
      } else if (key == "enabled") {
        enabled = bool_value(value, server_index)
      }
      next
    }

    section == "servers" && in_server && /^[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*:/ {
      key = trim(substr($0, 1, index($0, ":") - 1))
      value = scalar(substr($0, index($0, ":") + 1))

      if (key == "name") {
        name = value
      } else if (key == "host") {
        host = value
      } else if (key == "user") {
        user = value
      } else if (key == "port") {
        port = value
      } else if (key == "password") {
        password = value
      } else if (key == "enabled") {
        enabled = bool_value(value, server_index)
      }
      next
    }

    END {
      emit_server()
    }
  ' "$CONFIG_FILE"
}

is_integer() {
  [[ "${1:-}" =~ ^[0-9]+$ ]]
}

validate_integer_setting() {
  local name="$1"
  local value="$2"
  local min="$3"

  is_integer "$value" || fail "${name} must be an integer: ${value}"
  (( 10#$value >= min )) || fail "${name} must be >= ${min}: ${value}"
}

time_to_minutes() {
  local name="$1"
  local value="$2"
  local hour minute

  [[ "$value" =~ ^([0-9]{1,2}):([0-9]{2})$ ]] || fail "${name} must use HH:MM format: ${value}"
  hour="${BASH_REMATCH[1]}"
  minute="${BASH_REMATCH[2]}"

  is_integer "$hour" || fail "${name} has invalid hour: ${value}"
  is_integer "$minute" || fail "${name} has invalid minute: ${value}"
  (( hour >= 0 && hour <= 23 )) || fail "${name} hour must be 00-23: ${value}"
  (( minute >= 0 && minute <= 59 )) || fail "${name} minute must be 00-59: ${value}"

  printf '%s\n' $(( 10#$hour * 60 + 10#$minute ))
}

apply_setting() {
  local key="$1"
  local value="$2"

  case "$key" in
    window_start)
      WINDOW_START="$value"
      ;;
    window_end)
      WINDOW_END="$value"
      ;;
    slot_minutes)
      SLOT_MINUTES="$value"
      ;;
    max_parallel_per_slot)
      MAX_PARALLEL_PER_SLOT="$value"
      ;;
    duration_seconds)
      DURATION_SECONDS="$value"
      ;;
    cpu_divisor)
      CPU_DIVISOR="$value"
      ;;
    vm_workers)
      VM_WORKERS="$value"
      ;;
    vm_percent)
      VM_PERCENT="$value"
      ;;
    vm_min_mb)
      VM_MIN_MB="$value"
      ;;
    vm_max_mb)
      VM_MAX_MB="$value"
      ;;
    *)
      fail "unknown settings key: ${key}"
      ;;
  esac
}

validate_settings() {
  validate_integer_setting slot_minutes "$SLOT_MINUTES" 1
  validate_integer_setting max_parallel_per_slot "$MAX_PARALLEL_PER_SLOT" 1
  validate_integer_setting duration_seconds "$DURATION_SECONDS" 1
  validate_integer_setting cpu_divisor "$CPU_DIVISOR" 1
  validate_integer_setting vm_workers "$VM_WORKERS" 0
  validate_integer_setting vm_percent "$VM_PERCENT" 0
  validate_integer_setting vm_min_mb "$VM_MIN_MB" 0
  validate_integer_setting vm_max_mb "$VM_MAX_MB" 1

  (( VM_MAX_MB >= VM_MIN_MB )) || fail "vm_max_mb must be >= vm_min_mb"

  WINDOW_START_MINUTES="$(time_to_minutes window_start "$WINDOW_START")"
  WINDOW_END_MINUTES="$(time_to_minutes window_end "$WINDOW_END")"
  if (( WINDOW_END_MINUTES <= WINDOW_START_MINUTES )); then
    WINDOW_END_MINUTES=$(( WINDOW_END_MINUTES + 1440 ))
  fi

  (( WINDOW_END_MINUTES > WINDOW_START_MINUTES )) || fail "window_end must be later than window_start"
}

schedule_time_for_index() {
  local server_index="$1"
  local slot_index start_offset total_minutes hour minute

  slot_index=$(( server_index / MAX_PARALLEL_PER_SLOT ))
  start_offset=$(( slot_index * SLOT_MINUTES ))
  total_minutes=$(( (WINDOW_START_MINUTES + start_offset) % 1440 ))
  hour=$(( total_minutes / 60 ))
  minute=$(( total_minutes % 60 ))

  printf '%02d %02d\n' "$minute" "$hour"
}

remote_stress_env() {
  printf 'DURATION_SECONDS=%q CPU_DIVISOR=%q VM_WORKERS=%q VM_PERCENT=%q VM_MIN_MB=%q VM_MAX_MB=%q' \
    "$DURATION_SECONDS" "$CPU_DIVISOR" "$VM_WORKERS" "$VM_PERCENT" "$VM_MIN_MB" "$VM_MAX_MB"
}

inventory_needs_sshpass() {
  local row name host user password port

  for row in "$@"; do
    IFS=$'\x1f' read -r name host user password port <<<"$row"
    if [[ -n "$password" ]]; then
      return 0
    fi
  done

  return 1
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
  local cron_line="${cron_minute} ${cron_hour} * * * $(remote_stress_env) ${REMOTE_SCRIPT_PATH} >> ${REMOTE_LOG_PATH} 2>&1"
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

  local config_tmp
  config_tmp="$(mktemp)"
  if ! parse_config >"$config_tmp"; then
    rm -f "$config_tmp"
    fail "failed to parse config"
  fi

  local config_row row_type setting_key setting_value server_name host user password port
  local server_rows=()
  while IFS=$'\x1f' read -r row_type setting_key setting_value server_name host user password port; do
    case "$row_type" in
      setting)
        apply_setting "$setting_key" "$setting_value"
        ;;
      server)
        server_rows+=("${setting_key}"$'\x1f'"${setting_value}"$'\x1f'"${server_name}"$'\x1f'"${host}"$'\x1f'"${user}")
        ;;
      "")
        ;;
      *)
        rm -f "$config_tmp"
        fail "unknown parsed config row: ${row_type}"
        ;;
    esac
  done <"$config_tmp"
  rm -f "$config_tmp"

  validate_settings

  [[ ${#server_rows[@]} -ge 1 ]] || fail "no enabled servers found in ${CONFIG_FILE}"

  local enabled_count="${#server_rows[@]}"
  local max_slots total_window_minutes max_supported
  total_window_minutes=$(( WINDOW_END_MINUTES - WINDOW_START_MINUTES ))
  max_slots=$(( total_window_minutes / SLOT_MINUTES ))
  max_supported=$(( max_slots * MAX_PARALLEL_PER_SLOT ))

  if (( enabled_count > max_supported )); then
    fail "enabled server count ${enabled_count} exceeds max supported ${max_supported} for the ${WINDOW_START}-${WINDOW_END} window with ${MAX_PARALLEL_PER_SLOT} servers per ${SLOT_MINUTES}-minute slot"
  fi

  log "schedule window ${WINDOW_START}-${WINDOW_END}, slot=${SLOT_MINUTES}m, max_parallel=${MAX_PARALLEL_PER_SLOT}, duration=${DURATION_SECONDS}s"

  if (( DRY_RUN == 0 )); then
    prepare_remote_dependencies

    if inventory_needs_sshpass "${server_rows[@]}"; then
      ensure_local_dependency sshpass
    fi
  fi

  local index row name host user password port cron_minute cron_hour
  for (( index = 0; index < ${#server_rows[@]}; index++ )); do
    IFS=$'\x1f' read -r name host user password port <<<"${server_rows[index]}"
    read -r cron_minute cron_hour < <(schedule_time_for_index "$index")
    deploy_one_server "$name" "$host" "$user" "$password" "$port" "$cron_minute" "$cron_hour"
  done

  log "processed ${enabled_count} enabled server(s)"
}

main "$@"
