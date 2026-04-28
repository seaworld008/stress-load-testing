# Load Stress Deployment Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a reusable batch deployment workflow for managed load-test cron jobs.

**Architecture:** Keep the remote stress logic in one managed shell script and the fan-out deployment logic in a separate shell script. Use YAML for inventory, embedded Python for parsing, and deterministic slot assignment to limit concurrency.

**Tech Stack:** Bash, Python 3, PyYAML, sshpass, ssh, scp, cron, Linux package managers

---

### Task 1: Create the managed remote stress script

**Files:**
- Create: `scripts/load_stress.sh`

**Step 1: Write the script header and safety guards**

- Add `#!/usr/bin/env bash`
- Add `set -Eeuo pipefail`
- Require root

**Step 2: Add dependency installation logic**

- Check for `stress`
- If missing, install via `apt-get`, `dnf`, `yum`, `zypper`, or `apk`

**Step 3: Add resource detection**

- Read CPU core count via `nproc --all` or `getconf`
- Read RAM via `/proc/meminfo`
- Compute half-core CPU load with minimum 1
- Compute memory load from total RAM with safe caps

**Step 4: Add execution and locking**

- Prevent overlapping runs with a lock directory
- Execute `stress` for 900 seconds
- Log the exact parameters used

### Task 2: Create the batch deployment script

**Files:**
- Create: `scripts/deploy_load_stress.sh`

**Step 1: Add argument parsing**

- Support `--config <path>`
- Support `--script <path>`
- Support `--dry-run`

**Step 2: Add local dependency checks**

- Validate `ssh`, `scp`, `sshpass`, `python3`
- Ensure `yaml` Python module is available or install it

**Step 3: Add YAML parsing and validation**

- Merge `defaults` into `servers`
- Ignore disabled hosts
- Validate required fields such as `host`, `user`, `password`, `port`

**Step 4: Add schedule assignment**

- Use 15-minute slots from `01:00` to `02:45`
- Assign at most 2 enabled servers per slot
- Fail if enabled servers exceed 16

**Step 5: Add remote deployment**

- Create `/root/scripts`
- Upload the managed stress script
- Set `chmod 700`
- Replace cron entries referencing `/root/scripts/load_stress.sh`

### Task 3: Add operator-facing configuration examples

**Files:**
- Create: `scripts/servers.yaml.example`

**Step 1: Add the baseline example**

- Shared password in `defaults`
- Four enabled servers

**Step 2: Add common override examples as comments**

- Per-host password override
- Per-host SSH port override
- Disabled host
- Passwords with special characters

### Task 4: Verify shell syntax

**Files:**
- Verify: `scripts/load_stress.sh`
- Verify: `scripts/deploy_load_stress.sh`

**Step 1: Run shell syntax checks**

Run: `bash -n scripts/load_stress.sh`
Expected: exit 0

Run: `bash -n scripts/deploy_load_stress.sh`
Expected: exit 0

**Step 2: Summarize usage**

- Explain which files to edit
- Explain how to run the deploy script
- Explain the 16-server concurrency limit
