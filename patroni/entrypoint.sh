#!/bin/bash
set -e
export PATRONI_POSTGRESQL_DATA_DIR=${PATRONI_POSTGRESQL_DATA_DIR:-/var/lib/postgresql/data/patroni}
mkdir -p "$PATRONI_POSTGRESQL_DATA_DIR"
chmod 700 "$PATRONI_POSTGRESQL_DATA_DIR"
exec patroni /etc/patroni.yml