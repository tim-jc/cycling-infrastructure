#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$SCRIPT_DIR/preflight.sh"
"$SCRIPT_DIR/compose.sh" up -d mariadb
"$SCRIPT_DIR/compose.sh" ps mariadb
"$SCRIPT_DIR/reconcile_reference_database.sh"
