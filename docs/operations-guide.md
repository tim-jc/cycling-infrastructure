# Operations Guide

## Connect

```bash
ssh tim@cycling-prod.local
```

The production repository is `/home/tim/cycling-infrastructure`, and Compose commands run from `/home/tim/cycling-infrastructure/compose`.

## Bootstrap a fresh host

Raspberry Pi OS imaging remains manual. Configure the `tim` user, hostname `cycling-prod`, SSH access, and network during imaging. Install the seed packages with `sudo apt-get update && sudo apt-get install -y ca-certificates git`, then clone this repository to its production path.

Run the idempotent host bootstrap as `tim`:

```bash
cd /home/tim/cycling-infrastructure
./scripts/bootstrap.sh
```

Bootstrap verifies Debian/Raspberry Pi OS on ARM64, the expected user/home and hostname, installs required host utilities and cron, configures Docker Engine and the Compose plugin from Docker's official Debian repository when absent, enables Docker and cron, adds `tim` to the `docker` group, sets `Europe/London`, verifies `C.UTF-8`, and creates the production data/log paths.

If `tim` was newly added to the Docker group, log out and reconnect before running Docker without `sudo`.

Bootstrap deliberately does not install production cron. During disaster recovery, secrets and databases must be restored and validated before schedules resume.

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

Install cron only after production recovery and validation are complete:

```bash
cd /home/tim/cycling-infrastructure
./scripts/install_cron.sh --show
./scripts/install_cron.sh --dry-run
./scripts/install_cron.sh
```

The installer idempotently replaces only the marked `CYCLING_PLATFORM` block, removes duplicate managed blocks, and preserves unrelated entries. Its canonical block is:

```cron
# >>> CYCLING_PLATFORM_START >>>
0 2 * * * /home/tim/cycling-infrastructure/scripts/run_daily_platform.sh
30 3 * * * /home/tim/cycling-infrastructure/scripts/run_platform_validation.sh
# <<< CYCLING_PLATFORM_END <<<
```

Inspect scheduling and logs with:

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
