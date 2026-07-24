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

`mariadb` is the only long-running application container. Its data is bind-mounted from `/srv/cycling/data/mariadb`. The entrypoint initialisation script creates the five platform schemas only when MariaDB starts with an empty data directory:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_stage`
- `cycling_platform_silver`
- `cycling_platform_gold`

`cycling-platform` runs as an ephemeral Compose job. It shares the Compose network with MariaDB and writes logs to `/srv/cycling/logs/platform`.

## Data lifecycle

Admin, raw, silver, and gold are durable and included in the off-host backup. Stage is disposable working data and is deliberately excluded.

The backup runs from the Mac rather than `cycling-prod`; database dumps are not stored permanently on the production host.

## Scheduling

Production scheduling uses the `tim` user's crontab on `cycling-prod`. There are no systemd application timers or services in this repository.
