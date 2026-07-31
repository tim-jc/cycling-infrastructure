#!/bin/sh
set -eu

fail() { printf '[mariadb-guard] ERROR: %s\n' "$*" >&2; exit 1; }
unsafe_password() {
  normalized=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$normalized" in
    ''|replace-me|replace_me|changeme|change-me|password|example|example-password|example_password) return 0 ;;
    *) return 1 ;;
  esac
}

data_directory=${CYCLING_MARIADB_DATA_DIR:-/var/lib/mysql}
official_entrypoint=${CYCLING_MARIADB_OFFICIAL_ENTRYPOINT:-/usr/local/bin/docker-entrypoint.sh}

if [ ! -d "$data_directory/mysql" ]; then
  : "${MARIADB_PASSWORD:?MARIADB_PASSWORD must be set}"
  : "${MARIADB_ROOT_PASSWORD:?MARIADB_ROOT_PASSWORD must be set}"
  unsafe_password "$MARIADB_PASSWORD" && fail "MARIADB_PASSWORD is empty or a known placeholder; refusing first initialization."
  unsafe_password "$MARIADB_ROOT_PASSWORD" && fail "MARIADB_ROOT_PASSWORD is empty or a known placeholder; refusing first initialization."
  printf '%s\n' '[mariadb-guard] New data directory passed credential safety checks.'
else
  printf '%s\n' '[mariadb-guard] Existing data directory detected; environment password changes do not rotate existing database users.' >&2
fi

if [ "$#" -eq 0 ]; then
  set -- mariadbd
fi

exec "$official_entrypoint" "$@"
