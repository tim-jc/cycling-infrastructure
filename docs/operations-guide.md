# Operations Guide

## Connect

```bash
ssh tim@cycling-prod.local
```

The production repository is `/home/tim/cycling-infrastructure`, and Compose commands run from `/home/tim/cycling-infrastructure/compose`.

## Bootstrap host directories

From the repository root:

```bash
./scripts/bootstrap.sh
```

This creates the MariaDB data and platform log directories under `/srv/cycling`. It is safe to rerun. Docker Engine and the Docker Compose plugin are host prerequisites; this repository does not install them.

## Configure

```bash
cd /home/tim/cycling-infrastructure
cp compose/.env.example compose/.env
chmod 600 compose/.env
docker compose --env-file compose/.env -f compose/docker-compose.yml config --quiet
```

Populate `compose/.env` with production credentials and tokens. Never commit it.

## Deploy and inspect

```bash
cd /home/tim/cycling-infrastructure/compose
docker compose up -d mariadb
docker compose ps
docker compose logs mariadb
docker compose build cycling-platform
```

Run jobs manually:

```bash
/home/tim/cycling-infrastructure/scripts/run_daily_platform.sh
/home/tim/cycling-infrastructure/scripts/run_platform_validation.sh
```

The MariaDB script under `compose/mariadb/init` runs only for a new, empty MariaDB data directory. It must not be used to recreate existing production data.

## Production cron

The `tim` user's crontab on `cycling-prod` schedules:

```cron
0 2 * * * /home/tim/cycling-infrastructure/scripts/run_daily_platform.sh
30 3 * * * /home/tim/cycling-infrastructure/scripts/run_platform_validation.sh
```

The wrappers prevent overlapping runs and append logs beneath `/home/tim/cycling-infrastructure/logs`.

```bash
crontab -l
tail -n 200 /home/tim/cycling-infrastructure/logs/platform_daily.log
tail -n 200 /home/tim/cycling-infrastructure/logs/platform_validation.log
```

## Backups

MariaDB backups deliberately run on the Mac at 05:00 using `cycling-platform/scripts/backup_mariadb.sh`. The script connects to `cycling-prod.local` and writes timestamped compressed dumps to Mac storage.

Backed up:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_silver`
- `cycling_platform_gold`

`cycling_platform_stage` is deliberately excluded because it is disposable. Backup configuration and retention belong to the Mac-side `cycling-platform` checkout. Periodically test restoring all four durable schemas into an isolated MariaDB instance.

## Consumers

Mac-hosted tools use `cycling-prod.local` as the MariaDB host. `cycling-analytics` remains hosted and scheduled on the Mac.
