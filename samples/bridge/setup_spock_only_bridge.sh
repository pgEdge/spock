#!/usr/bin/env bash
#
# Stands up a 5-node spock-only bridge topology:
#
#   CLUSTER A (peer mesh)              CLUSTER B (peer mesh)
#      ca1 :25441                          cb1 :25444
#      ca2 :25442                          cb2 :25445
#
#                       bridge :25443
#                  (one spock node that's a
#                   member of BOTH clusters)
#
# All connections are spock subscriptions. Asymmetric forward_origins config
# breaks the cross-cluster loop:
#
#   bridge <- ca*, cb*         : forward_origins=['all']
#   ca* <- bridge              : forward_origins=['*_cb*_sub_*']  (B-side only)
#   cb* <- bridge              : forward_origins=['*_ca*_sub_*']  (A-side only)
#   ca1 <-> ca2, cb1 <-> cb2   : forward_origins=[]               (peer mesh)
#
# Spock's gen_slot_name() lowercases / underscore-sanitizes node names
# before embedding them in replication-origin names. So nodes are named in
# lower case with cluster-distinctive prefixes (ca / cb) here — otherwise
# distinct nodes would collide on origin name and forward_origins patterns
# could not distinguish them.
#
#
# Requirements: PG 17 + spock 6.0.0-devel+ on PATH. See ../README.md.
# Uses $BRIDGE_DEMO_DATA (default: $PWD/data) for data dirs.
#
set -euo pipefail

DATA_BASE="${BRIDGE_DEMO_DATA:-$PWD/data}"
DBNAME="pgadb"

# name:port
NODES=(ca1:25441 ca2:25442 bridge:25443 cb1:25444 cb2:25445)

port_of() {  # port_of <nodename>
    for np in "${NODES[@]}"; do
        n="${np%%:*}"; p="${np##*:}"
        [ "$n" = "$1" ] && { echo "$p"; return; }
    done
    return 1
}

dsn_of() {  # dsn_of <nodename>
    echo "host=localhost port=$(port_of "$1") dbname=${DBNAME} user=postgres"
}

# 1. Stop any nodes still running from earlier setups
for d in "$DATA_BASE"/*/postmaster.pid; do
    [ -f "$d" ] && pg_ctl -D "$(dirname "$d")" stop -m fast >/dev/null 2>&1 || true
done

# 2. initdb + configure + start each node
for np in "${NODES[@]}"; do
    name="${np%%:*}"; port="${np##*:}"
    datadir="${DATA_BASE}/${name}"

    rm -rf "$datadir"
    initdb -D "$datadir" -U postgres --no-locale --encoding=UTF8 -A trust >/dev/null

    cat >> "${datadir}/postgresql.conf" <<EOF
listen_addresses = 'localhost'
port = ${port}
shared_preload_libraries = 'spock'
wal_level = logical
max_wal_senders = 32
max_replication_slots = 32
max_worker_processes = 32
track_commit_timestamp = on
spock.enable_ddl_replication = 'on'
spock.include_ddl_repset = 'on'
spock.allow_ddl_from_functions = 'on'
log_min_messages = 'info'
EOF
    cat >> "${datadir}/pg_hba.conf" <<EOF
host    replication     postgres        127.0.0.1/32    trust
host    replication     postgres        ::1/128         trust
local   replication     postgres                        trust
EOF

    pg_ctl -D "$datadir" -l "${datadir}/server.log" start >/dev/null
done

# Wait a moment for everyone to settle
sleep 2

# 3. Create database, extension, register spock node, then add demo table
for np in "${NODES[@]}"; do
    name="${np%%:*}"; port="${np##*:}"
    psql -h localhost -p "$port" -U postgres -d postgres -v ON_ERROR_STOP=1 -q <<SQL
CREATE DATABASE ${DBNAME};
SQL
    psql -h localhost -p "$port" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 -q <<SQL
CREATE EXTENSION spock;
SELECT spock.node_create(node_name := '${name}', dsn := '$(dsn_of "$name")');
-- include_ddl_repset = on auto-adds the table to the default repset,
-- so no explicit repset_add_table call is needed.
CREATE TABLE public.demo (id integer PRIMARY KEY, msg text NOT NULL);
SQL
done

# 5. Helper to create a subscription
mk_sub() {  # mk_sub <on_node> <from_node> <forward_origins_array_sql>
    local on="$1" from="$2" fo="$3"
    # Sub names must be lowercase; node names (in DSN) can be mixed case.
    local subname
    subname="$(printf 'sub_%s_from_%s' "$on" "$from" | tr '[:upper:]' '[:lower:]')"
    psql -h localhost -p "$(port_of "$on")" -U postgres -d "${DBNAME}" -v ON_ERROR_STOP=1 -q \
        -c "SELECT spock.sub_create(
                subscription_name := '${subname}',
                provider_dsn      := '$(dsn_of "$from")',
                replication_sets  := ARRAY['default','default_insert_only','ddl_sql'],
                synchronize_structure := false,
                synchronize_data      := false,
                forward_origins   := ${fo}
            )"
}

# 6. Wire up the topology.
#
#    bridge ingests each provider's LOCAL writes only. Empty
#    forward_origins on the bridge ingress means foreign-origin (i.e.
#    peer-mesh-forwarded) writes are not pulled in here — each cluster
#    node only sends what it originated. Combined with the bridge's
#    egress subs below (selective on the other cluster's nodes), this
#    gives every row exactly one path bridge<->cluster.
mk_sub bridge ca1    "ARRAY[]::text[]"
mk_sub bridge ca2    "ARRAY[]::text[]"
mk_sub bridge cb1    "ARRAY[]::text[]"
mk_sub bridge cb2    "ARRAY[]::text[]"

#    Cluster A peer mesh — local writes only between ca1 and ca2:
mk_sub ca1 ca2       "ARRAY[]::text[]"
mk_sub ca2 ca1       "ARRAY[]::text[]"

#    Cluster B peer mesh — local writes only between cb1 and cb2:
mk_sub cb1 cb2       "ARRAY[]::text[]"
mk_sub cb2 cb1       "ARRAY[]::text[]"

#    Cluster A nodes receive ONLY cluster-B traffic from the bridge.
#    Spock identifies origin at filter time by spock.node.node_id, so the
#    selective filter matches forward_origins entries against the producer
#    node's name (e.g. 'cb1', 'cb2') resolved through spock.node.
mk_sub ca1 bridge    "ARRAY['cb1','cb2']"
mk_sub ca2 bridge    "ARRAY['cb1','cb2']"

#    Cluster B nodes receive ONLY cluster-A traffic from the bridge.
mk_sub cb1 bridge    "ARRAY['ca1','ca2']"
mk_sub cb2 bridge    "ARRAY['ca1','ca2']"

sleep 4

echo
echo "=== Subscription status ==="
for np in "${NODES[@]}"; do
    name="${np%%:*}"; port="${np##*:}"
    echo "--- ${name} (:${port}) ---"
    psql -h localhost -p "$port" -U postgres -d "${DBNAME}" -c \
        "SELECT subscription_name, status, provider_node FROM spock.sub_show_status()"
done

cat <<EOF

Spock-only bridge topology up. Connect with:
$(for np in "${NODES[@]}"; do
    n="${np%%:*}"; p="${np##*:}"
    printf '  psql -h localhost -p %s -U postgres -d %s    # %s\n' "$p" "${DBNAME}" "$n"
done)
EOF
