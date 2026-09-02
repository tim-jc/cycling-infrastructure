#!/bin/sh
set -eu

: "${MARIADB_USER:?MARIADB_USER must be set}"
: "${MARIADB_MCP_READER_USER:?MARIADB_MCP_READER_USER must be set}"
: "${MARIADB_MCP_READER_PASSWORD:?MARIADB_MCP_READER_PASSWORD must be set}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD must be set}"

case "$MARIADB_MCP_READER_USER" in
  ''|*[!a-zA-Z0-9_.-]*)
    printf '%s\n' 'Unsafe MariaDB cycling-mcp account name.' >&2
    exit 1
    ;;
esac
[ "$MARIADB_MCP_READER_USER" != "$MARIADB_USER" ] || {
  printf '%s\n' 'cycling-mcp and platform accounts must differ.' >&2
  exit 1
}

sql_user=$(printf '%s' "$MARIADB_MCP_READER_USER" | sed "s/'/''/g")
sql_password=$(printf '%s' "$MARIADB_MCP_READER_PASSWORD" | sed "s/'/''/g")
export MYSQL_PWD="$MARIADB_ROOT_PASSWORD"

mariadb --user=root <<SQL
CREATE USER IF NOT EXISTS '$sql_user'@'%' IDENTIFIED BY '$sql_password';
ALTER USER '$sql_user'@'%' IDENTIFIED BY '$sql_password';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$sql_user'@'%';
GRANT SELECT ON cycling_platform_silver.* TO '$sql_user'@'%';
SQL
