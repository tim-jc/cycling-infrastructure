#!/bin/sh
set -eu

: "${MARIADB_USER:?MARIADB_USER must be set}"
: "${MARIADB_PASSWORD:?MARIADB_PASSWORD must be set}"
: "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD must be set}"

sql_user=$(printf '%s' "$MARIADB_USER" | sed "s/'/''/g")
sql_password=$(printf '%s' "$MARIADB_PASSWORD" | sed "s/'/''/g")

mariadb --protocol=socket -uroot -p"$MARIADB_ROOT_PASSWORD" <<SQL
CREATE DATABASE IF NOT EXISTS cycling_platform_admin;
CREATE DATABASE IF NOT EXISTS cycling_platform_raw;
CREATE DATABASE IF NOT EXISTS cycling_platform_stage;
CREATE DATABASE IF NOT EXISTS cycling_platform_silver;
CREATE DATABASE IF NOT EXISTS cycling_platform_gold;

CREATE USER IF NOT EXISTS '$sql_user'@'%' IDENTIFIED BY '$sql_password';
GRANT ALL PRIVILEGES ON cycling_platform_admin.* TO '$sql_user'@'%';
GRANT ALL PRIVILEGES ON cycling_platform_raw.* TO '$sql_user'@'%';
GRANT ALL PRIVILEGES ON cycling_platform_stage.* TO '$sql_user'@'%';
GRANT ALL PRIVILEGES ON cycling_platform_silver.* TO '$sql_user'@'%';
GRANT ALL PRIVILEGES ON cycling_platform_gold.* TO '$sql_user'@'%';
SQL
