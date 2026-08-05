#!/usr/bin/env bash
#
# tests/run-cluster-upgrade.sh
#
# Does a Spock cluster survive a cross-major PostgreSQL upgrade when the
# replicated database is a *complex* one?  "Complex" here means the core
# PostgreSQL regression database: ~250 relations covering every object
# kind, inheritance, partitioning, matviews, foreign tables, C functions,
# odd types, dropped columns and rewritten heaps.
#
# The versions are parameters, not part of the scenario.  OLD_MAJORS lists one
# PostgreSQL major per node and NEW_MAJOR is what they all end up on; the
# defaults are `16 17` and `19`.  The old nodes are built from OLD_SPOCK_REF
# (default v5_STABLE), the upgraded ones from this working tree.  Below,
# "Spock 5" and "Spock 6" mean those two trees whatever they happen to
# contain.
#
# Scenario (four steps):
#
#   1. Build the first old major + Spock 5.  Bring up ONE node (n1) with a
#      Spock node registered but no subscriptions -- no replication is
#      active.
#   2. Run the core `make installcheck` against n1 to populate a complex
#      `regression` database, then health-check the node.  With no
#      subscriber this must come out clean; see check_node_health() for
#      what "clean" means.
#   3. Build each remaining old major + Spock 5, bring up a node with an
#      empty `regression` database, and join it to the cluster with
#      samples/Z0DAN/zodan.sql -- `CALL spock.add_node(...)`.  Every
#      subscription must reach status='replicating' within
#      WAIT_REPLICATING_TIMEOUT (60s); otherwise the rig dies.
#   4. Upgrade the whole cluster to NEW_MAJOR + Spock 6 by running
#      pg_upgrade on each node, then check whether the subscriptions are
#      back in 'replicating'.
#
# ---------------------------------------------------------------------------
# How step 4 reports its result (read this before interpreting a run)
# ---------------------------------------------------------------------------
#
# pg_upgrade is a physical upgrade: it transfers relation files, so Spock's
# own catalogs (spock.node, spock.subscription, spock.replication_set*, ...)
# come across with their contents intact even though only
# spock.reserved_object is marked with pg_extension_config_dump -- that
# marking governs logical pg_dump, not pg_upgrade.  What does not survive on
# its own is the replication *plumbing* around them: slots and replication
# origins.  Slots are migrated only from a PG17-or-later old cluster, and
# origins are preserved only for native pg_subscription entries, which
# Spock's are not.
#
# So the rig measures rather than assumes, and reports two results:
#
#   SURVIVAL  after pg_upgrade + `ALTER EXTENSION spock UPDATE` + the
#             documented re-enable steps, is the full mesh of subscriptions
#             still present and back in 'replicating'?
#   REBUILD   if not, re-bootstrap the mesh on the upgraded cluster
#             (node_create + repset re-add + sub_create, no data resync --
#             pg_upgrade already carried the data) and check again.
#
# A red SURVIVAL with a green REBUILD is the informative middle outcome: the
# data upgrades fine, but the replication configuration has to be rebuilt by
# hand.  Both are reported; the exit code says which.
#
# The one thing this rig has to be careful about is the pg_upgrade slot
# check.  From PG17, pg_upgrade migrates the old cluster's logical slots and
# refuses to run while any of them still has undrained changes: it decodes from
# each slot's confirmed_flush to the end of WAL and fails if anything decodable
# comes out (binary_upgrade_logical_slot_has_caught_up() ->
# LogicalReplicationSlotHasPendingWal()).  So the requirement is *drained*, not
# *disabled*.  Disabling a subscription is fine, and is what core's own
# pg_upgrade docs advise for a publisher -- but disabling it `immediate` kills
# the apply worker before it has consumed what is pending, which is what made
# this check fail here.  quiesce_node() therefore only turns off DDL
# replication, and drain_cluster() drives a sync event across every edge with
# the apply workers still connected.  docs/upgrading_spock.md mentions neither
# subscriptions nor slot catch-up at all.
# quiesce_node() only turns off DDL replication; drain_cluster() then drives a
# sync event across every edge and the apply workers stay connected until the
# node goes down.  If the check still rejects a node, that rejection is
# recorded as the finding and the rig drops the replication state and retries,
# so the run still reaches a verdict on the rest.
#
# ---------------------------------------------------------------------------
# Layout (under BASE_DIR, default <spock-repo>/cluster-upgrade)
# ---------------------------------------------------------------------------
# A "variant" is one PostgreSQL build plus the spock that goes with it, named
# pg<major>-<spock-tree>; it is the directory name and the key every lookup
# works from, so nothing has to be kept in step with OLD_MAJORS by hand.
#
#   spock-src/v5              spock source at $OLD_SPOCK_REF
#   spock-src/v6              spock source copied from this working tree
#   src/pg<M>-v5              PG clone, patched with v5's patches/<M>
#   src/pg<N>-v6              PG clone, patched with v6's patches/<N>
#   bin/pg<M>-v5 ...          one install prefix per variant
#   pgdata/n<i>-pg<M>-v5      node i before the upgrade
#   pgdata/n<i>-pg<N>-v6      node i after the upgrade (pg_upgrade target)
#   sock/                     unix-socket dir shared by every node
#   log/                      per-phase logs; fresh on each run
#   report/                   schema / row-count signatures being compared
#
# With the defaults that comes out as src/pg16-v5, src/pg17-v5, src/pg19-v6,
# pgdata/n1-pg16-v5, pgdata/n1-pg19-v6, pgdata/n2-pg17-v5, pgdata/n2-pg19-v6.
#
# Node i listens on PORT_BASE+i and keeps that port across the upgrade, so the
# DSNs recorded in spock.node_interface stay valid; PORT_BASE+10+i is used only
# by pg_upgrade's own throwaway server starts.
#
# Subscription naming follows Spock's convention: sub_<provider>_<subscriber>,
# so sub_n1_n2 lives on n2 and pulls from n1.
#
# Usage:
#   tests/run-cluster-upgrade.sh [--base-dir DIR] [--keep] [--force]
#                                [--jobs N] [--skip-installcheck]
#                                [--ignore-step2-health]
#
# Existing PG installs (bin/postgres present) and Spock installs
# (extension/spock.control present) are reused between runs; --force
# rebuilds everything.
#
# --skip-installcheck swaps the regression suite for a small synthetic schema.
# That turns a long run into a couple of minutes and is the way to iterate on
# the rig itself, but it does NOT test what this rig exists to test.
#
# --ignore-step2-health carries on past a failed step 2 instead of stopping.
# Use it to exercise steps 3 and 4 while a known step-2 problem is open; the
# failure is still reported, loudly, in the log and on the terminal.
#
# Environment:
#   OLD_MAJORS         PostgreSQL major per node, in node order
#                      (default: "16 17"; two or more required)
#   NEW_MAJOR          major every node is upgraded to (default: 19)
#   PORT_BASE          node i listens on PORT_BASE+i (default: 57700)
#   OLD_SPOCK_REF      git ref for the old nodes (default: v5_STABLE)
#   PG<major>_REF      override the PostgreSQL ref for one major, e.g.
#                      PG16_REF=REL_16_9.  Default: tests/resolve-pg-ref.sh,
#                      falling back to REL_<major>_STABLE if no tag is
#                      published yet.
#   SPOCK_PG_CONFIGURE extra ./configure flags for every PG build
#   WAIT_REPLICATING_TIMEOUT   seconds to wait for status='replicating'
#                              (default 60, per the scenario)
#   ZODAN_TIMEOUT      wall-clock cap on CALL spock.add_node() (default 900)
#   DRAIN_TIMEOUT      per-edge sync-event wait when draining (default 60)
#   INSTALLCHECK_TIMEOUT       wall-clock cap on the regression suite
#                              (default 3600)
#
# Exit status:
#   0   every check green: the complex database survived both upgrades
#       byte-for-byte, and the subscriptions came back to 'replicating'
#       without any manual re-bootstrap.
#   2   the upgraded database is intact and replication works, but the mesh
#       did not come back by itself and had to be rebuilt.
#   3   subscriptions never reached 'replicating' after the upgrade, even
#       after a full re-bootstrap.
#   4   the upgraded database itself differs from the pre-upgrade one
#       (relation set or row counts) -- a pg_upgrade correctness problem,
#       and the most serious verdict this rig can reach.
#   5   the nodes disagree on the contents of replicated tables after
#       zodan add_node.
#   10  bad command line.
#   11  build / clone / patch failure.
#   12  a node never became ready.
#   13  step 2 health check on the first (single) node failed.
#   14  zodan add_node failed, or the mesh did not reach 'replicating'
#       within WAIT_REPLICATING_TIMEOUT.
#   15  pg_upgrade refused to run or failed.
#
# When several verdicts apply the most serious one is returned, and every
# failing check is named in the summary.
#

# Deliberately NOT using `-E` (errtrace): with -E the ERR trap leaks into
# command substitutions and a single transient psql failure would shut the
# whole run down.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOCK_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_DIR="${SPOCK_SRC}/cluster-upgrade"
KEEP_RUNNING=0
FORCE_REBUILD=0
SKIP_INSTALLCHECK=0
IGNORE_STEP2_HEALTH=0
JOBS_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# The version matrix, and the only place versions are named.  OLD_MAJORS lists
# one PostgreSQL major per node, in node order: the first is the node the
# cluster starts as, the rest join it in turn.  Every node is then upgraded to
# NEW_MAJOR.  Two nodes is the minimum the scenario needs (a source and a
# joiner); adding majors adds nodes.
#
# Deliberately not baked into the file name or the directory layout -- the
# defaults move every release, the script does not.
OLD_MAJORS="${OLD_MAJORS:-16 17}"
NEW_MAJOR="${NEW_MAJOR:-19}"

# Nodes listen on PORT_BASE+n; pg_upgrade gets PORT_BASE+10+n for its own
# throwaway server starts.  Chosen not to collide with the other rigs in
# tests/ so they can run side by side.
PORT_BASE="${PORT_BASE:-57700}"

DBNAME=regression
DBUSER=regression

# git ref the 5.x half of the cluster is built from.
OLD_SPOCK_REF="${OLD_SPOCK_REF:-spoc-643}"

# Seconds to wait for every subscription to report status='replicating'.
# The scenario asks for a hard 1-minute bound.
WAIT_REPLICATING_TIMEOUT="${WAIT_REPLICATING_TIMEOUT:-60}"

# Seconds allowed for a single sync event to cross one edge when draining the
# cluster before the upgrade.
DRAIN_TIMEOUT="${DRAIN_TIMEOUT:-60}"

# Wall-clock cap on `CALL spock.add_node(...)`.  Generous: it has to pg_dump
# the source schema, restore it, and copy every replicated table.
ZODAN_TIMEOUT="${ZODAN_TIMEOUT:-900}"

# Wall-clock cap on the core regression suite.  A hang here (auto-DDL
# deadlocking against a regression test, say) is the nastiest failure mode
# for CI, so it gets a hard bound rather than an unbounded wait.
INSTALLCHECK_TIMEOUT="${INSTALLCHECK_TIMEOUT:-3600}"

# ICU is deliberately off: pg_upgrade compares the locale provider and ICU
# version between clusters, and three independently-configured majors are
# far more likely to agree on plain libc/C.
PG_CONFIGURE_FLAGS="--enable-debug --enable-cassert --without-icu --without-readline"
PG_CONFIGURE_FLAGS="${PG_CONFIGURE_FLAGS} ${SPOCK_PG_CONFIGURE:-}"

PG_GIT_REMOTES="https://git.postgresql.org/git/postgresql.git https://github.com/postgres/postgres.git"

# ---------------------------------------------------------------------------
# Version matrix, derived
# ---------------------------------------------------------------------------
# A "variant" is one build of PostgreSQL plus the spock that goes with it,
# named pg<major>-<spock-tree>, e.g. pg16-v5 or pg19-v6.  It is both the
# directory name under src/ and bin/ and the key every lookup below works
# from, so the naming convention is the schema -- there are no tables to keep
# in step with OLD_MAJORS.
#
# Bash-3-safe throughout: macOS /bin/bash has no `declare -A`.

# n3 -> 3.  The node names are positions in OLD_MAJORS.
node_index() { printf '%s' "${1#n}"; }

# Port a node listens on, before and after the upgrade alike.  Keeping the
# port stable is what lets the DSNs recorded in spock.node_interface survive
# the upgrade untouched.
node_to_port() {
	printf '%s\n' "$(( PORT_BASE + $(node_index "$1") ))"
}

# Scratch port handed to pg_upgrade for its own short-lived server starts.
# pg_upgrade refuses to run with both clusters on the same port.
node_to_stage_port() {
	printf '%s\n' "$(( PORT_BASE + 10 + $(node_index "$1") ))"
}

# Build variant a node starts life on: the major at its position in OLD_MAJORS.
node_to_old_variant() {
	local want major pos=0
	want="$(node_index "$1")"
	for major in ${OLD_MAJORS}; do
		pos=$(( pos + 1 ))
		if [ "${pos}" -eq "${want}" ]; then
			printf 'pg%s-v5\n' "${major}"
			return 0
		fi
	done
	return 1
}

# pg16-v5 -> 16
variant_to_major() {
	local v="${1#pg}"
	printf '%s\n' "${v%%-*}"
}

# pg16-v5 -> v5.  Selects both the spock source tree and the patches/<major>/
# applied to PostgreSQL, which must come from the same tree.
variant_to_spock() { printf '%s\n' "${1##*-}"; }

# Derive the node list and the full variant set from the matrix.  Variants are
# de-duplicated: two nodes may legitimately start on the same major, and each
# build must happen once.
#
# Bails with a bare printf rather than fail(): this runs before the logging
# helpers and the log directory exist.
NODES=""
NODE_COUNT=0
for _major in ${OLD_MAJORS}; do
	case "${_major}" in
		'' | *[!0-9]*)
			printf 'FATAL: OLD_MAJORS must be numeric majors, got "%s"\n' \
				"${_major}" >&2
			exit 10 ;;
	esac
	NODE_COUNT=$(( NODE_COUNT + 1 ))
	NODES="${NODES}${NODES:+ }n${NODE_COUNT}"
done
case "${NEW_MAJOR}" in
	'' | *[!0-9]*)
		printf 'FATAL: NEW_MAJOR must be a numeric major, got "%s"\n' \
			"${NEW_MAJOR}" >&2
		exit 10 ;;
esac

# zodan add_node needs somewhere to join from and somewhere to join to.
if [ "${NODE_COUNT}" -lt 2 ]; then
	printf 'FATAL: OLD_MAJORS needs at least two majors (got "%s")\n' \
		"${OLD_MAJORS}" >&2
	exit 10
fi

# The node the cluster starts as, and the source every other node joins from.
FIRST_NODE="n1"

NEW_VARIANT="pg${NEW_MAJOR}-v6"     # what every node is upgraded to

ALL_VARIANTS=""
for _major in ${OLD_MAJORS} ; do
	_v="pg${_major}-v5"
	case " ${ALL_VARIANTS} " in
		*" ${_v} "*) continue ;;
	esac
	ALL_VARIANTS="${ALL_VARIANTS}${ALL_VARIANTS:+ }${_v}"
done
ALL_VARIANTS="${ALL_VARIANTS} ${NEW_VARIANT}"
unset _major _v

# The variant a node is running *right now*.  Mutable state, so it lives in
# a per-node shell variable addressed by name (bash 3 has no hashes).
set_node_variant() { eval "NODE_VARIANT_$1=\"\$2\""; }
node_variant()     { eval "printf '%s\\n' \"\${NODE_VARIANT_$1}\""; }

# ---------------------------------------------------------------------------
# Logging / error trap
# ---------------------------------------------------------------------------

# log() writes only to disk -- the terminal stays readable.  Output goes to
# the caller's $NODE_LOG when set, otherwise to $MAIN_LOG.
log() {
	local msg
	msg="[$(date +%H:%M:%S)] $*"
	if [ -n "${NODE_LOG:-}" ]; then
		printf '%s\n' "${msg}" >>"${NODE_LOG}"
	elif [ -n "${MAIN_LOG:-}" ]; then
		printf '%s\n' "${msg}" >>"${MAIN_LOG}"
	fi
}

# say() is for the few things the user must see on the terminal.
say() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

fail() { say "FATAL: $1"; log "FATAL: $1"; exit "${2:-11}"; }

# run_phase LABEL PHASE CMD ARGS...
#   Runs CMD with stdout+stderr captured to ${LOG_DIR}/<label>-<phase>.log
#   and emits a single end-of-phase OK/FAILED line on the terminal.
#
# IMPORTANT for every _do_* helper invoked through here: bash ignores
# `set -e` while running a command whose exit status is being tested, and
# run_phase tests it (`"$@" || rc=$?`).  The suppression reaches into the
# helper -- and into subshells it starts, even ones that re-run `set -e`
# themselves (verified on bash 3.2).  So a multi-step helper MUST chain its
# steps with && or return explicitly after each one; relying on errexit
# means a failed first step is followed by every later step, and the log
# ends up showing the consequences instead of the cause.
run_phase() {
	local label="$1" phase="$2"
	shift 2
	local logf="${LOG_DIR}/${label}-${phase}.log"
	log "${label}: [${phase}] start  -> ${logf}"
	local rc=0
	"$@" >"${logf}" 2>&1 || rc=$?
	if [ "${rc}" -ne 0 ]; then
		log "${label}: [${phase}] FAILED rc=${rc}  (see ${logf})"
		say "${label}: ${phase} FAILED rc=${rc}  (see ${logf})"
		return "${rc}"
	fi
	log "${label}: [${phase}] ok"
	say "${label}: ${phase} ok"
}

# Run a command with a wall-clock cap, portably (macOS ships no timeout(1)).
# Returns the command's status, or 124 on expiry -- matching timeout(1) so
# callers can tell a hang from a plain failure.
run_with_timeout() {
	local secs="$1"
	shift
	"$@" &
	local pid=$!
	local deadline=$(( $(date +%s) + secs ))
	while kill -0 "${pid}" 2>/dev/null; do
		if [ "$(date +%s)" -ge "${deadline}" ]; then
			log "run_with_timeout: killing pid ${pid} after ${secs}s"
			# Signal the direct children too: the thing we background is a
			# subshell, and its `make` grandchildren would otherwise survive
			# and keep hammering the cluster.  Best effort -- pkill is not
			# guaranteed to exist, and it cannot reach further descendants.
			pkill -TERM -P "${pid}" 2>/dev/null || true
			kill -TERM "${pid}" 2>/dev/null || true
			sleep 5
			pkill -KILL -P "${pid}" 2>/dev/null || true
			kill -KILL "${pid}" 2>/dev/null || true
			wait "${pid}" 2>/dev/null || true
			return 124
		fi
		sleep 2
	done
	local rc=0
	wait "${pid}" || rc=$?
	return "${rc}"
}

trap 'on_err $? $LINENO' ERR

on_err() {
	local rc=$1 line=$2
	log "Aborted: exit ${rc} at line ${line}"
	say "see ${LOG_DIR}/ for per-phase log files"
	exit "${rc}"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

usage() {
	awk 'NR>1 { if ($0 !~ /^#/) exit; print }' "$0"
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--base-dir)          [ "$#" -ge 2 ] || fail "--base-dir requires a value" 10
		                     BASE_DIR="$2"; shift 2 ;;
		--keep)              KEEP_RUNNING=1; shift ;;
		--force)             FORCE_REBUILD=1; shift ;;
		--jobs)              [ "$#" -ge 2 ] || fail "--jobs requires a value" 10
		                     JOBS_TOTAL="$2"; shift 2 ;;
		--skip-installcheck) SKIP_INSTALLCHECK=1; shift ;;
		--ignore-step2-health) IGNORE_STEP2_HEALTH=1; shift ;;
		-h|--help)           usage; exit 0 ;;
		*)                   fail "unknown argument: $1" 10 ;;
	esac
done

mkdir -p "${BASE_DIR}/src"        \
         "${BASE_DIR}/bin"        \
         "${BASE_DIR}/spock-src"  \
         "${BASE_DIR}/pgdata"     \
         "${BASE_DIR}/log"        \
         "${BASE_DIR}/report"     \
         "${BASE_DIR}/sock"
BASE_DIR="$(cd "${BASE_DIR}" && pwd)"
SOCK_DIR="${BASE_DIR}/sock"
LOG_DIR="${BASE_DIR}/log"
REPORT_DIR="${BASE_DIR}/report"

# When BASE_DIR sits inside the spock tree -- which it does by default -- it
# must be kept out of the copy the v6 build is staged from: it holds tens of
# gigabytes of PostgreSQL builds, and copying it into a subdirectory of itself
# would recurse.  Computed from BASE_DIR rather than hard-coded, so it keeps
# working when --base-dir moves.
BASE_DIR_EXCLUDE=""
case "${BASE_DIR}/" in
	"${SPOCK_SRC}/"*)
		BASE_DIR_EXCLUDE="--exclude=/${BASE_DIR#"${SPOCK_SRC}/"}" ;;
esac

# Fresh log and report directories per run; src/, bin/, spock-src/ and
# pgdata/ are preserved so build reuse still works.
rm -rf "${LOG_DIR}" "${REPORT_DIR}"
mkdir -p "${LOG_DIR}" "${REPORT_DIR}"

# Sweep up anything reset_dir could not delete on a previous run.
rm -rf "${BASE_DIR}"/*/*.discard.* 2>/dev/null || true

MAIN_LOG="${LOG_DIR}/main.log"
: >"${MAIN_LOG}"

# Unix socket paths are capped at ~104 bytes on macOS; a deep --base-dir
# silently breaks every connection later on, so refuse early and loudly.
[ "${#SOCK_DIR}" -le 80 ] \
	|| fail "socket dir path too long (${#SOCK_DIR} chars): ${SOCK_DIR}" 10

log "BASE_DIR      = ${BASE_DIR}"
log "SPOCK_SRC     = ${SPOCK_SRC}"
log "JOBS_TOTAL    = ${JOBS_TOTAL}"
log "OLD_SPOCK_REF = ${OLD_SPOCK_REF}"
log "NODES         = ${NODES}"
log "NEW_VARIANT   = ${NEW_VARIANT}"

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

# Replace a directory with a fresh empty one.
#
# Not a plain `rm -rf`: on macOS, Finder or Spotlight can drop a .DS_Store into
# a directory while rm is walking it, and rm then fails the final rmdir with
# "Directory not empty" -- which killed a run here.  Renaming first is atomic,
# so a concurrent writer lands in the discarded copy and cannot race us.  If
# even the discard cannot be removed it is left behind: that wastes disk but
# breaks nothing, and the next run sweeps it up.
reset_dir() {
	local dest="$1"
	if [ -e "${dest}" ]; then
		local trash="${dest}.discard.$$"
		rm -rf "${trash}" 2>/dev/null || true
		mv "${dest}" "${trash}" || return 1
		rm -rf "${trash}" 2>/dev/null \
			|| log "reset_dir: could not remove ${trash}; left in place"
	fi
	mkdir -p "${dest}"
}

prefix_for()      { echo "${BASE_DIR}/bin/$1"; }
pgsrc_for()       { echo "${BASE_DIR}/src/$1"; }
pg_config_for()   { echo "${BASE_DIR}/bin/$1/bin/pg_config"; }
spock_src_for()   { echo "${BASE_DIR}/spock-src/$1"; }

# Data directory of a node under a given variant.  A node has one per
# variant it has lived on, which is what makes the old cluster inspectable
# after the upgrade.
data_for() { echo "${BASE_DIR}/pgdata/$1-$2"; }

# DSN that talks over the shared Unix socket directory.  zodan requires the
# database name to be spelled out in the DSN, and Spock stores this string
# verbatim in spock.node_interface -- hence the stable ports.
dsn_for_node() {
	local node="$1"
	local port; port="$(node_to_port "${node}")"
	echo "host=${SOCK_DIR} port=${port} dbname=${DBNAME} user=${DBUSER}"
}

# Run psql against a node using that node's *current* install, so the
# client always matches the server major.
psql_on() {
	local node="$1"; shift
	local port; port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_for "$(node_variant "${node}")")"
	PGPASSWORD="" "${prefix}/bin/psql" \
		-X -v ON_ERROR_STOP=1 \
		-h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -d "${DBNAME}" \
		"$@"
}

# Like psql_maint, but without ON_ERROR_STOP: for scripts where individual
# statements are allowed to fail.  Only used for the AdjustUpgrade fixups,
# which name objects the regression suite may or may not have left behind.
psql_maint_lax() {
	local node="$1"; shift
	local port; port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_for "$(node_variant "${node}")")"
	PGPASSWORD="" "${prefix}/bin/psql" \
		-X -h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -d postgres \
		"$@"
}

# Same, but against the `postgres` maintenance database -- needed while the
# target database is being created or does not exist yet.
psql_maint() {
	local node="$1"; shift
	local port; port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_for "$(node_variant "${node}")")"
	PGPASSWORD="" "${prefix}/bin/psql" \
		-X -v ON_ERROR_STOP=1 \
		-h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -d postgres \
		"$@"
}

# ---------------------------------------------------------------------------
# Spock source trees
# ---------------------------------------------------------------------------

# The v6 side is the working tree as it stands -- that is the whole point of
# running this rig locally.  rsync rather than `git archive` so uncommitted
# changes are covered.
_do_stage_spock_v6() {
	local dest="$1"
	reset_dir "${dest}" && \
	rsync -a \
		${BASE_DIR_EXCLUDE:+"${BASE_DIR_EXCLUDE}"} \
		--exclude='/single-pg18-installcheck' \
		--exclude='/.git' \
		--exclude='.DS_Store' \
		"${SPOCK_SRC}/" "${dest}/"
}

# The v5 side is a detached checkout of OLD_SPOCK_REF from the local repo.
# Cloning from the local repo keeps the network out of the picture; the
# extra fetch pulls the ref in when the caller names something only
# reachable via origin.
_do_stage_spock_v5() {
	local dest="$1"
	# git clone accepts an existing empty directory, so reset_dir is enough.
	reset_dir "${dest}" && \
	git clone --no-checkout --shared "${SPOCK_SRC}" "${dest}" && \
	{
		# Pull the source repo's remote-tracking refs across as well, so a
		# caller who names `origin/something` gets what they asked for.  Not
		# fatal on its own: the ref may already be local.
		git -C "${dest}" fetch --no-tags "${SPOCK_SRC}" \
			'+refs/remotes/origin/*:refs/remotes/origin/*' >/dev/null 2>&1 || true
		# A clone materialises only the source's HEAD as a local branch;
		# everything else arrives as origin/<name>, so try both spellings.
		git -C "${dest}" checkout --detach "${OLD_SPOCK_REF}" 2>/dev/null \
			|| git -C "${dest}" checkout --detach "origin/${OLD_SPOCK_REF}"
	} && \
	git -C "${dest}" --no-pager log -1 --format='staged spock ref %H %s'
}

stage_spock_sources() {
	local v5; v5="$(spock_src_for v5)"
	local v6; v6="$(spock_src_for v6)"

	if [ "${FORCE_REBUILD}" -eq 0 ] && [ -f "${v5}/Makefile" ]; then
		log "spock-v5: reusing staged source at ${v5}"
	else
		run_phase spock-v5 stage _do_stage_spock_v5 "${v5}"
	fi

	# The v6 tree is always restaged: it tracks the working tree, and a
	# stale copy would silently test yesterday's code.
	run_phase spock-v6 stage _do_stage_spock_v6 "${v6}"

	local v
	for v in v5 v6; do
		local d; d="$(spock_src_for "${v}")"
		[ -f "${d}/Makefile" ] \
			|| fail "spock source ${d} has no Makefile after staging" 11
	done

	# Record what we actually built, so a log tells you which 5.x this was.
	local v5ver v6ver
	v5ver="$(sed -n 's/^#define SPOCK_VERSION "\(.*\)"/\1/p' "${v5}/include/spock.h")"
	v6ver="$(sed -n 's/^#define SPOCK_VERSION "\(.*\)"/\1/p' "${v6}/include/spock.h")"
	log "spock versions: v5=${v5ver}  v6=${v6ver}"
	say "spock: old=${v5ver} (${OLD_SPOCK_REF})  new=${v6ver} (working tree)"
	SPOCK_V5_VERSION="${v5ver}"
	SPOCK_V6_VERSION="${v6ver}"
}

# ---------------------------------------------------------------------------
# PostgreSQL build pipeline, once per variant
# ---------------------------------------------------------------------------

# Pick the first reachable mirror.  Reachability is probed generically
# (HEAD), not by looking up the ref, because a ref may be a raw commit SHA;
# a bad ref is caught loudly by the fetch itself.
pick_pg_remote() {
	local r
	for r in ${PG_GIT_REMOTES}; do
		if git ls-remote --exit-code "${r}" HEAD >/dev/null 2>&1; then
			echo "${r}"
			return 0
		fi
	done
	return 1
}

# Concrete PostgreSQL ref for a major: an explicit PG<major>_REF override
# wins, then tests/resolve-pg-ref.sh (which reads postgres-build.conf), and
# finally the stable branch -- the last one matters for a major whose first
# tag has not been published yet.
resolve_pg_ref() {
	local major="$1"
	local override
	eval "override=\"\${PG${major}_REF:-}\""
	if [ -n "${override}" ]; then
		printf '%s\n' "${override}"
		return 0
	fi
	local ref
	if ref="$("${SCRIPT_DIR}/resolve-pg-ref.sh" "${major}" 2>>"${MAIN_LOG}")" \
			&& [ -n "${ref}" ]; then
		printf '%s\n' "${ref}"
		return 0
	fi
	log "pg${major}: resolve-pg-ref.sh found nothing; using REL_${major}_STABLE"
	printf '%s\n' "REL_${major}_STABLE"
}

# fetch + checkout rather than `clone --branch`, so an explicit commit SHA
# works as well as a branch or tag.  The && chain makes a mid-sequence
# failure propagate, and the ref marker is written only on full success.
_do_clone_pg() {
	local src="$1" remote="$2" ref="$3"
	reset_dir "${src}" && \
	git init "${src}" && \
	git -C "${src}" remote add origin "${remote}" && \
	git -C "${src}" fetch --depth 1 origin "${ref}" && \
	git -C "${src}" checkout --detach FETCH_HEAD && \
	printf '%s\n' "${ref}" > "${src}/.spock-pg-ref" && \
	printf '%s\n' "${src}" > "${src}/.spock-src-path"
}

clone_pg() {
	local variant="$1"
	local major; major="$(variant_to_major "${variant}")"
	local src;   src="$(pgsrc_for "${variant}")"
	local ref;   ref="$(resolve_pg_ref "${major}")"

	log "${variant}: PostgreSQL ref = ${ref}"

	# A cached checkout built for a different ref forces a full rebuild of
	# this variant, so the new ref reaches the configure and spock phases
	# too.  A moved branch tip (same name, new commits) is deliberately not
	# detected; use --force for that.
	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ -d "${src}/.git" ] \
		&& [ "$(cat "${src}/.spock-pg-ref" 2>/dev/null)" != "${ref}" ]; then
		log "${variant}: cached source is for a different ref; rebuilding for ${ref}"
		rm -rf "$(prefix_for "${variant}")"
		VARIANT_FORCE=1
	fi

	# Neither a built PostgreSQL source tree nor an install survives being
	# moved: the build symlinks src/include/**/*.h to absolute paths under
	# src/backend, and the installed binaries carry an absolute rpath.  Moving
	# BASE_DIR therefore leaves a tree that looks complete and fails with a
	# baffling "utils/errcodes.h: file not found", because make sees the
	# dangling symlink and considers the header done.  Detect the move and
	# start that variant over.
	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ -d "${src}/.git" ] \
		&& [ "$(cat "${src}/.spock-src-path" 2>/dev/null)" != "${src}" ]; then
		log "${variant}: cached source was built at a different path; starting over"
		say "${variant}: build cache is from another directory -- rebuilding"
		rm -rf "$(prefix_for "${variant}")"
		VARIANT_FORCE=1
	fi

	if [ "${FORCE_REBUILD}" -eq 0 ] && [ "${VARIANT_FORCE}" -eq 0 ] \
		&& [ -d "${src}/.git" ] \
		&& [ -f "${src}/src/test/regress/parallel_schedule" ]; then
		log "${variant}: source for ${ref} already present, skipping clone"
		return 0
	fi

	local remote
	remote="$(pick_pg_remote)" \
		|| fail "${variant}: no reachable git remote for ${ref}" 11

	run_phase "${variant}" pg-clone _do_clone_pg "${src}" "${remote}" "${ref}"
}

# Spock needs PostgreSQL with its own per-version patches.  They must come
# from the *same* spock tree that will be built against this PG: v5 and v6
# do not ship identical patch sets for a given major.
#
# patch(1), not `git apply`.  patches/19/pg19-030-per-subtrans-commit-ts.diff
# contains a zero-context insertion hunk (`@@ -97,0 +97,7 @@`); with nothing
# to anchor on, git apply reports success but drops the inserted block at the
# end of the file, so commit_ts.c ends up using three static variables that
# are declared 1000 lines below their first use and the build fails deep in
# contrib with a misleading link error.  patch(1) honours the stated line
# number and puts it where it belongs.
#
# -N -f forces forward-only, never-prompt mode: BSD patch on macOS otherwise
# hits its "Reversed (or previously applied) patch detected! Assume -R? [y]"
# heuristic when a hunk's context sits near EOF, auto-answers yes against
# piped stdin, silently skips the hunk and still exits 0 -- a half-applied
# patchset behind a marker that says "applied".
_do_patch_pg() {
	local src="$1" patch_dir="$2"
	[ -d "${patch_dir}" ] || { echo "no patch directory ${patch_dir}"; return 1; }
	local p any=0
	for p in "${patch_dir}"/*.diff "${patch_dir}"/*.patch; do
		[ -f "${p}" ] || continue
		any=1
		echo "----- applying $(basename "${p}") -----"
		( cd "${src}" && patch -p1 -N -f <"${p}" ) || {
			echo "FAILED to apply $(basename "${p}")"
			return 1
		}
	done
	[ "${any}" -eq 1 ] || { echo "no .diff/.patch files in ${patch_dir}"; return 1; }
	touch "${src}/.spock-patches-applied"
}

patch_pg() {
	local variant="$1"
	local src;   src="$(pgsrc_for "${variant}")"
	local major; major="$(variant_to_major "${variant}")"
	local spock; spock="$(spock_src_for "$(variant_to_spock "${variant}")")"
	local patch_dir="${spock}/patches/${major}"

	if [ -f "${src}/.spock-patches-applied" ]; then
		log "${variant}: patches already applied (marker present), skipping"
		return 0
	fi
	run_phase "${variant}" pg-patch _do_patch_pg "${src}" "${patch_dir}"
}

# run_phase invokes helpers in the current shell, so every `cd` here lives in
# a subshell -- a leaked working directory would silently misdirect a later
# phase.
_do_configure_pg() {
	local src="$1" prefix="$2"
	(
		cd "${src}"
		# shellcheck disable=SC2086  # PG_CONFIGURE_FLAGS is a flag list
		./configure --prefix="${prefix}" ${PG_CONFIGURE_FLAGS}
	)
}

# Beyond core: contrib (dblink, which zodan needs) and pg_regress (which
# `make installcheck` needs).  Both must exist in *every* install, not just
# the ones that use them directly: pg_upgrade's check_loadable_libraries
# walks pg_proc.probin of the old cluster and insists every library loads
# in the new one, so a dblink left out of the new install would block the
# upgrade of a database that merely has the extension installed.
# Is a regress*.so / regress*.dylib present in the given directory?  The
# extension differs by platform, and `ls a b` reports failure when either
# argument is missing, so test the two names separately rather than handing
# both to one ls.
have_regress_lib() {
	local dir="$1" f
	for f in "${dir}"/regress*.so "${dir}"/regress*.dylib; do
		[ -f "${f}" ] && return 0
	done
	return 1
}

# Install the regression suite's shared library into $libdir, which PostgreSQL
# itself never does.
#
# The core regression suite creates C functions whose probin is an absolute
# path into the build tree that ran it, because pg_regress passes --dlpath.
# That is fatal here in two places: spock's structure sync pg_restores the
# schema into a *different* major (a PG17 backend cannot dlopen PG16's
# regress.dylib -- "Symbol not found: _pg_char_to_encoding"), and pg_upgrade
# insists every library named in pg_proc.probin loads in the new cluster.
#
# Giving every install its own copy under the canonical name lets probin be
# rewritten to '$libdir/regress' once (normalise_regress_probin), after which
# each server resolves the name against its own major's library.
_do_install_regress_lib() {
	local src="$1" prefix="$2"
	local libdir; libdir="$("${prefix}/bin/pg_config" --pkglibdir)" || return 1
	local f found=0
	for f in "${src}"/src/test/regress/regress*.so \
	         "${src}"/src/test/regress/regress*.dylib; do
		[ -f "${f}" ] || continue
		echo "installing $(basename "${f}") into ${libdir}"
		cp "${f}" "${libdir}/" || return 1
		found=1
	done
	[ "${found}" -eq 1 ] || { echo "no regress library built under ${src}"; return 1; }
}

_do_build_pg() {
	local src="$1" jobs="$2" prefix="$3"
	# Generate the derived headers (utils/errcodes.h, fmgroids.h, gram.h, ...)
	# before the parallel build.  src/Makefile compiles src/common -- which
	# includes utils/errcodes.h -- before src/backend has generated it, and
	# `make -j` turns that gap into a "file not found".  It bites on a freshly
	# configured tree and again whenever configure is re-run over an existing
	# one, which happens when the flags or the install prefix change.
	make -C "${src}/src/backend" -s generated-headers && \
	make -C "${src}" -s -j"${jobs}" && \
	make -C "${src}" -s -j"${jobs}" install && \
	make -C "${src}/contrib" -s -j"${jobs}" install && \
	make -C "${src}/src/test/regress" -s install && \
	make -C "${src}/src/test/regress" -s all && \
	_do_install_regress_lib "${src}" "${prefix}"
}

build_pg() {
	local variant="$1"
	local src;    src="$(pgsrc_for "${variant}")"
	local prefix; prefix="$(prefix_for "${variant}")"

	# Reuse requires more than a postgres binary: dblink (for zodan) and the
	# regression shared library both come from build phases a plain
	# `make install` does not cover, so an install missing either is not
	# reusable.  Note that configure moves sharedir to
	# <prefix>/share/postgresql, hence asking pg_config rather than guessing.
	if [ "${FORCE_REBUILD}" -eq 0 ] && [ "${VARIANT_FORCE}" -eq 0 ] \
		&& [ -x "${prefix}/bin/postgres" ] \
		&& [ -x "${prefix}/bin/pg_config" ] \
		&& [ -f "$("${prefix}/bin/pg_config" --sharedir)/extension/dblink.control" ] \
		&& have_regress_lib "$("${prefix}/bin/pg_config" --pkglibdir)"; then
		log "${variant}: reusing existing PostgreSQL install at ${prefix}"
		return 0
	fi

	run_phase "${variant}" pg-configure _do_configure_pg "${src}" "${prefix}"
	run_phase "${variant}" pg-build     _do_build_pg     "${src}" "${JOBS_TOTAL}" \
		"${prefix}"
}

# Spock is built in a per-variant copy of its source tree: object files
# from another variant are linked against a different PostgreSQL, and a
# shared tree would install them verbatim.
# spock 5's default target also builds utils/spockctrl, which needs jansson
# via pkg-config.  Nothing in this rig uses spockctrl -- zodan is plain SQL
# over dblink -- so drop it from the throwaway build tree rather than making
# the whole run depend on a library CI may not have.
_do_drop_spockctrl() {
	local build_dir="$1"
	grep -q '^all: spock.control spockctrl' "${build_dir}/Makefile" || return 0
	echo "----- dropping spockctrl from the build (not needed here) -----"
	sed -e 's/^all: spock.control spockctrl$/all: spock.control/' \
	    -e 's/^clean: clean-spockctrl$/clean:/' \
	    -e 's/^install: install-spockctrl$/install:/' \
	    "${build_dir}/Makefile" >"${build_dir}/Makefile.nospockctrl" && \
	mv "${build_dir}/Makefile.nospockctrl" "${build_dir}/Makefile"
}

_do_build_spock() {
	local spock_src="$1" build_dir="$2" pg_config="$3" jobs="$4"
	reset_dir "${build_dir}" && \
	rsync -a --exclude='/.git' --exclude='.DS_Store' \
		"${spock_src}/" "${build_dir}/" && \
	_do_drop_spockctrl "${build_dir}" && \
	make -C "${build_dir}" PG_CONFIG="${pg_config}" clean && \
	make -C "${build_dir}" PG_CONFIG="${pg_config}" -j"${jobs}" && \
	make -C "${build_dir}" PG_CONFIG="${pg_config}" install
}

build_spock() {
	local variant="$1"
	local pg_config; pg_config="$(pg_config_for "${variant}")"
	local spock_src; spock_src="$(spock_src_for "$(variant_to_spock "${variant}")")"
	local build_dir="${BASE_DIR}/spock-build/${variant}"

	[ -x "${pg_config}" ] || fail "${variant}: no pg_config at ${pg_config}" 11

	local sharedir; sharedir="$("${pg_config}" --sharedir)"
	if [ "${FORCE_REBUILD}" -eq 0 ] && [ "${VARIANT_FORCE}" -eq 0 ] \
		&& [ -f "${sharedir}/extension/spock.control" ]; then
		log "${variant}: reusing existing spock install"
		return 0
	fi

	run_phase "${variant}" spock-build _do_build_spock \
		"${spock_src}" "${build_dir}" "${pg_config}" "${JOBS_TOTAL}"
}

build_variant() {
	local variant="$1"
	VARIANT_FORCE=0        # per-variant escalation set by clone_pg
	clone_pg    "${variant}"
	patch_pg    "${variant}"
	build_pg    "${variant}"
	build_spock "${variant}"
}

# ---------------------------------------------------------------------------
# Node lifecycle
# ---------------------------------------------------------------------------

# Data checksums are requested explicitly on every cluster: PG18 turned
# them on by default in initdb, and pg_upgrade refuses to move between
# clusters that disagree.  Likewise the locale provider and encoding are
# pinned rather than inherited from the environment.
_do_initdb() {
	local prefix="$1" data="$2"
	"${prefix}/bin/initdb" -D "${data}" -U "${DBUSER}" \
		--encoding=UTF8 --locale=C --locale-provider=libc --data-checksums
}

# Everything a Spock node needs, written identically to every data
# directory so the only difference across the upgrade is the binaries.
write_node_conf() {
	local data="$1" port="$2"

	cat >>"${data}/postgresql.conf" <<-EOF
		# --- spock cluster-upgrade test rig ---
		listen_addresses = ''
		unix_socket_directories = '${SOCK_DIR}'
		port = ${port}
		max_connections = 200

		wal_level = logical
		track_commit_timestamp = on
		max_worker_processes = 32
		max_replication_slots = 32
		max_wal_senders = 32

		log_min_messages = 'log'
		log_statement = 'none'
		logging_collector = off

		shared_preload_libraries = 'spock'
		spock.conflict_resolution = 'last_update_wins'
		spock.exception_behaviour = 'discard'
		spock.save_resolutions = on

		# Auto-DDL is the pgEdge default and the harsher test: it means the
		# regression suite's DDL flows through spock's ProcessUtility hook
		# and its tables land in a replication set as they are created.
		spock.enable_ddl_replication = on
		spock.include_ddl_repset    = on
		spock.allow_ddl_from_functions = on
	EOF

	# Trust over the shared Unix socket.  There is no TCP listener, so this
	# stays local-only -- and dblink (which zodan drives) needs a
	# password-free path.
	cat >>"${data}/pg_hba.conf" <<-EOF
		local all all trust
		local replication all trust
	EOF
}

# Create and configure a node's data directory for a given variant.  An
# existing directory is wiped: a half-initialised cluster left by a failed
# run is worse than a slow rebuild.
init_node() {
	local node="$1" variant="$2"
	local prefix; prefix="$(prefix_for "${variant}")"
	local data;   data="$(data_for "${node}" "${variant}")"
	local port;   port="$(node_to_port "${node}")"

	if [ -d "${data}" ]; then
		log "${node}: [initdb] clearing existing data dir ${data}"
		rm -rf "${data}"
	fi
	run_phase "${node}-${variant}" initdb _do_initdb "${prefix}" "${data}"
	write_node_conf "${data}" "${port}"
}

_do_pg_ctl_start() {
	local prefix="$1" data="$2" server_log="$3"
	"${prefix}/bin/pg_ctl" -D "${data}" -l "${server_log}" -w -t 120 start
}

# Start a node under a variant and remember that this is now its variant,
# so psql_on() and friends pick the matching client binaries.
start_node() {
	local node="$1" variant="$2"
	local prefix; prefix="$(prefix_for "${variant}")"
	local data;   data="$(data_for "${node}" "${variant}")"
	set_node_variant "${node}" "${variant}"
	run_phase "${node}-${variant}" pg-start _do_pg_ctl_start \
		"${prefix}" "${data}" "${LOG_DIR}/${node}-${variant}-server.log"
}

stop_node() {
	local node="$1" variant="$2"
	local prefix; prefix="$(prefix_for "${variant}")"
	local data;   data="$(data_for "${node}" "${variant}")"
	if [ -f "${data}/postmaster.pid" ]; then
		log "${node}: pg_ctl stop (${variant})"
		"${prefix}/bin/pg_ctl" -D "${data}" -m fast -w -t 120 stop || true
	fi
}

# Stop whatever is running, for every node and every variant it has ever
# used.  Safe to call at any exit point: a node that never started, or a
# data directory that was never created, is simply skipped.
stop_everything() {
	local node variant
	for node in ${NODES}; do
		for variant in ${ALL_VARIANTS}; do
			[ -d "$(data_for "${node}" "${variant}")" ] || continue
			[ -x "$(prefix_for "${variant}")/bin/pg_ctl" ] || continue
			stop_node "${node}" "${variant}"
		done
	done
}

# Bound to EXIT so shutdown runs on normal completion and on every failure
# path, including the ERR trap (which exits before main()'s tail runs).
cleanup_nodes() {
	if [ "${KEEP_RUNNING}" -eq 0 ]; then
		stop_everything
	else
		log "--keep set: leaving nodes running. Sockets under ${SOCK_DIR}"
	fi
}
trap cleanup_nodes EXIT

# Ctrl-C or a `kill` on a long run must not strand postmasters holding this
# rig's ports and socket files.  stop_node is a no-op for a node that is not
# running, so the EXIT trap firing afterwards as well costs nothing.
trap 'cleanup_nodes; exit 130' INT
trap 'cleanup_nodes; exit 143' TERM

wait_for_ready() {
	local node="$1"
	local port;   port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_for "$(node_variant "${node}")")"
	local deadline=$(( $(date +%s) + 120 ))
	while [ "$(date +%s)" -lt "${deadline}" ]; do
		if "${prefix}/bin/pg_isready" -q \
				-h "${SOCK_DIR}" -p "${port}" -U "${DBUSER}" -d postgres; then
			log "${node}: pg_isready OK"
			return 0
		fi
		sleep 1
	done
	log "${node}: pg_isready did not become ready within 120s"
	return 1
}

# ---------------------------------------------------------------------------
# Database bootstrap
# ---------------------------------------------------------------------------

_do_createdb() {
	local prefix="$1" port="$2"
	"${prefix}/bin/createdb" -h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -O "${DBUSER}" "${DBNAME}"
}

create_db_for_node() {
	local node="$1"
	local port;    port="$(node_to_port "${node}")"
	local variant; variant="$(node_variant "${node}")"
	local prefix;  prefix="$(prefix_for "${variant}")"
	run_phase "${node}" createdb _do_createdb "${prefix}" "${port}"
}

# CREATE EXTENSION spock (+ dblink, which zodan's procedures run over) and,
# optionally, register the Spock node.  n2 deliberately gets no node: zodan
# add_node creates it, and refuses to run if one already exists.
setup_spock_node() {
	local node="$1" create_node="$2"
	local logf="${LOG_DIR}/${node}-spock-bootstrap.log"
	log "${node}: [spock-bootstrap] extensions (node_create=${create_node}) -> ${logf}"
	{
		psql_on "${node}" -c "CREATE EXTENSION IF NOT EXISTS spock;"
		psql_on "${node}" -c "CREATE EXTENSION IF NOT EXISTS dblink;"
		if [ "${create_node}" = "yes" ]; then
			psql_on "${node}" <<-SQL
				SELECT spock.node_create(
					node_name := '${node}',
					dsn       := '$(dsn_for_node "${node}")'
				);
			SQL
		fi
	} >>"${logf}" 2>&1
}

# ---------------------------------------------------------------------------
# Step 2: populate a complex database
# ---------------------------------------------------------------------------

# The core regression suite, run against an existing database.
#
# --use-existing is essential: without it pg_regress drops and recreates
# `regression`, which would take the Spock node with it.  The suite's own
# pass/fail is noise here (spock is preloaded, auto-DDL perturbs outputs);
# what matters is the ~250 relations it leaves behind.
_do_installcheck() {
	local node="$1"
	local variant; variant="$(node_variant "${node}")"
	local src;     src="$(pgsrc_for "${variant}")"
	local prefix;  prefix="$(prefix_for "${variant}")"
	local port;    port="$(node_to_port "${node}")"

	(
		cd "${src}/src/test/regress"
		PATH="${prefix}/bin:${PATH}" \
		PGHOST="${SOCK_DIR}" PGPORT="${port}" \
		PGUSER="${DBUSER}" PGDATABASE="${DBNAME}" \
		make -k installcheck-parallel \
			USE_INSTALLED=1 \
			EXTRA_REGRESS_OPTS="--use-existing --host=${SOCK_DIR} --port=${port} --user=${DBUSER}"
	)
}

# A small stand-in for the regression suite, for --skip-installcheck runs.
# It exercises the plumbing (a few object kinds, some rows, a matview) in
# seconds, and is explicitly not a substitute for the real thing.
_do_synthetic_schema() {
	local node="$1"
	psql_on "${node}" <<-'SQL'
		CREATE SCHEMA synth;
		CREATE TABLE synth.keyed (id int primary key, payload text, amount numeric);
		CREATE TABLE synth.keyless (tag text, n int);
		-- A partitioned table's unique constraint has to include the
		-- partition key, hence the composite primary key.
		CREATE TABLE synth.parted (id int, part int, PRIMARY KEY (id, part))
			PARTITION BY RANGE (part);
		CREATE TABLE synth.parted_lo PARTITION OF synth.parted FOR VALUES FROM (0) TO (100);
		CREATE TABLE synth.parted_hi PARTITION OF synth.parted FOR VALUES FROM (100) TO (200);
		INSERT INTO synth.keyed
			SELECT g, 'row ' || g, g * 1.5 FROM generate_series(1, 5000) g;
		INSERT INTO synth.keyless
			SELECT 'tag ' || (g % 17), g FROM generate_series(1, 5000) g;
		INSERT INTO synth.parted
			SELECT g, g % 200 FROM generate_series(1, 5000) g;
		CREATE VIEW synth.v_keyed AS SELECT id, amount FROM synth.keyed WHERE id % 7 = 0;
		CREATE MATERIALIZED VIEW synth.mv_keyed AS SELECT count(*) AS n FROM synth.keyed;
		CREATE SEQUENCE synth.s_keyed;
		ANALYZE;
	SQL
}

# Populate the target database, either for real or -- under
# --skip-installcheck -- with the synthetic stand-in.  Returns the regression
# suite's own status, which the caller is expected to tolerate; only the
# hang case (124) is fatal, and that is checked by the caller.
populate_complex_database() {
	local node="$1"

	if [ "${SKIP_INSTALLCHECK}" -eq 1 ]; then
		say "${node}: --skip-installcheck -- synthetic schema, NOT the real payload"
		log "${node}: synthetic schema (NOT a substitute for installcheck)"
		# Unlike the regression suite, the synthetic schema is expected to
		# apply cleanly -- a failure here is a bug in the rig, so propagate it.
		run_phase "${node}" synthetic-schema _do_synthetic_schema "${node}"
		return $?
	fi

	log "${node}: make installcheck-parallel (cap ${INSTALLCHECK_TIMEOUT}s)"
	local rc=0
	run_phase "${node}" installcheck \
		run_with_timeout "${INSTALLCHECK_TIMEOUT}" _do_installcheck "${node}" \
		|| rc=$?
	return "${rc}"
}

# Tables created before the Spock node existed -- or that auto-DDL declined
# to pick up -- are not in any replication set, so zodan would copy their
# structure but none of their rows.  Add every ordinary table explicitly:
# ones with a usable key go to `default`, the rest to
# `default_insert_only`, which is the same split spock's auto-DDL applies.
_do_repset_add_all() {
	local node="$1"
	psql_on "${node}" <<-'SQL'
		DO $rs$
		DECLARE
			r      record;
			added  int := 0;
			skipped int := 0;
			target text;
		BEGIN
			FOR r IN
				SELECT c.oid::regclass AS rel,
				       (c.relreplident = 'f'
				        OR EXISTS (SELECT 1 FROM pg_index i
				                   WHERE i.indrelid = c.oid
				                     AND (i.indisprimary OR i.indisreplident)))
				         AS has_key
				FROM pg_class c
				JOIN pg_namespace n ON n.oid = c.relnamespace
				WHERE c.relkind = 'r'
				  AND c.relpersistence = 'p'
				  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'spock')
				  AND n.nspname NOT LIKE 'pg\_%'
				ORDER BY 1
			LOOP
				target := CASE WHEN r.has_key THEN 'default'
				               ELSE 'default_insert_only' END;
				BEGIN
					PERFORM spock.repset_add_table(target, r.rel);
					added := added + 1;
				EXCEPTION WHEN others THEN
					-- Already a member, or a relation spock declines to
					-- replicate. Either way it is not fatal here.
					skipped := skipped + 1;
				END;
			END LOOP;
			RAISE NOTICE 'repset_add_all: added %, skipped %', added, skipped;
		END
		$rs$;
	SQL
	[ $? -eq 0 ] || return 1
	psql_on "${node}" -c \
		"SELECT set_name, count(*) AS tables
		 FROM spock.replication_set r
		 JOIN spock.replication_set_table t ON t.set_id = r.set_id
		 GROUP BY 1 ORDER BY 1;"
}

repset_add_all_tables() {
	local node="$1"
	run_phase "${node}" repset-add-all _do_repset_add_all "${node}"
}

# Make every C function that names a library outside $libdir refer to it as
# '$libdir/<name>' instead.
#
# The regression suite hard-codes the absolute path of the build tree that ran
# it (pg_regress substitutes @libdir@ with --dlpath).  That path is meaningless
# to any other install, so it breaks both things this rig does next: spock's
# structure sync restores the schema into a different major, and pg_upgrade
# refuses to run unless every probin loads in the new cluster.
#
# Only the directory part is replaced -- the base name matters.  The suite
# references three different libraries: regress (which PostgreSQL does not
# install, hence _do_install_regress_lib) plus autoinc and refint, which come
# from contrib/spi and are already in $libdir thanks to the contrib install.
# Forcing everything to '$libdir/regress' would look like it worked and then
# fail with 'could not find function "autoinc"'.  The platform extension is
# stripped so the name is canonical and PostgreSQL appends the local DLSUFFIX.
#
# pg_dump emits SET check_function_bodies = false, so a symbol a later major
# dropped does not break the restore -- it would only fail if called, and
# nothing in this rig calls them.
_do_normalise_regress_probin() {
	local node="$1"
	local port;   port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_for "$(node_variant "${node}")")"
	local db dbs

	dbs="$(psql_maint "${node}" -At -c \
		"SELECT datname FROM pg_database WHERE datallowconn ORDER BY 1")" \
		|| return 1

	for db in ${dbs}; do
		printf '%s: ' "${db}"
		PGPASSWORD="" "${prefix}/bin/psql" -X -v ON_ERROR_STOP=1 \
			-h "${SOCK_DIR}" -p "${port}" -U "${DBUSER}" -d "${db}" -c "
			UPDATE pg_proc
			   SET probin = '\$libdir/' ||
			                regexp_replace(
			                    regexp_replace(probin, '^.*/', ''),
			                    '\.(so|dylib|dll|sl)\$', '')
			 WHERE probin IS NOT NULL
			   AND probin NOT LIKE '\$libdir/%';" || return 1
	done
}

normalise_regress_probin() {
	local node="$1"
	run_phase "${node}" normalise-probin _do_normalise_regress_probin "${node}"
}

# Crash markers in a node's server log, printed to the terminal.  Called after
# the payload step: a backend that dies on an assertion takes the whole cluster
# through crash recovery, and the resulting wall of "the database system is not
# yet accepting connections" hides the one line that matters.
CRASH_PATTERN='PANIC|TRAP: |Assertion|terminated by signal|was terminated by'

report_crash_markers() {
	local node="$1"
	local slog="${LOG_DIR}/${node}-$(node_variant "${node}")-server.log"
	[ -f "${slog}" ] || return 0

	local hits
	hits="$(grep -c -E "${CRASH_PATTERN}" "${slog}" 2>/dev/null || true)"
	hits="${hits:-0}"
	[ "${hits}" -eq 0 ] && return 0

	say "${node}: ${hits} crash marker(s) in the server log:"
	grep -E "${CRASH_PATTERN}" "${slog}" 2>/dev/null | head -3 \
		| sed 's/^/    /' >&2 || true
	say "    full log: ${slog}"
	log "${node}: crash markers present in ${slog}"
	return 1
}

# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------
# "Is this node healthy?" is not a single query, so it is spelled out as a
# list of independent probes.  Each writes a PASS/FAIL line into the node's
# health log; the function's status is the AND of all of them.
#
#   check_node_health NODE EXPECTED_SPOCK_MAJOR EXPECTED_NODES EXPECTED_SUBS
#
# EXPECTED_SUBS of 0 additionally asserts that nothing replication-shaped
# exists at all -- no slots, no origins -- which is what step 2 means by
# "no spock replication active".

HEALTH_LOG=""

_health() {
	local verdict="$1" what="$2"
	printf '%-6s %s\n' "${verdict}" "${what}" >>"${HEALTH_LOG}"
	[ "${verdict}" = "PASS" ] || log "health: FAIL ${what}"
}

# A scalar query on a node, or the empty string if it errors out.  Never
# lets a psql failure escape, so one broken probe cannot abort the run.
_q() {
	local node="$1" sql="$2"
	psql_on "${node}" -At -c "${sql}" 2>/dev/null || echo ""
}

check_node_health() {
	local node="$1" want_spock_major="$2" want_nodes="$3" want_subs="$4"
	local bad=0 got

	HEALTH_LOG="${LOG_DIR}/${node}-health-$(date +%H%M%S).log"
	: >"${HEALTH_LOG}"
	log "${node}: health check -> ${HEALTH_LOG}"

	# 1. The server answers at all.  Everything below is meaningless
	#    otherwise, so bail out early rather than emit a wall of noise.
	got="$(_q "${node}" 'SELECT 1')"
	if [ "${got}" != "1" ]; then
		_health FAIL "${node}: server does not answer a trivial query"
		return 1
	fi
	_health PASS "${node}: server answers"

	# 2. The C library and the catalog agree, and both are the major we
	#    think we installed.  A mismatch here means a stale spock.so or a
	#    skipped ALTER EXTENSION, and would make every later check lie.
	got="$(_q "${node}" 'SELECT spock.spock_version()')"
	case "${got}" in
		"${want_spock_major}".*) _health PASS "${node}: spock library ${got}" ;;
		*) _health FAIL "${node}: spock library is '${got}', want ${want_spock_major}.x"; bad=1 ;;
	esac
	got="$(_q "${node}" "SELECT extversion FROM pg_extension WHERE extname='spock'")"
	case "${got}" in
		"${want_spock_major}".*) _health PASS "${node}: spock extversion ${got}" ;;
		*) _health FAIL "${node}: spock extversion is '${got}', want ${want_spock_major}.x"; bad=1 ;;
	esac

	# 3. This node knows who it is, and knows exactly the peers it should.
	got="$(_q "${node}" "SELECT node_name FROM spock.node n JOIN spock.local_node l ON l.node_id = n.node_id")"
	if [ "${got}" = "${node}" ]; then
		_health PASS "${node}: local_node is '${got}'"
	else
		_health FAIL "${node}: local_node is '${got}', want '${node}'"; bad=1
	fi
	got="$(_q "${node}" 'SELECT count(*) FROM spock.node')"
	if [ "${got}" = "${want_nodes}" ]; then
		_health PASS "${node}: spock.node has ${got} row(s)"
	else
		_health FAIL "${node}: spock.node has '${got}' row(s), want ${want_nodes}"; bad=1
	fi

	# 4. The manager background worker is attached to our database.  A node
	#    with no manager looks fine in the catalogs and replicates nothing.
	got="$(_q "${node}" \
		"SELECT count(*) FROM pg_stat_activity
		 WHERE application_name LIKE 'spock manager%'
		   AND datname = current_database()")"
	if [ "${got}" = "1" ]; then
		_health PASS "${node}: spock manager worker attached"
	else
		_health FAIL "${node}: ${got} spock manager worker(s) on this database, want 1"; bad=1
	fi

	# 5. Subscription count, and -- for the quiescent case -- that no slot
	#    or replication origin exists either.
	got="$(_q "${node}" 'SELECT count(*) FROM spock.subscription')"
	if [ "${got}" = "${want_subs}" ]; then
		_health PASS "${node}: ${got} subscription(s)"
	else
		_health FAIL "${node}: ${got} subscription(s), want ${want_subs}"; bad=1
	fi
	if [ "${want_subs}" = "0" ]; then
		got="$(_q "${node}" "SELECT count(*) FROM pg_replication_slots")"
		if [ "${got}" = "0" ]; then
			_health PASS "${node}: no replication slots (replication really is inactive)"
		else
			_health FAIL "${node}: ${got} replication slot(s) on a node with no subscriptions"; bad=1
		fi
		got="$(_q "${node}" "SELECT count(*) FROM pg_replication_origin")"
		if [ "${got}" = "0" ]; then
			_health PASS "${node}: no replication origins"
		else
			_health FAIL "${node}: ${got} replication origin(s) on a node with no subscriptions"; bad=1
		fi
	fi

	# 6. Every subscription that does exist is replicating.
	got="$(_q "${node}" \
		"SELECT count(*) FROM spock.sub_show_status()
		 WHERE status IS DISTINCT FROM 'replicating'")"
	if [ "${got}" = "0" ]; then
		_health PASS "${node}: all subscriptions report status='replicating'"
	else
		_health FAIL "${node}: ${got} subscription(s) not in 'replicating'"; bad=1
	fi

	# 7. Nothing has been thrown into the exception log -- an apply error
	#    that `exception_behaviour = discard` swallowed still lands here.
	got="$(_q "${node}" 'SELECT count(*) FROM spock.exception_log')"
	if [ "${got}" = "0" ]; then
		_health PASS "${node}: spock.exception_log empty"
	else
		_health FAIL "${node}: spock.exception_log has ${got} row(s)"; bad=1
		psql_on "${node}" -c \
			"SELECT relname, operation, error_message FROM spock.exception_log LIMIT 20;" \
			>>"${HEALTH_LOG}" 2>&1 || true
	fi

	# 8. WAL still advances and spock.sync_event() works.  On a node with no
	#    subscriber nobody consumes the event, but emitting it exercises the
	#    write path and proves the extension is not wedged.
	local lsn_before lsn_after
	lsn_before="$(_q "${node}" 'SELECT pg_current_wal_lsn()')"
	got="$(_q "${node}" 'SELECT spock.sync_event()')"
	lsn_after="$(_q "${node}" 'SELECT pg_current_wal_lsn()')"
	if [ -n "${got}" ] && [ -n "${lsn_before}" ] && [ "${lsn_after}" != "${lsn_before}" ]; then
		_health PASS "${node}: spock.sync_event() emitted at ${got}"
	else
		_health FAIL "${node}: spock.sync_event() did not emit (got '${got}', wal ${lsn_before} -> ${lsn_after})"; bad=1
	fi

	# 9. A DDL + DML round trip succeeds.  With auto-DDL on, this is the
	#    cheapest proof that the ProcessUtility hook and the replication-set
	#    bookkeeping still work after whatever we just did to the node.
	#
	#    The scratch schema is named per node: this DDL is itself replicated,
	#    so a shared name would have n1's CREATE TABLE arrive on n2 where the
	#    same table already exists, land in the exception log, and fail probe
	#    7 on the next health check.  The signature snapshots skip
	#    spock_health%, so the probe never shows up in a comparison.
	if psql_on "${node}" >>"${HEALTH_LOG}" 2>&1 <<-SQL
			CREATE SCHEMA IF NOT EXISTS spock_health_${node};
			DROP TABLE IF EXISTS spock_health_${node}.probe;
			CREATE TABLE spock_health_${node}.probe (id int primary key, v text);
			INSERT INTO spock_health_${node}.probe VALUES (1, 'a'), (2, 'b');
			UPDATE spock_health_${node}.probe SET v = 'c' WHERE id = 1;
			DELETE FROM spock_health_${node}.probe WHERE id = 2;
		SQL
	then
		_health PASS "${node}: DDL + DML probe succeeded"
	else
		_health FAIL "${node}: DDL + DML probe failed (see ${HEALTH_LOG})"; bad=1
	fi

	# 10. No crash in the server log.  Only unambiguous markers are matched,
	#     because spock legitimately logs FATAL when an apply worker exits.
	#     On a cassert build an assertion failure is exactly the sort of
	#     thing this rig exists to catch.
	local slog="${LOG_DIR}/${node}-$(node_variant "${node}")-server.log"
	if [ -f "${slog}" ]; then
		local hits
		hits="$(grep -c -E "${CRASH_PATTERN}" "${slog}" 2>/dev/null || true)"
		hits="${hits:-0}"
		if [ "${hits}" -eq 0 ]; then
			_health PASS "${node}: no crash markers in the server log"
		else
			_health FAIL "${node}: ${hits} crash marker(s) in ${slog}"; bad=1
			grep -n -E "${CRASH_PATTERN}" "${slog}" 2>/dev/null \
				| head -20 >>"${HEALTH_LOG}" || true
		fi
	else
		_health PASS "${node}: no server log to scan (${slog} absent)"
	fi

	if [ "${bad}" -eq 0 ]; then
		say "${node}: health OK  (${HEALTH_LOG})"
	else
		say "${node}: health FAILED  (${HEALTH_LOG})"
	fi
	return "${bad}"
}

# ---------------------------------------------------------------------------
# Database signatures
# ---------------------------------------------------------------------------
# Two text files per snapshot, diffed rather than hashed, because the diff
# names the relation that went missing instead of just saying "different".
#
#   <tag>-relations.txt  every user relation, with its kind
#   <tag>-rowcounts.txt  count(*) per ordinary table
#
# ALL_TABLES scope is for comparing one node with itself across the
# upgrade; REPSET scope restricts to tables spock was actually told to
# replicate, which is the only fair basis for comparing two nodes.

# SQL fragment restricting a relation to those spock was told to replicate.
# Empty for the ALL_TABLES scope.
_repset_filter() {
	if [ "$1" = "repset" ]; then
		printf '%s' "AND c.oid IN (SELECT set_reloid FROM spock.replication_set_table)"
	fi
}

# Shared WHERE clause for both snapshots.  Extension-owned relations are
# excluded via pg_depend: the spock schema changes shape between 5.x and 6.x
# and dblink brings its own objects, neither of which says anything about
# whether the *user's* database survived.  spock_health_* are the DDL probe's
# per-node scratch schemas.
_signature_where() {
	local scope="$1" alias_ns="$2"
	cat <<-SQL
		  AND ${alias_ns}.nspname NOT IN ('pg_catalog','information_schema','spock')
		  AND ${alias_ns}.nspname NOT LIKE 'pg\\_%'
		  AND ${alias_ns}.nspname NOT LIKE 'spock\\_health%'
		  AND NOT EXISTS (SELECT 1 FROM pg_depend d
		                  WHERE d.objid = c.oid AND d.deptype = 'e')
		  $(_repset_filter "${scope}")
	SQL
}

# The relation inventory of a database: one "schema.name kind" line per user
# relation.  relkind is "char", which has no unambiguous || operator, hence
# the explicit cast.
capture_relations() {
	local node="$1" tag="$2" scope="$3"
	local out="${REPORT_DIR}/${tag}-relations.txt"
	local sqlf="${REPORT_DIR}/${tag}-relations.sql"

	cat >"${sqlf}" <<-SQL
		\pset tuples_only on
		\pset format unaligned
		SELECT ns.nspname || '.' || c.relname || ' ' || c.relkind::text
		FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
		WHERE c.relkind IN ('r','p','m','S','v','f')
		$(_signature_where "${scope}" ns)
		ORDER BY 1;
	SQL

	if ! psql_on "${node}" -q -f "${sqlf}" >"${out}" 2>>"${MAIN_LOG}"; then
		log "capture_relations(${tag}): psql failed"
		: >"${out}"
	fi
}

# count(*) for every ordinary, permanent table -- optionally only those in a
# replication set.
#
# One psql call per table, deliberately.  A single server-side loop would need
# a helper function, and CREATE FUNCTION is DDL: with auto-DDL on, taking a
# measurement would enqueue itself for replication and could land in the
# subscriber's exception log, which the health check reads.  A measurement must
# not perturb what it measures.  Per-table calls also isolate failures: a table
# that cannot be read (an ON SELECT rule, a broken leftover from a regression
# test) is recorded as -1 instead of truncating the snapshot, which would
# otherwise compare as "different" for the wrong reason.
capture_rowcounts() {
	local node="$1" tag="$2" scope="$3"
	local out="${REPORT_DIR}/${tag}-rowcounts.txt"
	local sqlf="${REPORT_DIR}/${tag}-rowcounts.sql"

	cat >"${sqlf}" <<-SQL
		\pset tuples_only on
		\pset format unaligned
		SELECT quote_ident(ns.nspname) || '.' || quote_ident(c.relname)
		FROM pg_class c JOIN pg_namespace ns ON ns.oid = c.relnamespace
		WHERE c.relkind = 'r'
		  AND c.relpersistence = 'p'
		$(_signature_where "${scope}" ns)
		ORDER BY 1;
	SQL

	local tables
	if ! tables="$(psql_on "${node}" -q -f "${sqlf}" 2>>"${MAIN_LOG}")"; then
		log "capture_rowcounts(${tag}): could not list tables"
		: >"${out}"
		return 0
	fi

	: >"${out}"
	local t n
	for t in ${tables}; do
		n="$(psql_on "${node}" -At -c "SELECT count(*) FROM ${t}" 2>/dev/null)" \
			|| n=-1
		[ -n "${n}" ] || n=-1
		printf '%s=%s\n' "${t}" "${n}" >>"${out}"
	done
}

# Take both snapshots under one tag and echo the relation count, so callers
# can assert the payload is non-trivial before drawing conclusions from it.
capture_signature() {
	local node="$1" tag="$2" scope="$3"
	capture_relations "${node}" "${tag}" "${scope}"
	capture_rowcounts "${node}" "${tag}" "${scope}"
	local rels rows
	rels="$(wc -l <"${REPORT_DIR}/${tag}-relations.txt" | tr -d ' ')"
	rows="$(wc -l <"${REPORT_DIR}/${tag}-rowcounts.txt" | tr -d ' ')"
	log "signature ${tag}: ${rels} relations, ${rows} counted tables (scope=${scope})"
	printf '%s' "${rels}"
}

# Diff two snapshots.  Returns 0 when identical; on a difference the diff
# is written where the summary can point at it.
compare_signatures() {
	local tag_a="$1" tag_b="$2" what="$3"
	local diff_out="${REPORT_DIR}/diff-${tag_a}-vs-${tag_b}.txt"
	local rc=0
	{
		printf '=== relations: %s vs %s ===\n' "${tag_a}" "${tag_b}"
		diff -u "${REPORT_DIR}/${tag_a}-relations.txt" \
		        "${REPORT_DIR}/${tag_b}-relations.txt" || rc=1
		printf '\n=== row counts: %s vs %s ===\n' "${tag_a}" "${tag_b}"
		diff -u "${REPORT_DIR}/${tag_a}-rowcounts.txt" \
		        "${REPORT_DIR}/${tag_b}-rowcounts.txt" || rc=1
	} >"${diff_out}" 2>&1

	if [ "${rc}" -eq 0 ]; then
		log "${what}: identical (${tag_a} == ${tag_b})"
		say "${what}: identical"
	else
		log "${what}: DIFFERS -- see ${diff_out}"
		say "${what}: DIFFERS  (see ${diff_out})"
	fi
	return "${rc}"
}

# ---------------------------------------------------------------------------
# Step 3: join a second node with zodan
# ---------------------------------------------------------------------------

# zodan refuses to add a node whose cluster is missing any role that exists
# on the source.  The regression suite creates and drops a lot of roles and
# does not always finish tidily, so copy whatever is left over.  Applied
# without ON_ERROR_STOP: roles that already exist are expected to fail.
_do_sync_roles() {
	local src_node="$1" dst_node="$2"
	local ddl
	ddl="$(psql_on "${src_node}" -At -c "
		SELECT format('CREATE ROLE %I%s;', rolname,
		              CASE WHEN rolsuper     THEN ' SUPERUSER'   ELSE '' END ||
		              CASE WHEN rolcreatedb  THEN ' CREATEDB'    ELSE '' END ||
		              CASE WHEN rolcreaterole THEN ' CREATEROLE' ELSE '' END ||
		              CASE WHEN rolcanlogin  THEN ' LOGIN'       ELSE '' END ||
		              CASE WHEN rolreplication THEN ' REPLICATION' ELSE '' END)
		FROM pg_roles
		WHERE rolname NOT LIKE 'pg\\_%'
		  AND rolname <> '${DBUSER}'
		ORDER BY rolname;")"

	if [ -z "${ddl}" ]; then
		echo "no extra roles on ${src_node}"
		return 0
	fi
	printf '%s\n' "${ddl}"

	local port;    port="$(node_to_port "${dst_node}")"
	local prefix;  prefix="$(prefix_for "$(node_variant "${dst_node}")")"
	printf '%s\n' "${ddl}" | PGPASSWORD="" "${prefix}/bin/psql" \
		-X -h "${SOCK_DIR}" -p "${port}" -U "${DBUSER}" -d postgres 2>&1 || true
}

sync_roles() {
	run_phase "$2" sync-roles _do_sync_roles "$1" "$2"
}

# Load the zodan procedures and run add_node from the new node -- zodan is
# explicit that add_node must be called on the node being added.
_do_zodan_add_node() {
	local src_node="$1" new_node="$2"
	local zodan="${SPOCK_SRC}/samples/Z0DAN/zodan.sql"
	[ -f "${zodan}" ] || { echo "zodan.sql not found at ${zodan}"; return 1; }

	echo "----- loading $(basename "${zodan}") on ${new_node} -----"
	psql_on "${new_node}" -f "${zodan}" || return 1

	echo "----- CALL spock.add_node(${src_node} -> ${new_node}) -----"
	psql_on "${new_node}" -c "
		CALL spock.add_node(
			src_node_name := '${src_node}',
			src_dsn       := '$(dsn_for_node "${src_node}")',
			new_node_name := '${new_node}',
			new_node_dsn  := '$(dsn_for_node "${new_node}")',
			verb          := true
		);"
}

# Wall-clock capped: zodan's later phases poll for replication lag and sync
# events in loops whose bounds are hard-coded inside zodan.sql, and on a
# regression-sized database the call has been observed to sit there for a
# quarter of an hour with no progress.  A rig that hangs teaches nothing, so
# treat an overrun as its own reportable outcome.
zodan_add_node() {
	local src_node="$1" new_node="$2"
	local rc=0
	run_phase "${new_node}" zodan-add-node \
		run_with_timeout "${ZODAN_TIMEOUT}" \
		_do_zodan_add_node "${src_node}" "${new_node}" || rc=$?
	if [ "${rc}" -eq 124 ]; then
		say "${new_node}: zodan add_node still running after ${ZODAN_TIMEOUT}s -- gave up"
		log "${new_node}: zodan add_node exceeded ${ZODAN_TIMEOUT}s"
	fi
	return "${rc}"
}

# ---------------------------------------------------------------------------
# Waiting for the mesh
# ---------------------------------------------------------------------------

# Poll every node until no subscription reports anything other than
# 'replicating'.  A psql failure counts as "not there yet" rather than as a
# hard error: a node restarting mid-poll is normal.
wait_for_mesh_replicating() {
	local timeout="$1"
	local deadline node not_replicating n
	deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -lt "${deadline}" ]; do
		not_replicating=0
		for node in ${NODES}; do
			n="$(psql_on "${node}" -At -c \
				"SELECT count(*) FROM spock.sub_show_status()
				 WHERE status IS DISTINCT FROM 'replicating';" \
				2>/dev/null)" || n=999
			[ -n "${n}" ] || n=999
			if [ "${n}" -ne 0 ]; then
				not_replicating=1
				break
			fi
		done
		if [ "${not_replicating}" -eq 0 ]; then
			log "every subscription reached status='replicating' within ${timeout}s"
			return 0
		fi
		sleep 1
	done
	log "timed out after ${timeout}s waiting for subscriptions to reach 'replicating'"
	return 1
}

# Total number of subscriptions across the cluster, so "nothing reached
# replicating" can be told apart from "there was nothing to reach it".
count_all_subscriptions() {
	local node total=0 n
	for node in ${NODES}; do
		n="$(_q "${node}" 'SELECT count(*) FROM spock.subscription')"
		[ -n "${n}" ] || n=0
		total=$(( total + n ))
	done
	printf '%s' "${total}"
}

print_subscription_state() {
	local label="$1" node
	for node in ${NODES}; do
		{
			printf '\n--- subscription state (%s) on %s ---\n' "${label}" "${node}"
			psql_on "${node}" -P null='(null)' \
				-c "SELECT sub_name, sub_enabled FROM spock.subscription
				    ORDER BY sub_name;" \
				-c "SELECT subscription_name, status, provider_node, slot_name
				    FROM spock.sub_show_status()
				    ORDER BY subscription_name;" \
				-c "SELECT slot_name, plugin, active, confirmed_flush_lsn
				    FROM pg_replication_slots ORDER BY slot_name;"
		} >>"${LOG_DIR}/${node}-subscriptions.log" 2>&1 || true
	done
}

print_subscription_state_to_screen() {
	local node
	for node in ${NODES}; do
		printf '\n=== %s (%s) ===\n' "${node}" "$(node_variant "${node}")" >&2
		if ! psql_on "${node}" -At -c 'SELECT 1' >/dev/null 2>&1; then
			printf '  (not reachable -- server stopped or socket gone)\n' >&2
			continue
		fi
		psql_on "${node}" -P null='(null)' \
			-c "SELECT sub_name, sub_enabled FROM spock.subscription
			    ORDER BY sub_name;" \
			-c "SELECT subscription_name, status, provider_node
			    FROM spock.sub_show_status()
			    ORDER BY subscription_name;" \
			1>&2 2>&1 || true
	done
	printf '\n' >&2
}

# Everything needed to explain a subscription that will not come up, in one
# file.  Worth having as its own step because a spock apply worker that cannot
# start does not say why: the server log gets "apply worker [N] ... exiting
# with error" every five seconds and no error message at all, so the catalogs
# are the only evidence available.
dump_replication_diagnostics() {
	local label="$1" node
	local out="${REPORT_DIR}/diagnostics-${label}.txt"
	: >"${out}"
	for node in ${NODES}; do
		{
			printf '\n==================== %s (%s) ====================\n' \
				"${node}" "$(node_variant "${node}")"
			psql_on "${node}" -P null='(null)' \
				-c "SELECT * FROM spock.sub_show_status();" \
				-c "SELECT sub_name, sub_enabled, sub_slot_name, sub_origin,
				           sub_target, sub_replication_sets
				    FROM spock.subscription ORDER BY sub_name;" \
				-c "SELECT * FROM spock.local_sync_status ORDER BY sync_nspname, sync_relname;" \
				-c "SELECT slot_name, plugin, active, restart_lsn, confirmed_flush_lsn
				    FROM pg_replication_slots ORDER BY slot_name;" \
				-c "SELECT * FROM pg_replication_origin_status ORDER BY external_id;" \
				-c "SELECT roname FROM pg_replication_origin ORDER BY roname;" \
				-c "SELECT count(*) AS exceptions FROM spock.exception_log;" \
				2>&1 || printf '  (node not reachable)\n'

			printf '\n--- last 60 lines of the server log ---\n'
			tail -60 "${LOG_DIR}/${node}-$(node_variant "${node}")-server.log" 2>/dev/null \
				|| printf '  (no server log)\n'
		} >>"${out}" 2>&1
	done
	log "replication diagnostics (${label}) -> ${out}"
	say "replication diagnostics written to ${out}"
}

print_connection_params() {
	local node port
	printf '\n=== Connection parameters ===\n' >&2
	if [ "${KEEP_RUNNING}" -eq 1 ]; then
		printf '(servers are left running -- you can attach right now)\n' >&2
	else
		printf '(servers stop on exit; re-run with --keep to keep them up)\n' >&2
	fi
	for node in ${NODES}; do
		port="$(node_to_port "${node}")"
		printf '\n  %s  (%s)\n' "${node}" "$(node_variant "${node}")" >&2
		printf '    psql = %s/bin/psql -h %s -p %s -U %s -d %s\n' \
			"$(prefix_for "$(node_variant "${node}")")" \
			"${SOCK_DIR}" "${port}" "${DBUSER}" "${DBNAME}" >&2
	done
	printf '\n' >&2
}

# ---------------------------------------------------------------------------
# Step 4: pg_upgrade
# ---------------------------------------------------------------------------

# Strip objects from a node's databases that a *newer* PostgreSQL major cannot
# accept, using PostgreSQL::Test::AdjustUpgrade -- the same module the core
# cross-version upgrade test (src/bin/pg_upgrade/t/002_pg_upgrade.pl) relies on.
# The module encodes which objects each old major leaves behind that a newer one
# chokes on, so it has to be read from the *target* major's source tree.
#
# Needed twice, for two different consumers:
#
#   before step 3   the regression database contains things the joining node's
#                   major has dropped (PG17 removed get_columns_length(oid[]),
#                   for instance).  spock's structure sync pg_restores that
#                   schema into the joining node and treats a non-zero
#                   pg_restore exit as failure, so the join stalls and zodan
#                   eventually times out waiting for its sync event.
#   before step 4   the same, for pg_upgrade into the new major.
#
# The other adaptation 002_pg_upgrade.pl makes -- repointing pg_proc.probin --
# happens in normalise_regress_probin(); it is repeated below in case a later
# step reintroduced a build-tree path.
_do_adapt_for_target() {
	local node="$1" target_variant="$2"
	local old_variant; old_variant="$(node_variant "${node}")"
	local old_major;   old_major="$(variant_to_major "${old_variant}")"
	local new_src;     new_src="$(pgsrc_for "${target_variant}")"

	echo "----- re-normalising pg_proc.probin -----"
	_do_normalise_regress_probin "${node}" || return 1

	echo "----- AdjustUpgrade fixups: PG${old_major} -> $(variant_to_major "${target_variant}") -----"
	local dbnames adapt_sql="${LOG_DIR}/${node}-adapt-for-${target_variant}.sql"
	dbnames="$(psql_maint "${node}" -At -c \
		"SELECT string_agg(datname, ' ') FROM pg_database WHERE datallowconn")" \
		|| return 1

	NEW_PG_SRC="${new_src}" OLD_PG_MAJOR="${old_major}" OLD_DBNAMES="${dbnames}" \
	perl -e '
		use strict; use warnings;
		use lib "$ENV{NEW_PG_SRC}/src/test/perl";
		use PostgreSQL::Version;
		use PostgreSQL::Test::AdjustUpgrade qw(adjust_database_contents);
		my $old = PostgreSQL::Version->new($ENV{OLD_PG_MAJOR});
		my %dbnames = map { $_ => 1 } split /\s+/, $ENV{OLD_DBNAMES};
		my $cmds = adjust_database_contents($old, %dbnames);
		for my $db (sort keys %$cmds) {
			printf "\\connect \"%s\"\n", $db;
			for my $c (@{ $cmds->{$db} }) {
				$c =~ s/;\s*$//;
				print "$c;\n";
			}
		}
	' >"${adapt_sql}" || return 1

	if [ ! -s "${adapt_sql}" ]; then
		echo "  (nothing to adjust)"
		return 0
	fi

	cat "${adapt_sql}"

	# Applied without ON_ERROR_STOP.  AdjustUpgrade names every object the
	# core regression suite is *expected* to leave behind, but this rig runs
	# that suite with spock preloaded and tolerates its diffs, so a test that
	# bailed early may simply not have created one -- and under
	# --skip-installcheck none of them exist at all.  A fixup that was
	# genuinely required and did not apply still surfaces loudly: pg_upgrade
	# is the next step and it will say exactly what it choked on.
	local errors
	errors="$(psql_maint_lax "${node}" -f "${adapt_sql}" 2>&1 | tee /dev/stderr \
		| grep -c '^psql:.*ERROR:' || true)"
	echo "----- AdjustUpgrade: ${errors:-0} statement(s) did not apply -----"
	return 0
}

adapt_for_target() {
	local node="$1" target_variant="$2"
	run_phase "${node}" "adapt-for-${target_variant}" \
		_do_adapt_for_target "${node}" "${target_variant}"
}

# Turn off DDL replication before the upgrade window, as
# docs/upgrading_spock.md prescribes.  Deliberately does NOT disable the
# subscriptions:
#
# From PostgreSQL 17 the old cluster's logical slots are migrated by pg_upgrade,
# which refuses to proceed while a slot still has pending decodable changes.
# Leaving the subscriptions enabled and draining them (see drain_cluster) is the
# simplest way to guarantee that.  Disabling would also be acceptable if it let
# the apply worker finish first -- what is not acceptable is
# sub_disable(immediate := true), which stops the worker mid-stream and strands
# whatever it had not yet consumed.
#
# spock itself stays in shared_preload_libraries throughout: spock.c returns
# early under IsBinaryUpgrade, so pg_upgrade's own server starts register no
# workers, while leaving it loaded keeps the extension's functions resolvable
# as pg_upgrade restores the dump.
_do_quiesce_node() {
	local node="$1"
	psql_on "${node}" -c "ALTER SYSTEM SET spock.enable_ddl_replication = off;" && \
	psql_on "${node}" -c "SELECT pg_reload_conf();" && \
	psql_on "${node}" -c \
		"SELECT slot_name, active, confirmed_flush_lsn
		 FROM pg_replication_slots ORDER BY 1;"
}

quiesce_node() {
	local node="$1"
	run_phase "${node}" upgrade-quiesce _do_quiesce_node "${node}"
}

# Re-enable DDL replication once every node is up on the new version --
# docs/upgrading_spock.md, final step.
_do_unquiesce_node() {
	local node="$1"
	psql_on "${node}" -c "ALTER SYSTEM SET spock.enable_ddl_replication = on;" && \
	psql_on "${node}" -c "SELECT pg_reload_conf();"
}

unquiesce_node() {
	local node="$1"
	run_phase "${node}" post-upgrade-unquiesce _do_unquiesce_node "${node}"
}

# Enable any subscription that came out of the upgrade disabled.  Normally a
# no-op -- the whole point of not disabling them beforehand -- but the
# fallback path in main() drops and recreates replication state on a node
# whose slots blocked the upgrade, and a stray disabled subscription would
# otherwise be misread as "replication is broken".
_do_enable_subscriptions() {
	local node="$1"
	psql_on "${node}" -c "
		DO \$e\$
		DECLARE s record;
		BEGIN
			FOR s IN SELECT sub_name FROM spock.subscription WHERE NOT sub_enabled
			LOOP
				RAISE NOTICE 'enabling %', s.sub_name;
				PERFORM spock.sub_enable(s.sub_name, true);
			END LOOP;
		END
		\$e\$;"
}

enable_subscriptions() {
	local node="$1"
	run_phase "${node}" post-upgrade-enable-subs _do_enable_subscriptions "${node}"
}

# Drive a sync event from every node to every other and wait for it to be
# applied.  This is the authoritative "everything committed has been applied
# and confirmed" barrier, and it is what lets each provider's slot advance
# before the cluster is shut down for the upgrade.
#
# Failures are logged, not fatal: a stalled edge is exactly the condition the
# pg_upgrade slot check will then report on, and reporting it there is more
# informative than dying here.
_do_drain_cluster() {
	local provider subscriber lsn
	for provider in ${NODES}; do
		lsn="$(psql_on "${provider}" -At -c 'SELECT spock.sync_event();' 2>/dev/null)" \
			|| lsn=
		if [ -z "${lsn}" ]; then
			echo "${provider}: spock.sync_event() produced nothing"
			continue
		fi
		echo "${provider}: sync_event at ${lsn}"
		for subscriber in ${NODES}; do
			[ "${subscriber}" = "${provider}" ] && continue
			if psql_on "${subscriber}" -c "
					DO \$w\$
					DECLARE r bool;
					BEGIN
						CALL spock.wait_for_sync_event(
							r, '${provider}'::name, '${lsn}'::pg_lsn, ${DRAIN_TIMEOUT});
						IF NOT r THEN
							RAISE EXCEPTION
								'sync_event from ${provider} not applied on ${subscriber} within ${DRAIN_TIMEOUT}s';
						END IF;
					END
					\$w\$;"; then
				echo "  ${provider} -> ${subscriber}: drained"
			else
				echo "  ${provider} -> ${subscriber}: NOT drained within ${DRAIN_TIMEOUT}s"
			fi
		done
	done
	return 0
}

drain_cluster() {
	run_phase cluster upgrade-drain _do_drain_cluster
}

# Last resort when pg_upgrade --check rejects the cluster because of the
# subscriptions themselves: drop them, and any slot or origin they left
# behind.  Doing this is itself the finding, so it is logged loudly.
_do_drop_replication_state() {
	local node="$1"
	psql_on "${node}" -c "
		DO \$d\$
		DECLARE s record;
		BEGIN
			FOR s IN SELECT sub_name FROM spock.subscription LOOP
				RAISE NOTICE 'dropping subscription %', s.sub_name;
				PERFORM spock.sub_drop(s.sub_name, true);
			END LOOP;
		END
		\$d\$;" && \
	psql_on "${node}" -c "
		DO \$d\$
		DECLARE r record;
		BEGIN
			FOR r IN SELECT slot_name FROM pg_replication_slots LOOP
				RAISE NOTICE 'dropping slot %', r.slot_name;
				PERFORM pg_drop_replication_slot(r.slot_name);
			END LOOP;
			FOR r IN SELECT roname FROM pg_replication_origin LOOP
				RAISE NOTICE 'dropping origin %', r.roname;
				PERFORM pg_replication_origin_drop(r.roname);
			END LOOP;
		END
		\$d\$;"
}

drop_replication_state() {
	local node="$1" why="$2"
	say "${node}: dropping subscriptions/slots/origins (${why})"
	run_phase "${node}" drop-replication _do_drop_replication_state "${node}"
}

_do_pg_upgrade() {
	local node="$1" mode="$2"      # mode: --check or empty for the real run
	local old_variant; old_variant="$(node_to_old_variant "${node}")"
	local old_data;    old_data="$(data_for "${node}" "${old_variant}")"
	local new_data;    new_data="$(data_for "${node}" "${NEW_VARIANT}")"
	local old_bin;     old_bin="$(prefix_for "${old_variant}")/bin"
	local new_bin;     new_bin="$(prefix_for "${NEW_VARIANT}")/bin"
	local stage_port;  stage_port="$(node_to_stage_port "${node}")"

	# pg_upgrade scatters its own log files into $PWD; keep that out of the
	# source tree, and out of the caller's working directory.
	mkdir -p "${LOG_DIR}/pg_upgrade-${node}"
	(
		cd "${LOG_DIR}/pg_upgrade-${node}"

		# Copy mode (the default) rather than --link: a failed upgrade must
		# leave the old cluster intact and startable for inspection, and this
		# rig has to be able to restart it to drop replication state.
		# shellcheck disable=SC2086  # $mode is one optional flag
		"${new_bin}/pg_upgrade" ${mode} \
			--no-sync \
			-d "${old_data}" -D "${new_data}" \
			-b "${old_bin}"  -B "${new_bin}" \
			-p "$(node_to_port "${node}")" -P "${stage_port}" \
			-U "${DBUSER}" \
			-s "${SOCK_DIR}"
	)
}

# Bring up the new-major data directory for a node.  Done fresh every time,
# because pg_upgrade requires an empty new cluster and a previous attempt
# may have half-populated it.
prepare_new_datadir() {
	local node="$1"
	init_node "${node}" "${NEW_VARIANT}"
}

# ---------------------------------------------------------------------------
# Step 4b: rebuild the mesh on the upgraded cluster
# ---------------------------------------------------------------------------

# Re-bootstrap Spock on an upgraded node: bring the extension's catalog
# version in line with the 6.x library, then register the node again.
# synchronize_structure/synchronize_data are both false in create_edges()
# below -- pg_upgrade already carried the data across, and a resync of a
# regression-sized database would test something else entirely.
_do_rebuild_node() {
	local node="$1"
	psql_on "${node}" -c "ALTER EXTENSION spock UPDATE;" && \
	psql_on "${node}" -c \
		"SELECT extversion FROM pg_extension WHERE extname = 'spock';" && \
	psql_on "${node}" -c "CREATE EXTENSION IF NOT EXISTS dblink;" \
		|| return 1

	local have
	have="$(psql_on "${node}" -At -c 'SELECT count(*) FROM spock.local_node')" \
		|| return 1
	if [ "${have}" = "0" ]; then
		echo "re-registering spock node ${node}"
		psql_on "${node}" -c "
			SELECT spock.node_create(
				node_name := '${node}',
				dsn       := '$(dsn_for_node "${node}")');"
	else
		echo "spock node already registered on ${node}"
	fi
}

# ALTER EXTENSION alone, for the survival check: the catalog version has to
# catch up with the 6.x library before spock.sub_show_status() and friends
# can be trusted, and spock's manager worker drives the same update on
# connect, so this may legitimately be a no-op.
_do_extension_update() {
	local node="$1"
	psql_on "${node}" -c "ALTER EXTENSION spock UPDATE;" && \
	psql_on "${node}" -c \
		"SELECT extversion FROM pg_extension WHERE extname = 'spock';"
}

extension_update() {
	local node="$1"
	run_phase "${node}" post-upgrade-extension-update _do_extension_update "${node}"
}

rebuild_node() {
	local node="$1"
	run_phase "${node}" rebuild-node _do_rebuild_node "${node}"
}

# Recreate the full set of edges: every node subscribes to every other.
_do_create_edges() {
	local subscriber provider subname
	for subscriber in ${NODES}; do
		for provider in ${NODES}; do
			[ "${provider}" = "${subscriber}" ] && continue
			subname="sub_${provider}_${subscriber}"
			echo "----- ${subscriber}: sub_create ${subname} -----"
			psql_on "${subscriber}" -c "
				SELECT spock.sub_create(
					subscription_name     := '${subname}',
					provider_dsn          := '$(dsn_for_node "${provider}")',
					synchronize_structure := false,
					synchronize_data      := false,
					forward_origins       := '{}'::text[],
					enabled               := true);" || return 1
		done
	done
}

create_edges() {
	run_phase cluster rebuild-subscriptions _do_create_edges
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# Verdict accumulators, resolved into an exit code at the end.
VERDICT_UPGRADE_DATA=PASS       # did the database survive pg_upgrade?
VERDICT_SURVIVAL=PASS           # did the subscriptions survive it?
VERDICT_REBUILD=SKIP            # could the mesh be rebuilt?
VERDICT_NODE_DATA=PASS          # do the nodes agree after zodan?

main() {
	# A previous --keep run leaves its servers up, and they hold the same
	# ports and socket files this run wants.  Without this the run dies at the
	# first pg_ctl start with a bare "lock file already exists", which points
	# at the symptom rather than the cause.  Only ever touches data
	# directories under BASE_DIR, so it cannot disturb anything else.
	log "stopping any servers left over from a previous run"
	stop_everything

	# --- Build everything up front -----------------------------------------
	stage_spock_sources

	local node variant
	for variant in ${ALL_VARIANTS}; do
		build_variant "${variant}"
	done

	# =====================================================================
	# Step 1 + 2: a single node on the first old major, with a complex
	#             database and no replication whatsoever.
	# =====================================================================
	local first_variant
	first_variant="$(node_to_old_variant "${FIRST_NODE}")"

	say "=== step 1: single ${first_variant} node, spock ${SPOCK_V5_VERSION} ==="

	init_node  "${FIRST_NODE}" "${first_variant}"
	start_node "${FIRST_NODE}" "${first_variant}"
	wait_for_ready "${FIRST_NODE}" || fail "${FIRST_NODE} never became ready" 12

	create_db_for_node "${FIRST_NODE}"
	setup_spock_node   "${FIRST_NODE}" yes

	say "=== step 2: populate and health-check ${FIRST_NODE} ==="
	local ic_rc=0
	populate_complex_database "${FIRST_NODE}" || ic_rc=$?
	if [ "${ic_rc}" -eq 124 ]; then
		fail "installcheck exceeded ${INSTALLCHECK_TIMEOUT}s -- treating as a hang" 13
	fi
	if [ "${SKIP_INSTALLCHECK}" -eq 1 ] && [ "${ic_rc}" -ne 0 ]; then
		fail "the synthetic schema failed to apply (rc=${ic_rc}) -- rig bug" 13
	fi
	# Regression diffs are expected and ignored: spock is preloaded and
	# auto-DDL perturbs a handful of outputs.  Only the database it leaves
	# behind matters here.
	log "populate step exit=${ic_rc} (regression diffs tolerated)"

	# A backend that dies on an assertion takes the whole cluster through
	# crash recovery, so the node may be up but not yet accepting connections.
	# Wait for it, or the next step fails for the wrong reason -- and name the
	# crash now, before the health check buries it in a list of probes.
	wait_for_ready "${FIRST_NODE}" \
		|| fail "${FIRST_NODE} did not come back after the payload step" 12
	report_crash_markers "${FIRST_NODE}" || true

	# Must happen before anything replicates or upgrades this database; see
	# normalise_regress_probin() for why.
	normalise_regress_probin "${FIRST_NODE}"

	repset_add_all_tables "${FIRST_NODE}"

	local n1_rels
	n1_rels="$(capture_signature "${FIRST_NODE}" "${FIRST_NODE}-populated" all)"
	[ "${n1_rels}" -gt 0 ] \
		|| fail "${FIRST_NODE}: the ${DBNAME} database has no user relations -- nothing to test" 13
	say "${FIRST_NODE}: ${DBNAME} holds ${n1_rels} user relations"

	if ! check_node_health "${FIRST_NODE}" 5 1 0; then
		if [ "${IGNORE_STEP2_HEALTH}" -eq 0 ]; then
			fail "${FIRST_NODE} failed its health check with no replication active (see ${HEALTH_LOG})" 13
		fi
		say "WARNING: --ignore-step2-health set -- continuing past a failed step 2"
		log "step 2 health failed but --ignore-step2-health was given; continuing"
	fi
	say "step 2 done: ${first_variant} node has ${n1_rels} relations, no replication active"

	# =====================================================================
	# Step 3: join every remaining node to n1 with zodan.
	# =====================================================================
	local joiner joiner_variant
	for joiner in ${NODES}; do
		[ "${joiner}" = "${FIRST_NODE}" ] && continue
		joiner_variant="$(node_to_old_variant "${joiner}")"

		say "=== step 3: add ${joiner_variant} node ${joiner} via zodan add_node ==="

		init_node  "${joiner}" "${joiner_variant}"
		start_node "${joiner}" "${joiner_variant}"
		wait_for_ready "${joiner}" || fail "${joiner} never became ready" 12

		create_db_for_node "${joiner}"
		setup_spock_node   "${joiner}" no   # zodan creates the spock node
		sync_roles "${FIRST_NODE}" "${joiner}"

		# The joiner is typically a newer major than the source, and spock's
		# structure sync pg_restores the source's schema into it.  Anything the
		# newer major no longer accepts has to go first, or the restore fails
		# and zodan times out waiting for its sync event with no indication of
		# why.  See adapt_for_target().
		adapt_for_target "${FIRST_NODE}" "${joiner_variant}" \
			|| fail "${FIRST_NODE}: could not adapt its schema for ${joiner_variant}" 14

		zodan_add_node "${FIRST_NODE}" "${joiner}" \
			|| { dump_replication_diagnostics "zodan-failed-${joiner}"
			     fail "zodan add_node failed for ${joiner} (see ${LOG_DIR}/${joiner}-zodan-add-node.log)" 14; }
	done

	wait_for_mesh_replicating "${WAIT_REPLICATING_TIMEOUT}" \
		|| { print_subscription_state "step 3 timeout"
		     dump_replication_diagnostics step3-timeout
		     print_subscription_state_to_screen
		     fail "subscriptions did not reach 'replicating' within ${WAIT_REPLICATING_TIMEOUT}s" 14; }

	print_subscription_state "after zodan add_node"

	# A full mesh of N nodes gives every node N-1 subscriptions.
	local subs_per_node=$(( NODE_COUNT - 1 ))
	for node in ${NODES}; do
		check_node_health "${node}" 5 "${NODE_COUNT}" "${subs_per_node}" \
			|| fail "${node} unhealthy after zodan add_node" 14
	done
	say "step 3 OK: ${NODE_COUNT}-node mesh replicating"

	# Do the nodes actually agree on the replicated tables?  Diagnostic only --
	# the scenario's verdict is subscription state -- but a divergence here is
	# reported and does colour the exit code.  Everything is compared against
	# the first node, which is where the data originated.
	capture_signature "${FIRST_NODE}" "${FIRST_NODE}-after-zodan" repset >/dev/null
	for node in ${NODES}; do
		[ "${node}" = "${FIRST_NODE}" ] && continue
		capture_signature "${node}" "${node}-after-zodan" repset >/dev/null
		compare_signatures "${FIRST_NODE}-after-zodan" "${node}-after-zodan" \
			"replicated tables agree between ${FIRST_NODE} and ${node}" \
			|| VERDICT_NODE_DATA=FAIL
	done

	# Baselines for the upgrade comparison, taken while every node is still on
	# its original major.
	for node in ${NODES}; do
		capture_signature "${node}" "${node}-pre-upgrade" all >/dev/null
	done

	# =====================================================================
	# Step 4: upgrade the whole cluster to the new major + spock 6.
	# =====================================================================
	say "=== step 4: upgrade the cluster to ${NEW_VARIANT}, spock ${SPOCK_V6_VERSION} ==="

	for node in ${NODES}; do
		quiesce_node "${node}"
	done

	# Drain while every apply worker is still connected, so each provider's
	# slot can confirm the last of the WAL before its node goes down.
	drain_cluster

	for node in ${NODES}; do
		adapt_for_target "${node}" "${NEW_VARIANT}" \
			|| fail "${node}: could not adapt the old cluster for a cross-major upgrade" 15
	done

	for node in ${NODES}; do
		stop_node "${node}" "$(node_to_old_variant "${node}")"
		prepare_new_datadir "${node}"

		# An offline --check first: it is the only mode that verifies
		# logical slots have caught up, and it tells us whether the
		# subscriptions themselves block the upgrade.
		local check_rc=0
		run_phase "${node}" upgrade-check _do_pg_upgrade "${node}" --check \
			|| check_rc=$?

		if [ "${check_rc}" -ne 0 ]; then
			say "${node}: pg_upgrade --check rejects the cluster with subscriptions in place"
			log "${node}: pg_upgrade --check rc=${check_rc}; retrying after dropping replication state"
			VERDICT_SURVIVAL=FAIL

			start_node "${node}" "$(node_to_old_variant "${node}")"
			wait_for_ready "${node}" || fail "${node}: would not restart for cleanup" 15
			drop_replication_state "${node}" "so pg_upgrade will accept the cluster"
			stop_node "${node}" "$(node_to_old_variant "${node}")"
			prepare_new_datadir "${node}"

			run_phase "${node}" upgrade-check-retry _do_pg_upgrade "${node}" --check \
				|| fail "${node}: pg_upgrade --check still fails after dropping replication state" 15
		fi

		run_phase "${node}" pg-upgrade _do_pg_upgrade "${node}" "" \
			|| fail "${node}: pg_upgrade failed (see ${LOG_DIR}/pg_upgrade-${node}/)" 15

		start_node "${node}" "${NEW_VARIANT}"
		wait_for_ready "${node}" \
			|| fail "${node}: ${NEW_VARIANT} cluster never became ready" 12
		extension_update "${node}"
	done

	# docs/upgrading_spock.md, final step: DDL replication back on once every
	# node is on the new version.  Then make sure nothing is left disabled, so
	# the survival check below measures replication and not our own quiescing.
	for node in ${NODES}; do
		unquiesce_node       "${node}"
		enable_subscriptions "${node}"
	done
	print_subscription_state "immediately after pg_upgrade"

	# --- Did the database itself survive? ---------------------------------
	for node in ${NODES}; do
		capture_signature "${node}" "${node}-post-upgrade" all >/dev/null
		compare_signatures "${node}-pre-upgrade" "${node}-post-upgrade" \
			"${node}: database survived pg_upgrade" \
			|| VERDICT_UPGRADE_DATA=FAIL
	done

	# --- Did the subscriptions survive? ----------------------------------
	local subs
	subs="$(count_all_subscriptions)"
	log "post-upgrade: ${subs} subscription(s) across the cluster"
	say "post-upgrade: ${subs} subscription(s) survived in the spock catalogs"

	# A mesh of N nodes needs N*(N-1) subscriptions; anything less means some
	# were lost, so do not let a partially-surviving cluster read as a pass.
	local want_subs=0 n_nodes=0
	for node in ${NODES}; do n_nodes=$(( n_nodes + 1 )); done
	want_subs=$(( n_nodes * (n_nodes - 1) ))

	if [ "${subs}" != "${want_subs}" ]; then
		VERDICT_SURVIVAL=FAIL
		say "SURVIVAL: FAIL -- ${subs} of ${want_subs} subscriptions survived the upgrade"
	elif wait_for_mesh_replicating "${WAIT_REPLICATING_TIMEOUT}"; then
		say "SURVIVAL: PASS -- subscriptions returned to 'replicating' on their own"
	else
		VERDICT_SURVIVAL=FAIL
		say "SURVIVAL: FAIL -- all ${subs} subscriptions survived but did not reach 'replicating' within ${WAIT_REPLICATING_TIMEOUT}s"
	fi
	print_subscription_state "after the survival wait"

	# --- Rebuild the mesh if it did not ----------------------------------
	if [ "${VERDICT_SURVIVAL}" = "FAIL" ]; then
		dump_replication_diagnostics survival-failed
		say "=== step 4b: re-bootstrapping the mesh on the upgraded cluster ==="
		VERDICT_REBUILD=FAIL

		for node in ${NODES}; do
			rebuild_node "${node}"
		done
		for node in ${NODES}; do
			repset_add_all_tables "${node}"
		done

		# A surviving-but-dead subscription would collide with sub_create.
		for node in ${NODES}; do
			if [ "$(_q "${node}" 'SELECT count(*) FROM spock.subscription')" != "0" ]; then
				drop_replication_state "${node}" "making way for the rebuilt mesh"
			fi
		done

		create_edges

		if wait_for_mesh_replicating "${WAIT_REPLICATING_TIMEOUT}"; then
			VERDICT_REBUILD=PASS
			say "REBUILD: PASS -- rebuilt mesh reached 'replicating'"
		else
			say "REBUILD: FAIL -- rebuilt mesh never reached 'replicating'"
		fi
		print_subscription_state "after rebuild"
	fi

	for node in ${NODES}; do
		check_node_health "${node}" 6 2 1 \
			|| log "${node}: health check reported problems after the upgrade"
	done

	# =====================================================================
	# Verdict
	# =====================================================================
	print_subscription_state_to_screen
	print_connection_params

	printf '=== Summary ===\n' >&2
	printf '  database survived pg_upgrade .......... %s\n' "${VERDICT_UPGRADE_DATA}" >&2
	printf '  nodes agree after zodan add_node ...... %s\n' "${VERDICT_NODE_DATA}"    >&2
	printf '  subscriptions survived pg_upgrade ..... %s\n' "${VERDICT_SURVIVAL}"     >&2
	printf '  mesh rebuildable after upgrade ........ %s\n' "${VERDICT_REBUILD}"      >&2
	printf '  reports under %s\n' "${REPORT_DIR}" >&2
	printf '  logs under    %s\n' "${LOG_DIR}"    >&2

	log "summary: data=${VERDICT_UPGRADE_DATA} node_data=${VERDICT_NODE_DATA} survival=${VERDICT_SURVIVAL} rebuild=${VERDICT_REBUILD}"

	# Most serious verdict wins; every failing check is named above.  `exit`
	# rather than `return`: a non-zero return from main would trip the ERR
	# trap and report a verdict as if the script had crashed.
	if [ "${VERDICT_UPGRADE_DATA}" = "FAIL" ]; then
		say "RESULT: FAIL (4) -- the upgraded database differs from the original"
		exit 4
	fi
	if [ "${VERDICT_REBUILD}" = "FAIL" ]; then
		say "RESULT: FAIL (3) -- replication never came back, even after a rebuild"
		exit 3
	fi
	if [ "${VERDICT_NODE_DATA}" = "FAIL" ]; then
		say "RESULT: FAIL (5) -- nodes disagree on replicated tables"
		exit 5
	fi
	if [ "${VERDICT_SURVIVAL}" = "FAIL" ]; then
		say "RESULT: PARTIAL (2) -- the database upgraded cleanly, but the mesh"
		say "        did not come back on its own and had to be rebuilt"
		exit 2
	fi
	say "RESULT: PASS -- the cluster survived the upgrade with replication intact"
	exit 0
}

main "$@"
