# Cycling Infrastructure

This repository is the source of truth for rebuilding and operating `cycling-prod`, the Raspberry Pi 5 production host for the cycling platform.

Production runs MariaDB 11 as a long-running Docker Compose service and `cycling-platform` as ephemeral Compose jobs. Cron runs daily ingestion, transformation, and publication at 02:00 and deep validation at 03:30.

MariaDB contains six peer databases:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_stage`
- `cycling_platform_silver`
- `cycling_platform_gold`
- `cycling_platform_reference`

`cycling_platform_stage` is disposable. Reference is durable even while empty. New off-host backups contain Admin, Raw, Reference, Silver and Gold; historical four-file sets without Reference remain restorable.

Mac clients connect through `cycling-prod.local`. `cycling-analytics` remains hosted and scheduled on the Mac.

## Repository layout

```text
compose/   Docker Compose definition and first-initialisation script
scripts/   Host bootstrap and cron entry points
docs/      Architecture, operations, baseline, and decisions
```

## Host bootstrap

After Raspberry Pi OS imaging and cloning this repository to its production path, run:

```bash
./scripts/bootstrap.sh
```

The bootstrap orchestrator runs deterministic numbered stages under `bootstrap/`: system update, package installation, Docker configuration, production-directory creation and final verification. If an OS update requires reboot, it exits with status `75` and prints the exact command to rerun after reconnecting. It never starts MariaDB, creates `compose/.env`, restores data or installs application cron.

Bootstrap installs and verifies current host prerequisites but intentionally leaves production cron disabled. Install cron explicitly with `./scripts/install_cron.sh` only after secrets, data, and application validation are complete.

Normal platform deployment uses `./scripts/deploy_platform.sh`. Success requires image build, quiet Compose validation, platform bootstrap/migrations, and publication validation. Deployment does not ingest data or change schedules.

## Production paths

- Repository: `/home/tim/cycling-infrastructure`
- Compose project: `/home/tim/cycling-infrastructure/compose`
- MariaDB data: `/srv/cycling/data/mariadb`
- Platform logs: `/srv/cycling/logs/platform`
- Mutable runtime credentials: `/srv/cycling/config/platform/runtime.Renviron`

Copy `compose/.env.example` to `compose/.env`, set mode `0600`, populate deployment credentials, and run `./scripts/preflight.sh` before MariaDB startup. Bootstrap creates the separate, writable `runtime.Renviron` credential file. Compose mounts its dedicated parent directory so the application can atomically replace the file without overwriting credentials during bootstrap. Both files are outside Git and require an approved off-host recovery source.

Manual age-encrypted runtime credential recovery uses `scripts/backup_runtime_credentials.sh`, `scripts/verify_runtime_credentials.sh`, and `scripts/restore_runtime_credentials.sh`. See [docs/runtime-credential-recovery.md](docs/runtime-credential-recovery.md); the scripts never print credential values.

Use `scripts/compose.sh` for Compose commands so containers receive the physical host identity dynamically. See [docs/operations-guide.md](docs/operations-guide.md) for normal operating procedures. For total host loss, use the [bootstrap and disaster-recovery runbook](docs/bootstrap-runbook.md).
