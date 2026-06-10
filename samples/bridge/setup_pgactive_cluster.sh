#!/usr/bin/env bash
#
# Stand up a 3-node pgactive mesh (the AWS side of the pgactive<->spock
# bridge demo). Node 3 doubles as the bridge node, so it loads both the
# pgactive and spock extensions and gets the relevant spock.* GUCs set.
#
# Requirements:
#   * PostgreSQL 17 binaries on PATH (initdb, pg_ctl, psql)
#   * pgactive 2.1.8+ and spock 6.0.0-devel+ installed for that PG
#   * Ports 15431-15433 free
#
# Data directories are created under $BRIDGE_DEMO_DATA
# (default: $PWD/data). See ../README.md.
#
set -euo pipefail

DATA_BASE="${BRIDGE_DEMO_DATA:-$PWD/data}"
DBNAME="pgadb"
PORTS=(15431 15432 15433)

dsn() { echo "host=localhost port=${PORTS[$(($1-1))]} dbname=${DBNAME} user=postgres"; }

mkdir -p "$DATA_BASE"

# Initialize, configure, and start each node.
# Node 3 doubles as a bridge to a spock cluster, so it loads both extensions
# and gets the spock.* settings.
for i in 1 2 3; do
    DATADIR="${DATA_BASE}/${i}"
    PORT="${PORTS[$((i-1))]}"

    rm -rf "$DATADIR"
    initdb -D "$DATADIR" -U postgres --no-locale --encoding=UTF8 -A trust >/dev/null

    if [ "$i" = "3" ]; then
        SPL="'pgactive,spock'"
        EXTRA_GUCS=$(cat <<EOF
spock.enable_ddl_replication = 'on'
spock.include_ddl_repset = 'on'
spock.allow_ddl_from_functions = 'on'
spock.save_resolutions = 'on'
EOF
)
    else
        SPL="'pgactive'"
        EXTRA_GUCS=""
    fi

    cat >> "${DATADIR}/postgresql.conf" <<EOF
listen_addresses = 'localhost'
port = ${PORT}
shared_preload_libraries = ${SPL}
wal_level = logical
max_wal_senders = 16
max_replication_slots = 16
max_worker_processes = 24
track_commit_timestamp = on
pgactive.skip_ddl_replication = false
pgactive.forward_non_peer_origins = on
${EXTRA_GUCS}
log_line_prefix = '%t [node${i}] '
EOF

    cat >> "${DATADIR}/pg_hba.conf" <<EOF
host replication all 127.0.0.1/32 trust
host replication all ::1/128 trust
EOF

    pg_ctl -D "$DATADIR" -l "${DATADIR}/server.log" -w start
done

# Create the database and the extension on each node
for PORT in "${PORTS[@]}"; do
    psql -h localhost -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
         -c "CREATE DATABASE ${DBNAME}"
    psql -h localhost -p "$PORT" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
         -c "CREATE EXTENSION pgactive"
done

# Form the group on node 1
psql -h localhost -p "${PORTS[0]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<SQL
SELECT pgactive.pgactive_create_group(
    node_name := 'node1',
    node_dsn  := '$(dsn 1)'
);
SELECT pgactive.pgactive_wait_for_node_ready(timeout => 60);
SQL

# Join nodes 2 and 3
for i in 2 3; do
    psql -h localhost -p "${PORTS[$((i-1))]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<SQL
SELECT pgactive.pgactive_join_group(
    node_name      := 'node${i}',
    node_dsn       := '$(dsn $i)',
    join_using_dsn := '$(dsn 1)'
);
SELECT pgactive.pgactive_wait_for_node_ready(timeout => 120);
SQL
done

# Create a table (DDL must be replicated explicitly in pgactive)
psql -h localhost -p "${PORTS[0]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<'SQL'
SELECT pgactive.pgactive_replicate_ddl_command($DDL$
    CREATE TABLE public.demo (
        id  integer PRIMARY KEY,
        msg text NOT NULL
    );
$DDL$);
SQL

# Insert 3 rows on node 1
psql -h localhost -p "${PORTS[0]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO public.demo VALUES
    (1, 'hello from node1'),
    (2, 'second row'),
    (3, 'third row');
SQL

# Give replication a moment to settle, then show the rows on each node
sleep 2
echo
for i in 1 2 3; do
    echo "--- node${i} (port ${PORTS[$((i-1))]}) ---"
    psql -h localhost -p "${PORTS[$((i-1))]}" -U postgres -d "${DBNAME}" \
         -c "SELECT * FROM public.demo ORDER BY id"
done

echo
echo "Cluster up. Connect with:"
for i in 1 2 3; do
    echo "  psql -h localhost -p ${PORTS[$((i-1))]} -U postgres -d ${DBNAME}"
done
echo
echo "Stop the cluster with:"
for i in 1 2 3; do
    echo "  pg_ctl -D ${DATA_BASE}/${i} stop"
done
