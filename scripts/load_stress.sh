#!/usr/bin/env bash

set -Eeuo pipefail

DURATION_SECONDS="${DURATION_SECONDS:-900}"
CPU_PERCENT="${CPU_PERCENT:-25}"
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
  for manager in apt-get dnf yum zypper apk; do
    if command -v "$manager" >/dev/null 2>&1; then
      printf '%s\n' "$manager"
      return 0
    fi
  done
  return 1
}

install_stress() {
  if command -v stress >/dev/null 2>&1; then
    return 0
  fi

  local manager
  manager="$(detect_package_manager)" || fail "cannot install stress automatically: no supported package manager found"

  log "stress not found; installing with ${manager}"
  case "$manager" in
    apt-get)
      DEBIAN_FRONTEND=noninteractive apt-get update -y
      DEBIAN_FRONTEND=noninteractive apt-get install -y stress
      ;;
    dnf)
      dnf install -y stress
      ;;
    yum)
      yum install -y stress
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

  command -v stress >/dev/null 2>&1 || fail "stress installation completed but command is still unavailable"
}

detect_cpu_workers() {
  local cpu_cores cpu_workers

  if command -v nproc >/dev/null 2>&1; then
    cpu_cores="$(nproc --all)"
  else
    cpu_cores="$(getconf _NPROCESSORS_ONLN)"
  fi

  [[ "$cpu_cores" =~ ^[0-9]+$ ]] || fail "failed to detect CPU core count"

  [[ "$CPU_PERCENT" =~ ^[0-9]+$ ]] || fail "CPU_PERCENT must be an integer"
  (( CPU_PERCENT <= 100 )) || fail "CPU_PERCENT must be <= 100"

  cpu_workers=$(( cpu_cores * CPU_PERCENT / 100 ))

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
  if (( cpu_workers > 0 )); then
    stress --cpu "$cpu_workers" --vm "$VM_WORKERS" --vm-bytes "$vm_bytes" --timeout "$DURATION_SECONDS"
  else
    stress --vm "$VM_WORKERS" --vm-bytes "$vm_bytes" --timeout "$DURATION_SECONDS"
  fi
  log "stress test completed"
}

main "$@"
