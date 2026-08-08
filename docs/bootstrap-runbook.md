# cycling-prod Bootstrap and Recovery Runbook

## Purpose and sign-off status

This is the canonical sequence for rebuilding `cycling-prod` from a clean Raspberry Pi OS installation using Git, protected configuration, an encrypted runtime-credential recovery asset and one matched off-host MariaDB dump set.

Disaster recovery is **not formally signed off**. The first production-like rehearsal succeeded after corrective intervention. A second clean-SD-card rehearsal must follow this revision without undocumented correction. Record the exercise live using [recovery-rehearsal-template.md](recovery-rehearsal-template.md).

All operator Compose commands use `/home/tim/cycling-infrastructure/scripts/compose.sh`; supported helpers such as database restore enter through the same shared Compose contract internally. It supplies the physical `hostname -s` and host `tim` UID/GID dynamically. Compose interpolates the entire file even for a MariaDB-only command, so do not bypass the helpers, manually export those variables, hard-code production identity, or forward container `HOSTNAME`.

Repository configuration, deployment environment and mutable credentials are distinct:

- Git contains Compose, scripts and non-secret examples.
- `compose/.env` contains protected deployment values such as database and OAuth client credentials; it is ignored by Git.
- `/srv/cycling/config/platform/runtime.Renviron` contains mutable application credentials including refresh tokens; its dedicated parent directory is mounted read-write into platform jobs, while the file itself is ignored by Git and recovered separately from database dumps.

## Prominent stop conditions

Stop immediately and do not enable schedules if any of these is true:

- target host identity is uncertain or differs from the intended recovery target;
- `.env` is absent, has unsafe placeholders, or fails preflight;
- the MariaDB target is not the intended new/empty target;
- backup identity or gzip integrity cannot be verified;
- database restore fails or leaves a partial target;
- the authoritative runtime credential asset is unavailable and re-authorisation is not deliberately planned;
- either repository remote, intended commit, or clean working-tree state cannot be established;
- image build, platform bootstrap, migration checksum verification, publication validation or full daily execution fails;
- a material manual intervention is not recorded in the live findings log.

After a failed manual stage, leave cron disabled. Destructive recovery is never part of generic host bootstrap.

## Required external assets

- Raspberry Pi 5 and clean replacement SD card;
- Raspberry Pi OS Lite 64-bit image and network access;
- SSH public key and access to both Git repositories;
- approved `compose/.env` recovery values;
- encrypted current `runtime.Renviron` asset or authority to re-authorise OAuth;
- one same-prefix current five-file logical dump set for Admin, Raw, Reference, Silver and Gold, or a retained historical four-file set without Reference;
- selected infrastructure and platform Git revisions;
- a copy of the rehearsal template opened for live recording.

## Phase 1 — Image and establish access

1. Image current supported Raspberry Pi OS Lite 64-bit.
2. For production set hostname `cycling-prod`; for an isolated rehearsal use the assigned non-production hostname such as `cycling-recovery-test`.
3. Create user `tim` with home `/home/tim`, install the Mac SSH public key and configure network access.
4. Establish SSH and network access. Bootstrap owns timezone configuration, locale verification and the full OS update; do not duplicate those package-update commands manually.

From the administration computer:

```bash
ssh tim@cycling-prod.local
```

The administrative account must remain `tim`; bootstrap rejects a different
user or home directory.

After intentionally reflashing the production host, its SSH host key will
change. A host-key warning protects against connecting to an impersonated or
misdirected host, so do not bypass it with `StrictHostKeyChecking=no` and do not
delete the whole `known_hosts` file.

First verify the replacement host's new fingerprint from its local console (or
another independently trusted management path):

```bash
for key in /etc/ssh/ssh_host_*_key.pub; do
  sudo ssh-keygen -lf "$key"
done
```

On the administration computer, inspect the entry for the exact name or address
reported by SSH, preserve a backup, and remove only that stale identity:

```bash
ssh-keygen -F cycling-prod.local
cp -p ~/.ssh/known_hosts ~/.ssh/known_hosts.before-cycling-prod-rebuild
ssh-keygen -R cycling-prod.local
ssh tim@cycling-prod.local
```

Compare the fingerprint offered during reconnection with the independently
verified fingerprint before accepting it. Repeat `ssh-keygen -F` / `-R` only
for another exact alias that actually reports a stale key, such as
`cycling-prod` or the Pi's confirmed current IP address. An IP entry must not be
removed merely because the address was used historically; confirm that the
address is now assigned to the rebuilt Pi.

For an isolated rehearsal, use its distinct identity, for example
`cycling-recovery-test.local`. Never remove or replace `cycling-prod` host-key
entries while the real production host remains online. These commands manage
the Mac's server-identity cache only; the Mac public key authorized for login
must still be installed in `/home/tim/.ssh/authorized_keys` on the rebuilt Pi.

5. Verify initial identity, network and capacity, and record results:

```bash
hostnamectl
cat /etc/os-release
dpkg --print-architecture
id
getent hosts github.com
df -h /
```

Stop if the hostname, user, architecture, clock, DNS or free space is unsuitable.

## Phase 2 — Clone and bootstrap infrastructure

Clone infrastructure if absent; never trust repository content recovered from an old filesystem:

```bash
sudo apt-get install -y ca-certificates git
cd /home/tim
git clone https://github.com/tim-jc/cycling-infrastructure.git
cd /home/tim/cycling-infrastructure
git remote -v
[ "$(git remote get-url origin)" = "https://github.com/tim-jc/cycling-infrastructure.git" ]
git fetch --prune --tags origin
git status --porcelain
git checkout --detach INTENDED_INFRASTRUCTURE_COMMIT_SHA
git rev-parse HEAD
```

The intended commit must be deliberate and recorded. A rehearsal normally uses the commits being qualified. Production recovery uses the currently approved production commits. Rollback uses a previously recorded accepted SHA, not an unexplained branch pull.

Run the single supported bootstrap orchestrator:

```bash
./scripts/bootstrap.sh
```

For a rehearsal host only:

```bash
EXPECTED_HOSTNAME=cycling-recovery-test ./scripts/bootstrap.sh
```

Bootstrap discovers and runs these numbered stages in order:

1. `10-system-update.sh` validates OS, ARM64, user/home and hostname; sets/verifies timezone and locale; then runs `apt-get update` and `apt-get full-upgrade -y`.
2. `20-install-packages.sh` installs the required host utilities and enables the cron daemon.
3. `30-install-docker.sh` reuses the established Docker installer, enables Docker and configures `tim` group membership.
4. `40-create-directories.sh` creates and secures production paths without replacing credentials or changing existing MariaDB contents.
5. `50-verify-host.sh` verifies host identity, commands, Docker/Compose and service state.

If Debian creates `/var/run/reboot-required`, stage 10 exits deliberately with status `75`. No later stage runs. Reboot, reconnect, return to the same checked-out infrastructure revision and rerun the same bootstrap command. Ordinary host state—not a marker maintained by this repository—allows completed work to resume safely. Bootstrap may also advise reconnecting when new Docker-group membership is not active in the current login session.

Bootstrap creates an empty `runtime.Renviron` only if absent. `/srv/cycling/config/platform` is dedicated to this one file, owned by `tim` with mode `0700`; the file uses mode `0600`. It does not create `.env`, overwrite runtime credentials, start MariaDB, restore data or enable application cron.

Verify:

```bash
id
docker version
docker compose version
locale
timedatectl status
ls -ld /srv/cycling/data/mariadb /srv/cycling/logs/platform /srv/cycling/config/platform
stat -c '%U %G %a %n' /srv/cycling/config/platform/runtime.Renviron
```

## Phase 3 — Configure deployment

Create, never overwrite, the ignored environment file:

```bash
cd /home/tim/cycling-infrastructure
[ ! -e compose/.env ] || { echo 'STOP: compose/.env already exists'; false; }
install -m 0600 compose/.env.example compose/.env
```

Edit it through an approved local editor or secure transfer. Do not place values on a command line. Refresh tokens belong in `runtime.Renviron`, not `.env`.

Run the supported preflight and Compose render before service startup:

```bash
./scripts/preflight.sh
./scripts/compose.sh config --quiet
```

Preflight rejects empty and known illustrative MariaDB passwords, checks protected files and reports whether the MariaDB directory appears initialized. `compose/.env.example` is intentionally illustrative and cannot pass unchanged.

Credential mount contract: Compose mounts `/srv/cycling/config/platform` at `/run/cycling-platform:rw`, while both R environment variables still point to `/run/cycling-platform/runtime.Renviron`. Mounting the directory—not the file—is required so crash-safe persistence can create a sibling temporary file and rename it atomically over `runtime.Renviron`. `scripts/compose.sh` supplies the rebuilt host `tim` UID/GID so the replacement inode remains `tim:tim` mode `0600`; preflight rejects ownership drift and unrelated entries in the dedicated directory.

Host identity contract: `scripts/compose.sh` evaluates the physical host's `hostname -s` for every invocation and Compose requires it. Platform notifications may rely on `CYCLING_PLATFORM_EXECUTION_HOST`; Docker container IDs and `HOSTNAME` are not physical-host identity.

## Phase 4 — Deploy MariaDB

Confirm `/srv/cycling/data/mariadb` is the intended target. A new directory must not contain `mysql/`. Then use the guarded startup entry point:

```bash
cd /home/tim/cycling-infrastructure
./scripts/start_mariadb.sh
./scripts/compose.sh ps mariadb
./scripts/compose.sh logs --tail=200 mariadb
```

Defense in depth exists in both host preflight and the container entrypoint. A new data directory with an empty/known-placeholder application or root password is rejected before MariaDB's official entrypoint initializes it.

Compose explicitly supplies `mariadbd` as the command for the guarded entrypoint, and the guard independently defaults an empty argument list to `mariadbd`. This is intentional: overriding an image `ENTRYPOINT` can otherwise discard or fail to preserve the image `CMD`, causing the official MariaDB entrypoint to exit successfully without starting the server and producing a `Restarting (0)` loop. Do not remove either layer without verifying the rendered and runtime `Entrypoint` and `Cmd`.

On an existing data directory the guard warns that `MARIADB_PASSWORD` and `MARIADB_ROOT_PASSWORD` are initialization inputs. Editing `.env` does not rotate existing accounts. Use [mariadb-credential-rotation.md](mariadb-credential-rotation.md). The guard cannot determine whether an existing database password equals `.env`; it therefore always emits the warning for initialized data.

Wait for healthy status. First initialization creates all six platform databases with canonical database defaults and grants; its init scripts are not rerun for existing data. `start_mariadb.sh` then runs the idempotent existing-instance Reference reconciliation. Verify it independently with `./scripts/reconcile_reference_database.sh --check-only`. Infrastructure, not platform bootstrap, is authoritative for physical database provisioning.

## Phase 5 — Restore production data

The authoritative restore point is a selected, retained matched logical dump set in the Mac backup job's configured `BACKUP_DIR` (normally the ignored `cycling-platform/backups` directory). It is off-host from the Pi and is not a copy of `/srv/cycling/data/mariadb`. The `.sql.gz` format provides compression and integrity checking, not encryption; confidentiality currently depends on the Mac filesystem and backup-storage controls unless storage-layer encryption is confirmed. Record the actual directory, prefix, timestamp, source, encryption-at-rest status and retention metadata.

Copy either a historical four-file set (Admin, Raw, Silver and Gold) or a current five-file set (also Reference) to a protected recovery directory. Stage has no dump. Do not mix prefixes. Run check-only with an exact host assertion:

```bash
cd /home/tim/cycling-infrastructure
./scripts/restore_platform_database.sh \
  --check-only \
  --expected-hostname INTENTIONAL_TARGET_HOSTNAME \
  /home/tim/recovery/YYYY-MM-DD_HHMMSS
```

The helper requires a complete matched four- or five-file set, non-empty files, `gzip -t`, healthy MariaDB, all six databases, canonical accessible Reference and empty durable targets. For restore, record output and preserve pipeline status:

```bash
set -o pipefail
./scripts/restore_platform_database.sh \
  --confirm-empty-target \
  --expected-hostname INTENTIONAL_TARGET_HOSTNAME \
  /home/tim/recovery/YYYY-MM-DD_HHMMSS \
  2>&1 | tee /home/tim/recovery/database-restore.log
```

For current sets it restores Admin, Raw, Reference, Silver and Gold in order. For historical sets it restores the original four and verifies that Reference remains empty. It reports read-only table/activity summaries and Reference settings/access. Stage remains empty/disposable. If any import fails, stop and recreate a fresh empty target; never import over the partial result.

A rehearsal must never use `cycling-prod`, the production data directory, or production Compose project. Record target hostname before the destructive confirmation.

The next isolated rehearsal must exercise both compatibility paths: restore a current five-file set and verify Reference content/settings/access, then recreate the isolated empty target and restore a historical four-file set, verifying Reference exists and remains empty. Record all six databases and the application grant result. Unit tests do not constitute recovery sign-off; a clean end-to-end rehearsal remains required.

## Phase 6 — Restore runtime credentials

Follow [runtime-credential-recovery.md](runtime-credential-recovery.md). From the trusted Mac checkout, review the ciphertext `.metadata` record and run the guarded restore entry point:

```bash
./scripts/restore_runtime_credentials.sh \
  --ciphertext /APPROVED/RECOVERY/runtime.Renviron.age \
  --identity /SECURE/IDENTITY/age-identity \
  --target tim@INTENTIONAL_TARGET_HOST \
  --expected-hostname INTENTIONAL_SHORT_HOSTNAME \
  --confirm-replace
```

The restore verifies the recorded SHA-256, decrypts only in an owner-only local temporary directory, transfers through an owner-only staging file, asserts the remote hostname, and atomically replaces the prepared runtime file. It then runs the equivalent of this reusable verification command automatically:

```bash
./scripts/verify_runtime_credentials.sh \
  --target tim@INTENTIONAL_TARGET_HOST \
  --expected-hostname INTENTIONAL_SHORT_HOSTNAME
```

This verification requires no platform image and reports metadata plus required token presence without values. After Phase 7, exercise provider authentication. If a token is invalid, run the platform-owned OAuth bootstrap and immediately create and verify a fresh encrypted off-host backup.

## Phase 7 — Deploy current code

Clone the platform repository if absent, verify its remote and cleanliness, then deploy an intentional revision:

```bash
cd /home/tim
git clone https://github.com/tim-jc/cycling-platform.git   # only if absent
git -C cycling-platform remote -v
git -C cycling-platform status --porcelain
cd /home/tim/cycling-infrastructure
./scripts/deploy_platform.sh \
  --ref INTENDED_PLATFORM_BRANCH_TAG_OR_SHA \
  --evidence-file /home/tim/recovery/recovery-evidence.txt
```

The helper fetches origin/tags, refuses dirty infrastructure or platform trees, resolves and checks out the selected commit, builds the image, validates Compose with `config --quiet`, requires healthy MariaDB, runs platform bootstrap/migrations, and runs publication validation. It records both repository SHAs, image identity, and both gate results. It does not run ETL or alter schedules. A non-zero gate means deployment is incomplete.

Omitting `--ref` deliberately selects the freshly fetched `origin/main` and is the normal latest-production deployment path. For deterministic rehearsals and incident recovery prefer an explicit recorded commit SHA. For rollback select a previously accepted SHA and assess database migration compatibility before rebuilding.

Restored production data and deployed application code have separate identities: the dump timestamp describes data; Git SHA and image ID describe executable state.

## Phase 8 — Bootstrap and migrate the platform

Historical backups may legitimately predate current schema. Current schema definition, character sets, collations, engines, migrations and drift validation belong to `cycling-platform`; infrastructure does not duplicate them.

`deploy_platform.sh` invokes the required Compose gate automatically:

```bash
./scripts/compose.sh run --rm cycling-platform \
  Rscript bootstrap_platform.R
```

This platform interface creates required current objects, applies unapplied migrations and verifies migration checksums. Retain its successful deployment log as evidence. Do not rerun it merely to compensate for a failed deployment: diagnose the named failure first, then rerun the complete deployment. Do not validate using host-native R.

## Phase 9 — Verify migration evidence

Query the actual ledger columns without displaying credentials:

```bash
cd /home/tim/cycling-infrastructure
./scripts/compose.sh exec -T mariadb sh -c '
export MYSQL_PWD="$MARIADB_PASSWORD"
exec mariadb --user="$MARIADB_USER" --batch --raw \
  --execute="SELECT migration_version, migration_filename, migration_checksum, applied_at FROM cycling_platform_admin.schema_migration ORDER BY migration_version;"
'
```

The first rehearsal observed migration `001`, filename `001_enforce_canonical_collation.sql`. Do not hard-code a checksum in infrastructure: the platform migration framework must compare ledger checksums with its managed migration files. A ledger row alone is not proof; retain the successful bootstrap/checksum-validation log plus the ledger query.

## Phase 10 — Run publication validation

`deploy_platform.sh` invokes publication validation through the production Compose runtime immediately after bootstrap:

```bash
./scripts/compose.sh run --rm cycling-platform \
  Rscript run_platform_validation.R --publication
```

The deployment is incomplete if this gate fails. It is not ingestion and does not replace the separate full-pipeline acceptance run required later in recovery.

## Phase 11 — Run the full platform pipeline

Run the normal production wrapper, which itself uses Compose and records logs:

```bash
start_time="$(date -Is)"
/home/tim/cycling-infrastructure/scripts/run_daily_platform.sh
run_status=$?
finish_time="$(date -Is)"
printf 'start=%s finish=%s status=%s\n' "$start_time" "$finish_time" "$run_status"
```

Record start/finish, exit status, log path, notification result, reported physical host and backup-health result. A restored host should report the actual age of the restored production backup. On a rehearsal/fresh recovery it is legitimate for that age to be critical while backup scheduling is intentionally disabled; record host identity and scheduling state rather than suppressing the warning. Production must remain critical until a genuinely fresh successful off-host backup exists. Any richer recovery-mode policy belongs in `cycling-platform` and must preserve real age/status.

## Phase 12 — Enable schedules

Do not enable schedules until platform bootstrap/checksums, migration evidence, publication validation, a full daily run, notifications, host identity and backup reporting have all been reviewed.

Production activation:

```bash
cd /home/tim/cycling-infrastructure
./scripts/install_cron.sh --show
./scripts/install_cron.sh --dry-run
./scripts/install_cron.sh
crontab -l
```

The installer owns one marked block, preserves unrelated entries and avoids duplicates. Bootstrap never invokes it.

During a rehearsal leave application cron uninstalled. If testing an already configured host, remove only the managed block through a reviewed crontab edit and record the deviation; do not disable the cron daemon globally if unrelated jobs exist.

## Phase 13 — Record evidence and decide result

Complete [recovery-rehearsal-template.md](recovery-rehearsal-template.md) with:

- hostname, OS version, date and operator;
- infrastructure/platform commit SHAs and repository remotes;
- image identities;
- dump prefix/timestamp and restore log;
- runtime ciphertext identifier/digest/freshness;
- migration ledger and checksum-validation evidence;
- publication validation and full-run results;
- notifications, physical host identity and backup-health status;
- every defect, discovery, deviation and manual intervention;
- schedule state and unresolved findings.

The second rehearsal passes only if every manual phase succeeds and there is no undocumented corrective intervention. Formal DR sign-off remains withheld until that clean rehearsal is reviewed. A material undocumented intervention is a new defect and may require another rehearsal.

## Exact command sequence for the second rehearsal

After Phase 1 imaging and secure asset preparation, execute in this order, substituting intentional SHAs, host and backup prefix:

```bash
# clone/checkout infrastructure
cd /home/tim
git clone https://github.com/tim-jc/cycling-infrastructure.git
cd cycling-infrastructure
git fetch --prune --tags origin
git checkout --detach INFRASTRUCTURE_SHA
EXPECTED_HOSTNAME=cycling-recovery-test ./scripts/bootstrap.sh

# protected deployment config, then guarded database startup
install -m 0600 compose/.env.example compose/.env
# securely populate compose/.env; do not log values
./scripts/preflight.sh
./scripts/compose.sh config --quiet
./scripts/start_mariadb.sh

# matched logical restore
./scripts/restore_platform_database.sh --check-only \
  --expected-hostname cycling-recovery-test /home/tim/recovery/BACKUP_PREFIX
set -o pipefail
./scripts/restore_platform_database.sh --confirm-empty-target \
  --expected-hostname cycling-recovery-test /home/tim/recovery/BACKUP_PREFIX \
  2>&1 | tee /home/tim/recovery/database-restore.log

# On the trusted Mac, from its cycling-infrastructure checkout:
./scripts/restore_runtime_credentials.sh \
  --ciphertext /APPROVED/RECOVERY/runtime.Renviron.age \
  --identity /SECURE/IDENTITY/age-identity \
  --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test \
  --confirm-replace
./scripts/verify_runtime_credentials.sh \
  --target tim@cycling-recovery-test.local \
  --expected-hostname cycling-recovery-test

# Return to the recovery Pi shell for deployment.

# clone/deploy deliberate platform revision
cd /home/tim
git clone https://github.com/tim-jc/cycling-platform.git
cd /home/tim/cycling-infrastructure
./scripts/deploy_platform.sh --ref PLATFORM_SHA \
  --evidence-file /home/tim/recovery/recovery-evidence.txt

# deploy_platform.sh already ran bootstrap/migrations and publication validation;
# retain its evidence, then independently inspect the migration ledger.
./scripts/compose.sh exec -T mariadb sh -c '
export MYSQL_PWD="$MARIADB_PASSWORD"
exec mariadb --user="$MARIADB_USER" --batch --raw --execute="SELECT migration_version, migration_filename, migration_checksum, applied_at FROM cycling_platform_admin.schema_migration ORDER BY migration_version;"
'
./scripts/run_daily_platform.sh

# review evidence; leave rehearsal cron disabled
```
