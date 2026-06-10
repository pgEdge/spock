#!/usr/bin/env bash
#
# Stands up a 3-node spock mesh: spock1 (port 25431), spock2 (port 25432),
# and node3 (port 15433) — node3 is the pgactive bridge node from
# setup_pgactive_cluster.sh. Run that first.
#
# Requirements: see setup_pgactive_cluster.sh and ../README.md.
# Uses $BRIDGE_DEMO_DATA for data dirs (default: $PWD/data); must match
# the value used when running setup_pgactive_cluster.sh.
#
set -euo pipefail

DATA_BASE="${BRIDGE_DEMO_DATA:-$PWD/data}"
DBNAME="pgadb"

SPOCK_PORTS=(25431 25432)         # spock1, spock2
NODE3_PORT=15433
NODE3_SPOCK_NAME=node3            # spock-side name for the bridge

dsn_spock() { echo "host=localhost port=${SPOCK_PORTS[$(($1-1))]} dbname=${DBNAME} user=postgres"; }
dsn_node3() { echo "host=localhost port=${NODE3_PORT} dbname=${DBNAME} user=postgres"; }

mkdir -p "$DATA_BASE"

# 1. Init + configure + start spock1 and spock2
for i in 1 2; do
    DATADIR="${DATA_BASE}/spock${i}"
    PORT="${SPOCK_PORTS[$((i-1))]}"

    rm -rf "$DATADIR"
    initdb -D "$DATADIR" -U postgres --no-locale --encoding=UTF8 -A trust >/dev/null

    cat >> "${DATADIR}/postgresql.conf" <<EOF
listen_addresses = 'localhost'
port = ${PORT}
shared_preload_libraries = 'spock'
wal_level = logical
max_wal_senders = 16
max_replication_slots = 16
max_worker_processes = 24
track_commit_timestamp = on
spock.enable_ddl_replication = 'on'
spock.include_ddl_repset = 'on'
spock.allow_ddl_from_functions = 'on'
spock.save_resolutions = 'on'
log_line_prefix = '%t [spock${i}] '
EOF

    cat >> "${DATADIR}/pg_hba.conf" <<EOF
host replication all 127.0.0.1/32 trust
host replication all ::1/128 trust
EOF

    pg_ctl -D "$DATADIR" -l "${DATADIR}/server.log" -w start
done

# 2. Create database + spock extension on spock1, spock2
for PORT in "${SPOCK_PORTS[@]}"; do
    psql -h localhost -p "$PORT" -U postgres -d postgres -v ON_ERROR_STOP=1 \
         -c "CREATE DATABASE ${DBNAME}"
    psql -h localhost -p "$PORT" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
         -c "CREATE EXTENSION spock"
done

# 3. Add the spock extension on node3 (already running with pgactive).
#    A bridge node has both extensions installed locally, but the spock
#    catalogs are local-only — they must not flow through pgactive's mesh
#    to peers that don't have the spock extension. We:
#    (a) suppress replication of the CREATE EXTENSION DDL itself, and
#    (b) apply pgactive's "exclude_rs" seclabel directly to each spock-schema
#        table to exclude it from replication.
#
#    Note: pgactive's pgactive_exclude_table_replication_set / our
#    pgactive_exclude_schema_replication_set wrapper currently refuse to run
#    once the cluster has more than one node. For this bridge use case the
#    table only exists on this node anyway, so applying the underlying
#    seclabel directly is safe — the change has no peer to be inconsistent
#    with. Pgactive should ideally relax that count check for the bridge
#    deployment pattern; until then, we bypass the wrapper.
psql -h localhost -p "${NODE3_PORT}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<'SQL'
SET pgactive.skip_ddl_replication = true;
CREATE EXTENSION spock;

DO $$
DECLARE
    r record;
    n integer := 0;
BEGIN
    FOR r IN
        SELECT c.oid::regclass AS rel
        FROM pg_class c
        JOIN pg_namespace ns ON ns.oid = c.relnamespace
        WHERE ns.nspname = 'spock'
          AND c.relkind IN ('r', 'p')
        ORDER BY c.relname
    LOOP
        EXECUTE format(
            'SECURITY LABEL FOR pgactive ON TABLE %s IS %L',
            r.rel::text,
            '{"sets": ["exclude_rs"]}'
        );
        n := n + 1;
    END LOOP;
    RAISE NOTICE 'excluded % table(s) in schema "spock" from pgactive replication', n;
END
$$;
SQL

# 4. Register each node in spock's catalog
psql -h localhost -p "${SPOCK_PORTS[0]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.node_create(node_name := 'spock1', dsn := '$(dsn_spock 1)')"
psql -h localhost -p "${SPOCK_PORTS[1]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.node_create(node_name := 'spock2', dsn := '$(dsn_spock 2)')"
psql -h localhost -p "${NODE3_PORT}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.node_create(node_name := '${NODE3_SPOCK_NAME}', dsn := '$(dsn_node3)')"

# 5. node3 already has the public.demo table from the pgactive setup — add it
#    to the default replication set so spock subscribers will pick it up.
psql -h localhost -p "${NODE3_PORT}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.repset_add_table('default', 'public.demo')"

# 6. Pre-create the demo table on spock1 and spock2 (synchronize_structure
#    via pg_dump from node3 fails because node3's dump includes
#    CREATE EXTENSION pgactive, which the spock-only nodes can't load).
for PORT in "${SPOCK_PORTS[@]}"; do
    psql -h localhost -p "$PORT" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 -c \
        "CREATE TABLE public.demo (id integer PRIMARY KEY, msg text NOT NULL)"
done

# 7. spock1 subscribes to node3 (the bridge) and COPIes the existing rows.
#    forward_origins=['pgactive_*'] so this subscription only forwards
#    changes whose replication origin comes from a pgactive peer (i.e.,
#    "real" pgactive-cluster traffic). Spock-cluster-internal traffic that
#    happens to flow through node3's WAL is NOT pulled in via this link;
#    spock2's writes reach spock1 directly via the spock1<->spock2 peer
#    mesh, so duplicating them here would just create extra apply work.
psql -h localhost -p "${SPOCK_PORTS[0]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<SQL
SELECT spock.sub_create(
    subscription_name     := 'sub_spock1_from_node3',
    provider_dsn          := '$(dsn_node3)',
    synchronize_structure := false,
    synchronize_data      := true,
    forward_origins       := ARRAY['pgactive_*']
);
SELECT spock.sub_wait_for_sync('sub_spock1_from_node3');
SQL

# 8. spock2 subscribes to spock1 and COPIes from there.
#    forward_origins=[] (default empty) — peer mesh between spock1/spock2,
#    each forwards only its own local writes. Foreign-origin changes (e.g.,
#    pgactive-origin changes that arrived at spock1 via node3) reach spock2
#    via spock2's own subscription to node3, not via this peer link, so
#    leaving forward_origins empty here prevents change-loops between the
#    spock peers and the bridge.
psql -h localhost -p "${SPOCK_PORTS[1]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 <<SQL
SELECT spock.sub_create(
    subscription_name     := 'sub_spock2_from_spock1',
    provider_dsn          := '$(dsn_spock 1)',
    synchronize_structure := false,
    synchronize_data      := true,
    forward_origins       := ARRAY[]::text[]
);
SELECT spock.sub_wait_for_sync('sub_spock2_from_spock1');
SQL

# 9. Wire up the remaining edges with the asymmetric forward_origins
#    topology that prevents loops:
#
#      spock1 <-> spock2  (peer mesh)              : forward_origins=[]
#      spock1 <- node3 (bridge consumer)           : forward_origins=['all']
#      spock2 <- node3 (bridge consumer)           : forward_origins=['all']
#      node3 <- spock1 (bridge ingest from spock1) : forward_origins=[]
#      node3 <- spock2 (bridge ingest from spock2) : forward_origins=[]
#
#    spock subscribers FROM node3 use 'all' so they receive pgactive-origin
#    changes that node3's WAL carries. The reverse direction (and the
#    spock1<->spock2 peer mesh) uses empty forward_origins so foreign-origin
#    changes don't bounce around the cluster causing the apply loop we saw
#    when every link forwarded everything.
psql -h localhost -p "${SPOCK_PORTS[0]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.sub_create('sub_spock1_from_spock2', '$(dsn_spock 2)', ARRAY['default','default_insert_only','ddl_sql'], false, false, ARRAY[]::text[])"

psql -h localhost -p "${SPOCK_PORTS[1]}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.sub_create('sub_spock2_from_node3', '$(dsn_node3)', ARRAY['default','default_insert_only','ddl_sql'], false, false, ARRAY['pgactive_*'])"

psql -h localhost -p "${NODE3_PORT}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.sub_create('sub_node3_from_spock1', '$(dsn_spock 1)', ARRAY['default','default_insert_only','ddl_sql'], false, false, ARRAY[]::text[])"

psql -h localhost -p "${NODE3_PORT}" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 \
     -c "SELECT spock.sub_create('sub_node3_from_spock2', '$(dsn_spock 2)', ARRAY['default','default_insert_only','ddl_sql'], false, false, ARRAY[]::text[])"

# 9. Give the subscriptions a moment to settle
sleep 5

# 10. Show what each node thinks the world looks like
echo
echo "=== Subscription status ==="
for label_port in "spock1:${SPOCK_PORTS[0]}" "spock2:${SPOCK_PORTS[1]}" "node3:${NODE3_PORT}"; do
    label="${label_port%%:*}"; port="${label_port##*:}"
    echo "--- ${label} (port ${port}) ---"
    psql -h localhost -p "${port}" -U postgres -d "${DBNAME}" -c \
        "SELECT subscription_name, status, provider_node, replication_sets FROM spock.sub_show_status()"
done

echo
echo "=== public.demo on each spock node ==="
for label_port in "spock1:${SPOCK_PORTS[0]}" "spock2:${SPOCK_PORTS[1]}" "node3:${NODE3_PORT}"; do
    label="${label_port%%:*}"; port="${label_port##*:}"
    echo "--- ${label} (port ${port}) ---"
    psql -h localhost -p "${port}" -U postgres -d "${DBNAME}" \
         -c "SELECT * FROM public.demo ORDER BY id" 2>&1 || true
done

echo
echo "Spock mesh up. Connect with:"
echo "  psql -h localhost -p ${SPOCK_PORTS[0]} -U postgres -d ${DBNAME}    # spock1"
echo "  psql -h localhost -p ${SPOCK_PORTS[1]} -U postgres -d ${DBNAME}    # spock2"
echo "  psql -h localhost -p ${NODE3_PORT} -U postgres -d ${DBNAME}    # node3 (bridge)"
echo
echo "Stop the spock-only nodes with:"
echo "  pg_ctl -D ${DATA_BASE}/spock1 stop"
echo "  pg_ctl -D ${DATA_BASE}/spock2 stop"
