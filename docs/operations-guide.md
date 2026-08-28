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

After bootstrap, always log out and reconnect before continuing. Verify `id`
contains the `docker` group and `docker info` succeeds without `sudo`; the
original SSH session cannot acquire newly assigned supplementary groups.

Bootstrap deliberately does not install production cron. During disaster recovery, secrets and databases must be restored and validated before schedules resume.

## Configure

During disaster recovery, restore `compose/.env` using
[Static Compose Configuration Recovery](static-config-recovery.md). Do not
reconstruct production values from the example file or memory.

```bash
./scripts/preflight.sh
./scripts/compose.sh config --quiet
```

Populate `compose/.env` with deployment configuration: MariaDB credentials/port,
OAuth client IDs and client secrets, platform-owned `NTFY_TOPIC`, and
analytics-owned `CYCLING_ANALYTICS_NTFY_TOPIC`. Refresh tokens do not belong in
this file. Never commit it.

Bootstrap owns the filesystem contract for the mutable credential file:

```text
/srv/cycling/config/platform/runtime.Renviron
```

The file is owned by `tim` with mode `0600`. Its dedicated host directory is owned by `tim` with mode `0700` and is mounted read-write at `/run/cycling-platform`; both `R_ENVIRON_USER` and `CYCLING_PLATFORM_RENVIRON_PATH` continue to select `/run/cycling-platform/runtime.Renviron`. `cycling-platform` owns its contents and updates refresh-token keys through `update_renviron()`. Infrastructure supplies the numeric UID and GID of the host `tim` account through `scripts/compose.sh`, and Compose runs every ephemeral platform job with that identity. This is required because atomic rename retains the new sibling inode's ownership. Running the writer as container root would replace the host file as `root:root`.

Infrastructure must back up and restore the file without inspecting or logging its values. The directory must contain only `runtime.Renviron`, because every entry would be exposed to the container. A direct file bind mount is prohibited: the application writes a sibling temporary file and atomically renames it over the target, and Linux cannot rename over a file that is itself a bind-mount point. `scripts/preflight.sh` and `scripts/verify_runtime_credentials.sh` reject ownership drift rather than weakening this contract.

The platform image must remain compatible with this non-root execution contract. Its renv library is restored without root-cache symlinks and made runtime-readable during the image build; a runtime attempt to bootstrap packages into `/opt/cycling-platform/renv/library` indicates an invalid image and must fail deployment.

Application notifications own success and failure reporting after
`run_daily_platform.R` has initialized. The host daily wrapper owns the outer
boundary: if Compose exits non-zero before the application confirms that its
failure notification was sent, the wrapper sends one concise ntfy alert using
`NTFY_TOPIC` (and optional `NTFY_BASE_URL`) from `compose/.env`. It includes only
the physical host, pipeline, exit status, timestamp and fixed failure context;
logs and secrets are never transmitted. A notification transport error is
logged but never replaces the original container exit status.

If drift is detected, first ensure no platform job is running. Record a SHA-256 digest without displaying the file, repair only ownership and mode with `sudo chown tim:tim` and `sudo chmod 0600`, then confirm the digest is unchanged and rerun preflight. The detailed incident-safe sequence is in [Runtime Credential Backup and Recovery](runtime-credential-recovery.md).

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

### Deploy cycling-analytics

Normal analytics deployment fetches and deploys the latest `origin/main`:

```bash
cd /home/tim/cycling-infrastructure
./scripts/deploy_analytics.sh
```

Use `--ref BRANCH_TAG_OR_COMMIT` only for an intentional specific revision,
rollback or recovery. The script refuses dirty or unexpected repositories,
checks the owner-only analytics runtime env file and writable output directory,
checks out the resolved analytics commit detached, verifies the selected
Dockerfile contains the mandatory offline smoke test, builds only
`cycling-analytics`, captures the image ID, and validates Compose quietly.

It holds `/tmp/cycling-analytics-deployment.lock` and refuses an analytics
render lock or the shared database-restore lock. Platform daily, validation and
deployment locks do not block this non-rendering build. Evidence is appended to
`logs/analytics_deployment.log` without resolved configuration values.

A successful deployment prepares a known image for later execution; it does
not connect the application to MariaDB, render or replace `index.html`, contact
CARTO, publish, notify, or alter scheduling.

### Refresh cycling-analytics manually

Use the production runtime wrapper for a trusted manual refresh:

```bash
cd /home/tim/cycling-infrastructure
./scripts/run_analytics_refresh.sh
```

The wrapper refuses analytics deployment and database-restore locks, then
atomically acquires `/tmp/cycling-analytics-render.lock`. A duplicate render is
a harmless zero-status skip; deployment or restore contention is a non-zero
operational failure. Platform daily, validation and deployment locks do not
block this read-only database consumer.

Execution remains `scripts/compose.sh run --rm cycling-analytics`. The wrapper
adds one private temporary bind mount for the application-produced notification
context, captures container output in `logs/analytics_refresh.log`, and removes
the context and render lock on exit. It preserves a failing container's exact
status even if failure notification also fails. Success notification is best
effort, uses only `CYCLING_ANALYTICS_NTFY_TOPIC`, and reports `Dashboard
refreshed` with the physical execution host plus the application's rendered,
YTD, latest-ride and next-refresh context. It does not claim publication.

`NTFY_TOPIC` remains exclusively owned by cycling-platform. If
`CYCLING_ANALYTICS_NTFY_TOPIC` is missing or empty, analytics notification is
skipped and logged without falling back to the platform topic. Notification is
operationally best-effort and does not replace the render/container status.

After a zero container status, the wrapper requires
`/srv/cycling/data/analytics/output/index.html` to be a non-empty regular file
newer than the refresh start. This rejects a stale artefact without performing
another render or expensive HTML validation.

Inspect the result with:

```bash
tail -n 100 logs/analytics_refresh.log
stat -c '%U:%G %s %y %n' /srv/cycling/data/analytics/output/index.html
```

Analytics scheduling and publication are not yet installed or documented as
active. Do not add Git publication commands to this runtime wrapper.

The MariaDB script under `compose/mariadb/init` runs only for a new, empty MariaDB data directory. It must not be used to recreate existing production data.

For normal application upgrades, use `scripts/deploy_platform.sh`; it fetches origin and defaults to the freshly fetched `origin/main`. Supply `--ref BRANCH_TAG_OR_COMMIT` for deterministic recovery/rehearsal or a previously accepted SHA for rollback.

A completed deployment has these mandatory gates:

1. build the `cycling-platform` image from the resolved commit;
2. run `docker compose config --quiet` without printing interpolated secrets;
3. require the existing MariaDB service to be healthy;
4. verify the physical Reference database and application grant are ready;
5. run `Rscript bootstrap_platform.R` through Compose, including checksum verification and unapplied migrations;
6. run the platform aggregate `Rscript scripts/reference/publish_reference_data.R` through Compose;
7. run `Rscript run_platform_validation.R --publication` through Compose.

The script stops at the first failure and reports the failed stage. Only after every gate passes does it print `Deployment ready`. Bootstrap is idempotent, but migrations can still be consequential. Reference publication is mandatory and idempotent when repository-owned data is unchanged; a failure leaves deployment incomplete and is retried by rerunning the same deployment after correcting the platform data or publisher defect. No automatic database rollback is attempted.

Infrastructure decides when to invoke only the aggregate publisher and propagates its status. `cycling-platform` owns the datasets, YAML parsing, transactions, reconciliation and validation behind that interface, so adding a future Reference dataset requires no infrastructure change. No separate planned-events publication command is normally required. Reference publication is deployment-only: it is not added to ingestion, the daily pipeline, cron or validation scheduling.

Any ref selected for deployment or rollback must contain the aggregate publisher entry point. An older ref that predates this deployment contract will fail the mandatory Reference publication gate and cannot be declared ready without a separately reviewed compatibility decision.

The checked-out code, built image, schema migrations, Reference publication and publication checks form one compatibility unit. Deployment never runs ingestion, transformations, notifications, the daily pipeline, or cron installation. Schedule activation remains separate.

Deployment holds `/tmp/cycling-platform-deployment.lock`; the managed daily, validation, and database-restore wrappers refuse to overlap it. It also refuses existing managed-operation locks or a running platform Compose container. Secret-free evidence is appended to `/home/tim/cycling-infrastructure/logs/platform_deployment.log`, including timestamps, host, infrastructure/platform commits, image identity, Reference publication, and gate results.

Never run unqualified `docker compose config` into shared output because rendered environment values may contain secrets; use `./scripts/compose.sh config --quiet`.

All supported Compose invocations enter through the contract implemented by `scripts/compose_contract.sh`. Normal operator commands use `scripts/compose.sh`; the database restore helper sources the same contract while retaining its testable command array. The contract dynamically supplies the physical short hostname and the host `tim` UID/GID. This is required even for MariaDB-only operations because Compose interpolates the entire project file before selecting a service. Do not call project `docker compose` directly or manually export these values.

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
0 2,20 * * * /home/tim/cycling-infrastructure/scripts/run_daily_platform.sh
30 2,20 * * * /home/tim/cycling-infrastructure/scripts/run_analytics_refresh.sh
30 3 * * * /home/tim/cycling-infrastructure/scripts/run_platform_validation.sh
# <<< CYCLING_PLATFORM_END <<<
```

The analytics offsets are fixed times, not dependencies on completion of the
preceding platform runs. Cron is authoritative. The analytics wrapper derives
the managed line from `scripts/analytics_schedule.sh`; when that exact line is
installed it supplies the next 02:30/20:30 display time to the container. A
manual refresh before schedule installation truthfully reports `not scheduled`.
Bootstrap and deployment never install or change this block.

Inspect scheduling and logs with:

```bash
crontab -l
tail -n 200 /home/tim/cycling-infrastructure/logs/platform_daily.log
tail -n 200 /home/tim/cycling-infrastructure/logs/analytics_refresh.log
tail -n 200 /home/tim/cycling-infrastructure/logs/platform_validation.log
```

## Backups

MariaDB backups deliberately run on the Mac at 05:00 through
`cycling-platform/scripts/run_backup_workflow.sh backup`. The underlying
`backup_mariadb.sh` still creates the proven timestamped per-database dumps.
The platform checkout installs user LaunchAgents rather than relying on classic
Mac cron: the calendar job runs at 05:00 and is coalesced after ordinary sleep,
while an hourly health job alerts when the Mac-side recovery point becomes
stale.

Infrastructure owns operational backup policy and recovery expectations. The platform repository currently implements Mac-side dump creation and backup observability; this repository owns restore execution and recovery rehearsal.

For recovery selection and transfer, use `scripts/prepare_recovery_backup.sh`;
it validates one exact timestamped set and reports the restore prefix. Long
restores must run in `tmux`, which bootstrap installs, following
[the bootstrap and recovery runbook](bootstrap-runbook.md). Do not infer an
active restore from `tmux ls` alone—also verify the restore process.

Durable backup expectation:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_reference` (new five-file sets)
- `cycling_platform_silver`
- `cycling_platform_gold`

`cycling_platform_stage` is deliberately excluded because it is disposable.
Current sets require all five files; retained historical four-file sets remain
valid recovery inputs. Retention operates on exact-prefix sets and always
preserves the newest valid complete set. Periodically test both restore formats
in an isolated MariaDB instance.

The verified Mac inventory and `latest_success.json` are authoritative for the
newest available physical recovery point. Admin backup tables are useful
platform observability but necessarily lag the set containing their own dump,
because Admin is dumped before that run records success. After restore, a stale
Pi notification can therefore describe restored metadata rather than the
newest Mac recovery asset. Inspect the Mac artefact/files before declaring the
physical backup stale; do not couple the Pi to the Mac filesystem.

Install, inspect or disable the Mac schedule from the platform checkout:

```bash
scripts/install_backup_launchd.sh install
scripts/install_backup_launchd.sh status
scripts/install_backup_launchd.sh uninstall
```

Installation removes only superseded Mac backup cron entries and preserves
unrelated cron. No plist contains credentials; ntfy and MariaDB settings remain
in the platform `.Renviron`.

## Reference database reconciliation

Fresh volumes receive Reference from MariaDB first initialization. Existing volumes do not rerun init scripts. After MariaDB is healthy, use:

```bash
./scripts/reconcile_reference_database.sh
./scripts/reconcile_reference_database.sh --check-only
```

The first command idempotently creates Reference if absent, corrects its database defaults and reconciles the configured application user's database-scoped grant. It does not alter table collations or create tables. Check-only changes nothing and fails if Reference is missing, incorrectly configured, inaccessible, missing the intended grant, or accompanied by an unintended global application-user privilege. `start_mariadb.sh` performs reconciliation; normal platform deployment requires the check-only gate.

Database dumps do not contain `/srv/cycling/config/platform/runtime.Renviron`. Use `scripts/backup_runtime_credentials.sh`, `scripts/verify_runtime_credentials.sh`, and `scripts/restore_runtime_credentials.sh` as described in [Runtime Credential Backup and Recovery](runtime-credential-recovery.md). Refresh and verify the encrypted copy after OAuth rotation/bootstrap. The approved Mac destination, age identity custody and responsible operator remain manual decisions; never copy plaintext into Git or ordinary logs.

## Consumers

Mac-hosted tools use `cycling-prod.local` as the MariaDB host. The Compose-managed
`cycling-analytics` job runs on `cycling-prod` and connects through Docker
service discovery at `mariadb:3306`; its production execution is not yet scheduled.

## Recovery evidence

Use [the bootstrap and recovery runbook](bootstrap-runbook.md) for the exact 13-phase sequence and maintain [the rehearsal record](recovery-rehearsal-template.md) during—not after—the exercise. Formal sign-off remains withheld until the second clean-SD-card rehearsal passes without undocumented corrective intervention.
