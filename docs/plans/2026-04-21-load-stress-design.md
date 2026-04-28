# Load Stress Deployment Design

**Date:** 2026-04-21

## Goal

Provide a production-friendly batch deployment workflow that pushes a managed
`/root/scripts/load_stress.sh` to multiple Linux servers, replaces any older
version, and configures a deterministic cron schedule between `01:00` and
`03:00` with at most two concurrent stress jobs.

## Scope

- Manage the server inventory from a compact YAML file with shared defaults and
  per-host overrides.
- Deploy one managed remote script to `/root/scripts/load_stress.sh`.
- Replace any existing cron entries that reference
  `/root/scripts/load_stress.sh`.
- Let the remote script detect CPU and memory, install `stress` when missing,
  and run for 900 seconds.

## Design Decisions

### Configuration format

Use a YAML file with:

- `defaults`: shared values such as `user`, `port`, `password`, `enabled`
- `servers`: per-server entries with overrides

This keeps the file compact while safely supporting passwords with special
characters.

### Scheduling model

- Fixed load duration: 900 seconds
- Fixed allowed window: `01:00-03:00`
- Fixed slot size: 15 minutes
- Fixed concurrency cap: 2 servers per slot

The deploy script assigns schedules in the order servers appear in YAML. The
first two enabled servers get `01:00`, the next two get `01:15`, and so on.
This yields a maximum capacity of 16 servers in the 2-hour window. If the
enabled server count exceeds 16, deployment fails fast with a clear error.

### Remote load strategy

The managed remote script:

- ensures it is running as root
- installs `stress` if missing
- detects total CPU cores
- uses `floor(total_cores / 2)`, with a minimum of 1 worker
- detects total RAM from `/proc/meminfo`
- allocates one memory worker using 15% of total RAM, capped to a safe range
- runs for 900 seconds
- prevents overlapping runs with a lock directory

This keeps CPU pressure aligned to the requirement while keeping memory load
safer for production hosts than a flat `1G` setting.

### Deployment strategy

The batch deployment script:

- validates local dependencies (`sshpass`, `ssh`, `scp`, `python3`, PyYAML)
- reads and merges YAML configuration
- prints the computed schedule per server
- creates `/root/scripts` on the target
- uploads the new `load_stress.sh`
- sets execute permission
- removes previous cron entries for `/root/scripts/load_stress.sh`
- installs one fresh cron entry for the computed schedule

## Risks and Mitigations

- **Risk:** More than 16 enabled servers cannot fit in the `01:00-03:00`
  window while respecting the 2-server concurrency cap.
  **Mitigation:** fail fast and ask the operator to split groups or change the
  window policy.

- **Risk:** Deployment host lacks YAML support.
  **Mitigation:** attempt to install `python3-yaml`/`PyYAML` automatically.

- **Risk:** A production host lacks the `stress` package repository metadata.
  **Mitigation:** the remote script supports common Linux package managers and
  fails with a clear error if none can install `stress`.

## Outputs

- `scripts/load_stress.sh`
- `scripts/deploy_load_stress.sh`
- `scripts/servers.yaml.example`
