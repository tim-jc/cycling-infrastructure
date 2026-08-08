# Production Architecture

`cycling-prod` is a Raspberry Pi 5 running Raspberry Pi OS Lite. Mac clients resolve it as `cycling-prod.local`.

```text
Mac
├── cycling-analytics (Mac-hosted and Mac-scheduled)
├── 05:00 off-host MariaDB backup
└── MariaDB clients ───────────────► cycling-prod.local
                                      │
cycling-prod                          ├── cron
├── Docker Engine                    │   ├── 02:00 daily platform job
├── MariaDB 11 Compose service       │   └── 03:30 deep validation job
└── ephemeral cycling-platform jobs  └── persistent MariaDB data
```

## Compose services

`mariadb` is the only long-running application container. Its data is bind-mounted from `/srv/cycling/data/mariadb`. The entrypoint initialisation script creates the six platform databases only when MariaDB starts with an empty data directory:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_stage`
- `cycling_platform_silver`
- `cycling_platform_gold`
- `cycling_platform_reference`

`cycling-platform` runs as an ephemeral Compose job. Infrastructure initializes every project Compose operation through `scripts/compose_contract.sh`; the operator-facing `scripts/compose.sh` and database restore helper share it. The contract propagates the physical host short name dynamically as `CYCLING_PLATFORM_EXECUTION_HOST` for notifications and evidence and resolves the numeric UID/GID of the host `tim` account. This initialization also applies to MariaDB-only operations because Compose interpolates all services before selecting a target. Compose runs the platform job with the host identity so writes to bind mounts—including atomic runtime credential replacement and platform logs—remain owned by `tim`. It shares the Compose network with MariaDB, writes logs to `/srv/cycling/logs/platform`, and uses the dedicated writable directory bind mount `/srv/cycling/config/platform` → `/run/cycling-platform` for mutable OAuth refresh tokens. The file remains `/run/cycling-platform/runtime.Renviron`; mounting its parent permits crash-safe sibling-file replacement. Compose injects deployment credentials from `compose/.env`; the application owns updates to the mounted runtime file.

## Data lifecycle

Admin, Raw, Reference, Silver and Gold are durable and included in new off-host backups. Stage is disposable working data and is deliberately excluded. Historical four-file backups restore Reference as an empty canonical database.

Infrastructure is authoritative for physical database creation, database defaults and grants. `scripts/reconcile_reference_database.sh` handles existing volumes and verifies application access. `cycling-platform` owns all objects inside the databases. Backup creation and observability currently remain Mac-hosted platform responsibilities; infrastructure owns backup policy, guarded restore execution and recovery rehearsal.

The backup runs from the Mac rather than `cycling-prod`; database dumps are not stored permanently on the production host.

## Scheduling

Production scheduling uses the `tim` user's crontab on `cycling-prod`. There are no systemd application timers or services in this repository.
