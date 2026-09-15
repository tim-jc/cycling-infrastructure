# Grafana operational observability

## Scope

Grafana is the authenticated, LAN-only presentation layer for durable
`cycling-platform` operational telemetry. It does not calculate platform
health, run ETL, own Raw/Silver/Gold data, or replace ntfy.

The initial vertical slice intentionally contains one dashboard and two panels:

* overall platform health from
  `cycling_platform_admin.v_platform_health_latest`;
* latest daily pipeline status from
  `cycling_platform_admin.v_pipeline_run_history`.

The MariaDB account can select only those two views. Broader Admin, Raw,
Reference, Silver and Gold access is deliberately absent.

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
`WARNING` and `CRITICAL`; Grafana owns only their presentation.

Compose, datasource YAML and dashboard JSON are stored in Git. MariaDB stores
operational facts. Grafana SQLite stores mutable application state. UI edits to
provisioned dashboards are disposable: export useful changes, review the JSON,
and promote it to Git.

Grafana can later present time series, tables, status panels, variables and
filters, and connect to additional appropriate data sources. Future reviewed
dashboards could show freshness, performance, validation, recovery or request
failures. Infrastructure metrics or logs would need their own datasource.
Grafana alerting is disabled; ntfy remains the attention channel.

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
restart, the datasource and two-panel dashboard must return. Confirm crontab is
unchanged and no Grafana alert rules exist.

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

## Deliberate limits

This slice has no TLS, public access, proxy, plugins, alerts, extended panels or
host metrics. The backup warning and Gold timing refinement remain platform
concerns and are not recreated in Grafana.
