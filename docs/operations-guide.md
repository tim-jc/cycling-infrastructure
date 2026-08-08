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

This is the only supported bootstrap entry point. It runs the numbered scripts under `bootstrap/` in deterministic order and stops on the first failure. A system-update reboot request exits with status `75`; reboot, reconnect and rerun the same command. Do not invoke individual stages during normal recovery.

Bootstrap verifies Debian/Raspberry Pi OS on ARM64, the expected user/home and hostname, installs required host utilities and cron, configures Docker Engine and the Compose plugin from Docker's official Debian repository when absent, enables Docker and cron, adds `tim` to the `docker` group, sets `Europe/London`, verifies `C.UTF-8`, and creates the production data, log, and platform credential paths. It creates an empty owner-only `runtime.Renviron` only when absent and never replaces existing credential contents.

If `tim` was newly added to the Docker group, log out and reconnect before running Docker without `sudo`.

Bootstrap deliberately does not install production cron. During disaster recovery, secrets and databases must be restored and validated before schedules resume.

## Configure

```bash
cd /home/tim/cycling-infrastructure
[ ! -e compose/.env ] || { echo 'STOP: compose/.env already exists'; false; }
install -m 0600 compose/.env.example compose/.env
# Securely populate compose/.env before continuing; do not log its values.
./scripts/preflight.sh
./scripts/compose.sh config --quiet
```

Populate `compose/.env` with deployment configuration: MariaDB credentials/port, OAuth client IDs and client secrets, and `NTFY_TOPIC`. Refresh tokens do not belong in this file. Never commit it.

Bootstrap owns the filesystem contract for the mutable credential file:

```text
/srv/cycling/config/platform/runtime.Renviron
```

The file is owned by `tim` with mode `0600`. Its dedicated host directory is owned by `tim` with mode `0700` and is mounted read-write at `/run/cycling-platform`; both `R_ENVIRON_USER` and `CYCLING_PLATFORM_RENVIRON_PATH` continue to select `/run/cycling-platform/runtime.Renviron`. `cycling-platform` owns its contents and updates refresh-token keys through `update_renviron()`. Infrastructure must back up and restore the file without inspecting or logging its values. The directory must contain only `runtime.Renviron`, because every entry would be exposed to the container. A direct file bind mount is prohibited: the application writes a sibling temporary file and atomically renames it over the target, and Linux cannot rename over a file that is itself a bind-mount point.

Before starting application jobs, restore the current runtime file from the approved encrypted off-host source. If no valid Strava refresh token is recoverable, run the interactive OAuth helper from the Compose directory:

```bash
cd /home/tim/cycling-infrastructure
./scripts/compose.sh run --rm cycling-platform \
  Rscript scripts/bootstrap_strava_oauth.R
```

Verify the mount without printing credentials:

```bash
./scripts/compose.sh run --rm cycling-platform Rscript -e '
path <- Sys.getenv("R_ENVIRON_USER")
cat("runtime file exists=", file.exists(path), "\n", sep = "")
cat("runtime file writable=", file.access(path, 2) == 0, "\n", sep = "")
cat("Strava refresh token=", if (nzchar(Sys.getenv("STRAVA_REFRESH_TOKEN"))) "set" else "MISSING", "\n", sep = "")
cat("Google refresh token=", if (nzchar(Sys.getenv("GOOGLE_HEALTH_REFRESH_TOKEN"))) "set" else "MISSING", "\n", sep = "")
'
```

## Deploy and inspect

```bash
cd /home/tim/cycling-infrastructure
./scripts/start_mariadb.sh
./scripts/compose.sh ps
./scripts/compose.sh logs mariadb
./scripts/deploy_platform.sh
```

Run jobs manually:

```bash
/home/tim/cycling-infrastructure/scripts/run_daily_platform.sh
/home/tim/cycling-infrastructure/scripts/run_platform_validation.sh
```

The MariaDB script under `compose/mariadb/init` runs only for a new, empty MariaDB data directory. It must not be used to recreate existing production data.

For normal application upgrades, use `scripts/deploy_platform.sh`; it fetches origin and defaults to the freshly fetched `origin/main`. Supply `--ref BRANCH_TAG_OR_COMMIT` for deterministic recovery/rehearsal or a previously accepted SHA for rollback.

A completed deployment now has five mandatory stages:

1. build the `cycling-platform` image from the resolved commit;
2. run `docker compose config --quiet` without printing interpolated secrets;
3. require the existing MariaDB service to be healthy;
4. run `Rscript bootstrap_platform.R` through Compose, including checksum verification and unapplied migrations;
5. run `Rscript run_platform_validation.R --publication` through Compose.

The script stops at the first failure and reports the failed stage. Only after both gates pass does it print `Deployment ready`. Bootstrap is idempotent, but migrations can still be consequential; the checked-out code, built image, schema migrations, and publication checks form one compatibility unit. Deployment never runs ingestion, transformations, notifications, the daily pipeline, or cron installation. Schedule activation remains separate.

Deployment holds `/tmp/cycling-platform-deployment.lock`; the managed daily, validation, and database-restore wrappers refuse to overlap it. It also refuses existing managed-operation locks or a running platform Compose container. Secret-free evidence is appended to `/home/tim/cycling-infrastructure/logs/platform_deployment.log`, including timestamps, host, infrastructure/platform commits, image identity, and gate results.

Never run unqualified `docker compose config` into shared output because rendered environment values may contain secrets; use `./scripts/compose.sh config --quiet`.

All supported Compose invocations use `scripts/compose.sh`. It dynamically supplies the physical short hostname as `CYCLING_PLATFORM_EXECUTION_HOST`, avoiding Docker container IDs and hard-coded production names.

MariaDB initialization rejects empty and known-placeholder passwords. For an existing data directory, changing `.env` does not rotate database users. Follow [MariaDB credential rotation](mariadb-credential-rotation.md) for an explicit coordinated rotation.

### Guarded-entrypoint command contract

The official `mariadb:11` image defines `docker-entrypoint.sh` plus the default command `mariadbd`. When Compose replaces an image `ENTRYPOINT`, the resulting container must not rely on the image command being retained implicitly: an override can render with a null/empty command. Invoking the official entrypoint without `mariadbd` exits successfully and, with `restart: unless-stopped`, creates a `Restarting (0)` loop rather than a database process.

The infrastructure therefore enforces the command twice:

- Compose explicitly renders `command: [mariadbd]` alongside the guarded entrypoint.
- `guarded-entrypoint.sh` defaults an empty argument list to `mariadbd`, while preserving explicitly supplied arguments unchanged.

After deploying a change to this contract, verify without removing or altering the persistent data directory:

```bash
cd /home/tim/cycling-infrastructure
git status --short
./scripts/preflight.sh
./scripts/compose.sh config --quiet
./scripts/compose.sh up -d --no-deps mariadb
./scripts/compose.sh ps mariadb
docker inspect cycling-mariadb \
  --format 'entrypoint={{json .Config.Entrypoint}} command={{json .Config.Cmd}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}'
./scripts/compose.sh logs --tail=100 mariadb
```

The rendered/runtime command must contain `mariadbd`, the service must become healthy, and the existing-data warning may appear once at container startup. Repeated warning-only logs or `Restarting (0)` indicate that no long-running MariaDB command was launched; stop and inspect the rendered entrypoint/command contract.

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

Infrastructure owns operational backup policy and recovery expectations. The platform repository currently implements Mac-side dump creation and backup observability; this repository owns restore execution and recovery rehearsal.

Durable backup expectation:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_reference` (new five-file sets)
- `cycling_platform_silver`
- `cycling_platform_gold`

`cycling_platform_stage` is deliberately excluded because it is disposable. Backup configuration and retention belong to the Mac-side `cycling-platform` checkout. That repository must add Reference to its backup creation and observability before five-file sets are produced; until then, newly generated four-file sets are incomplete for the new policy even though retained historical four-file sets remain valid recovery inputs. Periodically test both restore formats in an isolated MariaDB instance.

## Reference database reconciliation

Fresh volumes receive Reference from MariaDB first initialization. Existing volumes do not rerun init scripts. After MariaDB is healthy, use:

```bash
./scripts/reconcile_reference_database.sh
./scripts/reconcile_reference_database.sh --check-only
```

The first command idempotently creates Reference if absent, corrects its database defaults and reconciles the configured application user's database-scoped grant. It does not alter table collations or create tables. Check-only changes nothing and fails if Reference is missing, incorrectly configured, inaccessible, missing the intended grant, or accompanied by an unintended global application-user privilege. `start_mariadb.sh` performs reconciliation; normal platform deployment requires the check-only gate.

Database dumps do not contain `/srv/cycling/config/platform/runtime.Renviron`. Use `scripts/backup_runtime_credentials.sh`, `scripts/verify_runtime_credentials.sh`, and `scripts/restore_runtime_credentials.sh` as described in [Runtime Credential Backup and Recovery](runtime-credential-recovery.md). Refresh and verify the encrypted copy after OAuth rotation/bootstrap. The approved Mac destination, age identity custody and responsible operator remain manual decisions; never copy plaintext into Git or ordinary logs.

## Consumers

Mac-hosted tools use `cycling-prod.local` as the MariaDB host. `cycling-analytics` remains hosted and scheduled on the Mac.

## Recovery evidence

Use [the bootstrap and recovery runbook](bootstrap-runbook.md) for the exact 13-phase sequence and maintain [the rehearsal record](recovery-rehearsal-template.md) during—not after—the exercise. Formal sign-off remains withheld until the second clean-SD-card rehearsal passes without undocumented corrective intervention.
