# Stress Load Testing

Small Bash utilities for scheduling short CPU and memory stress jobs across a
group of Linux servers from one intranet control host.

The recommended entry point is:

```bash
./scripts/load_stress_distribute.sh --dry-run
./scripts/load_stress_distribute.sh
```

## What It Does

- Keeps a compact server inventory in one script.
- Uploads an embedded remote `load_stress.sh` payload to each enabled server.
- Configures a managed cron entry under `/root/scripts/load_stress.sh`.
- Schedules jobs between `01:00` and `03:00`.
- Limits concurrency to two servers per 15-minute slot.
- Runs `stress` for 900 seconds by default.

## Platform Notes

The scripts are written for Bash and common Linux server environments. They are
intended to work on CentOS 7 and Kylin V10 when the control host can SSH to the
target machines and the target package repositories provide `stress` or
`epel-release`.

Target servers should normally allow root SSH because the remote script writes
to `/root/scripts`, installs packages, updates root's crontab, and writes logs
under `/var/log`.

## Inventory

Edit the `SERVER_INVENTORY` block at the top of
`scripts/load_stress_distribute.sh`:

```text
name|host|user|port|password|enabled
pressure-node-01|192.0.2.11|root|22||true
```

Leave `password` empty to use SSH key authentication. If a password is present,
the control host needs `sshpass`.

`scripts/servers.yaml.example` is kept for the older two-script workflow. Keep
your real `scripts/servers.yaml` local; it is ignored by git.
