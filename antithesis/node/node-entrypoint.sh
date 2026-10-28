#!/usr/bin/env bash
#
# Spock node entrypoint for Antithesis (n1..n4).
#
# Runs initdb on an empty volume, writes the node configuration, and then
# keeps one postmaster running: when postgres exits (pg_ctl stop, kill -9 of
# the postmaster, an Assert), the loop starts it again.  postgres is never
# the container's main process, so killing it does not end the container.
#
# No Spock nodes or subscriptions are created here; the workload container
# does all cluster setup, so a restarted node comes back on its existing
# PGDATA.
#
# State under /data/state (outside PGDATA, same volume; readable with
# pg_read_file() as superuser):
#   boot_count  incremented before every postmaster start attempt (a start
#               that fails, e.g. on leftover shared memory after kill -9,
#               counts too; see exits.log)
#   last_exit   exit code of the most recent postmaster
#   exits.log   one line per postmaster exit
#   stay_down   if present, the loop does not restart postgres until it is
#               removed
#   restart_delay  seconds to wait before the next start, read and removed
#               after postgres exits (the graceful-restart driver writes it
#               before pg_ctl stop; the wait ends even if that command is
#               killed)
#   graceful.log   one line per graceful restart, written by the driver
#
# Settings that vary between run configurations come from the environment:
#   SPOCK_CAPACITY                worker, slot, sender and origin limits (32)
#   SPOCK_WAL_SENDER_TIMEOUT      wal_sender_timeout (60s)
#   SPOCK_APPLY_IDLE_TIMEOUT      spock.apply_idle_timeout, seconds (120)
#   SPOCK_EXCEPTION_BEHAVIOUR     spock.exception_behaviour (transdiscard)
#   SPOCK_PAUSE_TIMEOUT           spock.pause_timeout, seconds (1)
#   SPOCK_EXTRA_CONF              extra lines appended to the config
set -euo pipefail

# Start as root only to prepare what postgres must write to, then run the
# rest of this script as postgres.  The Antithesis output directory is
# root-owned; spock.so writes its assertions to sdk.jsonl from postgres
# processes, so the file must exist and be writable by postgres first.
if [ "$(id -u)" = 0 ]; then
	if [ -n "${ANTITHESIS_OUTPUT_DIR:-}" ]; then
		mkdir -p "${ANTITHESIS_OUTPUT_DIR}"
		touch "${ANTITHESIS_OUTPUT_DIR}/sdk.jsonl"
		chown postgres:postgres "${ANTITHESIS_OUTPUT_DIR}/sdk.jsonl"
	fi
	chown postgres:postgres /data
	export HOME=/home/postgres USER=postgres
	exec setpriv --reuid=postgres --regid=postgres --init-groups "$0" "$@"
fi

PGDATA=/data/pgdata
STATE=/data/state
LOGFILE="${PGDATA}/log/postgresql.log"
export PGDATA

log() { echo "node-entrypoint[$(hostname)]: $*"; }

mkdir -p "${STATE}"

# .antithesis-init-done is written last, so a container that died part way
# through first-start setup redoes all of it.
if [ ! -e "${PGDATA}/.antithesis-init-done" ]; then
	log "initializing ${PGDATA}"
	rm -rf "${PGDATA}"
	initdb -D "${PGDATA}" -U "${PGUSER}" --encoding=UTF8 --locale=C \
		--auth=trust > /dev/null
	{
		echo "host all all 0.0.0.0/0 trust"
		echo "host all all ::/0 trust"
		echo "host replication all 0.0.0.0/0 trust"
		echo "host replication all ::/0 trust"
	} >> "${PGDATA}/pg_hba.conf"
	echo "include = 'antithesis.conf'" >> "${PGDATA}/postgresql.conf"
	FRESH_INIT=1
else
	log "using existing ${PGDATA}"
	FRESH_INIT=0
fi

# The output_plugin_libraries security fix exists only in some minor
# releases; an unknown parameter would stop the postmaster.
OUTPUT_PLUGIN_LINE=""
# grep -c, not grep -q: -q exits at the first match and the SIGPIPE to
# postgres would fail the pipeline under pipefail.
if [ "$(postgres --describe-config 2>/dev/null | grep -c '^output_plugin_libraries')" != 0 ]; then
	OUTPUT_PLUGIN_LINE="output_plugin_libraries = 'pgoutput, test_decoding, spock_output'"
fi

CAP="${SPOCK_CAPACITY:-32}"

# Rewritten on every container start, so a changed configuration applies to
# an existing data directory too.
cat > "${PGDATA}/antithesis.conf" <<EOF
# Written by node-entrypoint.sh on every container start.
listen_addresses = '*'
port = ${PGPORT}

wal_level = logical
track_commit_timestamp = on
shared_preload_libraries = 'spock'
max_worker_processes = ${CAP}
max_replication_slots = ${CAP}
max_wal_senders = ${CAP}
max_active_replication_origins = ${CAP}
${OUTPUT_PLUGIN_LINE}

spock.conflict_resolution = 'last_update_wins'
spock.save_resolutions = on
spock.resolutions_retention_days = 0
spock.exception_behaviour = '${SPOCK_EXCEPTION_BEHAVIOUR:-transdiscard}'
spock.exception_logging = all
spock.pause_timeout = ${SPOCK_PAUSE_TIMEOUT:-1}

# apply_idle_timeout must stay well above wal_sender_timeout / 2: an idle
# walsender sends a keepalive only after about that long.
wal_sender_timeout = '${SPOCK_WAL_SENDER_TIMEOUT:-60s}'
spock.apply_idle_timeout = ${SPOCK_APPLY_IDLE_TIMEOUT:-120}

# Crash-recovery properties need applied commits since the last checkpoint.
# With '1d', WAL stayed under max_wal_size, so no checkpoint ever ran, no WAL
# was removed and a 30 minute run filled the disk.  5min still leaves most
# kills landing between checkpoints.
checkpoint_timeout = '5min'
max_wal_size = '8GB'

# Server log goes to a file the workload reads with pg_read_file(); the
# entrypoint also copies it to stdout for Antithesis.
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql.log'
log_rotation_age = 0
log_rotation_size = 0
log_line_prefix = '%m [%p] %b %a: '
lc_messages = 'C'

DateStyle = 'ISO, MDY'
TimeZone = 'UTC'
extra_float_digits = 1
${SPOCK_EXTRA_CONF:-}
EOF

# Copy the server log to container stdout.  Started before any postmaster,
# so -n 0 loses nothing and a container restart does not replay old lines;
# -F waits for the file on a fresh volume and keeps following it.
tail -n 0 -F "${LOGFILE}" 2>/dev/null &

if [ "${FRESH_INIT}" = 1 ]; then
	# Create the test database with a short-lived local postmaster.
	pg_ctl -D "${PGDATA}" -o "-c listen_addresses=''" -w -t 120 start > /dev/null
	createdb -h /tmp "${PGDATABASE}"
	pg_ctl -D "${PGDATA}" -m fast -w -t 120 stop > /dev/null
	touch "${PGDATA}/.antithesis-init-done"
fi

PG_PID=""
STOPPING=0
on_signal() {
	STOPPING=1
	if [ -n "${PG_PID}" ]; then
		kill -INT "${PG_PID}" 2>/dev/null || true
	fi
}
trap on_signal INT TERM

while [ "${STOPPING}" = 0 ]; do
	if [ -e "${STATE}/stay_down" ]; then
		sleep 1
		continue
	fi

	boot=$(( $(cat "${STATE}/boot_count" 2>/dev/null || echo 0) + 1 ))
	echo "${boot}" > "${STATE}/boot_count.tmp"
	mv "${STATE}/boot_count.tmp" "${STATE}/boot_count"
	log "starting postgres (boot ${boot})"

	postgres -D "${PGDATA}" &
	PG_PID=$!
	# A signal that arrived before PG_PID was set signalled nothing.
	[ "${STOPPING}" = 1 ] && kill -INT "${PG_PID}" 2>/dev/null
	set +e
	wait "${PG_PID}"
	rc=$?
	# A trapped signal interrupts wait; wait again for the real exit.
	while kill -0 "${PG_PID}" 2>/dev/null; do
		wait "${PG_PID}"
		rc=$?
	done
	set -e
	PG_PID=""

	echo "${rc}" > "${STATE}/last_exit"
	echo "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ) boot=${boot} exit=${rc}" >> "${STATE}/exits.log"
	log "postgres exited with ${rc} (boot ${boot})"

	delay=1
	if [ -e "${STATE}/restart_delay" ]; then
		# The file can be gone or empty by now (removed, or a write that
		# hit a full disk); either must not end this loop under set -e.
		delay=$(cat "${STATE}/restart_delay" 2>/dev/null || true)
		rm -f "${STATE}/restart_delay"
		case "${delay}" in
		'' | *[!0-9]*) delay=1 ;;
		esac
		log "restarting postgres in ${delay}s"
	fi
	[ "${STOPPING}" = 0 ] && sleep "${delay}"
done

log "stopped"
