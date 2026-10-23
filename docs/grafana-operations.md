# Grafana operational observability

## Scope

Grafana is the authenticated, LAN-only presentation layer for durable
`cycling-platform` operational telemetry. It does not calculate platform
health, run ETL, own Raw/Silver/Gold data, or replace ntfy.

The source-controlled `Platform Operations` dashboard is one operational entry
point with three sections:

* **Current health** presents governed platform, daily-pipeline and backup
  health without recalculating their classifications;
* **Current operational debt** lists current non-healthy conditions, including
  `UNKNOWN`, from the governed debt contract;
* **Recent execution history** presents daily pipeline runs, the phases of one
  selected run, validation history, backup attempts/recovery points and Google
  Health ingestion failures/recoveries.

Current health and event history are intentionally distinct. A recovered
incident remains in history without remaining current debt. Active executions
can appear in history but do not establish a completed assessment.

## How the pieces fit

* **Grafana server/container** runs the web application on `cycling-prod`.
* **Datasource** describes the read-only MariaDB connection.
* **Dashboard** is the named page, `Platform Operations`.
* **Panel** is one visual inside that dashboard.
* **Query** is the SQL a panel sends through the datasource.
* **Provisioning** loads datasource and dashboard definitions from Git.
* **SQLite state** in `/srv/cycling/data/grafana` stores Grafana users,
  sessions and preferences. It is not the source of platform telemetry.

One displayed value travels through the system as follows:

```text
cycling-platform calculates platform health
  -> the Admin view exposes health_status
  -> cycling_grafana_reader may SELECT that view
  -> the Grafana datasource connects to MariaDB
  -> the panel executes its small SELECT
  -> Grafana maps and renders the returned status
  -> the authenticated browser displays it
```

On refresh, Grafana reruns the panel queries. It does not recalculate health or
copy Admin data into SQLite. The platform owns the meaning of `HEALTHY`,
`WARNING`, `CRITICAL` and `UNKNOWN`; Grafana owns only their presentation.

The dashboard consumes exactly these public Admin contracts:

* `v_platform_health_latest`;
* `v_operational_debt_latest`;
* `v_pipeline_run_history`;
* `v_pipeline_phase_history`;
* `v_validation_history`;
* `v_backup_health_latest`;
* `v_backup_history`;
* `v_google_health_daily_ingestion_failure_history`.

The MariaDB Grafana account has `SELECT` on exactly those eight `SQL SECURITY
DEFINER` views. It has no base-table, Raw, Reference, Silver, Gold, write or
schema privileges. Reconciliation revokes all privileges before restoring the
allowlist, and host-side readiness verifies the exact contract. The host
helper streams the current checked-out reconciliation source into MariaDB;
this avoids executing an older file-bind inode retained by a running container
after an immutable Git checkout.

The daily-pipeline health stat reads the `latest_daily_pipeline` condition from
`v_operational_debt_latest`. It does not select a run by ID. The pipeline-run
dashboard variable is only a history drill-down: it is populated by recent
daily runs and filters `v_pipeline_phase_history`. Single-value SQL-string
interpolation plus an unsigned cast prevents arbitrary SQL substitution.

Validation execution, governed outcome and health remain separate columns.
Backup history distinguishes a physical attempt from a complete verified
recovery point. Google Health `RECOVERED`, `UNRESOLVED` and `UNKNOWN` values are
displayed directly; Grafana does not recreate coverage logic.

Compose, datasource YAML and dashboard JSON are stored in Git. MariaDB stores
operational facts. Grafana SQLite stores mutable application state. UI edits to
provisioned dashboards are disposable: export useful changes, review the JSON,
and promote it to Git.

The dashboard defaults to the previous seven days, displays timestamps in UTC,
and refreshes every two minutes. Historical queries are time-filtered and bounded to 50 rows; the
current debt query is deterministically bounded to 100 rows. Grafana alerting
is disabled; ntfy remains the attention channel.

## Configuration and security

Copy the Grafana entries from `compose/.env.example` into protected mode-0600
`compose/.env`. `GRAFANA_BIND_ADDRESS` must be the Pi's explicit LAN IPv4
address; wildcard, loopback and example addresses are rejected. Do not expose
port 3000 through the router.

The Grafana administrator and MariaDB reader use separate credentials. Because
Grafana provisioning expands `$` expressions, the reader password must not
contain `$`; preflight enforces this rather than risking altered credentials.

The datasource is non-editable and has stable UID `cycling-platform-admin`.
The approved views must remain `SQL SECURITY DEFINER`, allowing the reader to
query them without privileges on their underlying tables.

## Deployment and acceptance

Before deployment, inspect Pi capacity:

```bash
free -h
df -h /srv/cycling
```

Prepare the persistent directory and validate configuration:

```bash
cd ~/cycling-infrastructure
./scripts/bootstrap.sh
./scripts/preflight.sh
```

Bootstrap creates `/srv/cycling/data/grafana`, owned by Grafana UID/GID 472 and
mode 0750. Deploy only the vertical slice:

```bash
./scripts/deploy_grafana.sh
```

The script reconciles the reader, pulls the exact image, verifies ARM64, starts
Grafana, waits for `/api/health`, and rechecks grants. It does not run ingestion
or change schedules.

Browse to `http://<GRAFANA_BIND_ADDRESS>:<GRAFANA_PORT>`, authenticate with the
local administrator, and open `Cycling Platform / Platform Operations`.

Acceptance commands:

```bash
./scripts/compose.sh ps grafana mariadb
./scripts/reconcile_grafana_reader.sh --check-only
./scripts/compose.sh exec -T grafana wget -qO- http://127.0.0.1:3000/api/health
./scripts/compose.sh restart grafana
./scripts/compose.sh ps grafana
```

In a private browser window, anonymous access must redirect to login. After a
restart, the datasource and expanded dashboard must return. Confirm crontab is
unchanged and no Grafana alert rules exist.

Verify all eight view contracts with the protected reader and compare the
three current-health values and non-healthy debt rows directly with Admin.
Confirm the pipeline selector changes only the phase table, `UNKNOWN` remains
visible, and recovered Google Health incidents remain in history.

The Google Health recovery view performs interval-coverage work before the
dashboard limit is applied. On production data, inspect the plan and measured
runtime rather than assuming `LIMIT 50` makes it cheap:

```sql
EXPLAIN
SELECT failed_run_entity_id, recovery_status, recovery_completed_at_utc
FROM cycling_platform_admin.v_google_health_daily_ingestion_failure_history
WHERE failure_started_at_utc BETWEEN UTC_TIMESTAMP() - INTERVAL 7 DAY AND UTC_TIMESTAMP()
ORDER BY failure_started_at_utc DESC, failed_run_entity_id DESC
LIMIT 50;
```

Run the corresponding `SELECT` with timing enabled, observe MariaDB CPU/load
during several two-minute refreshes, and record the result during production
acceptance. If it is materially expensive, reduce the presentation only after
review; do not add indexes or duplicate recovery semantics in Grafana.

## State backup and recovery

Git restores datasource/dashboard definitions and the encrypted static-config
backup restores credentials. To preserve users, sessions and preferences, take
a stopped copy of SQLite state:

```bash
./scripts/compose.sh stop grafana
sudo tar -C /srv/cycling/data -czf /reviewed/recovery/location/grafana-state.tgz grafana
./scripts/compose.sh up -d grafana
```

Review the recovery destination first. Do not add Grafana state to the atomic
five-database MariaDB backup set. Before upgrades, stop and snapshot Grafana.
Rollback requires the previous image and its matching state snapshot.

## Rollback and deliberate limits

Deploy and rollback only with reviewed immutable infrastructure commits. After
checking out the previous commit, rerun `./scripts/deploy_grafana.sh`; its
revoke-then-grant reconciliation restores the previous dashboard and reader
allowlist as one governed unit. Do not roll back by editing the provisioned
dashboard or MariaDB grants manually.

This slice has no TLS, public access, proxy, plugins, alerts, host metrics or
drill-through to detailed error text. Empty tables use panel descriptions to
state their meaning. Table layout on narrow browsers depends on horizontal
scrolling. Query rendering and production MariaDB performance remain explicit
deployment-acceptance checks rather than claims made by local static tests.
