#!/usr/bin/env bash

set -Eeuo pipefail

# Edit this block on the intranet control host.
# Format: name|host|user|port|password|enabled
# Leave password empty to use SSH key authentication. Passwords cannot contain "|".
read -r -d '' SERVER_INVENTORY <<'EOF' || true
pressure-node-01|192.0.2.11|root|22||true
pressure-node-02|192.0.2.12|root|22||true
pressure-node-03|192.0.2.13|root|22||true
pressure-node-04|192.0.2.14|root|22||true
EOF

REMOTE_SCRIPT_DIR="/root/scripts"
REMOTE_SCRIPT_PATH="${REMOTE_SCRIPT_DIR}/load_stress.sh"
REMOTE_LOG_PATH="/var/log/load_stress.log"

WINDOW_START_HOUR=1
WINDOW_END_HOUR=3
SLOT_MINUTES=15
MAX_PARALLEL_PER_SLOT=2
DRY_RUN=0

SSH_OPTIONS=(
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
  -o ConnectTimeout=10
)

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
  load_stress_distribute.sh [--dry-run]

This single script:
  1. keeps the server inventory in the script itself
  2. renders the remote load_stress.sh payload
  3. uploads it to each enabled server
  4. installs/replaces the managed cron entry

Options:
  --dry-run   Print computed deployment actions without connecting to servers.
  -h, --help  Show this help message.
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
  for manager in dnf yum apt-get zypper apk; do
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

ensure_command() {
  local binary="$1"
  local package="${2:-$1}"

  if command -v "$binary" >/dev/null 2>&1; then
    return 0
  fi

  install_system_package "$package"
  command -v "$binary" >/dev/null 2>&1 || fail "required command not found after install attempt: ${binary}"
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

ensure_local_dependencies() {
  ensure_command ssh "$(openssh_client_package_name)"

  if inventory_needs_sshpass; then
    ensure_command sshpass sshpass
  fi
}

inventory_needs_sshpass() {
  local line name host user port password enabled
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -n "${line//[[:space:]]/}" ]] || continue
    IFS='|' read -r name host user port password enabled extra <<<"$line"
    enabled="$(normalize_enabled "$enabled")"
    if [[ "$enabled" == "true" && -n "${password:-}" ]]; then
      return 0
    fi
  done <<<"$SERVER_INVENTORY"

  return 1
}

normalize_enabled() {
  local value="${1:-true}"
  value="${value,,}"
  case "$value" in
    1|true|yes|on|"")
      printf 'true\n'
      ;;
    0|false|no|off)
      printf 'false\n'
      ;;
    *)
      fail "invalid enabled value: ${1}"
      ;;
  esac
}

parse_inventory_rows() {
  local line name host user port password enabled extra
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -n "${line//[[:space:]]/}" ]] || continue

    IFS='|' read -r name host user port password enabled extra <<<"$line"
    [[ -z "${extra:-}" ]] || fail "inventory line has too many fields: ${line}"

    name="${name:-$host}"
    user="${user:-root}"
    port="${port:-22}"
    enabled="$(normalize_enabled "$enabled")"

    [[ -n "$host" ]] || fail "inventory line missing host: ${line}"
    [[ -n "$user" ]] || fail "inventory line missing user for host ${host}"
    [[ "$port" =~ ^[0-9]+$ ]] || fail "invalid SSH port for host ${host}: ${port}"

    if [[ "$enabled" == "true" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\n' "$name" "$host" "$user" "$port" "${password:-}"
    fi
  done <<<"$SERVER_INVENTORY"
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
    SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$port" "${user}@${host}" "$command"
  else
    ssh "${SSH_OPTIONS[@]}" -p "$port" "${user}@${host}" "$command"
  fi
}

stream_remote_script() {
  local password="$1"
  local port="$2"
  local user="$3"
  local host="$4"

  if [[ -n "$password" ]]; then
    render_remote_script | SSHPASS="$password" sshpass -e ssh "${SSH_OPTIONS[@]}" -p "$port" "${user}@${host}" \
      "mkdir -p '${REMOTE_SCRIPT_DIR}' && cat > '${REMOTE_SCRIPT_PATH}' && chmod 700 '${REMOTE_SCRIPT_PATH}'"
  else
    render_remote_script | ssh "${SSH_OPTIONS[@]}" -p "$port" "${user}@${host}" \
      "mkdir -p '${REMOTE_SCRIPT_DIR}' && cat > '${REMOTE_SCRIPT_PATH}' && chmod 700 '${REMOTE_SCRIPT_PATH}'"
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
  local port="$4"
  local password="$5"
  local cron_minute="$6"
  local cron_hour="$7"

  log "deploying to ${name} (${user}@${host}:${port}) with schedule ${cron_hour}:${cron_minute}"

  if (( DRY_RUN == 1 )); then
    return 0
  fi

  stream_remote_script "$password" "$port" "$user" "$host"
  configure_remote_cron "$password" "$port" "$user" "$host" "$cron_minute" "$cron_hour"
}

render_remote_script() {
  cat <<'REMOTE_SCRIPT'
#!/usr/bin/env bash

set -Eeuo pipefail

DURATION_SECONDS="${DURATION_SECONDS:-900}"
CPU_DIVISOR="${CPU_DIVISOR:-2}"
VM_WORKERS="${VM_WORKERS:-1}"
VM_PERCENT="${VM_PERCENT:-15}"
VM_MIN_MB="${VM_MIN_MB:-256}"
VM_MAX_MB="${VM_MAX_MB:-8192}"
LOCK_DIR="${LOCK_DIR:-/var/run/load_stress.lock}"

log() {
  printf '[%s] %s\n' "$(date '+%F %T')" "$*"
}

fail() {
  log "ERROR: $*"
  exit 1
}

require_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    fail "this script must run as root"
  fi
}

detect_package_manager() {
  local manager
  for manager in dnf yum apt-get zypper apk; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s\n' "$manager"
      return 0
    fi
  done
  return 1
}

install_stress_with_yum() {
  yum install -y stress && return 0

  log "stress install failed; trying epel-release first"
  yum install -y epel-release || return 1
  yum install -y stress
}

install_stress() {
  if command -v stress >/dev/null 2>&1; then
    return 0
  fi

  local manager
  manager="$(detect_package_manager)" || fail "cannot install stress automatically: no supported package manager found"

  log "stress not found; installing with ${manager}"
  case "$manager" in
    dnf)
      dnf install -y stress || {
        log "stress install failed; trying epel-release first"
        dnf install -y epel-release && dnf install -y stress
      }
      ;;
    yum)
      install_stress_with_yum
      ;;
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y stress
      ;;
    zypper)
      zypper --non-interactive install stress
      ;;
    apk)
      apk add --no-cache stress
      ;;
    *)
      fail "unsupported package manager: ${manager}"
      ;;
  esac

  command -v stress >/dev/null 2>&1 || fail "stress installation completed but command is still unavailable; check OS repository access"
}

detect_cpu_workers() {
  local cpu_cores cpu_workers

  if command -v nproc >/dev/null 2>&1; then
    cpu_cores="$(nproc --all)"
  else
    cpu_cores="$(getconf _NPROCESSORS_ONLN)"
  fi

  [[ "$cpu_cores" =~ ^[0-9]+$ ]] || fail "failed to detect CPU core count"

  cpu_workers=$(( cpu_cores / CPU_DIVISOR ))
  if (( cpu_workers < 1 )); then
    cpu_workers=1
  fi

  printf '%s\n' "$cpu_workers"
}

detect_vm_bytes_mb() {
  local total_kb total_mb vm_mb

  total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  [[ "$total_kb" =~ ^[0-9]+$ ]] || fail "failed to detect total memory"

  total_mb=$(( total_kb / 1024 ))
  vm_mb=$(( total_mb * VM_PERCENT / 100 ))

  if (( vm_mb < VM_MIN_MB )); then
    vm_mb=$VM_MIN_MB
  fi

  if (( vm_mb > VM_MAX_MB )); then
    vm_mb=$VM_MAX_MB
  fi

  if (( vm_mb >= total_mb )); then
    vm_mb=$(( total_mb / 2 ))
  fi

  if (( vm_mb < 128 )); then
    vm_mb=128
  fi

  printf '%s\n' "${vm_mb}M"
}

acquire_lock() {
  if mkdir "$LOCK_DIR" >/dev/null 2>&1; then
    trap 'rm -rf "$LOCK_DIR"' EXIT
    return 0
  fi

  fail "another load_stress job is already running"
}

main() {
  require_root
  acquire_lock
  install_stress

  local cpu_workers vm_bytes
  cpu_workers="$(detect_cpu_workers)"
  vm_bytes="$(detect_vm_bytes_mb)"

  log "starting stress test: cpu_workers=${cpu_workers}, vm_workers=${VM_WORKERS}, vm_bytes=${vm_bytes}, duration=${DURATION_SECONDS}s"
  stress --cpu "$cpu_workers" --vm "$VM_WORKERS" --vm-bytes "$vm_bytes" --timeout "$DURATION_SECONDS"
  log "stress test completed"
}

main "$@"
REMOTE_SCRIPT
}

main() {
  parse_args "$@"
  ensure_local_dependencies

  mapfile -t server_rows < <(parse_inventory_rows)
  [[ ${#server_rows[@]} -gt 0 ]] || fail "no enabled servers found in SERVER_INVENTORY"

  local enabled_count="${#server_rows[@]}"
  local total_window_minutes max_slots max_supported
  total_window_minutes=$(( (WINDOW_END_HOUR - WINDOW_START_HOUR) * 60 ))
  max_slots=$(( total_window_minutes / SLOT_MINUTES ))
  max_supported=$(( max_slots * MAX_PARALLEL_PER_SLOT ))

  if (( enabled_count > max_supported )); then
    fail "enabled server count ${enabled_count} exceeds max supported ${max_supported} for the ${WINDOW_START_HOUR}:00-${WINDOW_END_HOUR}:00 window with ${MAX_PARALLEL_PER_SLOT} servers per ${SLOT_MINUTES}-minute slot"
  fi

  local index row name host user port password cron_minute cron_hour
  for (( index = 0; index < ${#server_rows[@]}; index++ )); do
    IFS=$'\t' read -r name host user port password <<<"${server_rows[index]}"
    read -r cron_minute cron_hour < <(schedule_time_for_index "$index")
    deploy_one_server "$name" "$host" "$user" "$port" "$password" "$cron_minute" "$cron_hour"
  done

  log "processed ${enabled_count} enabled server(s)"
}

main "$@"
