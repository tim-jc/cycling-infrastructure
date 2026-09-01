# Production Architecture

`cycling-prod` is a Raspberry Pi 5 running Raspberry Pi OS Lite. Mac clients resolve it as `cycling-prod.local`.

```text
Mac (development and off-host backup only)
├── 05:00 off-host MariaDB backup
└── MariaDB clients ───────────────────────────► cycling-prod.local

cycling-prod cron
├── 02:00,20:00 platform refresh
├── 02:30,20:30 run_analytics_refresh.sh
│   ├── ephemeral cycling-analytics render
│   ├── validate /srv/cycling/data/analytics/output/
│   │   ├── index.html
│   │   └── index_files/
│   ├── ephemeral Cloudflare Pages publisher
│   │   └── cycling-analytics-8bs.pages.dev
│   └── success/failure notification
└── 03:30 platform validation
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

`cycling-analytics` is also an ephemeral Compose job on `cycling-prod`. It is
built and identified by `scripts/deploy_analytics.sh`, receives only its
dedicated runtime env file, connects to `mariadb:3306` through service discovery,
and writes the complete site (`index.html` plus `index_files/`) from
`/app/output` to `/srv/cycling/data/analytics/output` as host user `tim`.
Deployment builds the image and runs its offline Dockerfile smoke test;
it does not render the production dashboard. Manual production rendering is
owned by `scripts/run_analytics_refresh.sh`, which supplies a private transient
bind mount for application-derived notification context, captures outer logs,
validates fresh persistent output and owns operational notification. After a
valid render it invokes the ephemeral infrastructure-owned Cloudflare Pages
publisher, which uploads the complete output directory to project
`cycling-analytics` using pinned Node/Wrangler. The `tim` user's managed cron
block invokes this combined render-and-publish wrapper at 02:30 and 20:30,
independently of whether the preceding platform run completed successfully.
Cloudflare credentials remain in a protected host file and are never exposed to
the analytics application or peer Compose services. The Mac and Git are not in
the production render or publication path.

## Data lifecycle

Admin, Raw, Reference, Silver and Gold are durable and included in new off-host backups. Stage is disposable working data and is deliberately excluded. Historical four-file backups restore Reference as an empty canonical database.

Infrastructure is authoritative for physical database creation, database defaults and grants. `scripts/reconcile_reference_database.sh` handles existing volumes and verifies application access. `cycling-platform` owns all objects inside the databases. Backup creation and observability currently remain Mac-hosted platform responsibilities; infrastructure owns backup policy, guarded restore execution and recovery rehearsal.

Version-controlled Reference data is published automatically during platform deployment, after schema bootstrap/migrations and before final publication validation. Infrastructure invokes only the platform aggregate publisher and treats failure as deployment failure; platform owns its constituent datasets, parsing, transactions, reconciliation and validation. Reference publication is not part of scheduled ingestion.

The backup runs from the Mac rather than `cycling-prod`; database dumps are not stored permanently on the production host.

## Scheduling

Production scheduling uses the `tim` user's crontab on `cycling-prod`: platform
runs at 02:00 and 20:00, analytics at 02:30 and 20:30, and validation at 03:30.
`scripts/analytics_schedule.sh` is the single infrastructure source for the
analytics cron expression. There are no systemd application timers or services.
Infrastructure calculates the next occurrence and supplies display-only text as
`CYCLING_ANALYTICS_NEXT_REFRESH_TEXT`; the application does not own or interpret
the production schedule. The offsets are fixed times, not a dependency between
the platform and analytics jobs.
