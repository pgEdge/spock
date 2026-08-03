#!/usr/bin/env bash
#
# set_synchronized_standby_slots.sh - Patroni on_role_change callback for Spock
#
# SAMPLE / REFERENCE ONLY. Read it, understand it, and adapt it to your
# environment before wiring it into a production cluster.
#
# Purpose
# -------
# Keeps PostgreSQL's `synchronized_standby_slots` pointed at the physical
# replication slot(s) of the *current* standby member(s) whenever a node's
# role changes. This holds the leader's walsenders back until the standby has
# confirmed the LSN, so a logical subscriber can never advance ahead of the
# physical standby that may later be promoted.
#
# The value is role-specific but Patroni's dynamic config is cluster-wide, so a
# hardcoded value points the new leader at a slot for itself after a switchover
# and freezes logical replication. Setting it from a callback avoids that. See
# docs/logical_slot_failover.md, "The switchover sharp edge", for the full
# rationale and the manual runbook this script automates.
#
# Installation
# ------------
# Place this script on every member and reference it from patroni.yml:
#
#   postgresql:
#     callbacks:
#       on_role_change: /etc/patroni/set_synchronized_standby_slots.sh
#
# Patroni invokes callbacks as:  <script> <action> <role> <scope>
#   $1 = action  (on_role_change)
#   $2 = role    (primary | master | replica | standby_leader)
#   $3 = scope   (cluster name)

set -euo pipefail

ACTION="${1:-}"
ROLE="${2:-}"
SCOPE="${3:-}"

# --- adapt these to your deployment -----------------------------------------
# Command + config used to enumerate the cluster's members.
PATRONICTL="${PATRONICTL:-patronictl}"
PATRONI_CONFIG="${PATRONI_CONFIG:-/etc/patroni/patroni.yml}"
# Local superuser psql connection used to run ALTER SYSTEM / pg_reload_conf().
# e.g. PGCONN="-h /var/run/postgresql -U postgres -d postgres"
PSQL="${PSQL:-psql}"
PGCONN="${PGCONN:-}"
# ----------------------------------------------------------------------------

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') set_synchronized_standby_slots: $*"; }

run_sql() {
	# shellcheck disable=SC2086
	$PSQL $PGCONN -X -q -v ON_ERROR_STOP=1 -c "$1"
}

# Patroni names a member's physical slot after the member, lowercased with any
# character outside [a-z0-9_] replaced by '_'. Mirror that transform here.
slot_name_from_member() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9_]/_/g'
}

# Comma-separated, quoted slot names of every member that is NOT this node.
other_member_slots() {
	local self="$1" name role slots=""
	while IFS='|' read -r name role; do
		[ -z "$name" ] && continue
		[ "$name" = "$self" ] && continue
		local slot
		slot="$(slot_name_from_member "$name")"
		if [ -z "$slots" ]; then
			slots="'$slot'"
		else
			slots="$slots, '$slot'"
		fi
	done < <("$PATRONICTL" -c "$PATRONI_CONFIG" list -f tsv "$SCOPE" \
		| awk -F'\t' 'NR>1 {print $2 "|" $4}')
	echo "$slots"
}

case "$ROLE" in
	primary|master)
		# This node is (becoming) the leader: hold its walsenders back for the
		# other members' physical slots.
		self="$(hostname)"
		slots="$(other_member_slots "$self")"
		if [ -z "$slots" ]; then
			log "no other members found; clearing synchronized_standby_slots"
			run_sql "ALTER SYSTEM SET synchronized_standby_slots = ''"
		else
			log "leader $self -> synchronized_standby_slots = $slots"
			run_sql "ALTER SYSTEM SET synchronized_standby_slots = '$(echo "$slots" | sed "s/'//g;s/, /,/g")'"
		fi
		run_sql "SELECT pg_reload_conf()"
		;;
	replica|standby_leader)
		# This node is (becoming) a standby: it must not hold anything back, or
		# it would point at a slot for itself and freeze on the next promotion.
		log "role $ROLE -> clearing synchronized_standby_slots"
		run_sql "ALTER SYSTEM SET synchronized_standby_slots = ''"
		run_sql "SELECT pg_reload_conf()"
		;;
	*)
		log "unhandled role '$ROLE' for action '$ACTION'; nothing to do"
		;;
esac
