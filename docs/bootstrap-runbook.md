# cycling-prod Bootstrap and Recovery Runbook

## Purpose

This runbook defines how to rebuild `cycling-prod` after total loss of its SD card, using only a fresh Raspberry Pi OS installation, the Mac, Git repositories, securely held credentials, and the latest complete off-host MariaDB backup set.

It separates:

- **Bootstrap:** fresh OS to a production-capable but unscheduled host.
- **Disaster recovery:** production-capable host to restored data, validated application, and resumed schedules.

Commands marked **TODO** are not yet proven or do not yet have a canonical recovery source. Do not enable cron until the recovery acceptance checks pass.

## Current recovery verdict

**cycling-prod is substantially reproducible, but recovery is not yet independently complete.** Git now represents host bootstrap, the persistent runtime-credential mount, MariaDB initialisation, guarded logical restore, application execution, and production cron. The remaining risk is primarily off-host custody and rehearsal rather than missing runtime wiring.

Minimum blockers are:

1. no documented, tested off-host canonical copy of `compose/.env`, especially `MARIADB_ROOT_PASSWORD`;
2. no documented, tested encrypted off-host backup of `/srv/cycling/config/platform/runtime.Renviron` after token rotation;
3. the guarded four-dump restore has not been exercised end to end against an isolated MariaDB 11 target;
4. production-specific manual host configuration such as firewall and SSH policy has not been inventoried on `cycling-prod`.

Host package and Docker installation, persistent-directory and credential-file creation, database restore checks, and managed production cron are represented by idempotent scripts. They still require a complete fresh-Pi recovery exercise.

## Recovery assumptions

After an SD-card failure, recovery assumes all of the following still exist:

- a working Raspberry Pi 5 and replacement storage;
- a Mac with network access and an SSH client;
- access to the two GitHub repositories;
- a complete, same-timestamp backup set for Admin, Raw, Silver, and Gold;
- the backup `latest_success.json` artefact where available;
- a secure off-host source for every credential listed below;
- access to the Strava and Google accounts/OAuth applications if re-authorisation is required;
- Internet access for OS packages, container images, GitHub, CRAN, and `renv` package restore.

Stage, logs, Docker cache, temporary containers, and lock directories are assumed lost and are not restored.

## Required external assets

| Asset | Recovery source | Status |
|---|---|---|
| Raspberry Pi OS Lite 64-bit image | Raspberry Pi Imager/download | Available externally |
| Wi-Fi credentials | Secure personal credential store | **TODO: confirm source** |
| Mac SSH private key | Mac SSH configuration/keychain | Expected; verify before incident |
| GitHub repository read access | Public HTTPS URLs today | READY for clone; confirm repositories remain public |
| `cycling-infrastructure` repository | `https://github.com/tim-jc/cycling-infrastructure.git` | READY, branch `main` |
| `cycling-platform` repository | `https://github.com/tim-jc/cycling-platform.git` | READY when the intended production revision is committed and pushed |
| Compose secrets | Secure off-host secret store | **TODO: no canonical source documented** |
| OAuth client credentials/tokens | Approved encrypted off-host copy plus OAuth providers | **TODO: canonical backup and rotation reconciliation not proven** |
| Latest four-file DB backup set | Mac `cycling-platform/backups` or configured backup path | Available today; restore not proven |
| Mac backup schedule | Mac scheduler | PARTIAL: fresh backups exist, but no matching crontab entry was readable during audit |

## Audit evidence and limits

This audit reviewed both repositories and the Mac-side ignored `.Renviron` without reading or recording secret values. It did not inspect the live Pi, production crontab, installed package list, Docker daemon configuration, firewall, Wi-Fi, SSH daemon settings, or actual `compose/.env`. Those remain **unknown / needs confirmation**.

Repository cleanliness and upstream alignment are point-in-time facts. Before recovery, verify both intended production revisions are committed, pushed, and recorded; do not rely on an uncommitted Mac working tree.

## Host reconstruction audit

| Requirement | Current classification | Evidence / gap | Required recovery action |
|---|---|---|---|
| Raspberry Pi 5, ARM64 | Documented but not automated | `system-baseline.md` | Select Pi 5 / 64-bit image manually |
| Raspberry Pi OS Lite 64-bit | Documented but not automated | ADR-0001 and baseline | Image with Raspberry Pi Imager |
| Hostname `cycling-prod` | Documented but not automated | Architecture/operations docs | Set during imaging; verify with `hostnamectl` |
| User `tim`, home `/home/tim` | Documented but not automated | Paths/scripts assume it | Create during imaging; verify UID/home |
| SSH public-key access | Documented historically | Public key installation not stored here | Install Mac public key during imaging; test before hardening |
| Wi-Fi/network | Manually configured and undocumented | Baseline says Wi-Fi; no recovery source | Restore SSID credential securely; confirm DHCP/mDNS |
| `cycling-prod.local` mDNS | Documented, implementation unknown | Consumers depend on it | Verify Avahi/mDNS resolution from Mac |
| Timezone Europe/London | Reproducible from Git | `bootstrap.sh` verifies and sets it | Run bootstrap |
| Locale | Reproducible from Git | host wrappers use `C.UTF-8`; bootstrap installs locales and verifies it | Run bootstrap |
| NTP/time synchronisation | Unknown | OAuth, cron, TLS require correct time | Verify `timedatectl status` |
| Git | Reproducible after infrastructure clone | Installed and verified by `bootstrap.sh` | Run bootstrap |
| Bash/coreutils/findutils | OS assumption | Used by operational wrappers | Verify; normally supplied by Raspberry Pi OS |
| `sudo` | OS/user assumption | `bootstrap.sh` requires it | Ensure `tim` has intended sudo access |
| Docker Engine | Reproducible from Git | `install_docker.sh` uses Docker official Debian repository | Run bootstrap; fresh-Pi test remains |
| Docker Compose plugin | Reproducible from Git | Installed with Docker packages and verified | Run bootstrap |
| Docker group access | Reproducible from Git | bootstrap adds `tim`; new session may be required | Run bootstrap, reconnect, verify |
| Docker service on boot | Reproducible from Git | bootstrap enables, starts, and verifies it | Run bootstrap |
| Cron package/daemon | Reproducible from Git | bootstrap installs, enables, starts, and verifies it | Run bootstrap |
| Production crontab | Reproducible from Git, explicitly activated | `install_cron.sh` owns one marked block | Install only after recovery validation |
| `/srv/cycling/data/mariadb` | Reproducible from Git | `bootstrap.sh` | Create before Compose start |
| `/srv/cycling/logs/platform` | Reproducible from Git | `bootstrap.sh` | Create before jobs |
| `/srv/cycling/config/platform/runtime.Renviron` | Reproducible filesystem; recoverable contents | Bootstrap creates it only when absent, mode `0600`; Compose mounts it read-write | Restore contents securely before jobs or re-authorise |
| Ownership/permissions | Reproducible from Git | bootstrap owns host/log parents as `tim` and never alters an existing MariaDB directory | Fresh-Pi/container write test remains |
| Firewall/port 3306 exposure | Unknown | Compose publishes configured port on all interfaces by default | Confirm intended LAN-only controls/firewall |
| SSH hardening | Unknown | Only historical key setup documented | Capture live policy or define desired minimal policy |
| Automatic OS security updates | Unknown | Not represented in Git | Decide and document |
| Raspberry Pi firmware/config (`config.txt`, overlays, power settings) | Unknown | No current requirement recorded | Compare live host; document only non-default requirements |
| Storage layout/mounts beyond SD card | Not required based on current docs | `/srv` is on root filesystem | Confirm no external mount is used |
| Host MariaDB/R clients | Not required | DB/app clients run in containers; backup clients run on Mac | Do not install merely for recovery |

### Host information to capture before an incident

Run on the live Pi and retain a redacted record outside the Pi:

```bash
hostnamectl
cat /etc/os-release
id tim
timedatectl status
locale
getent group docker
systemctl is-enabled docker cron
systemctl is-active docker cron
crontab -l
sudo nft list ruleset        # or the firewall tool actually in use
findmnt
ls -ld /srv/cycling /srv/cycling/data /srv/cycling/data/mariadb /srv/cycling/logs/platform /srv/cycling/config/platform
stat -c "%U %G %a %n" /srv/cycling/config/platform/runtime.Renviron
docker version
docker compose version
```

**TODO:** perform this inventory and update the classifications above. Do not record passwords, private keys, tokens, Wi-Fi PSKs, or raw environment files in Git.

## Repository reconstruction

| Repository | Required Pi path | Branch | Clone | Authentication | Local untracked state | Build/deploy coupling |
|---|---|---|---|---|---|---|
| `cycling-infrastructure` | `/home/tim/cycling-infrastructure` | `main` | `git clone --branch main --single-branch https://github.com/tim-jc/cycling-infrastructure.git /home/tim/cycling-infrastructure` | None for current public HTTPS clone; confirm policy | `compose/.env` required | Owns Compose and host scripts |
| `cycling-platform` | `/home/tim/cycling-platform` | `main` | `git clone --branch main --single-branch https://github.com/tim-jc/cycling-platform.git /home/tim/cycling-platform` | None for current public HTTPS clone; confirm policy | No project `.Renviron`; mutable tokens live in the infrastructure-owned host mount | Compose build context is `../../cycling-platform`, which resolves to this exact path |

A fresh clone can reconstruct application code and dependencies, but not secrets, cron, host packages, or data. Building also requires Internet access to the base image, Debian repositories, CRAN, and sources referenced by `renv.lock`.

`main` is inferred from both checked-out repositories and their upstreams. `deploy_platform.sh` does not enforce `main`, a clean tree, or a specific commit. **TODO:** decide whether production follows `origin/main` or an immutable release tag/commit and make that explicit.

## Secrets and configuration recovery inventory

Never paste values into this runbook, shell history, Git, Compose YAML, or Docker build arguments.

| Variable / file | Consumer | Secret? | Current location / tracking | Canonical recovery source today | Regenerable? | Fresh-host restoration | DR risk |
|---|---|---:|---|---|---|---|---|
| `compose/.env` | Compose interpolation | Contains secrets | Required on Pi, ignored; absent in audited Mac infra checkout | **Unknown; may be Pi-only** | Partly | Recreate mode `0600` from secure source | **CRITICAL** |
| `MARIADB_USER` | MariaDB init and app | No | `.env.example`; real value in Pi `.env` and Mac `.Renviron` | Mac `.Renviron` likely | Yes | Put matching value in Pi `compose/.env` | Low if confirmed |
| `MARIADB_PASSWORD` | MariaDB/app/backup | Yes | Pi `.env`; Mac `.Renviron`; both ignored | Mac `.Renviron` is an off-Pi copy, but canonical status undocumented | Yes, only with coordinated DB reset/change | Restore same value before empty DB initialisation | High |
| `MARIADB_ROOT_PASSWORD` | MariaDB init/admin | Yes | Pi `compose/.env` only as far as Git shows | **Unknown** | Yes on a fresh DB, but must be securely chosen/custodied | Generate/retrieve and store securely before first start | **CRITICAL** |
| `MARIADB_PORT` | Published port/Mac client | No | Examples and ignored files | Git example/current architecture | Yes | Normally `3306`; confirm LAN exposure policy | Low |
| `MARIADB_HOST` | App/backup | No | Compose hard-codes `mariadb`; Mac `.Renviron` should use `cycling-prod.local` | Git docs/config plus Mac `.Renviron` | Yes | Do not put `cycling-prod.local` into container jobs; use service DNS `mariadb` | Low |
| `STRAVA_CLIENT_ID` | Application OAuth | Identifier | Pi `.env`, Mac `.Renviron`, ignored | Mac `.Renviron` / Strava app console | Yes/retrievable | Copy securely into Pi `.env` | Medium |
| `STRAVA_CLIENT_SECRET` | Application OAuth | Yes | Pi `.env`, Mac `.Renviron`, ignored | Mac `.Renviron` / Strava app console | Rotatable | Copy or rotate; update all consumers | High |
| `STRAVA_REFRESH_TOKEN` | Application OAuth | Yes, rotating | Pi runtime credential file; application updates it durably | No tested off-host canonical copy | Yes, via re-authorisation | Restore runtime file or run OAuth bootstrap; then refresh encrypted off-host copy | **HIGH** |
| `GOOGLE_HEALTH_CLIENT_ID` | Application OAuth | Identifier | Pi `.env`, Mac `.Renviron` | Mac `.Renviron` / Google Cloud console | Yes/retrievable | Copy securely | Medium |
| `GOOGLE_HEALTH_CLIENT_SECRET` | Application OAuth | Yes | Pi `.env`, Mac `.Renviron` | Mac `.Renviron` / Google Cloud console | Rotatable | Copy or rotate | High |
| `GOOGLE_HEALTH_REFRESH_TOKEN` | Application OAuth | Yes | Pi runtime credential file; normally non-rotating | Mac copy may exist; canonical status unverified | Yes, via consent flow | Restore into runtime file; otherwise re-authorise with both required scopes | High |
| `NTFY_TOPIC` | Notifications | Treat as secret/capability | Pi `.env`, Mac `.Renviron` | Mac `.Renviron`, ownership undocumented | Yes | Copy or create a new private topic and update consumers | Medium |
| `CYCLING_PLATFORM_RENVIRON_PATH` | Token persistence helper | No | Compose sets `/run/cycling-platform/runtime.Renviron` | Git | Yes | Supplied automatically to every Compose job | READY |
| `R_ENVIRON_USER` | R credential loading | No | Compose sets `/run/cycling-platform/runtime.Renviron` | Git | Yes | Supplied automatically to every Compose job | READY |
| Mac `.Renviron` | Mac backup/native tools | Contains secrets | Exists off-Pi, ignored | Current Mac file; backup/custody not documented | Rebuild partly | Restore from encrypted Mac backup/secret manager | High |
| `config/platform.yml` | Application and backup behavior | No | Tracked in `cycling-platform` | Git | Yes | Restored by clone/image build | READY |
| Backup override variables (`BACKUP_*`, `MYSQLDUMP`) | Mac backup | Usually no; paths/settings | Optional environment plus tracked defaults | Tracked defaults; overrides unknown | Yes | Document only actual overrides in secure Mac automation config | Medium |
| Wi-Fi credentials | Host network | Yes | Raspberry Pi imaging/host | **Unknown secure source** | Yes | Supply through Imager or host setup | High |
| Mac SSH private key | SSH client | Yes | Mac only | Mac keychain/backup | Yes, with authorised-key replacement | Keep off Pi; install public key on Pi | Medium |
| Pi `authorized_keys` | SSH server | Public material | Pi-only unless derived from Mac key | Mac public key | Yes | Install during imaging/bootstrap | Low |
| Pi cron | Scheduler configuration | No, but operational | Pi user crontab | `scripts/install_cron.sh` | Yes | Install explicitly after validation | Low |
| Backup files and `latest_success.json` | DB recovery | Sensitive data | Mac backup directory, ignored | Mac storage/backup | Produced again, historical state is not | Select a verified complete set and protect access | High |

### Secret-custody decision required

Adopt one explicit off-host canonical source—preferably an encrypted password manager/secret store or encrypted recovery bundle—for:

- all values required by `compose/.env`;
- the current OAuth refresh tokens;
- Wi-Fi credentials where needed;
- the notification topic;
- instructions for locating the Mac backup set.

The secure source must be independently backed up and accessible during a Mac/Pi incident. Merely having an ignored file is not a recovery policy.

## OAuth and token recovery

### Strava

Production Compose bind-mounts `/srv/cycling/config/platform/runtime.Renviron` read-write and selects it with both `R_ENVIRON_USER` and `CYCLING_PLATFORM_RENVIRON_PATH`. Strava refresh-token rotation is therefore durable across ephemeral `docker compose run --rm` jobs. The application owns key-level updates through `update_renviron()`; infrastructure owns the host file, mount, permissions, backup, and restoration.

The Pi copy is still a single-host credential store. After a successful refresh or OAuth bootstrap, reconcile the file to the approved encrypted off-host recovery source. If no valid copy survives, run `Rscript scripts/bootstrap_strava_oauth.R` through Compose and store the resulting runtime file off-host without displaying it.

### Google Health

Google refresh tokens normally do not rotate on every refresh, so the Mac `.Renviron` may be a usable off-Pi copy. This has not been verified as canonical. If the token is invalid, revoked, expired, or lacks scopes, repeat consent with `access_type=offline`, `prompt=consent`, and both documented Google Health read scopes. Then run the existing auth check before production ingestion.

### OAuth incident steps

1. Retrieve client ID, client secret, and refresh token from the secure source.
2. If the token's freshness is unknown, test through the application's diagnostic without logging its value.
3. Re-authorise through the provider if refresh returns `invalid_grant` or required scopes are absent.
4. Store the new token in the Pi credential mechanism and the off-host canonical secret source.
5. Confirm no obsolete scheduled environment still holds an old token.

## State classification

### A. Reproducible state

- both Git repositories once all intended changes are committed and pushed;
- Dockerfile, `renv.lock`, R code, SQL DDL, tracked configuration;
- Compose services, MariaDB empty-volume initialisation, health check, and grants;
- host directory creation;
- documented production paths and job wrappers.

### B. Recoverable data state

- logical dumps for Admin, Raw, Silver, and Gold;
- backup metadata already present inside the Admin dump, except that the newest backup's post-dump metadata may only appear in `latest_success.json` until a later backup;
- `latest_success.json` and retained backup inventory on Mac storage.

### C. Machine-specific configuration and secrets

- Pi `compose/.env` — recovery source unknown;
- runtime credential file — durable on Pi, but its encrypted off-host recovery source and rotation reconciliation are not yet proven;
- Google token/client credentials — Mac copy exists, canonical status unknown;
- MariaDB root password — recovery source unknown;
- app DB password — Mac copy exists, canonical status unknown;
- `NTFY_TOPIC` — Mac copy exists, canonical status unknown;
- Wi-Fi credential — recovery source unknown;
- SSH server configuration and `authorized_keys` — rebuild from Mac key, policy incomplete;
- Pi user crontab — reproducible through `scripts/install_cron.sh`, but deliberately activated only after recovery validation;
- hostname, timezone, locale, Docker group, firewall, package/service settings — manual/partially documented.

### D. Disposable state

- all `cycling_platform_stage` contents;
- platform and wrapper logs unless needed for incident investigation;
- Docker images/build cache/networks and stopped/temporary containers;
- `/tmp` runtime copies and lock directories;
- R temporary files and regenerated access tokens.

### What would be permanently lost if the SD card died now?

Known disposable losses are stage contents, logs, caches, and temporary runtime state. Potentially permanent or operationally blocking losses are the Pi's `compose/.env`, MariaDB root password, current OAuth refresh-token state, SSH/firewall/service configuration, and any manual host changes not represented in Git. Whether those are truly lost depends on off-host copies that have not been documented or verified. The durable database content should survive through the Mac dumps, subject to a successful restore test.

## Implemented bootstrap architecture

The design remains small and Bash-based:

1. `scripts/bootstrap.sh` is the single fresh-host entry point after OS imaging and repository clone. It verifies Debian/Raspberry Pi OS on ARM64, `tim`, `/home/tim`, `cycling-prod`, `C.UTF-8`, and `Europe/London`; installs real host utilities and cron; invokes Docker setup; enables Docker and cron; configures docker-group membership; and creates the production directories.
2. `scripts/install_docker.sh` installs Docker Engine, Buildx, and the Compose plugin from Docker's official Debian repository only when Docker/Compose are absent. It enables and verifies the daemon. A partial pre-existing Docker installation fails for manual review rather than being replaced destructively.
3. `scripts/install_cron.sh` owns only the marked cycling-platform crontab block. It preserves unrelated entries, collapses duplicate managed blocks, is idempotent, and supports `--show` and `--dry-run`.

`bootstrap.sh` intentionally does **not** invoke `install_cron.sh`. Bootstrap makes a host capable of production; cron resumes production. Keeping activation explicit prevents ETL or validation from running before secrets and databases have been restored and accepted.

OS imaging, hostname/user/SSH/network creation, secrets, and database restore remain outside host bootstrap.

## Phase 1 — Prepare Raspberry Pi OS

1. Write a current supported Raspberry Pi OS Lite 64-bit image.
2. In Raspberry Pi Imager, configure hostname `cycling-prod`, user `tim`, timezone `Europe/London`, Wi-Fi, SSH, and the Mac public key.
3. Boot and verify from the Mac:

```bash
ssh tim@cycling-prod.local
hostnamectl
cat /etc/os-release
timedatectl status
```

4. Apply OS updates and reboot if required.

**TODO:** record the exact supported OS release, update commands, locale, Wi-Fi/mDNS expectations, and any non-default Pi firmware settings after auditing the live host.

## Phase 2 — Establish host baseline

Install the minimum seed packages needed to retrieve the infrastructure repository:

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates git
```

Verify the imaging prerequisites before cloning:

```bash
hostname -s        # cycling-prod
id -un             # tim
dpkg --print-architecture  # arm64
timedatectl status
```

The repository bootstrap installs and verifies the remaining host baseline after Phase 3.

## Phase 3 — Clone infrastructure and platform

```bash
cd /home/tim
git clone --branch main --single-branch \
  https://github.com/tim-jc/cycling-infrastructure.git
git clone --branch main --single-branch \
  https://github.com/tim-jc/cycling-platform.git

git -C /home/tim/cycling-infrastructure status -sb
git -C /home/tim/cycling-platform status -sb
```

Both should be clean and track `origin/main`. Record the recovered commit IDs in the incident log.

## Phase 4 — Install machine configuration

Run the host bootstrap now that the infrastructure repository exists:

```bash
cd /home/tim/cycling-infrastructure
./scripts/bootstrap.sh
```

The script installs host packages, Docker Engine and Compose, and cron; enables required services; establishes directory permissions; creates an empty owner-only runtime credential file only when absent; and reports when a logout/reconnect is required for docker-group membership. It is safe to rerun, preserves existing runtime credential contents, and does not install production cron.

The production recovery path must use the `cycling-prod` hostname and run bootstrap without an override. For an isolated recovery rehearsal while the real production host remains online, use a deliberately different hostname and explicitly tell bootstrap which hostname to require:

```bash
EXPECTED_HOSTNAME=cycling-recovery-test ./scripts/bootstrap.sh
```

The override changes only the hostname safety check, is reported in bootstrap output, and must be a non-empty single-label hostname. There is no option to skip the check. Do not use the override during an actual production recovery.

After reconnecting if requested, verify:

```bash
ls -ld /srv/cycling/data/mariadb /srv/cycling/logs/platform /srv/cycling/config/platform
stat -c "%U %G %a %n" /srv/cycling/config/platform/runtime.Renviron
id
docker info
```

Do **not** run `scripts/install_cron.sh` yet. Confirm the MariaDB path is the intended new/empty recovery target before Phase 6. Bootstrap preserves ownership and permissions on an existing MariaDB directory to avoid altering production data.

## Phase 5 — Restore secrets and configuration

1. Retrieve deployment secrets and the runtime credential file from the approved encrypted off-host canonical source.
2. Create `/home/tim/cycling-infrastructure/compose/.env` with mode `0600` from `.env.example`; it contains MariaDB credentials, OAuth client credentials, port, and notification configuration, but no refresh tokens.
3. Restore `/srv/cycling/config/platform/runtime.Renviron` with owner `tim:tim` and mode `0600` without printing its contents. If no valid Strava token survives, complete OAuth bootstrap after the image is built and immediately refresh the encrypted off-host copy.
4. Populate all named values; never echo either completed file or include it in incident logs.
5. Confirm the Compose file is ignored and untracked:

```bash
chmod 600 /home/tim/cycling-infrastructure/compose/.env
git -C /home/tim/cycling-infrastructure check-ignore compose/.env
git -C /home/tim/cycling-infrastructure status --short
```

6. Validate Compose interpolation and the runtime mount without printing rendered secrets or file contents into logs:

```bash
cd /home/tim/cycling-infrastructure/compose
docker compose config --quiet
```

**TODO:** define the canonical encrypted secret source and restoration procedure. Confirm or rotate the MariaDB root password, app password, OAuth tokens, and notification topic.

## Phase 6 — Start empty MariaDB

Safety precondition: `/srv/cycling/data/mariadb` must be the new recovery target, not a populated or live environment.

```bash
cd /home/tim/cycling-infrastructure/compose
docker compose pull mariadb
docker compose up -d mariadb
docker compose ps
docker compose logs --tail=200 mariadb
```

The first-initialisation script should create all five schemas and grant the application user privileges. It runs only when MariaDB initialises an empty data directory.

Verify without exposing passwords:

```bash
docker compose exec -T mariadb sh -c '
  export MYSQL_PWD="$MARIADB_PASSWORD"
  exec mariadb --user="$MARIADB_USER" --batch --skip-column-names \
    -e "SHOW DATABASES LIKE '\''cycling_platform_%'\'';"
'
```

Expected: Admin, Raw, Stage, Silver, and Gold. **TODO:** add a version-controlled preflight that also verifies grants and exactly five expected schemas.

## Phase 7 — Restore production databases

### Obtain one matched backup set

On the Mac, select one timestamp prefix that has exactly Admin, Raw, Silver, and Gold dumps. Do not copy a Stage dump. Verify the retained files against `latest_success.json` where available.

Create a protected transfer directory on the Pi, then copy the four files. Replace the example prefix with the selected run:

```bash
ssh tim@cycling-prod.local 'mkdir -p -m 700 /home/tim/recovery'

scp \
  /path/to/backups/2026-07-27_050000_cycling_platform_admin.sql.gz \
  /path/to/backups/2026-07-27_050000_cycling_platform_raw.sql.gz \
  /path/to/backups/2026-07-27_050000_cycling_platform_silver.sql.gz \
  /path/to/backups/2026-07-27_050000_cycling_platform_gold.sql.gz \
  tim@cycling-prod.local:/home/tim/recovery/
```

The helper takes the common path prefix without `_cycling_platform_...sql.gz`:

```text
/home/tim/recovery/2026-07-27_050000
```

### Check without restoring

Run check-only first; omitting the option also defaults to check-only:

```bash
cd /home/tim/cycling-infrastructure
./scripts/restore_platform_database.sh \
  --check-only \
  /home/tim/recovery/2026-07-27_050000
```

The check requires exactly the four expected files, rejects a Stage or other unexpected dump for that prefix, checks non-zero size and `gzip -t`, verifies `compose/.env`, requires healthy MariaDB with no platform job running, confirms all five schemas, and proves Admin/Raw/Silver/Gold contain no tables, views, routines, triggers, or events.

Other timestamped sets may coexist in the same directory because the supplied prefix selects one unambiguous set. Mixed timestamps cannot satisfy the exact filenames for that prefix.

### Restore the fresh target

A restore requires the explicit disaster-recovery flag:

```bash
./scripts/restore_platform_database.sh \
  --confirm-empty-target \
  /home/tim/recovery/2026-07-27_050000
```

`--confirm-empty-target` does not override the emptiness test. The helper always refuses a populated persistent target. It restores in dependency order:

1. `cycling_platform_admin`
2. `cycling_platform_raw`
3. `cycling_platform_silver`
4. `cycling_platform_gold`

Stage must exist but is never restored. Imports use `mariadb` inside the existing MariaDB Compose container, so no host database client is required. The script preserves pipeline/import failures and stops before later schemas.

### Validation and platform smoke test

After all four imports, the helper performs read-only checks and reports:

- base-table count for each restored schema;
- Silver activities row count and `start_date_local` range when that table exists;
- continued existence of `cycling_platform_stage`.

Review those results against known production expectations. Then build the application, apply idempotent schema additions (including disposable Stage objects), and run the application smoke test without ETL:

```bash
cd /home/tim/cycling-infrastructure/compose
docker compose build cycling-platform
docker compose run --rm cycling-platform Rscript bootstrap_platform.R
docker compose run --rm cycling-platform \
  Rscript --vanilla tests/smoke_check.R
```

Do not run daily ingestion or enable cron yet. Complete the OAuth, notification, logical-data, and deep-validation acceptance checks in Phase 10 first.

### Restore safety limits

The emptiness check is intentionally stricter than checking row counts: any persistent-schema database object causes refusal. It cannot prevent an external process from racing the restore after the preflight, so production cron must remain disabled and no manual platform job may run. The four schema imports are not one cross-database transaction. If an import fails, the target is partially restored and the helper will refuse a retry; recreate the fresh recovery target and start again rather than importing over partial state.

The restore path still assumes logical dump compatibility with the target `mariadb:11` image. A full isolated restore test with representative Raw and Silver sizes remains required before Database Restore can be rated READY.
## Phase 8 — Deploy cycling-platform

The current deployment helper:

```bash
/home/tim/cycling-infrastructure/scripts/deploy_platform.sh
```

performs `git pull --ff-only`, builds the image, and lists it. It does not run ETL, which is correct for deployment safety.

Fresh-host prerequisites it assumes:

- platform checkout exists at `/home/tim/cycling-platform`;
- infrastructure Compose exists at `/home/tim/cycling-infrastructure/compose`;
- current platform branch is the intended production branch;
- Git working tree is suitable for build;
- Docker and Compose work for `tim`;
- Internet/registry/CRAN dependency access works;
- Compose `.env` exists;
- the Dockerfile and `renv.lock` restore successfully on ARM64.

**TODO:** make deployment fail clearly unless the repository is clean, on the intended branch, and aligned with its upstream; run `docker compose config --quiet`; and add a non-ETL image smoke check. Pinning an immutable release/commit is preferable during an incident.

## Phase 9 — Restore scheduling

Only after database and application acceptance checks pass, inspect and install the canonical managed block:

```bash
cd /home/tim/cycling-infrastructure
./scripts/install_cron.sh --show
./scripts/install_cron.sh --dry-run
./scripts/install_cron.sh
crontab -l
```

The installer replaces every existing balanced `CYCLING_PLATFORM` managed block with one canonical block and preserves unrelated cron entries. It refuses malformed/unbalanced markers and is safe to rerun. Run it as `tim`, never through `sudo`.

Confirm Mac scheduling contains only the 05:00 backup and Mac-hosted analytics schedules; do not reintroduce platform execution on the Mac.

## Phase 10 — Production validation

Before enabling cron, verify:

- [ ] `docker compose config --quiet` succeeds.
- [ ] `docker compose ps` shows MariaDB healthy.
- [ ] exactly five expected platform schemas exist.
- [ ] application user grants cover all five and no unintended global privileges.
- [ ] Admin, Raw, Silver, and Gold contain expected tables.
- [ ] table/row-count comparisons against pre-incident or backup metadata are plausible.
- [ ] Stage exists but contains no required recovered state.
- [ ] `docker compose run --rm cycling-platform Rscript bootstrap_platform.R` succeeds.
- [ ] a DB connectivity/read-only smoke check succeeds without running ingestion.
- [ ] Google Health auth check succeeds.
- [ ] Strava token refresh/persistence is verified without losing the rotated token.
- [ ] deep validation succeeds or every warning/failure is understood.
- [ ] ntfy notification delivery succeeds.
- [ ] logs can be written to `/srv/cycling/logs/platform`.
- [ ] Mac can resolve `cycling-prod.local` and connect to the published MariaDB port.
- [ ] Mac backup credentials connect to the restored database.
- [ ] backup observability is understood after the restore.

The existing deep validation writes operational validation records and can notify; treat it as an acceptance action rather than a purely read-only probe.

**TODO:** define a supported read-only smoke command and expected row/table-count report. Record expected minimum tables and critical referential checks in a restore test specification.

## Phase 11 — Resume production

It is safe to resume only when:

1. the four durable schemas are restored and validated;
2. token persistence and notification delivery work;
3. no competing Mac platform schedule exists;
4. Pi cron is installed with the intended timezone;
5. the next backup can reach the restored MariaDB;
6. incident/recovery commit IDs, backup prefix, validation results, and credential rotations are recorded securely.

Install cron, list it, and monitor the first daily and validation runs. Confirm the following 05:00 Mac backup creates a complete four-file set and records/reconciles observability.

## Disaster recovery checklist

- [ ] Image replacement SD card with Raspberry Pi OS Lite 64-bit.
- [ ] Configure `cycling-prod`, `tim`, SSH key, Wi-Fi, timezone, and locale.
- [ ] Patch OS; verify time, DNS, mDNS, and storage.
- [ ] Install/verify Git, Docker Engine, Compose plugin, and cron.
- [ ] Clone both repositories to exact `/home/tim` paths and record commits.
- [ ] Run infrastructure bootstrap; verify `/srv/cycling` permissions.
- [ ] Retrieve secrets from the approved off-host store.
- [ ] Create protected `compose/.env`; restore the protected runtime credential file or plan OAuth re-authorisation.
- [ ] Keep application cron disabled.
- [ ] Start empty MariaDB and verify five schemas/grants.
- [ ] Select and verify one complete four-file backup set.
- [ ] Restore Admin, Raw, Silver, Gold in order; do not restore Stage.
- [ ] Build platform image and run idempotent application bootstrap.
- [ ] Run DB, application, OAuth, notification, and deep-validation checks.
- [ ] Confirm Mac connectivity and backup readiness.
- [ ] Install Pi cron only after acceptance.
- [ ] Observe first 02:00, 03:30, and following 05:00 runs.
- [ ] Update secure recovery record with results and any rotated credentials.

## Known gaps / TODO

1. Audit and record live Pi packages, services, firewall, SSH, mDNS, timezone/locale, Docker install source, group membership, and Pi-specific configuration.
2. Choose and test an encrypted off-host canonical secret source.
3. Establish and test encrypted off-host backup/reconciliation for `compose/.env` and the runtime credential file.
4. Exercise `bootstrap.sh`, Docker installation, filesystem permissions, and cron dry-run/install on a freshly imaged spare SD card.
5. Exercise the guarded restore helper with a complete backup against an isolated MariaDB 11 target and record expected logical counts.
6. Exercise a full restore using the latest four-file set against an isolated MariaDB 11 instance.
7. Confirm Mac 05:00 scheduler ownership; no matching current-user crontab entry was readable during this audit despite current backup artefacts.
8. Decide whether production deploys `main` or immutable release tags/commits.
9. Define firewall/LAN exposure policy for published MariaDB port 3306.

## Recovery test

Prove this runbook at least quarterly or after major infrastructure/schema changes using a spare SD card, spare Pi, or isolated ARM64-equivalent environment. Never target live production data.

A successful test must:

1. begin with no Pi filesystem state;
2. use only Git, the approved secret source, and a selected off-host backup set;
3. time every phase and record manual decisions;
4. restore all four durable schemas and recreate empty Stage;
5. compare schema inventory, critical row counts, and application validation results;
6. prove token refresh persistence and notification delivery;
7. prove cron installation in dry-run form without allowing duplicate production jobs;
8. prove a post-restore Mac backup and reconciliation;
9. feed every undocumented step back into this runbook or a small idempotent script.

The recovery test is not complete merely because MariaDB starts; normal production operation and the next off-host backup must also succeed.

## Recovery readiness scorecard

| Area | Rating | Reason |
|---|---|---|
| OS/host bootstrap | PARTIAL | Host packages/services are automated; imaging and live manual-state audit remain |
| Docker | PARTIAL | Official-repository install, Compose, group, and startup are automated but not yet exercised on a fresh Pi |
| Filesystem/permissions | PARTIAL | Data, logs, and owner-only runtime credential paths are idempotently created; fresh-host container write testing remains |
| Repository cloning | PARTIAL | URLs, paths, and `main` are clear; release pinning and dirty-tree enforcement are absent |
| Secrets/config | NOT READY | Pi `.env` and root-password recovery source are undocumented |
| OAuth tokens | PARTIAL | Runtime rotation persists on the Pi; encrypted off-host backup/reconciliation and recovery testing remain |
| MariaDB deployment | READY | Empty-volume init creates five schemas and grants with health checking |
| DB restore | PARTIAL | Guarded check/restore and read-only summaries are implemented and mock-tested; a real isolated full restore is still required |
| Application deployment | PARTIAL | Build-only deploy avoids ETL but assumes repos/config/Docker and performs limited verification |
| Cron/scheduling | READY | Canonical managed-block installer is idempotent, preserves unrelated entries, and leaves activation explicit |
| Validation | PARTIAL | Deep validation exists; read-only recovery smoke and restore acceptance baseline are missing |
| Off-host backup continuity | PARTIAL | Current complete Mac sets and status artefact exist; restore proof and scheduler ownership remain gaps |

## Final answer

**Could cycling-prod be rebuilt today after complete SD-card loss? Not with confidence.** A skilled operator could probably reconstruct it using the repositories, Mac `.Renviron`, current backup set, and manual judgement, but several critical values and machine settings have no verified off-host canonical source, and full database/runtime-credential recovery has not been rehearsed. Completing the prioritised TODOs above—especially off-host secret/runtime-file custody, a fresh-host rehearsal, and an isolated full restore test—is required before the answer becomes an unambiguous **YES**.
