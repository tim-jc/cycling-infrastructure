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

## Production paths

- Repository: `/home/tim/cycling-infrastructure`
- Compose project: `/home/tim/cycling-infrastructure/compose`
- MariaDB data: `/srv/cycling/data/mariadb`
- Platform logs: `/srv/cycling/logs/platform`

Copy `compose/.env.example` to `compose/.env` and populate the production credentials on the host. `.env` is ignored by Git.

See [docs/operations-guide.md](docs/operations-guide.md) for operating procedures.
