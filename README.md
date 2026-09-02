# Cycling Infrastructure

This repository is the source of truth for rebuilding and operating `cycling-prod`, the Raspberry Pi 5 production host for the cycling platform.

Production runs MariaDB 11 as a long-running Docker Compose service, with `cycling-platform` and `cycling-analytics` as ephemeral Compose jobs. Cron runs the platform at 02:00 and 20:00, analytics at 02:30 and 20:30, and deep platform validation at 03:30.

MariaDB contains six peer databases:

- `cycling_platform_admin`
- `cycling_platform_raw`
- `cycling_platform_stage`
- `cycling_platform_silver`
- `cycling_platform_gold`
- `cycling_platform_reference`

`cycling_platform_stage` is disposable. Reference is durable even while empty. New off-host backups contain Admin, Raw, Reference, Silver and Gold; historical four-file sets without Reference remain restorable.

MariaDB provisioning also owns a distinct `cycling_mcp_reader`-style account
whose sole privilege is `SELECT` on `cycling_platform_silver.*`. Its configured
name and password are protected values in ignored `compose/.env`; the main
platform application user's privileges are unchanged.

Mac clients connect through `cycling-prod.local`. The Pi-native managed cron block renders analytics and publishes the complete static artefact to Cloudflare Pages through an infrastructure-owned pinned Wrangler container. The Mac is a development and off-host-backup environment; it does not render or publish the production dashboard.

## Repository layout

```text
compose/   Docker Compose definition and first-initialisation script
scripts/   Host bootstrap and cron entry points
docs/      Architecture, operations, baseline, and decisions
```

## Host bootstrap

After Raspberry Pi OS imaging and cloning this repository to its production path, run:

```bash
./scripts/bootstrap.sh
```

The bootstrap orchestrator runs deterministic numbered stages under `bootstrap/`: system update, package installation, Docker configuration, production-directory creation and final verification. If an OS update requires reboot, it exits with status `75` and prints the exact command to rerun after reconnecting. It never starts MariaDB, creates `compose/.env`, restores data or installs application cron.

Bootstrap installs and verifies current host prerequisites but intentionally leaves production cron disabled. Install cron explicitly with `./scripts/install_cron.sh` only after secrets, data, and application validation are complete.

Normal platform deployment uses `./scripts/deploy_platform.sh`. Success requires image build, quiet Compose validation, platform bootstrap/migrations, aggregate platform-owned Reference publication, and publication validation. Deployment does not ingest data or change schedules.

## Production paths

- Repository: `/home/tim/cycling-infrastructure`
- Compose project: `/home/tim/cycling-infrastructure/compose`
- MariaDB data: `/srv/cycling/data/mariadb`
- Platform logs: `/srv/cycling/logs/platform`
- Mutable runtime credentials: `/srv/cycling/config/platform/runtime.Renviron`

- Analytics site: `/srv/cycling/data/analytics/output`
- Cloudflare credential: `/srv/cycling/config/analytics/cloudflare.env`

For production recovery, restore `compose/.env` from its verified encrypted
static-config asset; do not reconstruct it from the example or memory. Then run
`./scripts/preflight.sh` before MariaDB startup. Bootstrap creates the separate,
writable `runtime.Renviron` credential file. Compose mounts its dedicated parent
directory so the application can atomically replace the file without
overwriting credentials during bootstrap. Both files are outside Git and have
separate approved encrypted off-host recovery sources.

Manual age-encrypted runtime credential recovery uses `scripts/backup_runtime_credentials.sh`, `scripts/verify_runtime_credentials.sh`, and `scripts/restore_runtime_credentials.sh`. See [docs/runtime-credential-recovery.md](docs/runtime-credential-recovery.md); the scripts never print credential values.

Use `scripts/compose.sh` for Compose commands so containers receive the physical host identity dynamically. See [docs/operations-guide.md](docs/operations-guide.md) for normal operating procedures. For total host loss, use the [bootstrap and disaster-recovery runbook](docs/bootstrap-runbook.md). The current architecture received DR sign-off in [Bare-metal Recovery Rehearsal 4](docs/recovery-rehearsal-history.md).

Cloudflare publication and its separate encrypted credential recovery contract are documented in [docs/cloudflare-pages-publication.md](docs/cloudflare-pages-publication.md).

Run the complete fail-fast infrastructure test suite with `./tests/run_all.sh`. When Docker is available, it builds and exercises the real pinned Wrangler image offline with networking disabled.
