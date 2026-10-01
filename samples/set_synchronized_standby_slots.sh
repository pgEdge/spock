#!/usr/bin/env bash
#
# set_synchronized_standby_slots.sh - keep synchronized_standby_slots right
# under Patroni, for Spock's failover slots
#
# SAMPLE / REFERENCE ONLY. Read it, understand it, and adapt it to your
# environment before wiring it into a production cluster.
#
# Purpose
# -------
# Keeps PostgreSQL's `synchronized_standby_slots` pointed at the physical
# replication slot(s) of the *current* standby member(s). This holds the
# leader's walsenders back until a standby has confirmed the LSN, so a logical
# subscriber can never advance ahead of the physical standby that may later be
# promoted.
#
# The value is role-specific but Patroni's dynamic config is cluster-wide, so a
# hardcoded value points the new leader at a slot for itself after a switchover
# and freezes logical replication. Setting it from this script avoids that. See
# docs/logical_slot_failover.md, "The switchover sharp edge", for the full
# rationale and the manual runbook this script automates.
#
# Two entry points
# ----------------
# 1. As Patroni's on_role_change callback, run at promotion and demotion:
#
#      postgresql:
#        callbacks:
#          on_role_change: /etc/patroni/set_synchronized_standby_slots.sh
#
#    Patroni invokes callbacks as:  <script> <action> <role> <scope>
#      $1 = action  (on_role_change)
#      $2 = role    (primary | master | replica | standby_leader)
#      $3 = scope   (cluster name)
#
# 2. As a periodic reconcile, run on every member from cron or a systemd
#    timer, every minute or so:
#
#      set_synchronized_standby_slots.sh reconcile <scope>
#
#    Patroni fires on_role_change only on promotion and demotion, never when
#    a standby that was down comes back or when one goes away. The reconcile
#    asks Patroni for this member's current role and brings the setting up
#    to date, changing it only when it differs from what is set.
#
# Scope
# -----
# Supports Patroni's own member slots: use_slots on (the default) and no
# hand-made primary_slot_name on a member. Slot names come from Patroni's
# naming function, so they match the slots Patroni created.

set -euo pipefail

ACTION="${1:-}"

# --- adapt these to your deployment -----------------------------------------
# Command + config used to enumerate the cluster's members.
PATRONICTL="${PATRONICTL:-patronictl}"
PATRONI_CONFIG="${PATRONI_CONFIG:-/etc/patroni/patroni.yml}"
# The Python interpreter that runs Patroni. Slot names are derived by
# Patroni's own function, so the same rule applies as when the slots were
# created.
PYTHON="${PYTHON:-python3}"
# This member's name as Patroni knows it: the "name:" key of patroni.yml,
# which need not be the hostname. Patroni does not pass it to callbacks or
# export it; set PATRONI_NAME to override what is read from the config.
PATRONI_NAME="${PATRONI_NAME:-$(awk '$1 == "name:" {print $2; exit}' "$PATRONI_CONFIG" 2>/dev/null || true)}"
# Local superuser psql connection used to run ALTER SYSTEM / pg_reload_conf().
# e.g. PGCONN="-h /var/run/postgresql -U postgres -d postgres"
PSQL="${PSQL:-psql}"
PGCONN="${PGCONN:-}"
# Lock shared by the callback and the reconcile, so that a reconcile that
# looked at the cluster just before a promotion cannot overwrite what the
# promotion callback set. Must be writable by the user Patroni runs as.
LOCKFILE="${LOCKFILE:-/tmp/set_synchronized_standby_slots.lock}"
# ----------------------------------------------------------------------------

case "$ACTION" in
	on_role_change)
		ROLE="${2:-}"
		SCOPE="${3:-}"
		;;
	reconcile)
		ROLE=""
		SCOPE="${2:-}"
		;;
	*)
		echo "usage: $0 on_role_change <role> <scope> | reconcile <scope>" >&2
		exit 1
		;;
esac

# Stderr, which Patroni relays into its own log; stdout is captured below.
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') set_synchronized_standby_slots: $*" >&2; }

run_sql() {
	# shellcheck disable=SC2086
	$PSQL $PGCONN -X -q -v ON_ERROR_STOP=1 -c "$1"
}

# A single value, trimmed, for SHOW and the like.
query_value() {
	# shellcheck disable=SC2086
	$PSQL $PGCONN -X -tA -v ON_ERROR_STOP=1 -c "$1"
}

# Patroni names a member's physical slot after the member (lowercase, '-'
# and '.' become '_', other characters are spelled out, 63 characters at
# most). Ask Patroni itself rather than copy the rule: a name the leader's
# walsenders wait for must match the slot Patroni made.
slot_name_from_member() {
	"$PYTHON" -c 'import sys; from patroni.dcs import slot_name_from_member_name as f; print(f(sys.argv[1]))' "$1"
}

# The cluster as Patroni sees it, one "member|role|state" line per member.
# Columns of "patronictl list -f tsv": Cluster, Member, Host, Role, State,
# TL, Lag. Fails, so that callers leave the setting untouched, when the
# members cannot be listed.
list_members() {
	local listing
	if ! listing="$("$PATRONICTL" -c "$PATRONI_CONFIG" list -f tsv "$SCOPE")"; then
		log "patronictl list failed; leaving synchronized_standby_slots unchanged"
		return 1
	fi
	printf '%s\n' "$listing" | awk -F'\t' 'NR>1 {print $2 "|" $4 "|" $5}'
}

# Comma-separated slot names of every member that is NOT this node and is
# up. A listed slot that nothing consumes holds the walsenders back for
# good, so a member that is stopped or crashed is left out; the reconcile
# adds it back once it streams again.
other_member_slots() {
	local self="$1" members name role state slots=""
	members="$(list_members)" || return 1
	while IFS='|' read -r name role state; do
		[ -z "$name" ] && continue
		[ "$name" = "$self" ] && continue
		case "$state" in
			running|streaming) ;;
			*) log "skipping member $name in state '$state'"; continue ;;
		esac
		local slot
		if ! slot="$(slot_name_from_member "$name")"; then
			log "cannot derive the slot name of member $name; leaving synchronized_standby_slots unchanged"
			return 1
		fi
		slots="${slots:+$slots,}$slot"
	done <<< "$members"
	echo "$slots"
}

# This member's role as Patroni reports it ("Leader", "Replica", "Sync
# Standby", "Quorum Standby", "Standby Leader"), or nothing if unlisted.
own_role() {
	local self="$1" members
	members="$(list_members)" || return 1
	printf '%s\n' "$members" | awk -F'|' -v self="$self" '$1 == self {print $2; exit}'
}

# Set the value and reload, unless it is already what we want.
apply_setting() {
	local wanted="$1" current
	current="$(query_value "SHOW synchronized_standby_slots")"
	if [ "$current" = "$wanted" ]; then
		log "synchronized_standby_slots already '$wanted'"
		return 0
	fi
	log "synchronized_standby_slots '$current' -> '$wanted'"
	run_sql "ALTER SYSTEM SET synchronized_standby_slots = '$wanted'"
	run_sql "SELECT pg_reload_conf()"
}

if [ -z "$PATRONI_NAME" ]; then
	log "member name unknown: set PATRONI_NAME or the name: key in $PATRONI_CONFIG"
	exit 1
fi

# One run at a time per member. The cluster is read only after the lock is
# held, so whichever entry point runs second sees the role as it is then.
exec 9>"$LOCKFILE"
if ! flock -w 60 9; then
	log "could not lock $LOCKFILE within 60s; leaving synchronized_standby_slots unchanged"
	exit 1
fi

# Normalize what Patroni told us (callback role) or shows us (reconcile)
# to "leader" or "standby".
if [ "$ACTION" = "reconcile" ]; then
	patroni_role="$(own_role "$PATRONI_NAME")" || exit 1
	case "$patroni_role" in
		Leader) ROLE=leader ;;
		"") log "member $PATRONI_NAME not listed in cluster $SCOPE; nothing to do"; exit 0 ;;
		*) ROLE=standby ;;
	esac
else
	case "$ROLE" in
		primary|master) ROLE=leader ;;
		replica|standby_leader) ROLE=standby ;;
		*) log "unhandled role '$ROLE' for action '$ACTION'; nothing to do"; exit 0 ;;
	esac
fi

case "$ROLE" in
	leader)
		# Hold this leader's walsenders back for the other running members'
		# physical slots.
		slots="$(other_member_slots "$PATRONI_NAME")" || exit 1
		[ -z "$slots" ] && log "no other running members; clearing synchronized_standby_slots"
		apply_setting "$slots"
		;;
	standby)
		# A standby must not hold anything back, or it would point at a slot
		# for itself and freeze on the next promotion.
		apply_setting ""
		;;
esac
