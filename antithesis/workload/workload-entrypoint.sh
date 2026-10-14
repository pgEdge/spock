#!/usr/bin/env bash
#
# Workload container entrypoint for Antithesis.
#
# Builds the starting cluster, emits setup_complete, then idles while
# Antithesis runs the test commands in /opt/antithesis/test/v1.
#
#   n1, n2, n3  Spock nodes in a full mesh (6 subscriptions sub_<to>_<from>)
#   n4          spare: spock and dblink extensions and Z0DAN loaded, no Spock
#               node; the workload joins it with spock.add_node later
#
# Node nX runs on host ${NODE_HOST_PREFIX}nX.
#
# A plain assignment from $(q ...) lets set -e stop on a failed query; inside
# a [ ] test the failure would be read as "not found".
#
# Every step checks before it acts, so running this again against an
# existing cluster changes nothing.
set -euo pipefail

MESH="n1 n2 n3"
SPARE="n4"
ALL="${MESH} ${SPARE}"
WAIT_SECS="${SETUP_WAIT_SECS:-300}"
PREFIX="${NODE_HOST_PREFIX:-}"

log() { echo "workload-entrypoint: $*"; }

dsn() { echo "host=${PREFIX}$1 port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER}"; }

# q <node> <psql args...>
q() {
	local node=$1
	shift
	psql -X -q -At -v ON_ERROR_STOP=1 -h "${PREFIX}${node}" "$@"
}

wait_until() {
	local what=$1
	shift
	local deadline=$(( SECONDS + WAIT_SECS ))
	until "$@" > /dev/null 2>&1; do
		if (( SECONDS >= deadline )); then
			log "timed out after ${WAIT_SECS}s waiting for ${what}"
			exit 1
		fi
		sleep 1
	done
}

for n in ${ALL}; do
	wait_until "${n} to accept connections" pg_isready -q -h "${PREFIX}${n}"
	wait_until "database ${PGDATABASE} on ${n}" q "${n}" -c "SELECT 1"
done
log "all nodes accept connections"

tiebreaker=0
for n in ${MESH}; do
	tiebreaker=$(( tiebreaker + 1 ))
	q "${n}" -c "CREATE EXTENSION IF NOT EXISTS spock"
	count=$(q "${n}" -c "SELECT count(*) FROM spock.node WHERE node_name = '${n}'")
	if [ "${count}" = 0 ]; then
		log "creating Spock node ${n} (tiebreaker ${tiebreaker})"
		q "${n}" -c "SELECT spock.node_create(
			node_name := '${n}',
			dsn := '$(dsn "${n}")',
			info := '{\"tiebreaker\": \"${tiebreaker}\"}')" > /dev/null
	fi
done

for to in ${MESH}; do
	for from in ${MESH}; do
		[ "${to}" = "${from}" ] && continue
		sub="sub_${to}_${from}"
		count=$(q "${to}" -c "SELECT count(*) FROM spock.subscription WHERE sub_name = '${sub}'")
		if [ "${count}" = 0 ]; then
			log "creating subscription ${sub}"
			q "${to}" -c "SELECT spock.sub_create(
				subscription_name := '${sub}',
				provider_dsn := '$(dsn "${from}")')" > /dev/null
		fi
	done
done

sub_replicating() {
	[ "$(q "$1" -c "SELECT status FROM spock.sub_show_status() WHERE subscription_name = '$2'")" = replicating ]
}
for to in ${MESH}; do
	for from in ${MESH}; do
		[ "${to}" = "${from}" ] && continue
		wait_until "sub_${to}_${from} to be replicating" sub_replicating "${to}" "sub_${to}_${from}"
	done
done
log "mesh n1-n3 is replicating"

for n in ${SPARE}; do
	q "${n}" -c "CREATE EXTENSION IF NOT EXISTS dblink"
	q "${n}" -c "CREATE EXTENSION IF NOT EXISTS spock"
	q "${n}" -f /opt/spock/Z0DAN/zodan.sql > /dev/null
	log "spare node ${n} ready for add_node"
done

setup-complete.sh

exec sleep infinity
