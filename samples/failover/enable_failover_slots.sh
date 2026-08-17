#!/usr/bin/env bash
#
# enable_failover_slots.sh - mark existing Spock logical slots as failover slots
#
# Sample only. Review and adapt before using on a production cluster.
# See docs/logical_slot_failover.md.

set -uo pipefail

PROG=${0##*/}
VERSION=1.0

# Failover slots, pg_replication_slots.failover and ALTER_REPLICATION_SLOT
# all arrived in PostgreSQL 17.
MIN_PG_NUM=170000

# Must be non-whitespace: bash collapses runs of IFS whitespace, which would
# drop empty fields and shift every later column left.
SEP=$'\x1f'

PSQL=${PSQL:-psql}
CONNECT_TIMEOUT=${PGCONNECT_TIMEOUT:-10}
IDLE_TIMEOUT=60
DSN=
NODES=()
SUBS=()
DRY_RUN=0
ASSUME_YES=0
VERBOSE=0

TARGETS=()
PENDING=()
N_FLIP=0 N_OK=0 N_NA=0 N_SKIP=0 N_DONE=0 N_FAIL=0

# ---------------------------------------------------------------- output ---

log()   { printf '%s  %s\n' "$(date '+%H:%M:%S')" "$*"; }
warn()  { log "warning: $*" >&2; }
error() { log "error: $*" >&2; }
debug() { (( VERBOSE )) && log "debug: $*" >&2; return 0; }
fatal() { error "$*"; exit 2; }

usage() {
	cat <<EOF
Usage: $PROG (-d DSN | -n DSN...) [options]

Marks Spock's existing logical replication slots as failover slots, so
PostgreSQL's slotsync worker will copy them to a standby. Slots are only
flagged when created, so subscriptions predating
spock.use_native_failover_slots keep unflagged slots until this is run.

Each slot is flipped in place with ALTER_REPLICATION_SLOT; restart_lsn and
confirmed_flush_lsn are preserved, so no table data is re-copied. The
subscription is briefly disabled to release the slot, then re-enabled.

Nodes:
  -d, --dsn DSN              entry node; discover the rest of the cluster
  -n, --node DSN             process this node only (repeatable)
  -s, --subscription NAME    limit to this subscription (repeatable)

Options:
  -y, --yes                  do not prompt before making changes
  -N, --dry-run              check everything, print the plan, change nothing
  -t, --timeout SECS         wait for a slot to go idle (default $IDLE_TIMEOUT)
  -T, --connect-timeout SECS connection timeout (default $CONNECT_TIMEOUT)
  -v, --verbose              log each check
  -h, --help                 show this help
  -V, --version              show version

Environment:
  PSQL                       psql to use (default: psql)
  PGPASSWORD, ~/.pgpass      password, if the stored DSN has none

Requires PostgreSQL 17+ on the node hosting the slot, a role with REPLICATION,
and a pg_hba.conf entry allowing replication connections.

Exit: 0 ok, 1 something failed or was skipped, 2 usage or setup error.

Examples:
  $PROG -d "host=n1 dbname=app user=postgres" --dry-run
  $PROG -d "host=n1 dbname=app user=postgres" --yes
  $PROG -n "host=n2 dbname=app user=postgres" -s sub_n2_n1 -y
EOF
}

# ------------------------------------------------------------------ args ---

parse_args() {
	local arg val inline

	while (( $# )); do
		arg=$1 val= inline=0
		case $arg in
		--*=*)	val=${arg#*=}; arg=${arg%%=*}; inline=1; shift ;;
		*)	val=${2:-}; shift ;;
		esac

		case $arg in
		-d|--dsn)		[[ -n $val ]] || fatal "$arg requires a DSN"
					DSN=$val; (( inline )) || shift ;;
		-n|--node)		[[ -n $val ]] || fatal "$arg requires a DSN"
					NODES+=("$val"); (( inline )) || shift ;;
		-s|--subscription)	[[ -n $val ]] || fatal "$arg requires a name"
					SUBS+=("$val"); (( inline )) || shift ;;
		-t|--timeout)		[[ $val =~ ^[0-9]+$ ]] || fatal "$arg requires whole seconds"
					IDLE_TIMEOUT=$val; (( inline )) || shift ;;
		-T|--connect-timeout)	[[ $val =~ ^[0-9]+$ ]] || fatal "$arg requires whole seconds"
					CONNECT_TIMEOUT=$val; (( inline )) || shift ;;
		-y|--yes)		ASSUME_YES=1 ;;
		-N|--dry-run)		DRY_RUN=1 ;;
		-v|--verbose)		VERBOSE=1 ;;
		-h|--help)		usage; exit 0 ;;
		-V|--version)		printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
		-*)			fatal "unknown option: $arg (try --help)" ;;
		*)			fatal "unexpected argument: $arg (try --help)" ;;
		esac
	done

	if (( ${#NODES[@]} == 0 )) && [[ -z $DSN ]]; then
		usage >&2
		exit 2
	fi
	if (( ${#NODES[@]} > 0 )) && [[ -n $DSN ]]; then
		fatal "--dsn and --node are mutually exclusive"
	fi
}

# ------------------------------------------------------------------ psql ---

sql() {
	PGCONNECT_TIMEOUT=$CONNECT_TIMEOUT "$PSQL" "$1" -X -q -A -t -F "$SEP" \
		-v ON_ERROR_STOP=1 -c "$2" </dev/null 2>/dev/null
}

# Same, but the server's message comes back on stdout.
sql_e() {
	PGCONNECT_TIMEOUT=$CONNECT_TIMEOUT "$PSQL" "$1" -X -q -A -t -F "$SEP" \
		-v ON_ERROR_STOP=1 -c "$2" </dev/null 2>&1
}

repl() {
	local dsn=$1
	case $dsn in
	postgres://*|postgresql://*)
		[[ $dsn == *\?* ]] && dsn+="&replication=database" \
				   || dsn+="?replication=database" ;;
	*)	dsn+=" replication=database" ;;
	esac
	PGCONNECT_TIMEOUT=$CONNECT_TIMEOUT "$PSQL" "$dsn" -X -q \
		-v ON_ERROR_STOP=1 -c "$2" </dev/null 2>&1
}

quote() { printf "'%s'" "${1//\'/\'\'}"; }

first_line() { printf '%s' "$1" | head -n 1; }

# --------------------------------------------------------------- cleanup ---

restore() {
	local rec
	(( ${#PENDING[@]} )) || return 0
	for rec in "${PENDING[@]}"; do
		warn "re-enabling ${rec##*"$SEP"} after an interrupted run"
		sql "${rec%%"$SEP"*}" \
			"SELECT spock.sub_enable($(quote "${rec##*"$SEP"}"), true)" >/dev/null
	done
	PENDING=()
}

unpend() {
	local keep=() rec
	for rec in ${PENDING[@]+"${PENDING[@]}"}; do
		[[ $rec == "$1" ]] || keep+=("$rec")
	done
	PENDING=(${keep[@]+"${keep[@]}"})
}

trap restore EXIT
trap 'error interrupted; exit 1' INT TERM

# ---------------------------------------------------------------- checks ---

want_sub() {
	local s
	(( ${#SUBS[@]} )) || return 0
	for s in "${SUBS[@]}"; do
		[[ $s == "$1" ]] && return 0
	done
	return 1
}

add_target() {
	TARGETS+=("$1${SEP}$2${SEP}$3${SEP}$4${SEP}$5${SEP}$6${SEP}$7")
	case $6 in
	FLIP)	N_FLIP=$(( N_FLIP + 1 )) ;;
	OK)	N_OK=$(( N_OK + 1 )) ;;
	NA)	N_NA=$(( N_NA + 1 )) ;;
	*)	N_SKIP=$(( N_SKIP + 1 )) ;;
	esac
}

check_psql() {
	local ver
	command -v "$PSQL" >/dev/null 2>&1 \
		|| fatal "psql not found: $PSQL (set PSQL=/path/to/psql)"
	ver=$("$PSQL" --version 2>/dev/null | awk '{print $3}')
	[[ -n $ver ]] || fatal "cannot run $PSQL --version"
	log "psql $ver ($PSQL)"
}

discover() {
	local out dsn seen=

	out=$(sql_e "$DSN" "
		SELECT i.if_dsn FROM spock.node_interface i
		JOIN spock.node n ON n.node_id = i.if_nodeid
		WHERE i.if_name = n.node_name ORDER BY n.node_name")

	(( $? == 0 )) || fatal "entry node: $(first_line "$out")"
	[[ -n $out ]] || fatal "entry node lists no cluster nodes; is spock set up?"

	while IFS= read -r dsn; do
		[[ -n $dsn && $seen != *"<$dsn>"* ]] || continue
		seen+="<$dsn>"
		NODES+=("$dsn")
	done <<<"$out"

	log "discovered ${#NODES[@]} node(s)"
}

# check_slot <slot> <provider_dsn> <enabled> -> "ACTION SEP DETAIL" on stdout
check_slot() {
	local slot=$1 pdsn=$2 enabled=$3
	local row pgnum recovery failover active temp synced inval wal plugin out hint

	verdict() { printf '%s%s%s' "$1" "$SEP" "$2"; }

	[[ -n $slot ]] || { verdict SKIP "subscription has no slot name"; return; }

	# Interpolated as a quoted identifier below; gen_slot_name() only emits these.
	[[ $slot =~ ^[a-z0-9_]+$ ]] || { verdict SKIP "unexpected slot name"; return; }

	row=$(sql_e "$pdsn" "SELECT current_setting('server_version_num')::int, pg_is_in_recovery()")
	(( $? == 0 )) || { verdict SKIP "provider unreachable: $(first_line "$row")"; return; }

	pgnum=${row%%"$SEP"*}
	recovery=${row##*"$SEP"}

	if (( pgnum < MIN_PG_NUM )); then
		verdict NA "provider is PG$(( pgnum / 10000 )); spock's worker owns slot sync"
		return
	fi
	[[ $recovery == f ]] || { verdict SKIP "provider is in recovery"; return; }

	row=$(sql "$pdsn" "
		SELECT failover, active, temporary, synced,
		       coalesce(invalidation_reason::text, ''),
		       coalesce(wal_status, ''), coalesce(plugin, '')
		FROM pg_replication_slots WHERE slot_name = $(quote "$slot")")
	[[ -n $row ]] || { verdict SKIP "slot missing on provider"; return; }

	IFS=$SEP read -r failover active temp synced inval wal plugin <<<"$row"

	[[ $plugin == spock_output ]] || { verdict SKIP "slot plugin is '$plugin'"; return; }
	[[ $temp == f ]]              || { verdict SKIP "slot is temporary"; return; }
	[[ $synced == f ]]            || { verdict SKIP "slot is a synced copy; flag it on the primary"; return; }
	[[ -z $inval ]]               || { verdict SKIP "slot invalidated ($inval); needs recreating"; return; }
	[[ $wal != lost ]]            || { verdict SKIP "slot lost required WAL; needs recreating"; return; }

	[[ $failover == f ]] || { verdict OK "already a failover slot"; return; }

	# Prove this works before anything gets disabled: pg_hba.conf usually
	# needs a separate entry for the replication pseudo-database.
	out=$(repl "$pdsn" IDENTIFY_SYSTEM)
	if (( $? != 0 )); then
		hint=
		case $out in
		*"no pg_hba.conf entry"*)
			hint=" (needs a pg_hba entry for 'replication')" ;;
		*"permission denied to start WAL sender"*|*"replication role"*|\
		*"must be superuser"*|*"replication privilege"*)
			hint=" (role needs REPLICATION)" ;;
		esac
		verdict SKIP "no replication connection$hint: $(first_line "$out")"
		return
	fi

	verdict FLIP "unflagged (active=$active, enabled=$enabled)"
}

check_node() {
	local dsn=$1 name extver guc rows sub slot pdsn enabled res

	name=$(sql_e "$dsn" "
		SELECT n.node_name FROM spock.local_node ln
		JOIN spock.node n ON n.node_id = ln.node_id")

	if (( $? != 0 )) || [[ -z $name ]]; then
		warn "skipping node: ${name:-cannot read spock.local_node}"
		return
	fi

	extver=$(sql "$dsn" "SELECT extversion FROM pg_extension WHERE extname = 'spock'")
	[[ -n $extver ]] || { warn "$name: spock extension not installed"; return; }

	guc=$(sql "$dsn" "SELECT current_setting('spock.use_native_failover_slots', true)")
	log "$name: spock $extver, use_native_failover_slots=${guc:-unset}"
	[[ $guc == on ]] || warn "$name: GUC is ${guc:-unset}; new slots will be unflagged"

	rows=$(sql "$dsn" "
		SELECT s.sub_name, s.sub_slot_name, i.if_dsn, s.sub_enabled
		FROM spock.subscription s
		JOIN spock.node_interface i ON i.if_id = s.sub_origin_if
		ORDER BY s.sub_name")

	[[ -n $rows ]] || { log "$name: no subscriptions"; return; }

	while IFS=$SEP read -r sub slot pdsn enabled; do
		[[ -n $sub ]] || continue
		want_sub "$sub" || continue
		debug "$name: checking $sub ($slot)"
		res=$(check_slot "$slot" "$pdsn" "$enabled")
		add_target "$dsn" "$sub" "$slot" "$pdsn" "$enabled" \
			"${res%%"$SEP"*}" "${res##*"$SEP"}"
	done <<<"$rows"
}

# --------------------------------------------------------------- execute ---

wait_idle() {
	local pdsn=$1 slot=$2 waited=0 active

	active=$(sql "$pdsn" "SELECT active FROM pg_replication_slots WHERE slot_name = $(quote "$slot")")
	while [[ $active != f ]] && (( waited < IDLE_TIMEOUT )); do
		sleep 1
		waited=$(( waited + 1 ))
		active=$(sql "$pdsn" "SELECT active FROM pg_replication_slots WHERE slot_name = $(quote "$slot")")
	done
	[[ $active == f ]]
}

# flip <sub_dsn> <sub> <slot> <provider_dsn> <enabled>
flip() {
	local sdsn=$1 sub=$2 slot=$3 pdsn=$4 enabled=$5
	local rec= out failover

	if [[ $enabled == t ]]; then
		log "$sub: disabling to release $slot"
		out=$(sql_e "$sdsn" "SELECT spock.sub_disable($(quote "$sub"), true)")
		if (( $? != 0 )); then
			error "$sub: cannot disable: $(first_line "$out")"
			N_FAIL=$(( N_FAIL + 1 ))
			return
		fi
		rec="$sdsn$SEP$sub"
		PENDING+=("$rec")
	fi

	# ALTER_REPLICATION_SLOT waits, rather than failing, on a held slot.
	if ! wait_idle "$pdsn" "$slot"; then
		error "$sub: $slot still active after ${IDLE_TIMEOUT}s"
		N_FAIL=$(( N_FAIL + 1 ))
	else
		out=$(repl "$pdsn" "ALTER_REPLICATION_SLOT \"$slot\" (FAILOVER)")
		if (( $? != 0 )); then
			error "$sub: $(first_line "$out")"
			N_FAIL=$(( N_FAIL + 1 ))
		else
			failover=$(sql "$pdsn" "SELECT failover FROM pg_replication_slots WHERE slot_name = $(quote "$slot")")
			if [[ $failover == t ]]; then
				log "$sub: $slot is now a failover slot"
				N_DONE=$(( N_DONE + 1 ))
			else
				error "$sub: $slot still reports failover=$failover"
				N_FAIL=$(( N_FAIL + 1 ))
			fi
		fi
	fi

	[[ $enabled == t ]] || return

	out=$(sql_e "$sdsn" "SELECT spock.sub_enable($(quote "$sub"), true)")
	if (( $? != 0 )); then
		error "$sub: cannot re-enable: $(first_line "$out")"
		error "$sub: run: SELECT spock.sub_enable($(quote "$sub"), true);"
		N_FAIL=$(( N_FAIL + 1 ))
		return
	fi
	unpend "$rec"
	log "$sub: re-enabled"
	[[ $(sql "$sdsn" "SELECT sub_enabled FROM spock.subscription WHERE sub_name = $(quote "$sub")") == t ]] \
		|| warn "$sub: still reports disabled"
}

show_plan() {
	local rec sub slot action detail _d1 _d2 _d3

	printf '\n'
	for rec in "${TARGETS[@]}"; do
		IFS=$SEP read -r _d1 sub slot _d2 _d3 action detail <<<"$rec"
		case $action in
		FLIP)	printf '  flip  %-26s %-32s %s\n' "$sub" "$slot" "$detail" ;;
		OK)	printf '  ok    %-26s %-32s %s\n' "$sub" "$slot" "$detail" ;;
		NA)	printf '  n/a   %-26s %-32s %s\n' "$sub" "$slot" "$detail" ;;
		*)	printf '  SKIP  %-26s %-32s %s\n' "$sub" "$slot" "$detail" ;;
		esac
	done
	printf '\n'
	log "plan: $N_FLIP to flip, $N_OK already flagged, $N_NA n/a, $N_SKIP skipped"
}

confirm() {
	local reply
	(( ASSUME_YES )) && return 0
	[[ -t 0 ]] || fatal "refusing to change anything without --yes (or use --dry-run)"
	printf 'Briefly disable %d subscription(s) and flip their slots? [y/N] ' "$N_FLIP"
	read -r reply || reply=
	[[ $reply == [yY] || $reply == [yY][eE][sS] ]]
}

run_plan() {
	local rec sdsn sub slot pdsn enabled action _d

	for rec in "${TARGETS[@]}"; do
		IFS=$SEP read -r sdsn sub slot pdsn enabled action _d <<<"$rec"
		if [[ $action == FLIP ]]; then
			flip "$sdsn" "$sub" "$slot" "$pdsn" "$enabled"
		fi
	done
}

# ------------------------------------------------------------------ main ---

main() {
	local dsn

	parse_args "$@"
	check_psql

	(( ${#NODES[@]} )) || discover

	log "checking ${#NODES[@]} node(s)"
	for dsn in "${NODES[@]}"; do
		check_node "$dsn"
	done

	if (( ${#TARGETS[@]} == 0 )); then
		log "no subscriptions matched"
		return 0
	fi

	show_plan

	if (( N_FLIP == 0 )); then
		log "nothing to change"
		(( N_SKIP )) && return 1
		return 0
	fi
	if (( DRY_RUN )); then
		log "dry run: stopping before changes"
		return 0
	fi
	confirm || { log "aborted"; return 0; }

	run_plan

	printf '\n'
	log "done: $N_DONE flipped, $N_OK already flagged, $N_NA n/a, $N_SKIP skipped, $N_FAIL failed"

	(( N_FAIL || N_SKIP )) && return 1
	return 0
}

main "$@"
