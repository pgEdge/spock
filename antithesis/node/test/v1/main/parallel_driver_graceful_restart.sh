#!/usr/bin/env bash
#
# Graceful stop and restart of this node, for property
# graceful-restart-preserves-exactly-once.
#
# Runs in a node container (the node image has no Python, so this is Bash
# and makes no assertions).  It stops postgres with pg_ctl stop -m fast and
# leaves the restart to node-entrypoint.sh, after a delay written to
# /data/state/restart_delay first, so the node comes back even if this
# command is killed part way through.  Each restart is recorded in
# /data/state/graceful.log; eventually_mesh_barriers.py reads it with
# pg_read_file() and makes the assertions.
#
# Fast mode only: smart mode waits for every client backend, including the
# peers' plain connections, and can wait forever.
#
# Always exits 0: a node that is down or already stopping is not a bug here.

set -uo pipefail

STATE=/data/state
PGDATA=/data/pgdata

# n4 is the spare node, outside the mesh the checks cover.
case "$(hostname)" in
*n4) exit 0 ;;
esac

# One restart at a time on this node.
exec 9> "${STATE}/graceful.lock"
flock -n 9 || exit 0

rand() { od -An -N2 -tu2 /dev/urandom | tr -d ' '; }

pick() {
	local choices=("$@")
	echo "${choices[$(($(rand) % ${#choices[@]}))]}"
}

# Seconds since boot: not moved by the fault injector's clock jumps.
now() { cut -d' ' -f1 /proc/uptime; }
elapsed() { awk -v a="$1" -v b="$(now)" 'BEGIN { printf "%.1f", b - a }'; }

q() { psql -X -q -At -h localhost -U admin -d demo -c "$1" 2> /dev/null; }

# Swarm per node and timeline: some nodes never restart, some always do.
if [ ! -e "${STATE}/graceful_percent" ]; then
	pick 0 20 100 > "${STATE}/graceful_percent"
fi
percent=$(cat "${STATE}/graceful_percent")
[ $(($(rand) % 100)) -lt "${percent}" ] || exit 0

# Antithesis calls drivers often, so even a 100% node gets COOLDOWN seconds
# up between restarts for writes and catch-up.
COOLDOWN=60
last=$(cat "${STATE}/graceful_last" 2> /dev/null || echo 0)
awk -v a="$(now)" -v l="${last:-0}" -v c="${COOLDOWN}" \
	'BEGIN { exit !(a - l >= c) }' || exit 0

pg_isready -q -h localhost || exit 0

# What the stop lands on, for the reach claims.
writers=$(q "SELECT count(*) FROM pg_stat_activity
             WHERE application_name = 'parallel_driver_write_ledger.py'
               AND state <> 'idle'")
apply_in_txn=$(q "SELECT count(*) FROM pg_stat_activity
                  WHERE application_name LIKE 'spock apply %'
                    AND backend_xid IS NOT NULL")

# 0 and 1: back at once (1 is the entrypoint's default); 4-6: either side
# of spock.restart_delay_default (5 s), the peers' reconnect delay; 30: long
# enough for every peer to retry several times.
delay=$(pick 0 1 4 5 6 30)
boot=$(cat "${STATE}/boot_count")
echo "${delay}" > "${STATE}/restart_delay"

# A node pause freezes this script while /proc/uptime keeps counting.  A
# gap of more than PAUSE_GAP seconds between two polls marks the record
# paused, and its timing is not checked.
PAUSE_GAP=5
paused=0
prev=$(now)
poll() {
	sleep 0.2
	local t
	t=$(now)
	awk -v t="${t}" -v p="${prev}" -v g="${PAUSE_GAP}" \
		'BEGIN { exit !(t - p > g) }' && paused=1
	prev=${t}
}

# pg_ctl -w cannot be trusted to see the stop: with a short delay the new
# postmaster writes its pid file before pg_ctl looks again, and pg_ctl
# waits on it.  So signal without waiting, and take the outcome from the
# entrypoint's exits.log line for this boot.
start=$(now)
if ! setpriv --reuid=postgres --regid=postgres --init-groups \
	pg_ctl -D "${PGDATA}" -m fast -W stop > /dev/null 2>&1; then
	# Nothing was stopped, so no exit will consume the delay.
	rm -f "${STATE}/restart_delay"
	echo "boot=${boot} stop_rc=not_signalled" >> "${STATE}/graceful.log"
	exit 0
fi

# A stop waits for walsenders to get their flush confirmed, bounded by
# wal_sender_timeout (60 s, 5min in one variant), plus the supervisor's
# 5 s drain.
stop_rc=timeout
while awk -v a="$(now)" -v s="${start}" 'BEGIN { exit !(a - s < 330) }'; do
	rc=$(sed -n "s/.* boot=${boot} exit=\([0-9]*\)\$/\1/p" \
		"${STATE}/exits.log" 2> /dev/null | tail -n 1)
	if [ -n "${rc}" ]; then
		stop_rc=${rc}
		break
	fi
	poll
done
stop_s=$(elapsed "${start}")
if [ "${stop_rc}" != 0 ]; then
	echo "boot=${boot} stop_rc=${stop_rc} stop_s=${stop_s} paused=${paused}" \
		>> "${STATE}/graceful.log"
	exit 0
fi

now > "${STATE}/graceful_last"

# Wait for the entrypoint to start postgres again, then time how long it
# takes to accept connections.
deadline=$(awk -v a="$(now)" -v d="${delay}" 'BEGIN { print a + d + 120 }')
while [ "$(cat "${STATE}/boot_count")" = "${boot}" ]; do
	if awk -v a="$(now)" -v d="${deadline}" 'BEGIN { exit !(a > d) }'; then
		echo "boot=${boot} stop_rc=0 stop_s=${stop_s} delay=${delay} ready_s=not_started" \
			"paused=${paused}" >> "${STATE}/graceful.log"
		exit 0
	fi
	poll
done
restart=$(now)
ready_s=timeout
while awk -v a="$(now)" -v r="${restart}" 'BEGIN { exit !(a - r < 300) }'; do
	if pg_isready -q -h localhost; then
		ready_s=$(elapsed "${restart}")
		break
	fi
	poll
done
echo "boot=${boot} stop_rc=0 stop_s=${stop_s} delay=${delay} ready_s=${ready_s}" \
	"paused=${paused} writers=${writers:-?} apply_in_txn=${apply_in_txn:-?}" \
	>> "${STATE}/graceful.log"
exit 0
