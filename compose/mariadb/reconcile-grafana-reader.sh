#!/bin/sh
set -eu

: "${MARIADB_USER:?MARIADB_USER must be set}"
: "${MARIADB_GRAFANA_READER_USER:?MARIADB_GRAFANA_READER_USER must be set}"
: "${MARIADB_GRAFANA_READER_PASSWORD:?MARIADB_GRAFANA_READER_PASSWORD must be set}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD must be set}"

case "$MARIADB_GRAFANA_READER_USER" in
  ''|*[!a-zA-Z0-9_.-]*)
    printf '%s\n' 'Unsafe MariaDB Grafana account name.' >&2
    exit 1
    ;;
esac
[ "$MARIADB_GRAFANA_READER_USER" != "$MARIADB_USER" ] || {
  printf '%s\n' 'Grafana and platform accounts must differ.' >&2
  exit 1
}

sql_user=$(printf '%s' "$MARIADB_GRAFANA_READER_USER" | sed "s/'/''/g")
sql_password=$(printf '%s' "$MARIADB_GRAFANA_READER_PASSWORD" | sed "s/'/''/g")
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"

mariadb --user=root <<SQL
CREATE USER IF NOT EXISTS '$sql_user'@'%' IDENTIFIED BY '$sql_password';
ALTER USER '$sql_user'@'%' IDENTIFIED BY '$sql_password';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$sql_user'@'%';
GRANT SELECT ON cycling_platform_admin.v_platform_health_latest TO '$sql_user'@'%';
GRANT SELECT ON cycling_platform_admin.v_pipeline_run_history TO '$sql_user'@'%';
SQL
