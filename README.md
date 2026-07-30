# Cycling Infrastructure

This repository is the source of truth for rebuilding and operating `cycling-prod`, the Raspberry Pi 5 production host for the cycling platform.

Production runs MariaDB 11 as a long-running Docker Compose service and `cycling-platform` as ephemeral Compose jobs. Cron runs daily ingestion, transformation, and publication at 02:00 and deep validation at 03:30.

MariaDB contains five schemas:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_stage`
- `cycling_platform_silver`
- `cycling_platform_gold`

`cycling_platform_stage` is disposable. Database backups run off-host on the Mac at 05:00 and include admin, raw, silver, and gold only.

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

Bootstrap installs and verifies current host prerequisites but intentionally leaves production cron disabled. Install cron explicitly with `./scripts/install_cron.sh` only after secrets, data, and application validation are complete.

## Production paths

- Repository: `/home/tim/cycling-infrastructure`
- Compose project: `/home/tim/cycling-infrastructure/compose`
- MariaDB data: `/srv/cycling/data/mariadb`
- Platform logs: `/srv/cycling/logs/platform`
- Mutable runtime credentials: `/srv/cycling/config/platform/runtime.Renviron`

Copy `compose/.env.example` to `compose/.env` and populate deployment credentials on the host. Bootstrap creates the separate, writable `runtime.Renviron` mount used for rotating OAuth refresh tokens without overwriting existing contents. Both files are outside Git and require an approved off-host recovery source.

See [docs/operations-guide.md](docs/operations-guide.md) for normal operating procedures. For total host loss, use the [bootstrap and disaster-recovery runbook](docs/bootstrap-runbook.md).
