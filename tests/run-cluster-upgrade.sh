#!/usr/bin/env bash
#
# tests/run-cluster-upgrade.sh
#
# Does the documented upgrade procedure actually work?
#
# spock-upgrade-procedure-corrected.md describes a rolling PostgreSQL major
# upgrade of a Spock mesh: fence one node, record its inbound positions,
# pg_upgrade it, put the positions back, rebuild the peers' subscription from
# the record, verify, move on.  This script follows that document against a
# real three-node cluster it builds itself, and reports whether the procedure
# as written produces a cluster that still replicates and still agrees with
# itself.
#
# Usage:
#   tests/run-cluster-upgrade.sh [--stop-after join|upgrade]
#
# The procedure requires ACE (https://github.com/pgEdge/ace), which the
# document names as its companion for requirement 0 and step 12.  Point
# ACE_SRC at a checkout (it is built with `go build`) or ACE_BIN at a binary;
# without one the run stops rather than quietly skipping the document's own
# checks.  --stop-after join needs none of it, since it stops before
# requirement 0.
#
#   ACE_SRC=~/pgedge/ace tests/run-cluster-upgrade.sh
#
# ---------------------------------------------------------------------------
# What it does
# ---------------------------------------------------------------------------
#
# Steps 1 to 3 build what the document assumes exists: a healthy mesh holding
# a complex database.  A single node on the first old major, populated by the
# core PostgreSQL regression suite -- ~700 relations covering every object
# kind, inheritance, partitioning, matviews, foreign tables, C functions, odd
# types, dropped columns and rewritten heaps -- then the remaining nodes
# joined to it with spock.node_create() and spock.sub_create().
#
# Then the document itself, one node at a time.  Each of Part 1's numbered
# requirements is checked before the node is touched and again at step 5, and
# a requirement that does not hold stops the run rather than being noted and
# stepped over.  Each of Part 2's steps 1-13 is a named phase in the log.
#
# Two questions are answered separately:
#
#   PROCEDURE  did following the document leave a cluster that replicates and
#              whose nodes hold the same rows?
#   DOCUMENT   did the factual claims the document makes hold?  A claim that
#              turns out wrong in the reassuring direction is reported as a
#              failure, because that is how a procedure which "worked in
#              testing" loses data in production.
#
# Verifying the first needs something that changes while a node is away.  The
# regression database does not: a procedure that silently dropped every change
# made during the window would still compare equal afterwards.  Hence the
# witness table, written on the peers while the node is fenced and keyed so
# that a row which never arrived is a missing key and a row applied twice is a
# primary-key conflict rather than an invisible duplicate.
#
# ---------------------------------------------------------------------------
# --stop-after: hand the cluster over instead of finishing
# ---------------------------------------------------------------------------
#
# Both stages leave the servers running and write cluster-upgrade/
# CLUSTER-README.md -- the psql line per node, what each log file holds, the
# data directories, and how to shut it down.
#
#   join     stop once the mesh is up and replicating, before the document's
#            procedure begins.  The fastest way to get a real Spock mesh to
#            poke at by hand.
#   upgrade  carry on to the end of the document's Upgrade section: Part 1 plus
#            steps 1-7 for the first node, with the Restore section (steps 8,
#            9, 10) deliberately not run.  The cluster is mid-procedure and the
#            README says which steps have not happened and why writing to that
#            node would be skipped.
#
# Any other run of this script begins by stopping every server under
# cluster-upgrade/, so starting one takes a handed-over cluster down.
#
# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
#
# The version matrix is the only thing worth varying, so it is the only thing
# that can be.  Everything else -- ports, timeouts, parallelism, block sizes --
# is a constant in the section below, chosen once rather than asked for.
#
#   OLD_MAJORS      PostgreSQL major per node, in node order.  Default
#                   "17 17 17": three nodes, so a fenced node has two real
#                   peers, all on one major because the variable under test is
#                   the procedure and not the version spread.
#   NEW_MAJOR       major every node is upgraded to (default 19)
#   OLD_SPOCK_REF   git ref the pre-upgrade nodes are built from
#                   (default v5_STABLE)
#   NEW_SPOCK_REF   git ref the upgraded nodes are built from.  Empty -- the
#                   default -- means this working tree, uncommitted changes
#                   included, so the rig tests the code you are editing.  Both
#                   sides reporting the same SPOCK_VERSION is refused: such a
#                   run exercises no Spock upgrade and makes step 7's check
#                   pass for the wrong reason.
#   PG<major>_REF   override the PostgreSQL ref for one major, e.g.
#                   PG17_REF=REL_17_9.  Default: tests/resolve-pg-ref.sh.
#   PG_GIT_REMOTE   a private PostgreSQL mirror, tried before the public
#                   hosts.  Honoured because resolve-pg-ref.sh honours it:
#                   resolving a ref on one host and fetching it from another
#                   is how a mirror-only environment fails in this phase.
#   ACE_SRC         ACE checkout to build from
#   ACE_BIN         ACE binary to use as-is
#
# ---------------------------------------------------------------------------
# Reading the result
# ---------------------------------------------------------------------------
#
# The exit status is the verdict; every failing check is also named in the
# summary, and the findings are in cluster-upgrade/log/procedure.log.
#
#   0   the documented procedure works as written.
#   20  the procedure could not be followed: a Part 1 requirement did not
#       hold, or one of Part 2's steps failed outright.  The step number is
#       named in the message and in the phase log.
#   21  the procedure was followed to the end and the result is wrong: an edge
#       stopped replicating, a node lost rows written while it was fenced, or
#       the nodes diverged beyond the requirement-0 baseline.
#   22  the cluster is consistent, but the document says something that is not
#       true of it.
#   6   a node is unhealthy after the upgrade -- exception log, missing
#       worker, wrong extension version or a failed DDL/DML probe.
#   10  bad command line, or ACE could not be found.
#   11  build / clone / patch failure.
#   12  a node never became ready.
#   13  the payload step failed on the first node.
#   14  a node could not be attached, or the mesh did not reach 'replicating'.
#   15  pg_upgrade refused to run or failed.
#
# When several apply the most serious one is returned.  `on_err` remaps a raw
# tool status that collides with a verdict code (make exits 2, psql exits 3)
# to 11, because a `make` failure used to exit 2 and read as a verdict about
# the cluster.
#
# ---------------------------------------------------------------------------
# Known gaps, stated rather than left to be discovered
# ---------------------------------------------------------------------------
#
# The document's "If a check fails" rollback is not implemented, and this
# script does the opposite: a failed step 5 stops with the node still fenced
# and the cluster-wide settings still changed.  Its "Fallback -- rebuild
# instead of upgrade" section is not exercised at all.
#
# Step 12's per-table checksum and distinct-key count are missing.  That is
# not a missing line of SQL: during a rolling upgrade the nodes are on
# different majors, and PostgreSQL 18 changed how pg_lsn renders, so a
# text-based digest would report divergence between two nodes that agree.
# ACE's repset-diff covers the tables it can, and reports how many it cannot.
#
# Requirement 1 can only pass -- forward_origins is '{}' everywhere by
# construction -- and the sub_skip_lsn and skip_schema branches of step 9 are
# never entered.

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

# Left running only by --stop-after, which sets this itself.
KEEP_RUNNING=0

# Build parallelism.  Derived from the machine rather than asked for: there is
# one right answer on any given host and no reason to make the caller supply
# it.  The 4 is for a host whose getconf cannot say.
JOBS_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# The version matrix, and the only place versions are named.  OLD_MAJORS lists
# one PostgreSQL major per node, in node order: the first is the node the
# cluster starts as, the rest join it in turn.  Every node is then upgraded to
# NEW_MAJOR.  Two nodes is the minimum the scenario needs (a source and a
# joiner); adding majors adds nodes.
#
# Deliberately not baked into the file name or the directory layout -- the
# defaults move every release, the script does not.
# --stop-after has to be known here, before the version matrix below is
# derived from OLD_MAJORS, because it brings its own defaults with it.  The
# real argument parser runs much later and is the one that rejects typos;
# this pre-scan only looks for the one flag and never consumes anything.
SETUP_ONLY=0
# Which stage the run stops at.  Empty means "run the whole procedure".
#   join     stop once the mesh is up and replicating
#   upgrade  stop after the document's Upgrade section, i.e. steps 1-7 for the
#            first node, with the Restore section deliberately not run
SETUP_STAGE=""
# Which node --stop-after upgrade left on the new major.  Empty until it has.
SETUP_UPGRADED_NODE=""
_want_stage=0
for _arg in "$@"; do
	# The pre-scan has to read the VALUE and not just spot the flag: the
	# version matrix below is derived from it -- stopping at `join` needs no
	# v6 build at all, and anything else does.
	if [ "${_want_stage}" -eq 1 ]; then
		SETUP_ONLY=1
		SETUP_STAGE="${_arg}"
		_want_stage=0
	elif [ "${_arg}" = "--stop-after" ]; then
		_want_stage=1
	fi
done
unset _arg _want_stage

case "${SETUP_STAGE}" in
	'' | join | upgrade) ;;
	*) printf 'FATAL: unknown --stop-after stage "%s"; expected join or upgrade\n' \
		"${SETUP_STAGE}" >&2
	   exit 10 ;;
esac

# Three nodes, because the documented procedure is a rolling one and a fenced
# node needs two real peers.  They all start on the same major: the variable
# under test is the procedure, not the version spread.
OLD_MAJORS="${OLD_MAJORS:-17 17 17}"
if [ "${SETUP_STAGE}" = "join" ]; then
	# Nothing is upgraded when stopping at `join`, so the target major is
	# never used -- but the version matrix below is derived from it, so it
	# needs a valid value.  The old major means that if some future edit does
	# start building it, the cost is a cache hit rather than a whole extra
	# PostgreSQL.
	NEW_MAJOR="${NEW_MAJOR:-${OLD_MAJORS%% *}}"
else
	NEW_MAJOR="${NEW_MAJOR:-19}"
fi

# Nodes listen on PORT_BASE+n; pg_upgrade gets PORT_BASE+10+n for its own
# throwaway server starts.  Chosen not to collide with the other rigs in
# tests/ so they can run side by side.
PORT_BASE=57800

DBNAME=regression
DBUSER=regression

# The git refs the two halves of the cluster are built from.
#
# OLD_SPOCK_REF was spoc-643, which is itself a 6.0.0 branch -- so the rig
# reported "old=6.0.0 new=6.0.0" and quietly tested no Spock version change at
# all, while the header three hundred lines up promised v5_STABLE.  The header
# was right about the intent, so the code now matches it.
OLD_SPOCK_REF="${OLD_SPOCK_REF:-v5_STABLE}"

# NEW_SPOCK_REF names the ref the upgraded half is built from.  Empty -- the
# default -- means the working tree as it stands, which is what makes the rig
# useful locally: it tests the code you are editing, uncommitted changes and
# all.  Set it to a ref (main, a tag, a SHA) when you want a reproducible pair
# instead, e.g. NEW_SPOCK_REF=main for v5_STABLE -> main.
NEW_SPOCK_REF="${NEW_SPOCK_REF:-}"

# Seconds to wait for every subscription to report status='replicating'.
# The scenario asks for a hard 1-minute bound.
WAIT_REPLICATING_TIMEOUT=60

# The synchronisation budget, in seconds, written into every node's
# postgresql.conf as spock.sync_timeout.
#
# Not left at Spock's own default of 0, which means "each routine keeps its
# built-in limit" -- 180 seconds, sized for a cluster that syncs in seconds.
# This rig deliberately populates the core regression database, ~700
# relations, and the documented procedure's waits are measured against this
# budget on a cluster that size.
#
# Must be a bare integer: the readers below cast pg_settings.setting with
# ::integer, and a value written as '30min' would reach them as that string.
SPOCK_SYNC_TIMEOUT=1800

# Wall-clock cap on attaching one node in step 3.  Generous: the seed
# subscription has to pg_dump the source schema, restore it, and COPY every
# replicated table.
#
# This is the rig's own guard and not a spock setting: the initial sync is
# spock.sub_wait_for_sync(), which blocks with no timeout of its own.
JOIN_TIMEOUT=$(( SPOCK_SYNC_TIMEOUT * 2 ))

# Wall-clock cap on the core regression suite.  A hang here (auto-DDL
# deadlocking against a regression test, say) is the nastiest failure mode
# for CI, so it gets a hard bound rather than an unbounded wait.
INSTALLCHECK_TIMEOUT=3600

# ICU is deliberately off: pg_upgrade compares the locale provider and ICU
# version between clusters, and three independently-configured majors are
# far more likely to agree on plain libc/C.
# --with-ssl=openssl is here for ACE, not for TLS: contrib/Makefile builds
# pgcrypto only under `ifeq ($(with_ssl),openssl)`, and ACE's block hashing
# calls digest(), so without it every table-diff and repset-diff fails with
# "function digest(text, unknown) does not exist".  pg_upgrade does not compare
# SSL support between clusters, so unlike ICU this costs nothing there.
PG_CONFIGURE_FLAGS="--enable-debug --enable-cassert --without-icu --without-readline --with-ssl=openssl"

# Remotes to fetch PostgreSQL from, in order.
#
# GitHub first, git.postgresql.org as the fallback.  Two reasons:
#
#   - git.postgresql.org is community infrastructure serving a full-history
#     clone of a large repository; a CI rig that rebuilds several majors has
#     no business being its heaviest caller when an official mirror exists.
#   - tests/resolve-pg-ref.sh already resolves `tag` specs against GitHub by
#     default.  With the old order the rig resolved a tag on one host and
#     fetched it from another, which is precisely the split
#     _do_clone_pg warns about: a tag not yet propagated to the second host
#     fails the fetch for a reason that has nothing to do with the build.
#
# Set PG_GIT_REMOTE to put a private or internal mirror ahead of both; it is
# honoured by resolve-pg-ref.sh too, so resolution and fetch stay on one host.
PG_GIT_REMOTES="https://github.com/postgres/postgres.git https://git.postgresql.org/git/postgresql.git"

# Each remote is tried this many times before the next one is considered.
# A pack transfer dropped mid-stream ("early EOF", "unexpected disconnect
# while reading sideband packet", "RPC failed; curl 56") is almost always
# transient, so an immediate retry is the cheapest cure; only if that fails
# too is the remote itself suspect and the mirror worth a go.
PG_CLONE_ATTEMPTS=2
PG_CLONE_RETRY_DELAY=5

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

# Scratch ports handed to pg_upgrade for its own short-lived server starts.
# One for each cluster, because pg_upgrade refuses to run with both on the
# same port -- and, more importantly, because neither may be reachable at a
# production address while it is up.
#
# pg_upgrade isolates the servers it starts: listen_addresses='' plus a
# unix_socket_directories of its own choosing.  This rig defeats half of that
# by passing -s ${SOCK_DIR}, the directory every node's DSN names, and it has
# to: a socket path under BASE_DIR would exceed the ~104-byte limit checked at
# startup.  So the port is the only thing left separating pg_upgrade's
# throwaway servers from the peers still dialling this node.
#
# Giving the OLD cluster the production port used to cost a run outright.  The
# peers' apply workers retry in a loop from the moment the node is fenced, so
# one of them reconnects to the server pg_upgrade started, opens a replication
# connection, and pg_upgrade fails its own check with
#     connection failure: ERROR: replication slot "spk_..." is active for PID
# -- intermittently, depending on whether a reconnect lands inside the check
# window.  With a scratch port there is nothing at the address they dial.
#
# The production port is restored by write_node_conf, which is what the new
# data directory's postgresql.conf says; -p and -P only affect the servers
# pg_upgrade starts and stops itself.
node_to_stage_port() {
	printf '%s\n' "$(( PORT_BASE + 10 + $(node_index "$1") ))"
}

node_to_stage_port_old() {
	printf '%s\n' "$(( PORT_BASE + 20 + $(node_index "$1") ))"
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

# A join needs somewhere to join from and somewhere to join to.
if [ "${NODE_COUNT}" -lt 2 ]; then
	printf 'FATAL: OLD_MAJORS needs at least two majors (got "%s")\n' \
		"${OLD_MAJORS}" >&2
	exit 10
fi

# Three port bands ten apart -- production, pg_upgrade's new cluster, and
# pg_upgrade's old cluster -- so the tenth node's production port would be the
# first node's staging port.  Silent overlap there would mean a peer dialling
# a node and reaching pg_upgrade's throwaway server, which is the exact
# failure the separate bands exist to prevent.
if [ "${NODE_COUNT}" -gt 9 ]; then
	printf 'FATAL: at most 9 nodes; the port bands at PORT_BASE+0/+10/+20 would overlap (got %s)\n' \
		"${NODE_COUNT}" >&2
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
# --stop-after join never upgrades anything, so the v6 side is not built for
# it.  Not a micro-optimisation: on a machine that has not built it yet that is
# an entire extra PostgreSQL major plus its spock, for a run that will never
# start it.
if [ "${SETUP_ONLY}" -eq 0 ] || [ "${SETUP_STAGE}" = "upgrade" ]; then
	ALL_VARIANTS="${ALL_VARIANTS} ${NEW_VARIANT}"
fi
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
			# and keep hammering the cluster.
			#
			# All five calls below are guarded, and the guard is meant: each
			# addresses a process that may already have exited between the
			# liveness check and the signal, `pkill` is not guaranteed to
			# exist, and the caller learns what happened from the 124 return
			# rather than from any of these.
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

# The ERR trap fires only for a command failure nobody checked -- which is by
# definition a rig problem, never a verdict about the cluster.  fail() exits
# directly and does not come through here, and neither does main(), which
# exits with its verdict explicitly.
#
# So an rc that collides with a verdict code is remapped to 11.  Otherwise any
# tool that happens to exit 2, 3, 4 or 5 -- make exits 2, psql exits 3 --
# would have its status read as one of the things this rig is supposed to be
# measuring, and the more reassuring the collision the longer it survives:
# 2 means "upgraded cleanly, mesh rebuilt by hand".
on_err() {
	local rc=$1 line=$2
	log "Aborted: exit ${rc} at line ${line}"
	say "see ${LOG_DIR}/ for per-phase log files"
	case "${rc}" in
		2 | 3 | 4 | 5 | 6)
			log "exit ${rc} collides with a verdict code; reporting 11 (rig failure)"
			say "aborted with status ${rc} from an unchecked command; reporting 11 -- this is a rig failure, not a verdict"
			exit 11 ;;
	esac
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
		--stop-after)        [ "$#" -ge 2 ] || fail "--stop-after requires a stage (join or upgrade)" 10
		                     SETUP_ONLY=1; SETUP_STAGE="$2"
		                     # Implied, not merely compatible: a mode whose
		                     # output is a running cluster cannot also stop it.
		                     KEEP_RUNNING=1; shift 2 ;;  # pre-scan too
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
# working if BASE_DIR moves.
BASE_DIR_EXCLUDE=""
case "${BASE_DIR}/" in
	"${SPOCK_SRC}/"*)
		BASE_DIR_EXCLUDE="--exclude=/${BASE_DIR#"${SPOCK_SRC}/"}" ;;
esac

# Fresh log and report directories per run; src/, bin/, spock-src/ and
# pgdata/ are preserved so build reuse still works.
rm -rf "${LOG_DIR}" "${REPORT_DIR}"
mkdir -p "${LOG_DIR}" "${REPORT_DIR}"

# Sweep up anything reset_dir could not delete on a previous run.  Unguarded:
# `rm -rf` already succeeds on a path that is not there, so a failure here is
# a real one -- a permission problem or a read-only filesystem -- and the run
# is about to write to this tree anyway.
rm -rf "${BASE_DIR}"/*/*.discard.*

MAIN_LOG="${LOG_DIR}/main.log"
: >"${MAIN_LOG}"

# Unix socket paths are capped at ~104 bytes on macOS; a deep BASE_DIR
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
		rm -rf "${trash}"
		mv "${dest}" "${trash}" || return 1
		# The only tolerated failure in this function, and it is logged with
		# its reason: the rename already succeeded, so the caller gets its
		# empty directory either way and the next run sweeps the leftover up.
		rm -rf "${trash}" \
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

# DSN that talks over the shared Unix socket directory.  The database name is
# spelled out because Spock stores this string verbatim in
# spock.node_interface -- hence the stable ports.
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
_do_stage_spock_worktree() {
	local dest="$1"
	reset_dir "${dest}" && \
	rsync -a \
		${BASE_DIR_EXCLUDE:+"${BASE_DIR_EXCLUDE}"} \
		--exclude='/single-pg18-installcheck' \
		--exclude='/.git' \
		--exclude='.DS_Store' \
		"${SPOCK_SRC}/" "${dest}/"
}

# A detached checkout of one ref from the local repo.  Cloning from the local
# repo keeps the network out of the picture; the extra fetch pulls the ref in
# when the caller names something only reachable via origin.
#
# Used for both halves now: the old side always names a ref, and the new side
# names one whenever NEW_SPOCK_REF is set.
_do_stage_spock_ref() {
	local dest="$1" ref="$2"
	# git clone accepts an existing empty directory, so reset_dir is enough.
	reset_dir "${dest}" && \
	git clone --no-checkout --shared "${SPOCK_SRC}" "${dest}" && \
	{
		# Pull the source repo's remote-tracking refs across as well, so a
		# caller who names `origin/something` gets what they asked for.  Not
		# fatal on its own -- the ref may already be local -- but reported
		# with its reason, because the checkout below is then the only thing
		# left that can find it.
		git -C "${dest}" fetch --no-tags "${SPOCK_SRC}" \
			'+refs/remotes/origin/*:refs/remotes/origin/*' \
			|| log "stage: could not copy remote-tracking refs into ${dest}"
		# A clone materialises only the source's HEAD as a local branch;
		# everything else arrives as origin/<name>, so try both spellings.
		git -C "${dest}" checkout --detach "${ref}" 2>/dev/null \
			|| git -C "${dest}" checkout --detach "origin/${ref}"
	} && \
	git -C "${dest}" --no-pager log -1 --format="staged ${ref} as %H %s"
}

# What a staged tree was built from, so a changed ref forces a restage.
# Without this a cached spock-src/v5 from a previous run is reused verbatim:
# flipping OLD_SPOCK_REF would change nothing, and the rig would report the
# new ref's name while running the old ref's code.
_staged_ref_file() { echo "$(spock_src_for "$1")/.spock-staged-ref"; }

# The ref backing a slot, or the empty string for the working tree.
spock_ref_for_slot() {
	case "$1" in
		v5) printf '%s' "${OLD_SPOCK_REF}" ;;
		v6) printf '%s' "${NEW_SPOCK_REF}" ;;
		*)  return 1 ;;
	esac
}

_stage_one_side() {
	local slot="$1" ref="$2" want dir marker
	dir="$(spock_src_for "${slot}")"
	marker="$(_staged_ref_file "${slot}")"

	# An empty ref means "the working tree", which is never cached: it tracks
	# files the user is editing, and a stale copy would silently test
	# yesterday's code.
	if [ -z "${ref}" ]; then
		run_phase "spock-${slot}" stage _do_stage_spock_worktree "${dir}" || return 1
		printf '(working tree)\n' >"${marker}"
		return 0
	fi

	# A ref is pinned, so the tree can be reused -- but only if it was staged
	# from the same ref.  A moved branch tip is deliberately not detected
	# here.
	want="$(cat "${marker}" 2>/dev/null)" || want=""
	if [ -f "${dir}/Makefile" ] && [ "${want}" = "${ref}" ]; then
		log "spock-${slot}: reusing staged ${ref} at ${dir}"
		return 0
	fi
	if [ -n "${want}" ] && [ "${want}" != "${ref}" ]; then
		log "spock-${slot}: cached tree is ${want}, want ${ref} -- restaging"
	fi
	run_phase "spock-${slot}" stage _do_stage_spock_ref "${dir}" "${ref}" || return 1
	printf '%s\n' "${ref}" >"${marker}"
}

stage_spock_sources() {
	local v5; v5="$(spock_src_for v5)"
	local v6; v6="$(spock_src_for v6)"

	# The directory names are still v5/v6 for continuity with the rest of the
	# layout, but they mean "old side" and "new side": either can now be any
	# ref, and the new side defaults to the working tree.
	_stage_one_side v5 "${OLD_SPOCK_REF}" \
		|| fail "could not stage the old spock side from ${OLD_SPOCK_REF}" 11
	_stage_one_side v6 "${NEW_SPOCK_REF}" \
		|| fail "could not stage the new spock side from ${NEW_SPOCK_REF:-the working tree}" 11

	local v
	for v in v5 v6; do
		local d; d="$(spock_src_for "${v}")"
		[ -f "${d}/Makefile" ] \
			|| fail "spock source ${d} has no Makefile after staging" 11
	done

	# Record what we actually built.  Both sides are named, and both versions
	# are read from the staged trees rather than from the refs' names -- the
	# whole point of this block is that a ref called v5_STABLE is not proof
	# that a 5.x tree was staged.
	local v5ver v6ver newlabel
	v5ver="$(sed -n 's/^#define SPOCK_VERSION "\(.*\)"/\1/p' "${v5}/include/spock.h")"
	v6ver="$(sed -n 's/^#define SPOCK_VERSION "\(.*\)"/\1/p' "${v6}/include/spock.h")"
	newlabel="${NEW_SPOCK_REF:-working tree}"

	# Does the OLD side carry the generated-column fix?
	#
	# Probed in the staged source, not inferred from a version number or a
	# commit SHA: what matters is whether this tree keeps generated columns out
	# of the sync path, and the two places that have to do it are
	# make_copy_attnamelist() in spock_sync.c (the subscriber's COPY column
	# list) and spock_show_repset_table_info() in spock_functions.c (the
	# provider's attnames, the belt to that braces).
	#
	# Without it, COPY <tab> (<cols>) TO stdout names a generated column, the
	# server rejects it, and no such table can be initial-synced -- so those
	# tables have to be kept out of a replication set or the rig never reaches
	# step 3.  With it there is nothing to work around and they belong in the
	# test, which is why this is a probe and not a constant.
	# The files are asserted present first.  Probing with the read error
	# suppressed would answer "no" for a tree that was staged wrong, and "no"
	# is the answer that silently narrows the payload.
	local f
	for f in spock_sync.c spock_functions.c; do
		[ -f "${v5}/src/${f}" ] \
			|| fail "staged old tree ${v5} has no src/${f}; the generated-column probe cannot run" 11
	done
	if grep -q 'attgenerated' "${v5}/src/spock_sync.c" \
		&& grep -q 'attgenerated' "${v5}/src/spock_functions.c"; then
		OLD_SPOCK_SYNCS_GENERATED=yes
	else
		OLD_SPOCK_SYNCS_GENERATED=no
	fi
	log "old side ${OLD_SPOCK_REF}: keeps generated columns out of the sync path = ${OLD_SPOCK_SYNCS_GENERATED}"
	if [ "${OLD_SPOCK_SYNCS_GENERATED}" = "no" ]; then
		say "NOTE: ${OLD_SPOCK_REF} does not exclude generated columns during initial"
		say "      sync, so tables that have one are kept out of the replication sets"
	fi
	log "spock versions: old=${v5ver} (${OLD_SPOCK_REF})  new=${v6ver} (${newlabel})"
	say "spock: old=${v5ver} (${OLD_SPOCK_REF})  new=${v6ver} (${newlabel})"
	SPOCK_V5_VERSION="${v5ver}"
	SPOCK_V6_VERSION="${v6ver}"

	# Both sides the same version is almost always a misconfiguration, and a
	# silent one: the run still passes, having tested no Spock upgrade at
	# all.  It also makes step 7's check -- "spock brought its
	# catalog up to the new version by itself" -- trivially true, because
	# there was nothing to bring it up to.
	if [ "${v5ver}" = "${v6ver}" ]; then
		# Refused rather than warned about: such a run exercises no Spock
		# upgrade at all and makes step 7's check -- "spock brought its own
		# catalog up to the new version" -- trivially true, because there was
		# nothing to bring it up to.
		fail "both sides are spock ${v5ver} (${OLD_SPOCK_REF} and ${newlabel}), so no Spock upgrade would be exercised and step 7 would pass for the wrong reason; set OLD_SPOCK_REF and NEW_SPOCK_REF to different trees" 10
	fi
}

# ---------------------------------------------------------------------------
# PostgreSQL build pipeline, once per variant
# ---------------------------------------------------------------------------

# PG_GIT_REMOTE may embed credentials, so strip any user:pass@ before a
# remote reaches a log that CI uploads as an artefact.  A URL without
# credentials passes through unchanged.
_redact_remote() {
	printf '%s' "$1" | sed -e 's,//[^/@]*@,//,g'
}

# fetch + checkout rather than `clone --branch`, so an explicit commit SHA
# works as well as a branch or tag.  The && chain makes a mid-sequence
# failure propagate, and the ref markers are written only on full success.
# Starting with reset_dir leaves no half-fetched tree behind for the next
# attempt to trip over.
_do_clone_pg_once() {
	local src="$1" remote="$2" ref="$3"
	reset_dir "${src}" && \
	git init "${src}" && \
	git -C "${src}" remote add origin "${remote}" && \
	git -C "${src}" fetch --depth 1 origin "${ref}" && \
	git -C "${src}" checkout --detach FETCH_HEAD && \
	printf '%s\n' "${ref}" > "${src}/.spock-pg-ref" && \
	printf '%s\n' "${src}" > "${src}/.spock-src-path"
}

# Try each remote in turn, PG_CLONE_ATTEMPTS times each, stopping at the
# first attempt that completes.
#
# The fetch is its own reachability test.  This used to probe with
# `git ls-remote HEAD` and then commit to whichever remote answered, which
# does not work: a remote can serve that cheap request and still drop the
# connection part-way through the real pack transfer.  Selecting on the probe
# meant the fallback was never reached on the one occasion it would have
# helped, and a run died with "early EOF" while a working mirror sat unused.
# Whichever host is listed first, that failure mode is a property of large
# pack transfers over flaky links, not of any one server -- so the retry and
# fall-through stay regardless of the order in PG_GIT_REMOTES.
#
# Every attempt reports itself into the phase log, so a run that eventually
# succeeds still shows which remote it had to fall back to.
_do_clone_pg() {
	local src="$1" ref="$2"
	local remote attempt first=1 rc=1
	local remotes="${PG_GIT_REMOTES}"

	# resolve-pg-ref.sh resolves a `tag` spec against PG_GIT_REMOTE, which
	# exists so a private or internal mirror can stand in for the public
	# hosts.  Honour it here too: resolving the ref from one remote and then
	# fetching it from another is how a mirror-only environment fails in this
	# phase.  It goes first, with the public defaults kept as fallback, and is
	# not added twice if it already names one of them.
	if [ -n "${PG_GIT_REMOTE:-}" ]; then
		case " ${remotes} " in
			*" ${PG_GIT_REMOTE} "*) ;;
			*) remotes="${PG_GIT_REMOTE} ${remotes}" ;;
		esac
	fi

	for remote in ${remotes}; do
		attempt=1
		while [ "${attempt}" -le "${PG_CLONE_ATTEMPTS}" ]; do
			# Delay between attempts only -- never before the first, and
			# never after the last.
			[ "${first}" -eq 1 ] || sleep "${PG_CLONE_RETRY_DELAY}"
			first=0

			echo "----- fetch ${ref} from $(_redact_remote "${remote}")" \
				"(attempt ${attempt}/${PG_CLONE_ATTEMPTS}) -----"
			rc=0
			_do_clone_pg_once "${src}" "${remote}" "${ref}" || rc=$?
			[ "${rc}" -eq 0 ] && return 0
			echo "----- fetch from $(_redact_remote "${remote}")" \
				"failed rc=${rc} -----"

			attempt=$(( attempt + 1 ))
		done
	done

	# rc starts at 1 so an empty remote list reports failure rather than
	# silently "succeeding" with no source tree.
	echo "all remotes exhausted for ${ref}: $(_redact_remote "${remotes}")"
	return "${rc}"
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

clone_pg() {
	local variant="$1"
	local major; major="$(variant_to_major "${variant}")"
	local src;   src="$(pgsrc_for "${variant}")"
	local ref;   ref="$(resolve_pg_ref "${major}")"

	log "${variant}: PostgreSQL ref = ${ref}"

	# A cached checkout built for a different ref forces a full rebuild of
	# this variant, so the new ref reaches the configure and spock phases
	# too.  A moved branch tip (same name, new commits) is deliberately not
	# detected.
	if [ -d "${src}/.git" ] \
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
	if [ -d "${src}/.git" ] \
		&& [ "$(cat "${src}/.spock-src-path" 2>/dev/null)" != "${src}" ]; then
		log "${variant}: cached source was built at a different path; starting over"
		say "${variant}: build cache is from another directory -- rebuilding"
		rm -rf "$(prefix_for "${variant}")"
		VARIANT_FORCE=1
	fi

	if [ "${VARIANT_FORCE}" -eq 0 ] \
		&& [ -d "${src}/.git" ] \
		&& [ -f "${src}/src/test/regress/parallel_schedule" ]; then
		log "${variant}: source for ${ref} already present, skipping clone"
		return 0
	fi

	run_phase "${variant}" pg-clone _do_clone_pg "${src}" "${ref}"
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
# Configure the tree, cleaning first if the flags have changed since last time.
#
# Re-running configure over an already-built tree with DIFFERENT flags does not
# produce a tree built with the new flags -- it produces a broken link.  make
# recompiles what configure's output made stale, and an object whose *content*
# depends on a flag it cannot see is not stale.  Adding --with-ssl=openssl hit
# exactly that:
#
#   duplicate symbol '_PQgetssl' in:
#       .../libpq/fe-secure.o          <- compiled without SSL, not rebuilt
#       .../libpq/fe-secure-openssl.o  <- new, compiled with SSL
#   ld: 7 duplicate symbols
#
# So the flags are recorded beside config.status and compared.  A change means
# `make distclean` before configuring; an unchanged flag list keeps the
# incremental build, which is the common case and worth keeping fast.  distclean
# rather than clean because configure's own generated files (Makefile.global,
# pg_config.h) are part of what has to go.
_do_configure_pg() {
	local src="$1" prefix="$2"
	local want="--prefix=${prefix} ${PG_CONFIGURE_FLAGS}"
	local marker="${src}/.rig-configure-flags"

	if [ -f "${src}/config.status" ] && [ "$(cat "${marker}" 2>/dev/null)" != "${want}" ]; then
		echo "----- configure flags changed, cleaning ${src} first -----"
		echo "  was: $(cat "${marker}" 2>/dev/null || echo '(not recorded)')"
		echo "  now: ${want}"
		# Not fatal on its own: distclean fails on a tree that was never fully
		# configured, and configure below will sort that out.  Reported rather
		# than hidden, because a distclean that did not happen is the whole
		# reason this function exists.
		make -C "${src}" -s distclean \
			|| echo "  NOTE: distclean failed; continuing to configure anyway"
	fi

	(
		cd "${src}"
		# shellcheck disable=SC2086  # PG_CONFIGURE_FLAGS is a flag list
		./configure --prefix="${prefix}" ${PG_CONFIGURE_FLAGS}
	) || return 1

	printf '%s\n' "${want}" >"${marker}"
}

# Beyond core: contrib (pgcrypto for ACE, and spi's autoinc/refint, which the
# regression suite's C functions name) and pg_regress (which `make
# installcheck` needs).  These must exist in *every* install, not just the
# ones that use them directly: pg_upgrade's check_loadable_libraries walks
# pg_proc.probin of the old cluster and insists every library loads in the new
# one, so a contrib module left out of the new install would block the
# upgrade of a database that merely has it installed.
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

	# Reuse requires more than a postgres binary: pgcrypto (for ACE) and the
	# regression shared library both come from build phases a plain `make
	# install` does not cover, so an install missing either is not reusable.  Note that configure moves sharedir to
	# <prefix>/share/postgresql, hence asking pg_config rather than guessing.
	#
	# pgcrypto is in this list for a second reason: it is the observable
	# consequence of --with-ssl=openssl.  The reuse test does not compare
	# configure flags, so adding that flag would otherwise leave every existing
	# install in place, and ACE would keep failing on a missing digest() with
	# nothing in the log to say why.  Checking for the artefact the flag
	# produces makes the flag change force its own rebuild.
	if [ "${VARIANT_FORCE}" -eq 0 ] \
		&& [ -x "${prefix}/bin/postgres" ] \
		&& [ -x "${prefix}/bin/pg_config" ] \
		&& [ -f "$("${prefix}/bin/pg_config" --sharedir)/extension/pgcrypto.control" ] \
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
# Keep utils/spockctrl out of the build.
#
# This applies to the OLD side only.  6.0.0 already dropped it -- its Makefile
# reads `all: spock.control` -- while v5_STABLE still has
# `all: spock.control spockctrl`, plus spockctrl prerequisites on `clean` and
# `install`.  Building it needs jansson via pkg-config, and nothing in this rig
# uses spockctrl, so a library CI may not have should not decide whether the
# old side builds at all.
#
# Edits the throwaway copy, never ${SPOCK_SRC}: _do_build_spock rsyncs the
# staged tree into build_dir first.
#
# The three outcomes are told apart rather than collapsed.  The version this
# replaced returned 0 the moment its `all:` pattern did not match, so a
# reshaped Makefile meant the strip silently did not happen and the build began
# requiring jansson with nothing in the log to explain it.
_do_drop_spockctrl() {
	local build_dir="$1" mk
	mk="${build_dir}/Makefile"

	if ! grep -q 'spockctrl' "${mk}"; then
		echo "----- no spockctrl in this Makefile (6.x already dropped it) -----"
		return 0
	fi
	if ! grep -q '^all: spock.control spockctrl$' "${mk}"; then
		echo "${mk} names spockctrl but not as '^all: spock.control spockctrl$',"
		echo "  so this rig does not know how to keep it out of the build.  Left as"
		echo "  it is: the build below will need jansson via pkg-config.  Lines:"
		grep -n 'spockctrl' "${mk}" | sed 's/^/    /'
		return 0
	fi

	echo "----- dropping spockctrl from the build (not needed here) -----"
	sed -e 's/^all: spock.control spockctrl$/all: spock.control/' \
	    -e 's/^clean: clean-spockctrl$/clean:/' \
	    -e 's/^install: install-spockctrl$/install:/' \
	    "${mk}" >"${mk}.nospockctrl" \
		|| { echo "could not rewrite ${mk}"; return 1; }
	mv "${mk}.nospockctrl" "${mk}" || return 1

	# Asserted, because a partial strip is worse than none: `all` would build
	# without spockctrl while `install` still demanded it.
	if grep -qE '^(all|clean|install):.*spockctrl' "${mk}"; then
		echo "spockctrl survived the strip in ${mk}:"
		grep -nE '^(all|clean|install):.*spockctrl' "${mk}" | sed 's/^/    /'
		return 1
	fi
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

	# What this install was built from.  Reusing on the mere existence of
	# spock.control is not safe: restaging the source from a different ref
	# leaves the previously installed library in place, so the run would
	# report the new ref's version while executing the old ref's code -- a
	# false pass that looks more convincing than the bug it hides.  So the
	# marker carries both the ref and the SPOCK_VERSION found in the tree,
	# and a mismatch forces a rebuild.
	local slot; slot="$(variant_to_spock "${variant}")"
	local ref;  ref="$(spock_ref_for_slot "${slot}")"
	local marker="${sharedir}/extension/.spock-built-from"
	local srcver; srcver="$(sed -n 's/^#define SPOCK_VERSION "\(.*\)"/\1/p' \
		"${spock_src}/include/spock.h")"
	local want="${ref}|${srcver}"

	# An empty ref means the working tree, which is never reused: its
	# SPOCK_VERSION does not move while its code does, so the marker cannot
	# tell yesterday's build from today's.
	if [ "${VARIANT_FORCE}" -eq 0 ] \
		&& [ -n "${ref}" ] \
		&& [ -f "${sharedir}/extension/spock.control" ] \
		&& [ "$(cat "${marker}" 2>/dev/null)" = "${want}" ]; then
		log "${variant}: reusing spock install built from ${want}"
		return 0
	fi
	if [ -f "${marker}" ]; then
		log "${variant}: installed spock is $(cat "${marker}"), want ${want} -- rebuilding"
	fi

	run_phase "${variant}" spock-build _do_build_spock \
		"${spock_src}" "${build_dir}" "${pg_config}" "${JOBS_TOTAL}" || return 1
	printf '%s\n' "${want}" >"${marker}"
}

# Every phase is mapped to exit 11 explicitly, and not left to propagate its
# own status.  run_phase returns whatever the tool returned -- make exits 2 --
# and with no mapping that 2 reached the ERR trap and became the script's exit
# code, where 2 is a documented verdict: "the database upgraded cleanly, but
# the mesh had to be rebuilt by hand".  A missing bison reported itself as a
# successful upgrade with a caveat.
build_variant() {
	local variant="$1"
	VARIANT_FORCE=0        # per-variant escalation set by clone_pg
	clone_pg    "${variant}" || fail "${variant}: could not fetch the PostgreSQL source" 11
	patch_pg    "${variant}" || fail "${variant}: spock's PostgreSQL patches did not apply" 11
	build_pg    "${variant}" || fail "${variant}: PostgreSQL did not build" 11
	build_spock "${variant}" || fail "${variant}: spock did not build" 11
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
	local data="$1" port="$2" prefix="$3"

	cat >>"${data}/postgresql.conf" <<-EOF
		# --- spock cluster-upgrade test rig ---
		# A TCP listener on loopback only.
		#
		# The rig itself talks over the unix socket and needs no TCP at all;
		# this is here for ACE, which addresses nodes by host and port (its
		# cluster JSON has no socket-directory field) and so cannot reach a
		# socket-only cluster.  Bound to 127.0.0.1 rather than '*' because
		# nothing outside this machine has any business connecting, and
		# initdb's default pg_hba already trusts 127.0.0.1/32.
		#
		# Each node already has its own port, and pg_upgrade's throwaway
		# servers use PORT_BASE+10+i and PORT_BASE+20+i, so nothing collides
		# and no peer can reach either of them.
		listen_addresses = '127.0.0.1'
		unix_socket_directories = '${SOCK_DIR}'
		port = ${port}
		max_connections = 200

		wal_level = logical
		track_commit_timestamp = on
		max_worker_processes = 32
		max_replication_slots = 32
		max_wal_senders = 32

		# 'warning', not 'log'.  log_min_messages orders severities
		# ... WARNING, ERROR, LOG, FATAL, PANIC -- LOG sits *above* ERROR, so
		# 'log' silently drops every ERROR and WARNING from the server log.
		# That is how a spock apply worker that failed instantly, 360 times
		# in a row, showed up as nothing but "exiting with error" with no
		# error attached.  A rig must not hide the diagnosis it exists to
		# produce.
		log_min_messages = 'warning'
		log_min_error_statement = 'error'
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

		# The budget every synchronisation wait is measured against.
		#
		# Written to postgresql.conf and not applied with ALTER SYSTEM so it
		# is in force before the first connection, and so it lands in the new
		# data directory too -- pg_upgrade does not carry it, but init_node
		# writes this same file for the target cluster.
		#
		# On a 5.x node spock.sync_timeout is not a registered GUC at all: it
		# arrived in 6.x.  It still works here, because the spock GUC prefix
		# is not reserved (no MarkGUCPrefixReserved), so the name is accepted
		# as a placeholder.  The rig's own readers (effective_sync_budget and
		# proc_sync_budget) go through pg_settings and current_setting, so
		# both halves of the cluster honour this identically, which is what a
		# rolling upgrade needs.
		spock.sync_timeout = ${SPOCK_SYNC_TIMEOUT}
	EOF

	# PostgreSQL gained output_plugin_libraries -- an allowlist of libraries
	# that may be named as a logical decoding output plugin -- and it arrived
	# in minor releases, so `pg16_ref=tag` picks it up on a tag bump.  Its
	# default is "pgoutput, test_decoding", which does not include
	# spock_output, and a slot cannot then be created with that plugin at all.
	#
	# The symptom is remote from the cause: sub_create succeeds, the apply
	# worker dies instantly and forever, no slot ever appears on the provider,
	# and local_sync_status stays at 'i' until the join times out.
	#
	# Probed rather than tested against the major version: on a server
	# predating the GUC, writing an unrecognised parameter stops the
	# postmaster.  A probe that cannot run is a broken install, not an old
	# server, so that is fatal here rather than left to become a slot
	# creation failure once the mesh is being wired up.
	local described
	described="$("${prefix}/bin/postgres" --describe-config 2>&1)" \
		|| fail "could not run postgres --describe-config at ${prefix}: ${described}" 11

	# Matched with a here-string, not `printf ... | grep -q`: grep -q exits at
	# the first match, printf then takes EPIPE on the rest of the ~60kB
	# listing, and under `set -o pipefail` that fails the whole pipeline --
	# so the probe would report "GUC absent" precisely when it is present,
	# but only on servers whose listing exceeds the pipe buffer.
	if grep -q '^output_plugin_libraries' <<<"${described}"; then
		cat >>"${data}/postgresql.conf" <<-EOF
			# spock_output is not in the built-in allowlist; without this
			# entry no spock replication slot can be created.
			output_plugin_libraries = 'pgoutput, test_decoding, spock_output'
		EOF
	fi

	# Trust over the shared Unix socket.  There is no TCP listener, so this
	# stays local-only, and spock's own connections need a password-free
	# path.
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
	write_node_conf "${data}" "${port}" "${prefix}"
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
		# Not fatal -- this is called from the exit path, where refusing to
		# finish would lose the verdict -- but never silent: a server that
		# will not stop leaves a data directory the next run cannot reuse.
		"${prefix}/bin/pg_ctl" -D "${data}" -m fast -w -t 120 stop \
			|| say "WARNING: ${node} (${variant}) did not stop; ${data} may be locked"
	fi
}

# Stop whatever is running, for every node and every variant it has ever
# used.  Safe to call at any exit point: a node that never started, or a
# data directory that was never created, is simply skipped.
# Stop every server this rig has ever left running under BASE_DIR.
#
# Driven from the pgdata/ directories themselves, NOT from ${NODES} x
# ${ALL_VARIANTS}.  That cross product is only this run's matrix, and a
# leftover postmaster is by definition from a different one: it holds the port
# and the socket file, and the run then dies at the first pg_ctl start with
# "lock file already exists", pointing at the symptom.
#
# Found the hard way.  A --stop-after upgrade run left n1 up on pg19-v6; the
# next --stop-after join run had no v6 in its matrix at all, so the sweep did not
# look there, and n1 could not start.  The same hole opens whenever OLD_MAJORS
# or the node count changes between runs -- pgdata/ here holds n1-pg16-v5 and
# n3-* from earlier matrices.
#
# The directory name is the schema: <node>-<variant>, e.g. n1-pg19-v6, and
# node names are n<digits>, so the first hyphen splits it unambiguously.
stop_everything() {
	local d base node variant prefix pid
	for d in "${BASE_DIR}"/pgdata/*/; do
		[ -d "${d}" ] || continue           # unmatched glob
		[ -f "${d}postmaster.pid" ] || continue
		base="$(basename "${d}")"
		node="${base%%-*}"
		variant="${base#*-}"
		prefix="$(prefix_for "${variant}")"

		# No pg_ctl means the install this cluster was built with is gone --
		# but the postmaster is still there holding the port, so say so with
		# the pid rather than skipping in silence.
		if [ ! -x "${prefix}/bin/pg_ctl" ]; then
			pid="$(head -1 "${d}postmaster.pid" 2>/dev/null)" || pid="?"
			say "WARNING: ${base} has a running postmaster (pid ${pid}) but no pg_ctl at ${prefix}/bin;"
			say "         it will keep its port. Stop it by hand: kill ${pid}"
			log "stop_everything: no pg_ctl for ${variant}; ${base} left running (pid ${pid})"
			continue
		fi

		log "stop_everything: stopping ${node} (${variant})"
		"${prefix}/bin/pg_ctl" -D "${d%/}" -m fast -w -t 120 stop \
			|| say "WARNING: pg_ctl could not stop ${base}; a later start may fail on its port"
	done
	return 0
}

# Bound to EXIT so shutdown runs on normal completion and on every failure
# path, including the ERR trap (which exits before main()'s tail runs).
cleanup_nodes() {
	if [ "${KEEP_RUNNING}" -eq 0 ]; then
		stop_everything
	else
		log "--stop-after set: leaving nodes running. Sockets under ${SOCK_DIR}"
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

# The effective synchronisation budget on a node, as a bare integer, or
# ABSENT.
#
# Two sources, because one is not enough.  On a node whose Spock registers
# spock.sync_timeout (6.x) pg_settings.setting holds the value in seconds,
# already unit-normalised.  On a 5.x node the name is not a registered GUC at
# all and survives only as an unreserved-prefix placeholder -- and
# add_placeholder_variable() stamps every placeholder with GUC_NO_SHOW_ALL,
# which pg_show_all_settings() skips.  So the placeholder is readable with
# SHOW and current_setting() and simply is not in pg_settings.
#
# current_setting() alone would not do either: for a registered GUC declared
# GUC_UNIT_S it pretty-prints ("30min"), while for the placeholder it returns
# the literal the rig wrote.  pg_settings first, current_setting second, is
# the combination that yields a bare number on both.
effective_sync_budget() {
	local node="$1"
	psql_maint "${node}" -At -c \
		"SELECT coalesce(
		            (SELECT setting FROM pg_settings
		              WHERE name = 'spock.sync_timeout'),
		            current_setting('spock.sync_timeout', true),
		            'ABSENT');"
}

# Is the budget actually in force on this node?
#
# The value is read back rather than assumed applied.  On a 5.x node
# spock.sync_timeout is not a registered GUC at all -- it survives only as an
# unreserved-prefix placeholder -- so "it was written to postgresql.conf" and
# "anything can read it" are genuinely different questions, and
# effective_sync_budget() is what reconciles them.
#
# The consumer is the documented procedure: proc_sync_budget() resolves every
# wait in it from this value.  Step 3's own initial sync is bounded by
# JOIN_TIMEOUT instead, from outside.
assert_sync_budget_visible() {
	local node="$1" got

	got="$(effective_sync_budget "${node}")" \
		|| fail "${node}: could not read spock.sync_timeout" 12

	if [ "${got}" = "ABSENT" ]; then
		fail "${node}: spock.sync_timeout is not set at all, so every wait in the documented procedure falls back to the 180s built-in. The GUC prefix may now be reserved (MarkGUCPrefixReserved), in which case postgresql.conf is no longer a way to set it." 12
	fi
	if [ "${got}" != "${SPOCK_SYNC_TIMEOUT}" ]; then
		fail "${node}: spock.sync_timeout reads back as '${got}', not the ${SPOCK_SYNC_TIMEOUT} that was written" 12
	fi
	log "${node}: spock.sync_timeout = ${got}s, in force"
	say "synchronisation budget ${got}s (spock.sync_timeout)"
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

# CREATE EXTENSION spock and, optionally, register the Spock node.  The
# `create_node` argument exists because step 1 registers the first node before
# there is anything to join, while the joiners register theirs in step 3.
setup_spock_node() {
	local node="$1" create_node="$2"
	local logf="${LOG_DIR}/${node}-spock-bootstrap.log"
	log "${node}: [spock-bootstrap] extensions (node_create=${create_node}) -> ${logf}"
	{
		psql_on "${node}" -c "CREATE EXTENSION IF NOT EXISTS spock;"
		# pgcrypto is for ACE: its block hashing calls digest(), and without
		# the extension every table-diff and repset-diff fails on a missing
		# function rather than on anything about the cluster.  Only functions,
		# no relations, so it does not enter any of the rig's own comparisons.
		psql_on "${node}" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto;"
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
# what matters is the ~700 relations it leaves behind.
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


# Populate the target database, either for real or -- under
# Returns the regression
# suite's own status, which the caller is expected to tolerate; only the
# hang case (124) is fatal, and that is checked by the caller.
# Populate the target database with the core regression suite.  Returns the
# suite's own status, which the caller is expected to tolerate -- spock is
# preloaded and auto-DDL perturbs a lot of expected output.  Only the hang
# case (124) is fatal, and that is checked by the caller.
populate_complex_database() {
	local node="$1"

	log "${node}: make installcheck-parallel (cap ${INSTALLCHECK_TIMEOUT}s)"
	local rc=0
	run_phase "${node}" installcheck \
		run_with_timeout "${INSTALLCHECK_TIMEOUT}" _do_installcheck "${node}" \
		|| rc=$?
	return "${rc}"
}

# Tables created before the Spock node existed -- or that auto-DDL declined
# to pick up -- are not in any replication set, so the initial sync would copy
# their structure but none of their rows.  Add every ordinary table explicitly:
# ones with a usable key go to `default`, the rest to
# `default_insert_only`, which is the same split spock's auto-DDL applies.
_do_repset_add_all() {
	local node="$1"
	# Two arguments, one session: psql runs -c and -f in order on the same
	# connection, so the SET is visible to the DO block.  spock_rig is an
	# unreserved GUC prefix, so the name is accepted as a placeholder.
	#
	# Done this way rather than by interpolating the value into the SQL,
	# because the heredoc has to stay single-quoted: it contains $rs$
	# dollar-quoting and a LIKE pattern with an escaped underscore
	# ('pg\_%'), both of which an interpolating heredoc would mangle.
	psql_on "${node}" \
		-c "SET spock_rig.exclude_generated = '${OLD_SPOCK_SYNCS_GENERATED:-no}';" \
		-f - <<-'SQL'
		DO $rs$
		DECLARE
			r      record;
			s      record;
			added  int := 0;
			already int := 0;
			skipped int := 0;
			generated int := 0;
			removed int := 0;
			closure int := 0;
			i      int;
			member int := 0;
			left_over int := 0;
			target text;
			exclude_generated bool;
		BEGIN
			-- The rig sets spock_rig.exclude_generated to 'yes' when the
			-- provider's Spock DOES keep generated columns out of the sync
			-- path, i.e. when there is nothing to work around.  Anything else
			-- -- including the GUC being absent -- errs towards excluding,
			-- since a missing exclusion costs the whole run at step 3 while an
			-- unnecessary one only narrows the payload.
			exclude_generated :=
				coalesce(current_setting('spock_rig.exclude_generated', true), 'no')
				IS DISTINCT FROM 'yes';
			FOR r IN
				SELECT c.oid::regclass AS rel,
				       (c.relreplident = 'f'
				        OR EXISTS (SELECT 1 FROM pg_index i
				                   WHERE i.indrelid = c.oid
				                     AND (i.indisprimary OR i.indisreplident)))
				         AS has_key,
				       EXISTS (SELECT 1 FROM pg_attribute a
				               WHERE a.attrelid = c.oid
				                 AND a.attnum > 0
				                 AND NOT a.attisdropped
				                 AND a.attgenerated <> '')
				         AS has_generated
				FROM pg_class c
				JOIN pg_namespace n ON n.oid = c.relnamespace
				WHERE c.relkind = 'r'
				  AND c.relpersistence = 'p'
				  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'spock')
				  AND n.nspname NOT LIKE 'pg\_%'
				ORDER BY 1
			LOOP
				-- A table with a generated column is left out, loudly -- but
				-- only when the provider cannot sync it.
				--
				-- spock's initial sync issues COPY <tab> (<all columns>) TO
				-- stdout, and PostgreSQL rejects a COPY that names a
				-- generated column: "column ... is a generated column".  The
				-- apply worker then reports "initialization failed during
				-- nonrecoverable step (d)" and is restarted every 5 seconds
				-- forever, so the join waits out its whole budget on a state
				-- the server itself calls nonrecoverable.
				--
				-- The core regression database has several such tables
				-- (gtest*), so with them in a replication set this rig cannot
				-- get past step 3 at all and tests nothing.  They are named
				-- in the notice below rather than dropped silently: the
				-- exclusion is a workaround for a defect in one branch, not a
				-- property of the scenario, and it does reduce coverage.
				--
				-- Fixed on main by 3387e1a1 ("Fix replication errors with
				-- tables containing generated columns"), which is NOT in
				-- v5_STABLE -- hence the probe rather than an unconditional
				-- exclusion.
				IF r.has_generated AND exclude_generated THEN
					generated := generated + 1;
					-- Declining to ADD it is not enough, and assuming it was
					-- cost a full-payload run.  Auto-DDL is on while the
					-- regression suite builds the database, so spock has
					-- already put every table it watched being created into a
					-- replication set -- generated columns and all -- long
					-- before this function runs.  So the exclusion was a
					-- no-op for exactly the tables it was written for: the
					-- log said "EXCLUDED gtest0" while gtest0 sat in
					-- `default`, and the first initial sync died on
					--   COPY "public"."gtest0" ("a","b") TO stdout
					--   ERROR: column "b" is a generated column
					-- after which the apply worker retried the step the
					-- server itself calls nonrecoverable, every five seconds,
					-- until the whole synchronisation budget was gone.
					--
					-- Observed as: added 0, already-member 509, excluded 33,
					-- yet 624 tables in replication sets.
					--
					-- Existing memberships are cleared by the sweep after
					-- this loop, not here.  This loop is filtered to
					-- relkind='r', relpersistence='p' and a handful of
					-- schemas, and removing only what it happens to visit
					-- left one table behind on the first attempt -- caught by
					-- the post-condition below, which is why that assertion
					-- exists.  The sweep walks the membership table itself,
					-- so no filter of this loop's can hide anything from it.
					RAISE NOTICE
						'repset_add_all: EXCLUDED % -- it has a generated column, which this spock cannot COPY during initial sync',
						r.rel;
					CONTINUE;
				END IF;

				-- Already in a replication set is the normal case, not a
				-- failure: auto-DDL is on while the payload is created, so
				-- anything created after the Spock node exists is already a
				-- member.  Counted separately from a genuine error, because
				-- the two used to share the `skipped` bucket -- and then the
				-- "added nothing" guard below could not tell "every table was
				-- already covered" from "every call failed" and reported a
				-- fully-populated replication set as a rig failure.
				IF EXISTS (SELECT 1 FROM spock.replication_set_table
				           WHERE set_reloid = r.rel) THEN
					already := already + 1;
					CONTINUE;
				END IF;

				target := CASE WHEN r.has_key THEN 'default'
				               ELSE 'default_insert_only' END;
				BEGIN
					PERFORM spock.repset_add_table(target, r.rel);
					added := added + 1;
				EXCEPTION WHEN others THEN
					-- A relation spock declines to replicate.  Not fatal --
					-- but named, with the server's own message, rather than
					-- silently absorbed: a table missing from a replication
					-- set surfaces much later as "the nodes disagree", which
					-- points at the wrong thing entirely.
					skipped := skipped + 1;
					RAISE WARNING 'repset_add_all: could NOT add % to %: %',
						r.rel, target, SQLERRM;
				END;
			END LOOP;

			-- The member count and the summary line are both emitted after
			-- the sweep below, so they describe the state this function
			-- actually leaves behind rather than the state halfway through.

			-- The sweep.  Driven from spock.replication_set_table rather
			-- than from pg_class, so it reaches every member whatever its
			-- relkind, persistence or schema -- the loop above is filtered
			-- three ways and each filter is a place for a generated-column
			-- table to hide.  One did: 33 were removed by the loop and the
			-- post-condition still found a 34th.
			IF exclude_generated THEN
				FOR s IN
					SELECT rs.set_name,
					       rt.set_reloid::regclass AS rel
					FROM spock.replication_set_table rt
					JOIN spock.replication_set rs ON rs.set_id = rt.set_id
					WHERE EXISTS (SELECT 1 FROM pg_attribute a
					              WHERE a.attrelid = rt.set_reloid
					                AND a.attnum > 0
					                AND NOT a.attisdropped
					                AND a.attgenerated <> '')
					ORDER BY 2, 1
				LOOP
					PERFORM spock.repset_remove_table(s.set_name, s.rel);
					removed := removed + 1;
					RAISE NOTICE
						'repset_add_all: REMOVED % from % -- it has a generated column, which this spock cannot COPY during initial sync',
						s.rel, s.set_name;
				END LOOP;
			END IF;

			-- Referential closure.
			--
			-- Removing a table from the replication sets is not a local
			-- decision: spock's structure sync restores the WHOLE schema on
			-- the subscriber, foreign keys included, but only copies rows for
			-- tables that are in a replication set.  So a replicated table
			-- whose foreign key points at an excluded one gets its rows while
			-- the table it references stays empty, and the restore fails when
			-- it re-adds the constraint:
			--
			--   ERROR: insert or update on table "gtest23q" violates foreign
			--          key constraint "gtest23q_b_fkey"
			--   DETAIL: Key (b)=(2) is not present in table "gtest23p".
			--
			-- gtest23p has a generated column and had just been excluded;
			-- gtest23q does not, and referenced it.  The join then failed at
			-- nonrecoverable step (c) -- structure sync -- rather than (d),
			-- and was retried every five seconds like every other
			-- nonrecoverable step.
			--
			-- So the exclusion is closed transitively over foreign keys: a
			-- referrer of an excluded table is excluded too.  Looped, because
			-- excluding a referrer can strand its own referrers, and bounded
			-- so a cycle cannot spin here.
			IF exclude_generated THEN
				FOR i IN 1..10 LOOP
					closure := 0;
					FOR s IN
						SELECT DISTINCT rs.set_name,
						       rt.set_reloid::regclass AS rel
						FROM spock.replication_set_table rt
						JOIN spock.replication_set rs ON rs.set_id = rt.set_id
						JOIN pg_constraint fk ON fk.conrelid = rt.set_reloid
						                     AND fk.contype = 'f'
						WHERE NOT EXISTS (
						          SELECT 1 FROM spock.replication_set_table rt2
						          WHERE rt2.set_reloid = fk.confrelid)
						  AND fk.confrelid <> rt.set_reloid
						ORDER BY 2, 1
					LOOP
						PERFORM spock.repset_remove_table(s.set_name, s.rel);
						removed := removed + 1;
						closure := closure + 1;
						RAISE NOTICE
							'repset_add_all: REMOVED % from % -- it has a foreign key into a table that is not replicated, and structure sync would fail re-adding the constraint',
							s.rel, s.set_name;
					END LOOP;
					EXIT WHEN closure = 0;
				END LOOP;
			END IF;

			SELECT count(*) INTO member FROM spock.replication_set_table;

			-- Assert the OUTCOME, not the intent.  The version before this
			-- reported "EXCLUDED gtest0" and left gtest0 replicating, and
			-- nothing downstream noticed until the initial sync failed on a
			-- step the server itself calls nonrecoverable -- then retried it
			-- every five seconds until the synchronisation budget ran out.
			-- Counting what is actually still there keeps the claim and the
			-- catalog from drifting apart again, and names the offenders so
			-- the next gap in the sweep is a one-line diagnosis.
			IF exclude_generated THEN
				SELECT count(*) INTO left_over
				FROM spock.replication_set_table rt
				WHERE EXISTS (SELECT 1 FROM pg_attribute a
				              WHERE a.attrelid = rt.set_reloid
				                AND a.attnum > 0
				                AND NOT a.attisdropped
				                AND a.attgenerated <> '');
				IF left_over <> 0 THEN
					FOR s IN
						SELECT rt.set_reloid::regclass AS rel,
						       c.relkind, c.relpersistence
						FROM spock.replication_set_table rt
						JOIN pg_class c ON c.oid = rt.set_reloid
						WHERE EXISTS (SELECT 1 FROM pg_attribute a
						              WHERE a.attrelid = rt.set_reloid
						                AND a.attnum > 0
						                AND NOT a.attisdropped
						                AND a.attgenerated <> '')
						ORDER BY 1
					LOOP
						RAISE WARNING 'repset_add_all: STILL A MEMBER: % (relkind=%, relpersistence=%)',
							s.rel, s.relkind, s.relpersistence;
					END LOOP;
					RAISE EXCEPTION
						'repset_add_all: % table(s) with a generated column are still in a replication set; this spock cannot COPY them, so the first initial sync would fail on a nonrecoverable step',
						left_over;
				END IF;
			END IF;

			RAISE NOTICE 'repset_add_all: added %, already-member %, failed %, generated-column tables % (% membership(s) removed); % table(s) in replication sets',
				added, already, skipped, generated, removed, member;

			-- The gate is on what is in the replication sets when this
			-- finishes, not on how many calls this particular invocation
			-- made.  An empty replication set is what matters: the
			-- node-agreement check downstream would then compare two empty
			-- snapshots and pass, and step 9's `synchronize_data := false`
			-- would be justified by a requirement 5 that counted nothing.
			IF member = 0 THEN
				RAISE EXCEPTION
					'repset_add_all: no table is in any replication set (added %, already %, failed %, excluded %)',
					added, already, skipped, generated;
			END IF;
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

# Count the lines of a file matching an ERE, on stdout.
#
# awk and not `grep -c`, deliberately.  grep exits 1 when nothing matched and
# 2 when it could not read the file, and `grep -c ... || true` -- which is what
# this replaced -- collapses both into "0 matches".  A server log that has gone
# missing then reads as "no crashes".  awk prints 0 for an empty match set and
# fails only when it genuinely cannot read, which is what the caller wants to
# hear about.
count_matching_lines() {
	local pattern="$1" file="$2"
	awk -v re="${pattern}" '$0 ~ re { n++ } END { print n+0 }' "${file}"
}

# The same, for a literal prefix rather than a regex.
#
# Separate because a prefix containing a regex metacharacter cannot be passed
# safely through `awk -v`: the assignment does its own backslash processing, so
# `^node\|` arrives as `^node|` on BSD awk -- a trailing alternation, which is
# a regex error, and every count came back empty.  index() takes the string as
# a string and has no such problem.
count_lines_with_prefix() {
	local prefix="$1" file="$2"
	awk -v p="${prefix}" 'index($0, p) == 1 { n++ } END { print n+0 }' "${file}"
}

report_crash_markers() {
	local node="$1" slog
	slog="${LOG_DIR}/${node}-$(node_variant "${node}")-server.log"
	[ -f "${slog}" ] || return 0

	local hits
	hits="$(count_matching_lines "${CRASH_PATTERN}" "${slog}")" \
		|| { say "${node}: could not scan ${slog} for crash markers"; return 1; }
	[ "${hits}" -eq 0 ] && return 0

	say "${node}: ${hits} crash marker(s) in the server log:"
	grep -E "${CRASH_PATTERN}" "${slog}" | head -3 | sed 's/^/    /' >&2
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

# A scalar query on a node, or the empty string if it errors out.  Never lets
# a psql failure escape, so one broken probe cannot abort a health check
# part-way and lose the probes after it -- every caller treats "" as a FAIL.
# The error text goes to the health log rather than to /dev/null: "" on its own
# says a probe failed but not why.
_q() {
	local node="$1" sql="$2"
	psql_on "${node}" -At -c "${sql}" 2>>"${HEALTH_LOG:-${MAIN_LOG}}" || echo ""
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

	# 6b. This node publishes something.
	#
	#     Every check above is about what arrives here; none is about what
	#     leaves.  A node with no table in any replication set passes all of
	#     them and still sends none of its own writes anywhere, because
	#     replication-set membership is per-node catalog state that structure
	#     sync does not carry.  It went unnoticed for a whole run.
	#
	#     Only asserted where the node is part of a mesh: before step 3 the
	#     first node legitimately has subscriptions to nobody.
	if [ "${want_subs}" != "0" ]; then
		got="$(_q "${node}" \
			"SELECT count(*) FROM spock.replication_set r
			 JOIN spock.replication_set_table t ON t.set_id = r.set_id")"
		if [ -n "${got}" ] && [ "${got}" != "0" ]; then
			_health PASS "${node}: ${got} table membership(s) in replication sets"
		else
			_health FAIL "${node}: ${got:-no} table(s) in any replication set -- it subscribes to the mesh and publishes nothing"; bad=1
		fi
	fi

	# 7. Nothing has been thrown into the exception log -- an apply error
	#    that `exception_behaviour = discard` swallowed still lands here.
	got="$(_q "${node}" 'SELECT count(*) FROM spock.exception_log')"
	if [ "${got}" = "0" ]; then
		_health PASS "${node}: spock.exception_log empty"
	else
		_health FAIL "${node}: spock.exception_log has ${got} row(s)"; bad=1
		# Detail for a probe that has already failed; if the dump itself
		# cannot run that is recorded too, not swallowed.
		psql_on "${node}" -c \
			"SELECT relname, operation, error_message FROM spock.exception_log LIMIT 20;" \
			>>"${HEALTH_LOG}" 2>&1 \
			|| echo "(could not read spock.exception_log)" >>"${HEALTH_LOG}"
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
	local slog
	slog="${LOG_DIR}/${node}-$(node_variant "${node}")-server.log"
	if [ -f "${slog}" ]; then
		local hits
		if ! hits="$(count_matching_lines "${CRASH_PATTERN}" "${slog}")"; then
			_health FAIL "${node}: could not scan ${slog} for crash markers"; bad=1
		elif [ "${hits}" -eq 0 ]; then
			_health PASS "${node}: no crash markers in the server log"
		else
			_health FAIL "${node}: ${hits} crash marker(s) in ${slog}"; bad=1
			grep -n -E "${CRASH_PATTERN}" "${slog}" | head -20 >>"${HEALTH_LOG}"
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

# Shared WHERE clause for both snapshots.  An extension's own relations are
# excluded: the spock schema changes shape between 5.x and 6.x, which says
# nothing about whether the *user's* database survived.  spock_health_* are the DDL probe's per-node
# scratch schemas.
#
# "An extension's own" means a relation that is an extension member AND lives
# in that extension's schema.  The qualifier is load-bearing, and its absence
# produced a false FAIL at exit 21 -- the most serious verdict this mode can
# reach -- on the first full-payload run.
#
# The clause used to be a bare `deptype = 'e'`, which excluded ANY relation
# that had been made a member of ANY extension.  On this cluster that is not a
# stable property of a table: ordinary regression tables in `public` end up as
# members of `spock`, and WHICH tables varies from node to node and from run
# to run --
#
#   n1: public.float4_tbl, public.money_data, public.num_data,
#       public.num_exp_mul  -> members of spock
#   n2: public.complex      -> member of spock
#
# -- which is a product bug in its own right (see
# proc_check_absorption).  Its effect here was subtler than a wrong
# answer: it made the population being compared node-dependent.  Four tables
# silently left n1's snapshot and stayed in n2's, and the rig reported
# "replicated tables diverged beyond the requirement-0 baseline" about a
# cluster whose rows were identical.
#
# Keying on the schema keeps every user table in the comparison, wherever some
# extension has managed to claim it, while still leaving spock's own catalogs
# out.
_signature_where() {
	local scope="$1" alias_ns="$2"
	cat <<-SQL
		  AND ${alias_ns}.nspname NOT IN ('pg_catalog','information_schema','spock')
		  AND ${alias_ns}.nspname NOT LIKE 'pg\\_%'
		  AND ${alias_ns}.nspname NOT LIKE 'spock\\_health%'
		  AND NOT EXISTS (SELECT 1 FROM pg_depend d
		                  JOIN pg_extension e ON e.oid = d.refobjid
		                  WHERE d.objid = c.oid AND d.deptype = 'e'
		                    AND e.extnamespace = c.relnamespace)
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
		return 1
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
		return 1
	fi

	: >"${out}"
	local t n
	for t in ${tables}; do
		# -1 is a sentinel that shows up as a difference in the comparison
		# rather than as a silent match; the reason goes to the main log.
		n="$(psql_on "${node}" -At -c "SELECT count(*) FROM ${t}" 2>>"${MAIN_LOG}")" \
			|| n=-1
		[ -n "${n}" ] || n=-1
		printf '%s=%s\n' "${t}" "${n}" >>"${out}"
	done
}

# Take both snapshots under one tag and echo the relation count, so callers
# can assert the payload is non-trivial before drawing conclusions from it.
# Take both snapshots under one tag, echo the relation count, and FAIL if
# either snapshot could not be taken.
#
# Both halves used to swallow a psql failure into an empty file and a zero
# status, so two snapshots that could not be taken diffed as "identical" --
# and that diff is the evidence behind the "database survived pg_upgrade"
# verdict.  A comparison of nothing against nothing must not be able to pass.
capture_signature() {
	local node="$1" tag="$2" scope="$3"
	local rc=0
	capture_relations "${node}" "${tag}" "${scope}" || rc=1
	capture_rowcounts "${node}" "${tag}" "${scope}" || rc=1
	local rels rows
	rels="$(wc -l <"${REPORT_DIR}/${tag}-relations.txt" | tr -d ' ')"
	rows="$(wc -l <"${REPORT_DIR}/${tag}-rowcounts.txt" | tr -d ' ')"
	log "signature ${tag}: ${rels} relations, ${rows} counted tables (scope=${scope}) rc=${rc}"
	printf '%s' "${rels}"
	if [ "${rc}" -ne 0 ]; then
		log "signature ${tag}: INCOMPLETE -- a snapshot query failed on ${node}"
		return 1
	fi
	# A snapshot of nothing compares equal to another snapshot of nothing.
	# Under `repset` scope an empty answer can be legitimate only if no table
	# is replicated at all, which repset_add_all_tables already refuses to
	# leave behind; under `all` scope it never can be.
	if [ "${rels}" -eq 0 ]; then
		log "signature ${tag}: no relations on ${node} at scope=${scope}"
		return 1
	fi
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
# Step 3: roles
# ---------------------------------------------------------------------------

# Spock's structure sync restores the source's schema, GRANTs and ownership
# included, so every role named in it has to exist on the joiner first or the
# restore fails.  The regression suite creates and drops a lot of roles and
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

	# No ON_ERROR_STOP: a role that already exists is expected to fail and the
	# rest still have to be applied.  psql's own exit status is not waved
	# through, though -- without ON_ERROR_STOP it is non-zero only when psql
	# could not connect or could not read its input, which is exactly the case
	# where nothing was applied at all and the structure sync is about to fail
	# on a missing role instead.
	local out
	out="$(printf '%s\n' "${ddl}" | PGPASSWORD="" "${prefix}/bin/psql" \
		-X -h "${SOCK_DIR}" -p "${port}" -U "${DBUSER}" -d postgres 2>&1)" \
		|| { printf '%s\n' "${out}"
		     echo "psql could not apply any role DDL on ${dst_node}"
		     return 1; }
	printf '%s\n' "${out}"
	echo "----- roles on ${dst_node}: $(printf '%s\n' "${out}" | awk '/^CREATE ROLE/ { n++ } END { print n+0 }') created," \
	     "$(printf '%s\n' "${out}" | awk '/already exists/ { n++ } END { print n+0 }') already present -----"
}

sync_roles() {
	run_phase "$2" sync-roles _do_sync_roles "$1" "$2"
}

# ---------------------------------------------------------------------------
# Step 3: attach a node with spock's own primitives
# ---------------------------------------------------------------------------

# Step 3 is scaffolding: what the upgrade procedure is tested against is a
# healthy old-major mesh holding a complex database, and how that mesh came to
# exist is not part of what is being tested.  It is built from spock's own
# API, which is the same shape on both sides of the upgrade.

# The one subscription that carries the database across.
#
# synchronize_structure pg_dumps the provider's schema and restores it here;
# synchronize_data then COPYs every table the provider replicates.  Both are
# on for exactly this edge and off for every other one, because after it
# finishes each node already holds the same rows -- a second copy would be
# waste, and a concurrent one a race.
#
# spock.sub_wait_for_sync() blocks until the initial sync is complete, with no
# timeout of its own, so the caller caps it.  Waiting is not optional: without
# it the next edge would be created against a half-populated node.
_do_seed_sub() {
	local src_node="$1" joiner="$2"
	local subname="sub_${src_node}_${joiner}"

	echo "----- ${joiner}: sub_create ${subname} (structure + data) -----"
	psql_on "${joiner}" -c "
		SELECT spock.sub_create(
			subscription_name     := '${subname}',
			provider_dsn          := '$(dsn_for_node "${src_node}")',
			synchronize_structure := true,
			synchronize_data      := true,
			forward_origins       := '{}'::text[],
			enabled               := true);" || return 1

	echo "----- ${joiner}: waiting for ${subname} to finish its initial sync -----"
	psql_on "${joiner}" -c "SELECT spock.sub_wait_for_sync('${subname}');" || return 1

	psql_on "${joiner}" -c \
		"SELECT subscription_name, status, provider_node
		 FROM spock.sub_show_status();"
}

# The remaining edges, in both directions, between a joiner and the nodes that
# were already attached.
#
# Both sync flags off: the joiner's data came from the source, and every other
# node holds the same rows, so there is nothing to copy.  This is only true
# because nothing writes to the cluster during step 3 -- the regression suite
# has finished and the witness table does not exist yet.  A workload running
# here would need each edge's initial sync, or a sync_event wait per edge, and
# neither is what this rig is for.
#
# `${attached}` excludes the source node for the joiner's own direction: that
# subscription is the seed one, already created.
_do_join_edges() {
	local joiner="$1" src_node="$2"; shift 2
	local attached="$*"
	local peer subname

	for peer in ${attached}; do
		[ "${peer}" = "${joiner}" ] && continue

		if [ "${peer}" != "${src_node}" ]; then
			subname="sub_${peer}_${joiner}"
			echo "----- ${joiner}: sub_create ${subname} -----"
			psql_on "${joiner}" -c "
				SELECT spock.sub_create(
					subscription_name     := '${subname}',
					provider_dsn          := '$(dsn_for_node "${peer}")',
					synchronize_structure := false,
					synchronize_data      := false,
					forward_origins       := '{}'::text[],
					enabled               := true);" || return 1
		fi

		subname="sub_${joiner}_${peer}"
		echo "----- ${peer}: sub_create ${subname} -----"
		psql_on "${peer}" -c "
			SELECT spock.sub_create(
				subscription_name     := '${subname}',
				provider_dsn          := '$(dsn_for_node "${joiner}")',
				synchronize_structure := false,
				synchronize_data      := false,
				forward_origins       := '{}'::text[],
				enabled               := true);" || return 1
	done
}

# Attach one node.  The order is load-bearing:
#
#   1. the seed subscription, which brings the schema and the data;
#   2. the joiner's own replication sets, so it publishes as well as
#      subscribes -- structure sync carries tables, not repset membership,
#      which is per-node catalog state and does not replicate;
#   3. the remaining edges, once there is something on this node to publish.
#
# Step 2 is easy to leave out, and leaving it out produces a cluster that
# passes every subscription-level check while the joiner replicates nothing
# outward -- caught, eventually, by a later phase tripping over an empty
# `default` set.
attach_node() {
	local src_node="$1" joiner="$2"; shift 2
	local attached="$*"
	local rc=0

	run_phase "${joiner}" join-seed-sub \
		run_with_timeout "${JOIN_TIMEOUT}" \
		_do_seed_sub "${src_node}" "${joiner}" || rc=$?
	if [ "${rc}" -eq 124 ]; then
		say "${joiner}: initial sync from ${src_node} still running after ${JOIN_TIMEOUT}s -- gave up"
		log "${joiner}: initial sync exceeded ${JOIN_TIMEOUT}s"
		return "${rc}"
	fi
	[ "${rc}" -eq 0 ] || return "${rc}"

	repset_add_all_tables "${joiner}" \
		|| { say "${joiner}: could not populate its replication sets"; return 1; }
	mirror_repsets "${src_node}" "${joiner}" || return 1
	assert_publishes "${joiner}" || return 1

	run_phase "${joiner}" join-edges \
		_do_join_edges "${joiner}" "${src_node}" ${attached} || return 1
}

# Make the joiner's replication-set membership match the source's, and say
# what had to change.
#
# repset_add_all_tables() cannot get all of it right, because the two nodes
# reached their membership differently.  On the source, auto-DDL filed each
# table as the regression suite created it.  On the joiner it filed them as
# structure sync restored them -- and pg_dump splits a primary key out of
# CREATE TABLE into a separate ALTER TABLE ... ADD CONSTRAINT, so at the moment
# the joiner sees the CREATE the table has no key and lands in
# `default_insert_only`.  The PK arrives a moment later and nothing moves it
# back; the rig's classifier will not either, since it treats "already a
# member" as done without asking whether the set is the right one.  In the core
# regression database that is the partitioned roots -- fkpart*,
# regress_indexing.pk, trigger_parted.
#
# Corrected against the source rather than recomputed: the source is the
# definition of what this cluster replicates.  Every correction is named in the
# log, because a silent overwrite is what let the asymmetry survive unnoticed.
# Set membership only: this rig never sets column lists or row filters, and a
# mirror that dropped them quietly would be worse than one that says so.
#
# include_partitions := false on both calls, and it is not optional.  Both
# functions default it to TRUE, so a call naming a partitioned root reaches
# every partition too: the removal emptied `default_insert_only` of the root
# AND its partitions, and the matching add then collided with the partitions
# already in `default` -- duplicate key on replication_set_table_pkey, on the
# very first add.  The diff enumerates memberships one at a time, so each call
# must act on exactly the relation it names.
_do_mirror_repsets() {
	local src_node="$1" joiner="$2"
	# The health-probe schemas are per node by design, so they are excluded:
	# comparing them would report a difference the rig itself created.
	local sql="SELECT r.set_name || '|' ||
	                  quote_ident(n.nspname) || '.' || quote_ident(c.relname)
	           FROM spock.replication_set r
	           JOIN spock.replication_set_table t ON t.set_id = r.set_id
	           JOIN pg_class c      ON c.oid = t.set_reloid
	           JOIN pg_namespace n  ON n.oid = c.relnamespace
	           WHERE n.nspname NOT LIKE 'spock\\_health%'
	           ORDER BY 1"
	local src_f="${LOG_DIR}/${joiner}-mirror-src.txt"
	local dst_f="${LOG_DIR}/${joiner}-mirror-dst.txt"

	psql_on "${src_node}" -At -c "${sql}" | sort >"${src_f}" || return 1
	psql_on "${joiner}"   -At -c "${sql}" | sort >"${dst_f}" || return 1

	local extra missing n_extra n_missing set_name tbl
	extra="$(comm -13 "${src_f}" "${dst_f}")"
	missing="$(comm -23 "${src_f}" "${dst_f}")"
	n_extra="$(printf '%s' "${extra}"   | grep -c . )" || n_extra=0
	n_missing="$(printf '%s' "${missing}" | grep -c . )" || n_missing=0

	echo "${src_node}: $(wc -l <"${src_f}") membership(s); ${joiner}: $(wc -l <"${dst_f}")"
	if [ "${n_extra}" = "0" ] && [ "${n_missing}" = "0" ]; then
		echo "${joiner} already agrees with ${src_node} on every replication-set membership"
		return 0
	fi

	# Removals first: a table that moved between sets appears in both lists,
	# and adding before removing would leave it in two.
	if [ "${n_extra}" != "0" ]; then
		echo "----- ${n_extra} membership(s) on ${joiner} that ${src_node} does not have -----"
		printf '%s\n' "${extra}" | sed 's/^/    /'
		while IFS='|' read -r set_name tbl; do
			[ -n "${set_name}" ] || continue
			psql_on "${joiner}" -c \
				"SELECT spock.repset_remove_table('${set_name}', '${tbl}'::regclass,
				                                  include_partitions := false);" \
				|| return 1
		done <<<"${extra}"
	fi
	if [ "${n_missing}" != "0" ]; then
		echo "----- ${n_missing} membership(s) ${src_node} has that ${joiner} lacks -----"
		printf '%s\n' "${missing}" | sed 's/^/    /'
		while IFS='|' read -r set_name tbl; do
			[ -n "${set_name}" ] || continue
			psql_on "${joiner}" -c \
				"SELECT spock.repset_add_table('${set_name}', '${tbl}'::regclass,
				                               include_partitions := false);" \
				|| return 1
		done <<<"${missing}"
	fi

	# Read back.  A mirror that did not take is exactly the failure this
	# function exists to prevent, so it is asserted rather than assumed.
	psql_on "${joiner}" -At -c "${sql}" | sort >"${dst_f}" || return 1
	if ! diff -u "${src_f}" "${dst_f}"; then
		echo "MIRROR FAILED: ${joiner} still disagrees with ${src_node} after correction"
		return 1
	fi
	echo "${joiner} now matches ${src_node} on all $(wc -l <"${src_f}") membership(s)"
}

mirror_repsets() {
	local src_node="$1" joiner="$2"
	run_phase "${joiner}" mirror-repsets _do_mirror_repsets "${src_node}" "${joiner}"
}

# A node that subscribes to everything and publishes nothing looks healthy
# from every angle this rig used to check: its subscriptions replicate, its
# manager worker is attached, its DDL probe round-trips.  What it does not do
# is send anything.  Assert membership directly, right after the point where
# it is established, so the gap is caught where it is created.
assert_publishes() {
	local node="$1" n
	# psql_on, not psql_maint: spock's catalogs live in the replicated
	# database, and the maintenance connection goes to `postgres`, where
	# spock.replication_set does not exist at all.
	n="$(psql_on "${node}" -At -c "
		SELECT count(*) FROM spock.replication_set r
		JOIN spock.replication_set_table t ON t.set_id = r.set_id;")" \
		|| { say "${node}: could not count replication-set membership"; return 1; }
	case "${n}" in
		'' | *[!0-9]*)
			say "${node}: replication-set membership read back as '${n}', which is not a count"
			return 1 ;;
		0)
			say "${node}: no table is in any replication set, so it publishes nothing -- it would subscribe to the mesh and send none of its own writes"
			return 1 ;;
	esac
	log "${node}: ${n} table membership(s) across its replication sets"
	return 0
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
			# A node restarting mid-poll is normal here, so an unreachable
			# node counts as "not there yet" rather than as an error -- but
			# the reason is kept, because the same symptom at the deadline is
			# what the caller has to explain.
			n="$(psql_on "${node}" -At -c \
				"SELECT count(*) FROM spock.sub_show_status()
				 WHERE status IS DISTINCT FROM 'replicating';" \
				2>>"${MAIN_LOG}")" || n=999
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
		# Diagnostic dump, and the node may legitimately be down when it runs
		# -- on the step-3 timeout path, for instance.  The failure lands in
		# the same file, so the log says "unreachable" instead of nothing.
		} >>"${LOG_DIR}/${node}-subscriptions.log" 2>&1 \
			|| echo "(${node} unreachable)" >>"${LOG_DIR}/${node}-subscriptions.log"
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
			1>&2 2>&1 || printf '  (%s not reachable)\n' "${node}" >&2
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
			tail -60 "${LOG_DIR}/${node}-$(node_variant "${node}")-server.log" \
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
		printf '(servers stop on exit; --stop-after keeps them up)\n' >&2
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
#                   pg_restore exit as failure, so the seed subscription never
#                   finishes its initial sync and the join hits JOIN_TIMEOUT.
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
	# A fixup that was
	# genuinely required and did not apply still surfaces loudly: pg_upgrade
	# is the next step and it will say exactly what it choked on.
	local out errors
	out="$(psql_maint_lax "${node}" -f "${adapt_sql}" 2>&1)"
	printf '%s\n' "${out}"
	errors="$(printf '%s\n' "${out}" | awk '/^psql:.*ERROR:/ { n++ } END { print n+0 }')"
	echo "----- AdjustUpgrade: ${errors} statement(s) did not apply -----"
	return 0
}

adapt_for_target() {
	local node="$1" target_variant="$2"
	run_phase "${node}" "adapt-for-${target_variant}" \
		_do_adapt_for_target "${node}" "${target_variant}"
}

_do_pg_upgrade() {
	local node="$1" mode="$2"      # mode: --check or empty for the real run
	local old_variant; old_variant="$(node_to_old_variant "${node}")"
	local old_data;    old_data="$(data_for "${node}" "${old_variant}")"
	local new_data;    new_data="$(data_for "${node}" "${NEW_VARIANT}")"
	local old_bin;     old_bin="$(prefix_for "${old_variant}")/bin"
	local new_bin;     new_bin="$(prefix_for "${NEW_VARIANT}")/bin"
	local stage_port;  stage_port="$(node_to_stage_port "${node}")"
	local stage_old;   stage_old="$(node_to_stage_port_old "${node}")"

	# pg_upgrade scatters its own log files into $PWD; keep that out of the
	# source tree, and out of the caller's working directory.
	mkdir -p "${LOG_DIR}/pg_upgrade-${node}"
	(
		cd "${LOG_DIR}/pg_upgrade-${node}"

		# Echoed so the phase log records which ports were used.  Not
		# cosmetic: -p must NOT be the node's production port, or a peer
		# reconnects to the server pg_upgrade starts and its slot check
		# fails intermittently.  See node_to_stage_port_old().
		echo "----- pg_upgrade ${mode:-(run)} old=-p ${stage_old} new=-P ${stage_port}" \
		     "(production port for ${node} is $(node_to_port "${node}"), deliberately not used here) -----"

		# Copy mode (the default) rather than --link: a failed upgrade must
		# leave the old cluster intact and startable for inspection, and this
		# rig has to be able to restart it to drop replication state.
		# shellcheck disable=SC2086  # $mode is one optional flag
		"${new_bin}/pg_upgrade" ${mode} \
			--no-sync \
			-d "${old_data}" -D "${new_data}" \
			-b "${old_bin}"  -B "${new_bin}" \
			-p "${stage_old}" -P "${stage_port}" \
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

# ===========================================================================
# The documented rolling upgrade
# ===========================================================================
#
# Everything from here to the end of the section implements
# spock-upgrade-procedure-corrected.md literally.  Part 1's numbered
# requirements are checked, Part 2's numbered steps are executed in order,
# one node at a time, and each is named in the log by the number it carries
# in the document, so a failing phase log points straight at the paragraph
# that describes it.
#
# Two questions are answered separately, because they have different
# remedies:
#
#   PROCEDURE  following the document produced a cluster that replicates and
#              whose nodes agree.  A failure here means the procedure does
#              not work as written.
#   DOC        the factual claims the document makes about PostgreSQL and
#              Spock held.  A failure here means the cluster is fine but a
#              sentence in the document is wrong -- and a sentence that is
#              wrong in the reassuring direction is how a procedure that
#              "worked in testing" loses data in production.
#
# Nothing in this section is allowed to convert a failure into silence.
# There is no `|| true` below: a check that cannot run has not passed.

PROC_LOG=""                     # set in proc_init, once LOG_DIR exists
PROC_FINDINGS=0                 # deviations from what the document claims
PROC_FAILURES=0                 # the procedure did not produce a working cluster
PROC_WITNESS_TABLE="public.spock_upgrade_witness"

# The node currently off the write path, if any -- requirement 4 checks the
# rig's own intent against it.  Declared here so `set -u` cannot turn a
# missing assignment into an unbound-variable abort in the middle of a fence.
PROC_WRITE_PATH_OFF=""
# How many subscriptions each node must have: a full mesh, so N-1.  Set for
# real in proc_run_documented_upgrade, once NODE_COUNT is known.
PROC_SUBS_PER_NODE=0

# Rows written per witness batch.  Small on purpose: the point is whether
# they arrive at all, not throughput.
PROC_WITNESS_ROWS=50

# Bytes of WAL in two seconds that count as "idle" for requirement 4.
#
# 16 kB was the first value and it was far too tight: autovacuum on a
# freshly-synced 721-relation database wrote 360 kB in 2 s on a node with no
# client backend at all, so the requirement failed intermittently on the third
# node of a real payload.  A megabyte is generous enough for post-sync
# housekeeping and still small enough that real write traffic blows past it --
# and exceeding it is no longer fatal on its own; see proc_req4_off_write_path.
PROC_IDLE_WAL_BYTES=1048576

# Seconds to wait for Spock to bring its own catalog up to the library
# version after the upgrade (document, step 7).
#
# Deliberately NOT derived from spock.sync_timeout: that GUC bounds a
# *synchronisation* wait between nodes -- a sync event arriving, a peer
# catching up, a subscription starting -- and this is a local startup event
# on one node with no peer involved.  Stretching the GUC over it would make
# a future reader think the two are related.
PROC_EXTENSION_TIMEOUT=180

# ---------------------------------------------------------------------------
# The synchronisation budget: spock.sync_timeout
# ---------------------------------------------------------------------------
#
# Every wait in this section that bounds a whole synchronisation step reads
# its limit from spock.sync_timeout on the node it is waiting on, rather than
# from a number invented by the rig.  Two reasons:
#
#   - it is the knob an operator actually has, so CI and a real cluster are
#     tuned the same way and the collected evidence records the value; and
#   - reading it means the rig notices if a routine ever stops honouring it.
#
# Read from pg_settings and not with SHOW.  spock.sync_timeout is declared
# GUC_UNIT_S, so SHOW pretty-prints it ("3min") while pg_settings.setting
# holds bare seconds.
#
# The GUC was added in 6.x, so a 5.x node does not register it -- and during
# a rolling upgrade the peers doing the waiting are 5.x until their own turn
# comes.  It is honoured there anyway: write_node_conf puts it in every
# postgresql.conf, the spock prefix is unreserved so the name survives as a
# placeholder, and pg_settings is the only place anything ever reads it from.
# The budget is still probed per node and the effective value logged, because
# assuming a setting took effect is exactly how the 180s default came back
# unnoticed once already.
PROC_SYNC_FALLBACK=180

# Does this node register spock.sync_timeout as a real GUC, as opposed to
# carrying it as a placeholder?  Only pg_settings can tell the two apart --
# a placeholder is stamped GUC_NO_SHOW_ALL and never appears there -- and the
# distinction is worth logging, because it is the difference between spock
# honouring the budget itself and the rig's readers being the only consumers.
proc_has_sync_timeout() {
	local node="$1" n
	if ! n="$(proc_q "${node}" "
			SELECT count(*) FROM pg_settings WHERE name = 'spock.sync_timeout';")"; then
		return 1
	fi
	[ "${n}" != "0" ]
}

# The budget, in seconds, for one synchronisation wait on this node.
# Precedence: an explicit environment override, then the node's own
# spock.sync_timeout, then the documented built-in limit.
proc_sync_budget() {
	local node="$1" v
	# effective_sync_budget() reads pg_settings first and current_setting()
	# second, which is what makes this work on a 5.x node: there the name is
	# only a placeholder, invisible to pg_settings but perfectly readable
	# with current_setting().  Reading pg_settings alone here would have
	# returned the fallback on exactly the nodes the fence waits on.
	if ! v="$(effective_sync_budget "${node}")"; then
		return 1
	fi
	if [ "${v}" = "ABSENT" ]; then
		printf '%s' "${PROC_SYNC_FALLBACK}"
		return 0
	fi
	# Zero means "leave each routine on its own built-in limit", per the GUC
	# description -- not "do not wait".
	case "${v}" in
		'' | 0 | *[!0-9]*) printf '%s' "${PROC_SYNC_FALLBACK}" ;;
		*)                 printf '%s' "${v}" ;;
	esac
}

# The largest budget in the cluster, for the rig's own cross-node polling
# loops, which have no single node to read from.  The largest and not the
# smallest: a loop that gives up before the slowest node's own routines have
# is measuring the rig, not the cluster.
proc_sync_budget_max() {
	local node b max=0
	for node in ${NODES}; do
		b="$(proc_sync_budget "${node}")" || return 1
		[ "${b}" -gt "${max}" ] && max="${b}"
	done
	printf '%s' "${max}"
}

# Report the budget a node is actually running under, so the log says it
# rather than implying it.  Nothing sets the GUC here any more: it is written
# into every postgresql.conf by write_node_conf, before the server starts and
# for the upgrade target as well, which is both simpler and the only way the
# 5.x half of the cluster can honour it (see the comment there).
proc_report_sync_budget() {
	local node="$1" b registered
	b="$(proc_sync_budget "${node}")" || return 1
	if proc_has_sync_timeout "${node}"; then
		registered="spock.sync_timeout, registered"
	else
		registered="spock.sync_timeout, placeholder -- only the rig reads it here"
	fi
	log "${node}: synchronisation budget ${b}s (${registered})"
	printf '%s' "${b}"
}

# Idempotent: callers before the procedure proper also need PROC_LOG, so this
# may be called twice and must not truncate the log the second time.
proc_init() {
	[ -z "${PROC_LOG}" ] || return 0
	PROC_LOG="${LOG_DIR}/procedure.log"
	: >"${PROC_LOG}"
	printf 'documented upgrade procedure, %s\n' "$(date)" >>"${PROC_LOG}"
}

# A claim in the document that the cluster did not honour.  Recorded, never
# fatal on its own: the run carries on so it can also say whether the rest of
# the procedure still works.
proc_finding() {
	PROC_FINDINGS=$(( PROC_FINDINGS + 1 ))
	printf 'DOC-DEVIATION: %s\n' "$1" >>"${PROC_LOG}"
	log "DOC-DEVIATION: $1"
	say "DOC-DEVIATION: $1"
}

# The procedure was followed and the result is wrong.
proc_failure() {
	PROC_FAILURES=$(( PROC_FAILURES + 1 ))
	printf 'PROCEDURE-FAILURE: %s\n' "$1" >>"${PROC_LOG}"
	log "PROCEDURE-FAILURE: $1"
	say "PROCEDURE-FAILURE: $1"
}

# A scalar query that must succeed.
#
# Deliberately NOT _q(): that helper turns a psql error into an empty
# string, which is the right trade-off for a diagnostic probe and exactly
# the wrong one for a requirement check.  "The check could not run" and
# "the check passed" have to stay distinguishable, so a failure here is a
# non-zero return and the caller has to deal with it.
proc_q() {
	local node="$1" sql="$2" out
	if ! out="$(psql_on "${node}" -At -c "${sql}" 2>>"${PROC_LOG}")"; then
		printf 'proc_q FAILED on %s: %s\n' "${node}" "${sql}" >>"${PROC_LOG}"
		return 1
	fi
	printf '%s' "${out}"
}

# Every node except the named one.
proc_peers() {
	local target="$1" node
	for node in ${NODES}; do
		[ "${node}" = "${target}" ] && continue
		printf '%s ' "${node}"
	done
	return 0
}

proc_fence_dir() { echo "${REPORT_DIR}/fence-$1"; }

# ---------------------------------------------------------------------------
# The witness table
# ---------------------------------------------------------------------------
#
# The regression database is a good test of pg_upgrade, but a poor test of
# the fence: nothing in it changes while a node is away, so a procedure that
# silently dropped every change made during the window would still compare
# equal afterwards.  The witness table is what changes during the window.
#
# Every row is uniquely keyed by (node, wseq) and written by exactly one node,
# so the two failure modes the document worries about are both visible:
# a row that never arrived is a missing key, and a row applied twice is a
# primary-key conflict rather than an invisible duplicate.

_do_proc_witness_create() {
	psql_on "${FIRST_NODE}" -c "
		CREATE TABLE ${PROC_WITNESS_TABLE} (
			node    text        NOT NULL,
			-- `wseq` and not `seq`, which is what it was called first.
			--
			-- ACE cannot compare a table whose primary key contains a column
			-- named `seq`.  Its offsets query is generated in
			-- db/queries/queries.go as
			--     LEAD(<key col>) OVER (ORDER BY seq, <key cols>)
			-- where that bare `seq` is ACE's own alias, introduced as
			-- `0 as seq` in db/queries/templates.go.  With a key column of
			-- the same name the ORDER BY is ambiguous and the whole table
			-- fails with SQLSTATE 42702:
			--     offsets query execution failed on n3:
			--     ERROR: column reference \"seq\" is ambiguous
			--
			-- That is an ACE bug and it is reported as one.  The column is
			-- renamed here anyway, because this table exists to test the
			-- fence and not ACE's SQL generation, and leaving the collision
			-- in place would mean the one table the fence depends on is the
			-- one table ACE never checks.
			wseq    bigint      NOT NULL,
			phase   text        NOT NULL,
			written timestamptz NOT NULL DEFAULT clock_timestamp(),
			PRIMARY KEY (node, wseq)
		);"
}

# Wait for the table to reach every node, then make sure every node
# replicates it.  Both are asserted rather than assumed: auto-DDL is on at
# this point in the run, but requirement 2 turns it off immediately
# afterwards, so this is the last moment at which a missing table can be
# noticed cheaply.
_do_proc_witness_distribute() {
	local node deadline got
	for node in ${NODES}; do
		deadline=$(( $(date +%s) + 120 ))
		while :; do
			got="$(proc_q "${node}" \
				"SELECT coalesce(to_regclass('${PROC_WITNESS_TABLE}')::text, 'NONE');")" \
				|| return 1
			[ "${got}" != "NONE" ] && break
			if [ "$(date +%s)" -ge "${deadline}" ]; then
				echo "witness table never reached ${node} within 120s"
				return 1
			fi
			sleep 2
		done
		echo "${node}: witness table present as ${got}"

		psql_on "${node}" -c "
			DO \$w\$
			BEGIN
				IF NOT EXISTS (SELECT 1 FROM spock.replication_set_table
				               WHERE set_reloid = '${PROC_WITNESS_TABLE}'::regclass)
				THEN
					PERFORM spock.repset_add_table('default', '${PROC_WITNESS_TABLE}');
					RAISE NOTICE 'added the witness table to the default repset';
				END IF;
			END
			\$w\$;" || return 1
	done
}

_do_proc_witness_write() {
	local node="$1" phase="$2" count="$3"
	psql_on "${node}" -c "
		INSERT INTO ${PROC_WITNESS_TABLE} (node, wseq, phase)
		SELECT '${node}',
		       coalesce((SELECT max(wseq) FROM ${PROC_WITNESS_TABLE}
		                 WHERE node = '${node}'), 0) + g,
		       '${phase}'
		FROM generate_series(1, ${count}) g;" && \
	psql_on "${node}" -c "
		SELECT phase, count(*) FROM ${PROC_WITNESS_TABLE}
		WHERE node = '${node}' GROUP BY phase ORDER BY phase;"
}

proc_witness_write() {
	local node="$1" phase="$2" count="${3:-${PROC_WITNESS_ROWS}}"
	run_phase "${node}" "proc-witness-${phase}" \
		_do_proc_witness_write "${node}" "${phase}" "${count}"
}

# An order-independent digest of the whole witness table plus its row count.
# coalesce() so an empty table produces a distinguishable answer rather than
# an empty string that would compare equal to another empty string.
proc_witness_digest() {
	local node="$1"
	proc_q "${node}" "
		SELECT coalesce(
		           md5(string_agg(node || ':' || wseq || ':' || phase,
		                          ',' ORDER BY node, wseq)),
		           'EMPTY')
		       || ' rows=' || count(*)
		FROM ${PROC_WITNESS_TABLE};"
}

# Do all nodes hold exactly the same witness rows?
proc_compare_witness() {
	local label="$1"
	local node ref="" got bad=0

	printf '\n--- witness digests (%s) ---\n' "${label}" >>"${PROC_LOG}"
	for node in ${NODES}; do
		if ! got="$(proc_witness_digest "${node}")"; then
			say "witness (${label}): could not read ${node}"
			return 1
		fi
		printf '%-4s %s\n' "${node}" "${got}" >>"${PROC_LOG}"
		case "${got}" in
			*' rows=0')
				say "witness (${label}): ${node} holds no witness rows at all"
				bad=1 ;;
		esac
		if [ -z "${ref}" ]; then
			ref="${got}"
		elif [ "${got}" != "${ref}" ]; then
			bad=1
		fi
	done

	if [ "${bad}" -ne 0 ]; then
		printf '\n--- witness detail (%s) ---\n' "${label}" >>"${PROC_LOG}"
		for node in ${NODES}; do
			printf '\n== %s ==\n' "${node}" >>"${PROC_LOG}"
			if ! psql_on "${node}" -c "
					SELECT node, phase, count(*) AS rows,
					       min(wseq) AS lo, max(wseq) AS hi
					FROM ${PROC_WITNESS_TABLE}
					GROUP BY node, phase
					ORDER BY node, phase;" >>"${PROC_LOG}" 2>&1; then
				printf '  (could not be read)\n' >>"${PROC_LOG}"
			fi
		done
		say "witness (${label}): nodes DISAGREE -- see ${PROC_LOG}"
		return 1
	fi
	say "witness (${label}): every node agrees -- ${ref}"
}

# spock's own conflict counter, summed over every subscription on a node.
#
# Independent of spock.resolutions, and that independence is the whole point:
# it is what lets the self-test tell "the detector did not fire" apart from
# "no conflict was ever produced".  Present in 5.x and 6.x alike.
proc_conflict_count() {
	local node="$1" n
	if ! n="$(proc_q "${node}" "
			SELECT coalesce(sum(n_conflict), 0)::text
			FROM spock.channel_summary_stats;")"; then
		return 1
	fi
	case "${n}" in
		'' | *[!0-9]*) return 1 ;;
	esac
	printf '%s' "${n}"
}

# ---------------------------------------------------------------------------
# Extension absorption
# ---------------------------------------------------------------------------
#
# A user table in a user schema that has become a member of an extension.
#
# Found while diagnosing a false FAIL: on the full-payload cluster, ordinary
# regression tables in `public` are members of `spock`, and which ones varies
# between nodes and between runs.  The likely mechanism is PostgreSQL's
# CurrentExtensionObject -- while `creating_extension` is set, anything the
# same backend creates is recorded as a member of the extension being created
# or updated -- and spock's DDL machinery runs in backends that also execute
# other DDL.
#
# Worth its own check rather than a footnote, because extension membership is
# not cosmetic:
#
#   - pg_dump does not dump the definition of an extension member, so a
#     logical dump of this database silently omits those tables; and
#   - DROP EXTENSION spock would take the user's tables with it.
#
# Counted at the baseline and re-counted afterwards.  A count that is already
# non-zero before the procedure starts is reported and carried, because the
# procedure did not cause it -- exactly the reasoning requirement 0 applies to
# divergence.  A count that GROWS during the procedure is attributable, and
# becomes a finding.
_do_proc_absorbed_list() {
	local node="$1"
	psql_on "${node}" -At -F '|' -c "
		SELECT quote_ident(n.nspname) || '.' || quote_ident(c.relname), e.extname
		FROM pg_class c
		JOIN pg_namespace n ON n.oid = c.relnamespace
		JOIN pg_depend d    ON d.objid = c.oid AND d.deptype = 'e'
		JOIN pg_extension e ON e.oid = d.refobjid
		WHERE c.relkind IN ('r','p')
		  AND n.nspname NOT IN ('pg_catalog','information_schema','spock')
		  AND n.nspname NOT LIKE 'pg\\_%'
		  AND n.nspname NOT LIKE 'spock\\_health%'
		  AND e.extnamespace <> c.relnamespace
		ORDER BY 1;"
}

# Write the list for every node under one tag and report the totals.
proc_capture_absorption() {
	local tag="$1" node out n total=0
	for node in ${NODES}; do
		out="${REPORT_DIR}/absorbed-${tag}-${node}.txt"
		if ! _do_proc_absorbed_list "${node}" >"${out}" 2>>"${PROC_LOG}"; then
			say "extension absorption (${tag}): could not be read on ${node}"
			return 1
		fi
		n="$(grep -c '' "${out}")" || n=0
		total=$(( total + n ))
		log "extension absorption (${tag}) ${node}: ${n} user table(s) owned by an extension"
	done
	printf '%s' "${total}"
}

# Report the baseline situation, loudly but without failing: it predates the
# procedure.
proc_report_absorption_baseline() {
	local total node out
	total="$(proc_capture_absorption baseline)" || return 1
	if [ "${total}" = "0" ]; then
		say "extension absorption: no user table is owned by an extension"
		return 0
	fi
	say "WARNING: ${total} user table(s) across the cluster are members of an extension"
	say "         before the procedure starts.  pg_dump omits extension members and"
	say "         DROP EXTENSION would remove them.  Not caused by the upgrade, so it"
	say "         does not fail this run -- but it is a product bug, not a quirk of"
	say "         the payload.  Detail in ${PROC_LOG}."
	printf '\n--- user tables owned by an extension, at the baseline ---\n' >>"${PROC_LOG}"
	for node in ${NODES}; do
		out="${REPORT_DIR}/absorbed-baseline-${node}.txt"
		printf '%s:\n' "${node}" >>"${PROC_LOG}"
		if [ -s "${out}" ]; then
			sed 's/^/  /' "${out}" >>"${PROC_LOG}"
		else
			printf '  (none)\n' >>"${PROC_LOG}"
		fi
	done
	return 0
}

# Did the procedure absorb anything new?
proc_check_absorption() {
	local tag="$1" node before after rc=0
	for node in ${NODES}; do
		before="${REPORT_DIR}/absorbed-baseline-${node}.txt"
		after="${REPORT_DIR}/absorbed-${tag}-${node}.txt"
		[ -f "${before}" ] || { say "extension absorption (${tag}): no baseline for ${node}"; rc=1; continue; }
		[ -f "${after}" ]  || { say "extension absorption (${tag}): no snapshot for ${node}"; rc=1; continue; }
		# comm needs sorted input; both lists are ORDER BY 1 from the server,
		# but the server's collation is not necessarily comm's, so sort again.
		LC_ALL=C sort "${before}" -o "${before}"
		LC_ALL=C sort "${after}"  -o "${after}"
		local new
		new="$(LC_ALL=C comm -13 "${before}" "${after}")"
		if [ -n "${new}" ]; then
			say "extension absorption (${tag}): ${node} gained extension-owned user table(s)"
			printf '\n--- newly extension-owned on %s at %s ---\n%s\n' \
				"${node}" "${tag}" "${new}" >>"${PROC_LOG}"
			rc=1
			# Fold what was just reported into the reference list, so the
			# comparison means "newly absorbed since the last check" rather
			# than "since the baseline".  Without this a single absorbed table
			# is re-reported at every remaining step-12, and four identical
			# findings about one table read as four problems.
			cp "${after}" "${before}"
		fi
	done
	return "${rc}"
}

# ---------------------------------------------------------------------------
# Making step 9 testable
# ---------------------------------------------------------------------------
#
# Step 9 exists to recreate a peer subscription "from the requirement 7(b)
# record, NOT from sub_create's defaults", and the document calls getting that
# wrong "the quiet way to lose data".  But every value step 3 leaves behind
# equals sub_create's own default -- replication_sets is exactly
# {default,default_insert_only,ddl_sql}, forward_origins is '{}', apply_delay
# is 00:00:00, force_text_transfer is false -- so a step 9 that threw the
# record away and passed the defaults would produce a byte-identical
# subscription and pass every check in the section.  The step was untestable.
#
# So one non-default value is seeded before the roll: a user replication set
# carrying one already-replicated table, added to every subscription.  Nothing
# about replication changes -- the table simply travels in a set of its own --
# but sub_replication_sets is no longer the default array, and a step 9 that
# ignored the record now comes back short by exactly that set, which both the
# step's own read-back and the configuration diff report.
#
# The table is MOVED rather than created, deliberately.  Creating one would be
# DDL, and this runs after requirement 2 has turned DDL replication off; the
# rig would then have to create it on every node by hand and hope the copies
# matched.  Moving an existing one is a catalog change local to each node,
# applied identically everywhere.
# `-` and not `:-`: PROC_SEED_REPSET= (explicitly empty) has to mean "do not
# seed", which is how the claim that the seed is load-bearing gets tested.
# With `:-` an empty value silently became the default and the demonstration
# run reported a PASS for the wrong reason.
# ACE's cluster name, which is also its JSON file's basename.
ACE_CLUSTER=spockrig

PROC_SEED_REPSET=proc_seed_set

# The table to move: the first replicated table in `default`, in a stable
# order, excluding the witness -- that one has to keep travelling in `default`
# because the fence checks depend on it arriving promptly.
_do_proc_seed_pick() {
	local node="$1"
	proc_q "${node}" "
		SELECT quote_ident(ns.nspname) || '.' || quote_ident(c.relname)
		FROM spock.replication_set r
		JOIN spock.replication_set_table t ON t.set_id = r.set_id
		JOIN pg_class c      ON c.oid = t.set_reloid
		JOIN pg_namespace ns ON ns.oid = c.relnamespace
		WHERE r.set_name = 'default'
		  AND c.oid <> '${PROC_WITNESS_TABLE}'::regclass
		  -- and not one of the rig's own health-probe tables: check_node_health
		  -- writes to those on every pass, and a measurement should not be
		  -- moved around by the thing being measured.
		  AND ns.nspname NOT LIKE 'spock\\_health%'
		ORDER BY 1
		LIMIT 1;"
}

_do_proc_seed_repset() {
	local node="$1" tbl="$2"

	psql_on "${node}" -c "
		DO \$s\$
		BEGIN
			IF NOT EXISTS (SELECT 1 FROM spock.replication_set
			               WHERE set_name = '${PROC_SEED_REPSET}') THEN
				PERFORM spock.repset_create('${PROC_SEED_REPSET}');
			END IF;
			PERFORM spock.repset_remove_table('default', '${tbl}'::regclass);
			PERFORM spock.repset_add_table('${PROC_SEED_REPSET}', '${tbl}'::regclass);
		END
		\$s\$;" || return 1

	# Every subscription on this node now carries the new set as well.  Done
	# per subscription rather than cluster-wide because sub_add_repset is a
	# local catalog change on the subscriber.
	psql_on "${node}" -c "
		DO \$s\$
		DECLARE sub record;
		BEGIN
			FOR sub IN SELECT sub_name FROM spock.subscription ORDER BY 1 LOOP
				IF NOT ('${PROC_SEED_REPSET}' = ANY (
				        SELECT unnest(sub_replication_sets)
				        FROM spock.subscription
				        WHERE sub_name = sub.sub_name)) THEN
					PERFORM spock.sub_add_repset(sub.sub_name, '${PROC_SEED_REPSET}');
					RAISE NOTICE 'added % to %', '${PROC_SEED_REPSET}', sub.sub_name;
				END IF;
			END LOOP;
		END
		\$s\$;" || return 1

	# Read back, and require the seed to have taken on every subscription.
	# A silent no-op here would leave step 9 exactly as untestable as before,
	# while the log claimed otherwise.
	local subs seeded
	subs="$(proc_q "${node}" "SELECT count(*) FROM spock.subscription;")" || return 1
	seeded="$(proc_q "${node}" "
		SELECT count(*) FROM spock.subscription
		WHERE '${PROC_SEED_REPSET}' = ANY (sub_replication_sets);")" || return 1
	if [ "${subs}" != "${seeded}" ]; then
		echo "seed FAILS on ${node}: ${seeded} of ${subs} subscription(s) carry ${PROC_SEED_REPSET}"
		return 1
	fi
	echo "${node}: ${tbl} now travels in ${PROC_SEED_REPSET}, carried by all ${subs} subscription(s)"
	psql_on "${node}" -c \
		"SELECT sub_name, sub_replication_sets FROM spock.subscription ORDER BY 1;"
}

# Seed the whole cluster.  The table is chosen on the first node and used
# everywhere: the nodes agree on replication-set membership at this point --
# requirement 0's own baseline is about to assert as much -- so choosing per
# node could pick different tables and make the configuration diverge by
# construction.
proc_seed_nondefault_repset() {
	local node tbl

	tbl="$(_do_proc_seed_pick "${FIRST_NODE}")" \
		|| fail "could not choose a table to seed ${PROC_SEED_REPSET} with" 20
	if [ -z "${tbl}" ]; then
		fail "no replicated table outside the witness to seed ${PROC_SEED_REPSET} with, so step 9 cannot be made testable" 20
	fi
	say "seeding ${PROC_SEED_REPSET} with ${tbl} so step 9 has a non-default value to restore"

	for node in ${NODES}; do
		run_phase "${node}" proc-seed-repset \
			_do_proc_seed_repset "${node}" "${tbl}" \
			|| fail "${node}: could not seed ${PROC_SEED_REPSET}" 20
	done
}

# ---------------------------------------------------------------------------
# ACE -- the companion the document actually names
# ---------------------------------------------------------------------------
#
# Requirement 0 asks for a baseline taken with pgEdge ACE: repset-diff for the
# DATA and spock-diff for the CONFIGURATION.  Step 12 asks for the same two
# again, compared against that baseline.  The rig has its own native
# equivalents -- they need no external program and they run in CI -- but the
# document names ACE, so ACE is what has to be shown to work.
#
# ACE's exit status is not its verdict.  The document says so at line 164 and
# it understates the problem; all three of these were measured here:
#
#   - repset-diff found a real one-row divergence, reported "1 table(s) have
#     differences", wrote synth_keyed_diffs-<ts>.json -- and exited 0.
#   - spock-diff found a subscription carrying an extra replication set,
#     reported mismatch=true in its report -- and exited 0.
#   - repset-diff failed to compare ALL SEVEN tables in the repset (pgcrypto
#     was missing, so digest() did not exist), logged seven ERRO lines, wrote
#     NO report at all -- and exited 0.
#
# That last one is the dangerous shape, and it is worse than the document
# suggests: "fails only on a table it could not compare" is not true either.
# Total failure and total success are both exit 0 with no report file, so
# presence-of-report cannot be the test on its own.  The rig therefore reads
# the report contents where there is one, and cross-checks the summary counts
# against the number of tables in the replication set where there is not.
#
# Where ACE comes from.  ACE_BIN names the binary; ACE_SRC names a checkout to
# build one from (go build ./cmd/ace).  With neither set the script looks for
# `ace` on PATH.  Not found at all is fatal rather than a skip: requirement 0
# and step 12 are ACE's job in the document, and a run that quietly fell back
# to this script's own comparisons would report on something the document does
# not describe while looking exactly like a run that did what was asked.
ACE_BIN="${ACE_BIN:-}"
ACE_SRC="${ACE_SRC:-}"
ACE_STATE=""          # UNSET until probed: READY | ABSENT
ACE_WHY=""            # why it is ABSENT, for the message

ace_dir() { echo "${BASE_DIR}/ace"; }

# Resolve ACE once.  Sets ACE_BIN and ACE_STATE.
proc_ace_resolve() {
	[ -z "${ACE_STATE}" ] || return 0

	if [ -n "${ACE_BIN}" ]; then
		if [ -x "${ACE_BIN}" ]; then
			ACE_STATE=READY
		else
			ACE_STATE=ABSENT
			ACE_WHY="ACE_BIN=${ACE_BIN} is not an executable"
		fi
		return 0
	fi

	if [ -n "${ACE_SRC}" ]; then
		if [ ! -d "${ACE_SRC}" ]; then
			ACE_STATE=ABSENT
			ACE_WHY="ACE_SRC=${ACE_SRC} is not a directory"
			return 0
		fi
		if ! command -v go >/dev/null 2>&1; then
			ACE_STATE=ABSENT
			ACE_WHY="ACE_SRC is set but there is no go toolchain to build it with"
			return 0
		fi
		local out; out="$(ace_dir)/ace"
		mkdir -p "$(ace_dir)"
		log "building ACE from ${ACE_SRC}"
		if ( cd "${ACE_SRC}" && go build -o "${out}" ./cmd/ace ) >>"${MAIN_LOG}" 2>&1; then
			ACE_BIN="${out}"
			ACE_STATE=READY
		else
			ACE_STATE=ABSENT
			ACE_WHY="go build failed in ${ACE_SRC}; see ${MAIN_LOG}"
		fi
		return 0
	fi

	if command -v ace >/dev/null 2>&1; then
		ACE_BIN="$(command -v ace)"
		ACE_STATE=READY
		return 0
	fi

	ACE_STATE=ABSENT
	ACE_WHY="no ACE_BIN, no ACE_SRC, and no 'ace' on PATH"
	return 0
}

# Say plainly whether the document's own checks are being run.  Called once,
# early, so the answer is at the top of the log rather than implied by the
# absence of later lines.
proc_ace_report_availability() {
	proc_ace_resolve
	if [ "${ACE_STATE}" = "READY" ]; then
		say "ACE: ${ACE_BIN}"
		log "ACE available at ${ACE_BIN}"
		printf 'ACE: %s\n' "${ACE_BIN}" >>"${PROC_LOG}"
		return 0
	fi
	# Fatal, not a skip.  Requirement 0 and step 12 are ACE's job in the
	# document, and a run that quietly substituted this script's own
	# comparisons would report on something the document does not describe --
	# while looking exactly like a run that did what was asked.
	fail "ACE is required and could not be found: ${ACE_WHY}. Set ACE_SRC=<checkout> or ACE_BIN=<binary>." 10
}

# ACE addresses nodes by host and port -- its cluster JSON has no
# socket-directory field -- which is why write_node_conf opens a loopback TCP
# listener.  The file is regenerated every run because PORT_BASE and the node
# count are both variables.
_do_ace_write_cluster_json() {
	local out node first=1
	out="$(ace_dir)/${ACE_CLUSTER}.json"
	mkdir -p "$(ace_dir)"
	{
		printf '{\n'
		printf '  "json_version": "1.0",\n'
		printf '  "cluster_name": "%s",\n' "${ACE_CLUSTER}"
		printf '  "log_level": "info",\n'
		printf '  "pgedge": {\n'
		printf '    "pg_version": %s,\n' "${OLD_MAJORS%% *}"
		printf '    "spock": { "spock_version": "%s", "auto_ddl": "off" },\n' \
			"${SPOCK_V5_VERSION%%.*}.0"
		printf '    "databases": [ { "db_name": "%s", "db_user": "%s", "db_password": "" } ]\n' \
			"${DBNAME}" "${DBUSER}"
		printf '  },\n'
		printf '  "node_groups": [\n'
		for node in ${NODES}; do
			[ "${first}" -eq 1 ] || printf ',\n'
			first=0
			printf '    { "name": "%s", "is_active": "on", "public_ip": "127.0.0.1", "port": "%s" }' \
				"${node}" "$(node_to_port "${node}")"
		done
		printf '\n  ]\n}\n'
	} >"${out}" || return 1

	# ACE reads ace.yaml from its working directory, and it is NOT optional in
	# the way it looks.  An ace.yaml carrying only `default_cluster: ""` made
	# every table fail with
	#
	#     ERRO - synth.keyless: block row size should be <= 0
	#
	# because the block-size and compare-unit numbers live in that file and
	# have no built-in fallback: absent means zero, and zero fails validation.
	# So the shipped file is copied when there is one, and a complete
	# equivalent written when there is not.
	local yaml
	yaml="$(ace_dir)/ace.yaml"
	if [ -n "${ACE_SRC}" ] && [ -f "${ACE_SRC}/ace.yaml" ]; then
		cp "${ACE_SRC}/ace.yaml" "${yaml}" || return 1
		echo "ace.yaml copied from ${ACE_SRC}"
	elif [ ! -f "${yaml}" ]; then
		cat >"${yaml}" <<-'YAML'
			default_cluster: ""
			postgres:
			  statement_timeout: 0
			  connection_timeout: 10
			  application_name: "ACE"
			table_diff:
			  concurrency_factor: 1
			  max_diff_rows: 1000000
			  min_diff_block_size: 1
			  max_diff_block_size: 1000000
			  diff_block_size: 1000
			  diff_batch_size: 1
			  max_diff_batch_size: 1000
			  compare_unit_size: 10000
			  max_connections: 0
			mtree:
			  schema: "pgedge_ace"
			  diff:
			    min_block_size: 1000
			    block_size: 100000
			    max_block_size: 1000000
			debug_mode: false
		YAML
		echo "ace.yaml written with the shipped defaults"
	fi

	echo "----- ${out} -----"
	cat "${out}"
	# Prove every node in it is actually reachable over TCP, so an ACE failure
	# later is about ACE and not about the listener.
	local port
	for node in ${NODES}; do
		port="$(node_to_port "${node}")"
		if ! psql_on "${node}" -At -c "SELECT 1;" >/dev/null 2>&1; then
			echo "${node}: not reachable on its socket -- ACE will not fare better"
			return 1
		fi
		if ! PGPASSWORD="" "$(prefix_for "$(node_variant "${node}")")/bin/psql" \
				-X -At -h 127.0.0.1 -p "${port}" -U "${DBUSER}" -d "${DBNAME}" \
				-c "SELECT 1;" >/dev/null 2>&1; then
			echo "${node}: reachable on its socket but NOT on 127.0.0.1:${port};"
			echo "  ACE needs the TCP listener that write_node_conf sets up."
			return 1
		fi
	done
	echo "all ${NODE_COUNT} node(s) reachable on 127.0.0.1"
}

# spock-diff: the configuration half.  The verdict is the per-pair `mismatch`
# flag inside the report, never the exit status.
#
# Writes the number of mismatching pairs to <ace dir>/spock-diff-<tag>.count.
_do_ace_spock_diff() {
	local tag="$1"
	local d; d="$(ace_dir)"
	local rc=0

	rm -f "${d}"/spock_diffs-*.json
	( cd "${d}" && "${ACE_BIN}" spock-diff "${ACE_CLUSTER}" -d "${DBNAME}" ) || rc=$?
	echo "ace spock-diff exit status: ${rc} (not the verdict)"

	local report
	report="$(ls -t "${d}"/spock_diffs-*.json 2>/dev/null | head -1)" || report=""
	if [ -z "${report}" ]; then
		# spock-diff writes its report whether or not anything mismatched, so
		# no report means it did not get far enough to have an opinion.
		echo "spock-diff produced NO report -- it did not run to completion."
		echo "That is not 'no differences'; treat it as the check not having run."
		return 1
	fi
	echo "report: ${report}"
	cp "${report}" "${d}/spock-diff-${tag}.json"

	local bad
	bad="$(python3 - "${report}" <<-'PY'
		import json, sys
		d = json.load(open(sys.argv[1]))
		diffs = d.get("diffs")
		if not isinstance(diffs, dict) or not diffs:
		    print("NOPAIRS")
		    raise SystemExit(0)
		bad = []
		for pair, r in diffs.items():
		    if not isinstance(r, dict) or "mismatch" not in r:
		        print("MALFORMED")
		        raise SystemExit(0)
		    if r["mismatch"]:
		        bad.append(f'{pair}: {r.get("message", "")}')
		print(len(bad))
		for line in bad:
		    print("  " + line)
	PY
	)" || { echo "could not read ${report}"; return 1; }

	case "${bad%%$'\n'*}" in
		NOPAIRS)
			echo "spock-diff report has no node pairs at all -- nothing was compared."
			return 1 ;;
		MALFORMED)
			echo "spock-diff report has no per-pair 'mismatch' flag; ACE's report"
			echo "  format has changed and this check is reading the wrong thing."
			return 1 ;;
	esac
	printf '%s\n' "${bad}"
	printf '%s\n' "${bad%%$'\n'*}" >"${d}/spock-diff-${tag}.count"
	echo "spock-diff (${tag}): ${bad%%$'\n'*} mismatching pair(s)"
}

# repset-diff: the data half, over every replication set that has tables.
#
# Two things are read, because neither alone is sufficient: the per-table diff
# reports ACE writes when it finds differences, and the summary counts, which
# are the only way to notice that ACE could not compare anything at all.
_do_ace_repset_diff() {
	local tag="$1"
	local d; d="$(ace_dir)"
	local sets set rc=0 total_diff=0 total_err=0 total_nopk=0 total_ident=0

	# Only sets that actually hold tables: repset-diff over an empty set has
	# nothing to say and its "0 identical" would be indistinguishable from a
	# failure to compare.
	sets="$(proc_q "${FIRST_NODE}" "
		SELECT string_agg(DISTINCT r.set_name, ' ' ORDER BY r.set_name)
		FROM spock.replication_set r
		JOIN spock.replication_set_table t ON t.set_id = r.set_id;")" || return 1
	if [ -z "${sets}" ]; then
		echo "no replication set holds any table; there is nothing for repset-diff to do"
		return 1
	fi
	echo "replication sets with tables: ${sets}"

	for set in ${sets}; do
		local want out
		want="$(proc_q "${FIRST_NODE}" "
			SELECT count(*) FROM spock.replication_set r
			JOIN spock.replication_set_table t ON t.set_id = r.set_id
			WHERE r.set_name = '${set}';")" || return 1

		rm -f "${d}"/*_diffs-*.json
		out="${d}/repset-diff-${tag}-${set}.out"
		echo "----- ace repset-diff ${ACE_CLUSTER} ${set} (${want} table(s)) -----"
		rc=0
		( cd "${d}" && "${ACE_BIN}" repset-diff "${ACE_CLUSTER}" "${set}" -d "${DBNAME}" ) \
			>"${out}" 2>&1 || rc=$?
		echo "ace repset-diff exit status: ${rc} (not the verdict)"

		# The counts ACE prints in its summary.  Parsed rather than trusted:
		# an all-tables-failed run prints them and exits 0.
		local n_ident n_diff n_err
		n_ident="$(sed -n 's/.*  \([0-9]\{1,\}\) table(s) are identical.*/\1/p' "${out}" | tail -1)"
		n_diff="$(sed -n 's/.*  \([0-9]\{1,\}\) table(s) have differences.*/\1/p' "${out}" | tail -1)"
		n_err="$(sed -n 's/.*  \([0-9]\{1,\}\) table(s) encountered errors.*/\1/p' "${out}" | tail -1)"
		: "${n_ident:=0}" "${n_diff:=0}" "${n_err:=0}"
		echo "summary for ${set}: identical=${n_ident} differing=${n_diff} errored=${n_err} (expected ${want} table(s))"

		if [ "${n_err}" != "0" ]; then
			# Not every ACE error means ACE failed to run.  Some are
			# structural: table-diff needs a primary key, and a replication
			# set may legitimately contain a table that has none -- the rig
			# puts exactly those in `default_insert_only`, which is what that
			# set is for.  Those are a COVERAGE GAP, to be reported and
			# counted, not a broken check.
			#
			# The distinction matters in both directions.  Treating them as
			# failures makes the run unusable on any realistic cluster;
			# treating everything as a gap is how "ACE compared nothing at
			# all" becomes a pass, which is the failure this whole section is
			# built to avoid.
			local n_nopk
			n_nopk="$(grep -cE 'ERRO +- .*: no primary key found' "${out}")" || n_nopk=0
			local n_real=$(( n_err - n_nopk ))
			[ "${n_real}" -ge 0 ] || n_real=0

			if [ "${n_nopk}" != "0" ]; then
				echo "repset-diff cannot compare ${n_nopk} table(s) in ${set}: no primary key."
				echo "  ACE's table-diff requires one, so these are outside its reach and the"
				echo "  document's 'repset-diff over every table in a replication set' is not"
				echo "  achievable for them.  The rig's own row-count and relation comparison"
				echo "  still covers them.  Tables:"
				grep -E 'ERRO +- .*: no primary key found' "${out}" \
					| sed 's/.*ERRO *- /    /;s/: no primary key found.*//'
				total_nopk=$(( total_nopk + n_nopk ))
			fi
			# "table X not found on <node>, or the current user does not have
			# adequate privileges" is ACE reporting two very different things in
			# one sentence, and the difference is the whole point of the check:
			#
			#   - the table is there but ACE's user cannot read it -> a coverage
			#     gap, like the missing primary key.  The core regression database
			#     is full of these on purpose (datdba_only, and friends).
			#   - the table is genuinely absent on one node -> schema divergence,
			#     which is exactly what requirement 0 is looking for.
			#
			# So it is not tolerated on the strength of the wording.  Each table is
			# looked up on every node and the two cases are separated.
			local unreadable=0
			if [ "${n_real}" != "0" ]; then
				local tbl missing present
				while read -r tbl; do
					[ -n "${tbl}" ] || continue
					missing=""
					for node in ${NODES}; do
						present="$(proc_q "${node}" \
							"SELECT CASE WHEN to_regclass('${tbl}') IS NULL THEN 'NO' ELSE 'YES' END;")" \
							|| present="UNKNOWN"
						[ "${present}" = "YES" ] || missing="${missing} ${node}(${present})"
					done
					if [ -n "${missing}" ]; then
						echo "  DIVERGENCE: ${tbl} is in ${set} but absent on:${missing}"
						total_err=$(( total_err + 1 ))
					else
						echo "  present on every node but not readable by ACE's user: ${tbl}"
						unreadable=$(( unreadable + 1 ))
					fi
				done <<-EOF
					$(grep -E 'ERRO +- ' "${out}" \
						| grep -v 'no primary key found' \
						| sed "s/.*ERRO *- //;s/:.*//")
				EOF
				if [ "${unreadable}" != "0" ]; then
					echo "repset-diff could not read ${unreadable} table(s) in ${set}: present on every"
					echo "  node but outside the privileges of the user ACE connects as. A coverage"
					echo "  gap, not a failed comparison -- the core regression database creates"
					echo "  tables with restricted ownership on purpose."
					total_nopk=$(( total_nopk + unreadable ))
				fi
			fi
		fi
		if [ $(( n_ident + n_diff + n_err )) -ne "${want}" ]; then
			echo "repset-diff accounted for $(( n_ident + n_diff + n_err )) of ${want} table(s) in ${set}"
			echo "  -- the comparison did not cover the replication set."
			total_err=$(( total_err + 1 ))
		fi
		total_diff=$(( total_diff + n_diff ))
		total_ident=$(( total_ident + n_ident ))

		# Keep whatever reports it wrote; their existence is the per-table
		# evidence behind the differing count.
		local f
		for f in "${d}"/*_diffs-*.json; do
			[ -f "${f}" ] || continue
			mv "${f}" "${d}/repset-diff-${tag}-${set}-$(basename "${f}")"
		done
	done

	printf '%s\n' "${total_diff}" >"${d}/repset-diff-${tag}.count"
	printf '%s\n' "${total_nopk}" >"${d}/repset-diff-${tag}.nopk"
	echo "repset-diff (${tag}): ${total_ident} identical, ${total_diff} differing," \
	     "${total_nopk} not comparable (no primary key), ${total_err} failed to compare"
	if [ "${total_ident}" -eq 0 ] && [ "${total_diff}" -eq 0 ]; then
		echo "repset-diff compared NOTHING successfully -- every table was skipped or"
		echo "  failed, so this run says nothing about the data."
		return 1
	fi
	[ "${total_err}" -eq 0 ] || return 1
	return 0
}

# Run both ACE checks under one tag.  Returns non-zero only when a check could
# not be RUN; what it FOUND is left to the caller, which knows whether a
# finding is attributable.
proc_ace_run() {
	local tag="$1" rc=0
	proc_ace_resolve

	run_phase cluster "ace-cluster-json-${tag}" _do_ace_write_cluster_json \
		|| { say "ACE (${tag}): the cluster definition could not be written"; return 1; }
	run_phase cluster "ace-spock-diff-${tag}" _do_ace_spock_diff "${tag}" \
		|| { say "ACE (${tag}): spock-diff could not be run"; rc=1; }
	run_phase cluster "ace-repset-diff-${tag}" _do_ace_repset_diff "${tag}" \
		|| { say "ACE (${tag}): repset-diff could not compare the replication sets"; rc=1; }
	return "${rc}"
}

# What ACE found under a tag, as two numbers on stdout: "<config> <data>".
proc_ace_counts() {
	local tag="$1" d; d="$(ace_dir)"
	printf '%s %s' \
		"$(cat "${d}/spock-diff-${tag}.count" 2>/dev/null || echo '?')" \
		"$(cat "${d}/repset-diff-${tag}.count" 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------------------
# Requirement 0, second half: the configuration baseline
# ---------------------------------------------------------------------------
#
# Requirement 0 asks for two baselines, not one.  ACE's repset-diff compares
# the DATA; its spock-diff compares the CONFIGURATION -- nodes, subscriptions
# and replication-set membership -- and the document is explicit about why
# that second one matters: step 9 retypes the `replication_sets` array by
# hand, and "getting it wrong leaves a subscription that replicates, but not
# everything it used to".  It calls that "the quiet way to lose data".
#
# Nothing here shells out to ACE.  Not because ACE is the wrong tool -- it is
# the one an operator should use -- but because a rig whose central verdict
# depends on an external program mostly reports on whether that program is
# installed.  The comparison ACE performs is a few catalog queries, so they are
# made directly and the answer is the rig's own.  ACE still runs, separately,
# because the document names it; see proc_ace_*.
#
# The comparison is per node against that node's own baseline, rather than
# node against node: a mesh's subscription rows differ between nodes by
# construction (n2 holds sub_n1_n2 and sub_n3_n2, n1 holds neither).  What
# must not change is what any one node's configuration says, because the
# procedure's only sanctioned change to it is step 9 dropping and recreating a
# subscription that is supposed to come back identical.
#
# Array-valued columns are sorted element-wise before recording.  The existing
# read-back inside step 9 compares sub_replication_sets as text, so it fires
# on a reordering that means nothing and stays silent on a membership change
# that means everything -- the handoff notes it "only catches it by accident".
# Sorting makes ordering invisible and membership the only thing left to
# differ.
proc_config_file() { echo "${REPORT_DIR}/config-$2-$1.txt"; }

# One node's Spock configuration, canonicalised and sorted.
#
# sub_slot_name is included: it is what step 8 keys the restored origins on,
# so a subscription recreated under a different slot name would leave the
# fence record pointing at nothing.  sub_skip_lsn is deliberately NOT
# included -- the document says recreation resets it to 0/0 and step 4
# already records and reports a non-zero value.
_do_proc_capture_config() {
	local node="$1" tag="$2"
	local out; out="$(proc_config_file "${node}" "${tag}")"
	local has_col skipschema

	if ! has_col="$(proc_q "${node}" "
			SELECT count(*) FROM pg_attribute
			WHERE attrelid = 'spock.subscription'::regclass
			  AND attname = 'sub_skip_schema'
			  AND attnum > 0 AND NOT attisdropped;")"; then
		echo "config (${tag}): could not inspect spock.subscription on ${node}"
		return 1
	fi
	if [ "${has_col}" != "0" ]; then
		skipschema="coalesce((SELECT array_agg(x ORDER BY x)::text
		                      FROM unnest(sub_skip_schema) x), '{}')"
	else
		skipschema="'NOCOLUMN'"
	fi

	: >"${out}"

	# The nodes this node knows about, and how it reaches them.  A node whose
	# interface DSN changed across the upgrade would still replicate until the
	# next reconnect, so it is worth recording rather than discovering later.
	psql_on "${node}" -At -F '|' -c "
		SELECT 'node', n.node_name, i.if_name, i.if_dsn
		FROM spock.node n
		JOIN spock.node_interface i ON i.if_nodeid = n.node_id
		ORDER BY 1, 2, 3;" >>"${out}" || return 1

	psql_on "${node}" -At -F '|' -c "
		SELECT 'sub', sub_name, sub_slot_name,
		       coalesce((SELECT array_agg(x ORDER BY x)::text
		                 FROM unnest(sub_replication_sets) x), '{}'),
		       coalesce((SELECT array_agg(x ORDER BY x)::text
		                 FROM unnest(sub_forward_origins) x), '{}'),
		       sub_apply_delay::text,
		       sub_force_text_transfer::text,
		       sub_enabled::text,
		       ${skipschema}
		FROM spock.subscription
		ORDER BY 2;" >>"${out}" || return 1

	# Replication-set membership, by name rather than by oid: oids do not
	# survive pg_upgrade and comparing them would report a difference on every
	# node every time.
	psql_on "${node}" -At -F '|' -c "
		SELECT 'repset', r.set_name,
		       quote_ident(ns.nspname) || '.' || quote_ident(c.relname)
		FROM spock.replication_set r
		JOIN spock.replication_set_table t ON t.set_id = r.set_id
		JOIN pg_class c     ON c.oid = t.set_reloid
		JOIN pg_namespace ns ON ns.oid = c.relnamespace
		ORDER BY 2, 3;" >>"${out}" || return 1

	if [ ! -s "${out}" ]; then
		echo "config (${tag}): the configuration snapshot of ${node} is empty"
		return 1
	fi
	echo "config (${tag}) ${node}: $(wc -l <"${out}") line(s)"
	echo "  nodes=$(count_lines_with_prefix 'node|' "${out}")" \
	     "subs=$(count_lines_with_prefix 'sub|' "${out}")" \
	     "repset-members=$(count_lines_with_prefix 'repset|' "${out}")"
}

# Capture every node's configuration under one tag.  Fatal to the caller if
# any node cannot be read: a missing snapshot compares equal to nothing.
proc_capture_config() {
	local tag="$1" node rc=0
	for node in ${NODES}; do
		run_phase "${node}" "proc-config-${tag}" \
			_do_proc_capture_config "${node}" "${tag}" || rc=1
	done
	return "${rc}"
}

# Did any node's Spock configuration change since the baseline?
#
# This is the check that makes step 9 mean something.  A subscription
# recreated with sub_create's defaults instead of the recorded array comes
# back carrying `{default,default_insert_only,ddl_sql}` and nothing else --
# with no error and no log line anywhere.  Here it is a diff.
proc_compare_config() {
	local tag="$1" node rc=0
	local base now dout

	for node in ${NODES}; do
		base="$(proc_config_file "${node}" baseline)"
		now="$(proc_config_file "${node}" "${tag}")"
		if [ ! -s "${base}" ]; then
			say "config (${tag}): no baseline for ${node}"
			rc=1
			continue
		fi
		if [ ! -s "${now}" ]; then
			say "config (${tag}): no snapshot for ${node}"
			rc=1
			continue
		fi
		dout="${REPORT_DIR}/config-diff-${tag}-${node}.txt"
		if diff -u "${base}" "${now}" >"${dout}" 2>&1; then
			rm -f "${dout}"
			continue
		fi
		say "config (${tag}): ${node}'s spock configuration changed -- see ${dout}"
		printf '\n--- configuration diff (%s) on %s ---\n' "${tag}" "${node}" \
			>>"${PROC_LOG}"
		cat "${dout}" >>"${PROC_LOG}"
		rc=1
	done

	[ "${rc}" -eq 0 ] && say "config (${tag}): every node's spock configuration is unchanged"
	return "${rc}"
}

# ---------------------------------------------------------------------------
# Re-application: reading spock.resolutions
# ---------------------------------------------------------------------------
#
# The rig configures spock.conflict_resolution = 'last_update_wins' and
# exception_behaviour = 'discard', so a primary-key conflict during apply is
# *resolved* rather than raised.  That is the right production setting and the
# wrong thing for a test to leave unread: if step 8 restored an origin to an
# LSN earlier than the true one, N replays WAL it had already applied, every
# replayed row conflicts, each conflict resolves to identical content, and
# every row-count and digest comparison in this rig passes.  Only the "rows
# missing" direction had a detector.
#
# spock.resolutions is where a resolved conflict is recorded.  During this
# procedure it should stay empty: one node writes each witness key, no two
# nodes write the same row, and the fence means nothing is applied twice.  So
# any new row is evidence -- either of re-application, or of a rig that has
# started generating genuine conflicts and needs to say so.
proc_resolutions_count() {
	local node="$1" n
	# The table has existed since 5.0.0, so its absence is a real problem and
	# not something to route around.
	if ! n="$(proc_q "${node}" "SELECT count(*) FROM spock.resolutions;")"; then
		return 1
	fi
	printf '%s' "${n}"
}

# Record the resolution count on every node, so a later reading can be
# attributed to the window between the two.
proc_resolutions_mark() {
	local tag="$1" node n
	for node in ${NODES}; do
		n="$(proc_resolutions_count "${node}")" || return 1
		printf '%s\n' "${n}" >"${REPORT_DIR}/resolutions-${tag}-${node}.txt"
		log "resolutions (${tag}) ${node}: ${n}"
		n="$(proc_conflict_count "${node}")" || return 1
		printf '%s\n' "${n}" >"${REPORT_DIR}/conflicts-${tag}-${node}.txt"
		log "conflicts (${tag}) ${node}: ${n}"
	done
	return 0
}

# The same question asked of spock's conflict COUNTER rather than of the
# resolutions table.
#
# Two detectors and not one, because their blind spots are different and both
# were observed under injection:
#
#   - spock.resolutions is written only when spock.save_resolutions is on.
#     It defaults to OFF, so on a cluster that has not been configured for it
#     the resolutions detector reads zero forever and looks like a pass.
#     write_node_conf turns it on here; a real cluster may not have.
#   - the counter behind spock.channel_summary_stats has no such switch, but
#     it lives in shared memory and is therefore reset when the node
#     restarts -- which in this procedure happens to every node, at step 6.
#     In the witness-conflict self-test the resolutions table reported the
#     injected conflict on all three nodes while the counter reported it only
#     on the two that had not yet been upgraded.
#
# Whichever of the two fires, a conflict during this procedure is a finding.
proc_conflicts_since() {
	local tag="$1" mark="$2" node before after rc=0
	for node in ${NODES}; do
		if ! before="$(cat "${REPORT_DIR}/conflicts-${mark}-${node}.txt")"; then
			say "conflicts (${tag}): no '${mark}' mark for ${node}"
			rc=1
			continue
		fi
		if ! after="$(proc_conflict_count "${node}")"; then
			say "conflicts (${tag}): the counter could not be read on ${node}"
			rc=1
			continue
		fi
		printf '%s\n' "${after}" >"${REPORT_DIR}/conflicts-${tag}-${node}.txt"
		if [ "${after}" -le "${before}" ]; then
			continue
		fi
		say "conflicts (${tag}): ${node} counted $(( after - before )) conflict(s) since ${mark}"
		printf '\n--- conflict counters on %s at %s (was %s at %s) ---\n' \
			"${node}" "${tag}" "${before}" "${mark}" >>"${PROC_LOG}"
		psql_on "${node}" -c "
			SELECT sub_name, n_tup_ins, n_tup_upd, n_tup_del, n_conflict
			FROM spock.channel_summary_stats
			ORDER BY 1;" >>"${PROC_LOG}" 2>&1 \
			|| printf '  (the counters could not be read)\n' >>"${PROC_LOG}"
		rc=1
	done
	[ "${rc}" -eq 0 ] && log "conflicts (${tag}): spock counted no conflict anywhere since ${mark}"
	return "${rc}"
}

# Did anything get resolved since the named mark?  Returns non-zero if so,
# and names the conflicts.
proc_resolutions_since() {
	local tag="$1" mark="$2" node before after rc=0
	for node in ${NODES}; do
		if ! before="$(cat "${REPORT_DIR}/resolutions-${mark}-${node}.txt")"; then
			say "resolutions (${tag}): no '${mark}' mark for ${node}"
			rc=1
			continue
		fi
		if ! after="$(proc_resolutions_count "${node}")"; then
			say "resolutions (${tag}): could not be read on ${node}"
			rc=1
			continue
		fi
		printf '%s\n' "${after}" >"${REPORT_DIR}/resolutions-${tag}-${node}.txt"
		if [ "${after}" = "${before}" ]; then
			continue
		fi
		say "resolutions (${tag}): ${node} resolved $(( after - before )) conflict(s) since ${mark}"
		printf '\n--- conflicts resolved on %s between %s and %s ---\n' \
			"${node}" "${mark}" "${tag}" >>"${PROC_LOG}"
		psql_on "${node}" -c "
			SELECT log_time, relname, conflict_type, conflict_resolution,
			       local_xid, remote_xid, remote_lsn
			FROM spock.resolutions
			ORDER BY id DESC
			LIMIT 50;" >>"${PROC_LOG}" 2>&1 \
			|| printf '  (the resolution log could not be read)\n' >>"${PROC_LOG}"
		rc=1
	done
	[ "${rc}" -eq 0 ] && log "resolutions (${tag}): no conflict was resolved anywhere since ${mark}"
	return "${rc}"
}

# ---------------------------------------------------------------------------
# Requirement 0: a baseline, and the divergence attribution it buys
# ---------------------------------------------------------------------------
#
# The document is explicit that convergence is not demanded: pre-existing
# divergence passes through the upgrade untouched.  What the baseline buys is
# the ability to say "no NEW divergence", which is the only claim the check
# could ever support.  So the baseline is a *list* of the tables the nodes
# already disagree about, and the post-upgrade check asks whether that list
# grew.

# Write a sorted "node table" list of every replicated relation whose row
# count or existence differs from FIRST_NODE's.
proc_capture_divergence() {
	local tag="$1"
	local out="${REPORT_DIR}/divergence-${tag}.txt"
	local tmpf="${REPORT_DIR}/.divergence-${tag}.raw"
	local node rc rels

	: >"${out}"

	# capture_signature returns the relation count, and capture_relations /
	# capture_rowcounts both turn a failed query into an empty file and a
	# zero status.  Discarding that count -- which this function used to do --
	# meant a snapshot that could not be taken compared equal to another
	# snapshot that could not be taken, and the check reported "nothing out of
	# step" having compared nothing.  Worse, a single failure on one node
	# during the baseline capture put every relation into the baseline, after
	# which comm -13 could never report anything new for the rest of the run.
	local cap_rc=0
	rels="$(capture_signature "${FIRST_NODE}" "${tag}-${FIRST_NODE}" repset)" || cap_rc=$?
	if [ "${cap_rc}" -ne 0 ] || [ -z "${rels}" ] || [ "${rels}" -eq 0 ]; then
		say "divergence (${tag}): the snapshot of ${FIRST_NODE} is incomplete (rc=${cap_rc}, ${rels:-0} relations) -- refusing to compare it"
		return 1
	fi

	for node in ${NODES}; do
		[ "${node}" = "${FIRST_NODE}" ] && continue
		cap_rc=0
		rels="$(capture_signature "${node}" "${tag}-${node}" repset)" || cap_rc=$?
		if [ "${cap_rc}" -ne 0 ] || [ -z "${rels}" ] || [ "${rels}" -eq 0 ]; then
			say "divergence (${tag}): the snapshot of ${node} is incomplete (rc=${cap_rc}, ${rels:-0} relations) -- refusing to compare it"
			return 1
		fi

		rc=0
		diff "${REPORT_DIR}/${tag}-${FIRST_NODE}-rowcounts.txt" \
		     "${REPORT_DIR}/${tag}-${node}-rowcounts.txt" >"${tmpf}" || rc=$?
		if [ "${rc}" -gt 1 ]; then
			say "divergence: diff failed comparing row counts for ${node} (rc=${rc})"
			return 1
		fi
		# The row COUNT stays in the key.  It used to be stripped
		# (`s/...=.*$/\1/`), which made the key just "node relation" -- so a
		# relation that already differed at the requirement-0 baseline was
		# exempt from any further change of any size: 100 vs 101 at the
		# baseline and 100 vs 0 afterwards produced the same key, comm -13
		# emitted nothing, and the rig reported "nothing beyond the baseline".
		# Since the baseline is expected to be non-empty, that was an
		# unbounded blind spot precisely where the document asks for
		# attribution.
		#
		# capture_rowcounts quotes its identifiers and capture_relations does
		# not, so the quotes come off: otherwise one table appears under two
		# spellings and a reader cannot tell one problem from two.
		sed -n 's/^[<>] \(.*\)$/'"${node}"' count \1/p' "${tmpf}" \
			| tr -d '"' >>"${out}"

		rc=0
		diff "${REPORT_DIR}/${tag}-${FIRST_NODE}-relations.txt" \
		     "${REPORT_DIR}/${tag}-${node}-relations.txt" >"${tmpf}" || rc=$?
		if [ "${rc}" -gt 1 ]; then
			say "divergence: diff failed comparing relations for ${node} (rc=${rc})"
			return 1
		fi
		sed -n 's/^[<>] \(.*\) .$/'"${node}"' rel \1/p' "${tmpf}" >>"${out}"
	done

	LC_ALL=C sort -u "${out}" -o "${out}"
	rm -f "${tmpf}"
	log "divergence ${tag}: $(wc -l <"${out}" | tr -d ' ') relation(s) out of step"
}

# Did anything fall out of step that was not already out of step at the
# baseline?  comm needs sorted input, which proc_capture_divergence
# guarantees.
proc_check_no_new_divergence() {
	local tag="$1"
	local base="${REPORT_DIR}/divergence-baseline.txt"
	local now="${REPORT_DIR}/divergence-${tag}.txt"
	local new="${REPORT_DIR}/divergence-new-${tag}.txt"
	local n

	if [ ! -f "${base}" ]; then
		say "divergence (${tag}): no requirement-0 baseline was recorded"
		return 1
	fi
	LC_ALL=C comm -13 "${base}" "${now}" >"${new}"
	n="$(wc -l <"${new}" | tr -d ' ')"
	if [ "${n}" != "0" ]; then
		say "divergence (${tag}): ${n} relation(s) newly out of step -- see ${new}"
		log "divergence (${tag}) new entries:"
		cat "${new}" >>"${MAIN_LOG}"
		return 1
	fi
	say "divergence (${tag}): nothing beyond the requirement-0 baseline"
}

# ---------------------------------------------------------------------------
# Part 1: the required state of node N
# ---------------------------------------------------------------------------

# Requirement 1 -- no subscription anywhere forwards a third node's changes.
#
# Written with coalesce() rather than the document's bare `<>`: a NULL
# sub_forward_origins is not '{}' either, and `NULL <> '{}'` evaluates to
# NULL, so the document's own query silently counts a NULL as compliant.
# Being stricter here can only produce a false failure, never a false pass.
proc_req1_forward_origins() {
	local node n
	for node in ${NODES}; do
		if ! n="$(proc_q "${node}" "
				SELECT count(*) FROM spock.subscription
				WHERE coalesce(sub_forward_origins, '{}'::text[]) <> '{}'::text[];")"; then
			echo "req 1: could not be evaluated on ${node}"
			return 1
		fi
		if [ "${n}" != "0" ]; then
			echo "req 1 FAILS on ${node}: ${n} subscription(s) with non-empty forward_origins"
			return 1
		fi
	done
	echo "req 1 ok: forward_origins is '{}' on every node"
}

# Requirement 2 -- DDL replication off, cluster-wide.
proc_req2_ddl_off() {
	local node v
	for node in ${NODES}; do
		if ! v="$(proc_q "${node}" "SHOW spock.enable_ddl_replication;")"; then
			echo "req 2: could not be evaluated on ${node}"
			return 1
		fi
		if [ "${v}" != "off" ]; then
			echo "req 2 FAILS on ${node}: spock.enable_ddl_replication = ${v}"
			return 1
		fi
	done
	echo "req 2 ok: DDL replication is off on every node"
}

# Requirement 3 -- peers retain WAL for N while it is away.
proc_req3_wal_keep() {
	local target="$1" peer v
	for peer in $(proc_peers "${target}"); do
		if ! v="$(proc_q "${peer}" "SHOW max_slot_wal_keep_size;")"; then
			echo "req 3: could not be evaluated on ${peer}"
			return 1
		fi
		if [ "${v}" != "-1" ]; then
			echo "req 3 FAILS on ${peer}: max_slot_wal_keep_size = ${v}"
			return 1
		fi
	done
	echo "req 3 ok: every peer of ${target} retains WAL without bound"
}

# Requirement 4 -- N is off the write path.
#
# The rig is the only writer, so taking N off the write path is a decision
# it makes rather than a setting it changes; what is checked here is the
# observable consequence the document names -- no user write transaction is
# open on N.  Spock's own workers are excluded by application_name: they are
# not application traffic.
proc_req4_off_write_path() {
	local node="$1" busy
	if ! busy="$(proc_q "${node}" "
			SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database()
			  AND pid <> pg_backend_pid()
			  AND backend_type = 'client backend'
			  AND coalesce(application_name, '') NOT LIKE 'spock%'
			  AND xact_start IS NOT NULL;")"; then
		echo "req 4: could not be evaluated on ${node}"
		return 1
	fi
	if [ "${busy}" != "0" ]; then
		echo "req 4 FAILS on ${node}: ${busy} user transaction(s) still open"
		return 1
	fi
	# PROC_WRITE_PATH_OFF is set by step 1 of this same procedure, so
	# comparing it here proved only that step 1 ran.  It is kept as a rig
	# invariant -- a mismatch means the driver is out of step with itself --
	# but it is not evidence about the node.
	if [ "${PROC_WRITE_PATH_OFF:-}" != "${node}" ]; then
		echo "req 4 FAILS: rig invariant broken -- ${node} is being verified but PROC_WRITE_PATH_OFF is '${PROC_WRITE_PATH_OFF:-}'"
		return 1
	fi

	# The document's second half of requirement 4 -- "N's own commits have
	# stopped" -- needs care, because the obvious reading of it is wrong.
	#
	# The first version of this sampled pg_current_wal_insert_lsn() twice and
	# failed if it had moved more than 16 kB in two seconds.  That passed on a
	# synthetic schema and on the first two nodes of a real one, then failed on
	# the THIRD node of the 721-relation payload with 360 kB in 2 s -- with no
	# client backend connected, no apply worker running, and requirement 5
	# satisfied.  What was writing was autovacuum, which has plenty to do on a
	# database that has just received a full initial sync.  So the check
	# demanded a frozen WAL position on a node where housekeeping legitimately
	# writes, and it did so intermittently, which is worse than not checking.
	#
	# What the document actually asks for is that *application* traffic has
	# stopped -- "no application traffic reaching it" is the first half of the
	# same requirement. Autovacuum is not application traffic.  And the
	# replicable part of "N's own commits" is already bounded hard by
	# requirement 5: every slot at or past LSN0 means the peers have consumed
	# everything N produced, whatever the WAL position does afterwards.
	#
	# So the byte sample is kept as evidence and not as the gate.  It is polled
	# until it settles, because post-sync housekeeping is a burst and not a
	# steady state; if it will not settle, what decides the verdict is whether a
	# CLIENT BACKEND is writing, which is the thing requirement 4 is about.
	local lsn_a lsn_b delta attempt settled=0
	for attempt in 1 2 3 4 5; do
		lsn_a="$(proc_q "${node}" "SELECT pg_current_wal_insert_lsn()::text;")" || return 1
		sleep 2
		lsn_b="$(proc_q "${node}" "SELECT pg_current_wal_insert_lsn()::text;")" || return 1
		if ! delta="$(proc_q "${node}" \
				"SELECT '${lsn_b}'::pg_lsn - '${lsn_a}'::pg_lsn;")"; then
			return 1
		fi
		case "${delta%%.*}" in
			'' | *[!0-9]*)
				echo "req 4 FAILS on ${node}: could not measure the WAL delta (got '${delta}')"
				return 1 ;;
		esac
		if [ "${delta%%.*}" -le "${PROC_IDLE_WAL_BYTES}" ]; then
			settled=1
			break
		fi
		echo "req 4: ${node} WAL advanced ${delta} bytes in 2s (attempt ${attempt}/5), waiting for it to settle"
	done

	if [ "${settled}" -eq 1 ]; then
		echo "req 4 ok: no user write transactions on ${node}, WAL advanced ${delta} bytes in 2s"
		return 0
	fi

	# Did not settle.  Decide on application traffic, not on bytes.
	local writers
	if ! writers="$(proc_q "${node}" "
			SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database()
			  AND pid <> pg_backend_pid()
			  AND backend_type = 'client backend'
			  AND coalesce(application_name, '') NOT LIKE 'spock%'
			  AND state IN ('active', 'idle in transaction');")"; then
		echo "req 4: could not re-check for client backends on ${node}"
		return 1
	fi
	echo "----- what is running on ${node} -----"
	psql_on "${node}" -c \
		"SELECT pid, application_name, backend_type, state,
		        left(coalesce(query, ''), 60) AS query
		 FROM pg_stat_activity WHERE datname = current_database()
		 ORDER BY backend_type, backend_start;" \
		|| echo "  (activity list could not be read)"

	if [ "${writers}" != "0" ]; then
		echo "req 4 FAILS on ${node}: WAL still advancing (${delta} bytes/2s) AND ${writers} client backend(s) active -- this is application traffic, not housekeeping"
		return 1
	fi

	echo "req 4 ok (with a note): ${node} has no application traffic -- no client backend"
	echo "  is connected and no apply worker is running -- but its WAL is still"
	echo "  advancing at ${delta} bytes/2s from background activity, most likely"
	echo "  autovacuum after the initial sync. That is housekeeping, not commits"
	echo "  the peers need; the replicable part is bounded by requirement 5,"
	echo "  which is checked separately and must hold."
	return 0
}

# Requirement 5 -- every peer has consumed everything N produced, measured
# on N as the confirmed flush position of its own slots.
#
# Polled rather than sampled once, exactly as the document insists: a peer
# applying the sync event and N's walsender processing that peer's feedback
# are two different instants, and a single sample taken between them shows
# slots behind for no reason.
proc_req5_slots_drained() {
	local node="$1" lsn0="$2" timeout="${3:-}"
	local deadline behind total
	if [ -z "${timeout}" ]; then
		timeout="$(proc_sync_budget "${node}")" || return 1
	fi
	deadline=$(( $(date +%s) + timeout ))
	# A node with no slots at all reports zero slots behind LSN0, which is how
	# this check used to announce "every slot is at or past LSN0" without any
	# peer having been observed to consume anything.  Requirement 5 is the sole
	# justification for synchronize_data := false in step 9, so it is the one
	# check that must not be satisfiable by counting nothing.  Step 12 already
	# applies this reasoning to subscriptions; it was missing here.
	if ! total="$(proc_q "${node}" "SELECT count(*) FROM pg_replication_slots;")"; then
		echo "req 5: could not count the slots on ${node}"
		return 1
	fi
	if [ "${total}" != "${PROC_SUBS_PER_NODE}" ]; then
		echo "req 5 FAILS on ${node}: ${total} replication slot(s), expected ${PROC_SUBS_PER_NODE} (one per peer)"
		psql_on "${node}" -c \
			"SELECT slot_name, active, confirmed_flush_lsn
			 FROM pg_replication_slots ORDER BY 1;" || \
			echo "  (slot list could not be read)"
		return 1
	fi

	while :; do
		if ! behind="$(proc_q "${node}" "
				SELECT count(*) FROM pg_replication_slots
				WHERE confirmed_flush_lsn IS NULL
				   OR confirmed_flush_lsn < '${lsn0}'::pg_lsn;")"; then
			echo "req 5: could not be evaluated on ${node}"
			return 1
		fi
		[ "${behind}" = "0" ] && break
		if [ "$(date +%s)" -ge "${deadline}" ]; then
			echo "req 5 FAILS on ${node}: ${behind} slot(s) still behind ${lsn0} after ${timeout}s"
			psql_on "${node}" -c \
				"SELECT slot_name, active, confirmed_flush_lsn
				 FROM pg_replication_slots ORDER BY 1;" || \
				echo "  (slot list could not be read)"
			return 1
		fi
		sleep 1
	done
	echo "req 5 ok: every slot on ${node} is at or past ${lsn0}"
	psql_on "${node}" -c \
		"SELECT slot_name, active, confirmed_flush_lsn
		 FROM pg_replication_slots ORDER BY 1;"
}

# Requirement 6 -- N's subscriptions are disabled and its apply workers are
# gone.  Both halves, because sub_disable returns as soon as the catalog is
# updated; the worker exits on its own time.
proc_req6_workers_gone() {
	local node="$1" timeout="${2:-60}"
	local deadline reps workers
	deadline=$(( $(date +%s) + timeout ))
	while :; do
		if ! reps="$(proc_q "${node}" "
				SELECT count(*) FROM spock.sub_show_status()
				WHERE status = 'replicating';")"; then
			echo "req 6: could not be evaluated on ${node}"
			return 1
		fi
		if ! workers="$(proc_q "${node}" "
				SELECT count(*) FROM pg_stat_activity
				WHERE application_name LIKE 'spock apply%';")"; then
			echo "req 6: could not be evaluated on ${node}"
			return 1
		fi
		if [ "${reps}" = "0" ] && [ "${workers}" = "0" ]; then
			echo "req 6 ok: ${node} has no replicating subscription and no apply worker"
			return 0
		fi
		if [ "$(date +%s)" -ge "${deadline}" ]; then
			echo "req 6 FAILS on ${node}: replicating=${reps} apply workers=${workers} after ${timeout}s"
			return 1
		fi
		sleep 1
	done
}

# ---------------------------------------------------------------------------
# The commit-timestamp claim
# ---------------------------------------------------------------------------
#
# The document's third preamble claim is that pg_commit_ts is never copied,
# so every xid from before the upgrade reads back with no commit timestamp
# afterwards.  Spock's last_update_wins resolution is built on that
# timestamp, so if the claim is wrong in either direction the document's
# reasoning about conflicts is wrong.  Checked with a probe row committed as
# late as possible on the old cluster, and a negative control: if the
# timestamp is already unavailable *before* the upgrade the probe proves
# nothing and the rig says so rather than banking a free pass.

proc_committs_probe_before() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local xid ts

	if ! psql_on "${node}" -c "
			INSERT INTO ${PROC_WITNESS_TABLE} (node, wseq, phase)
			SELECT '${node}',
			       coalesce((SELECT max(wseq) FROM ${PROC_WITNESS_TABLE}
			                 WHERE node = '${node}'), 0) + 1,
			       'committs-probe';" >>"${PROC_LOG}" 2>&1; then
		say "commit-ts probe: could not write the probe row on ${node}"
		return 1
	fi

	if ! xid="$(proc_q "${node}" "
			SELECT xmin::text::bigint FROM ${PROC_WITNESS_TABLE}
			WHERE node = '${node}' AND phase = 'committs-probe'
			ORDER BY wseq DESC LIMIT 1;")"; then
		return 1
	fi
	case "${xid}" in
		'' | *[!0-9]*)
			say "commit-ts probe: ${node} returned no usable xid ('${xid}')"
			return 1 ;;
	esac
	if [ "${xid}" -le 2 ]; then
		say "commit-ts probe: ${node} returned a special xid (${xid}); the probe row was frozen"
		return 1
	fi

	if ! ts="$(proc_q "${node}" "
			SELECT coalesce(pg_xact_commit_timestamp('${xid}'::text::xid)::text, 'NULL');")"; then
		return 1
	fi
	if [ "${ts}" = "NULL" ]; then
		say "commit-ts probe: ${node} has no commit timestamp for xid ${xid} even before the upgrade"
		return 1
	fi

	printf '%s\n' "${xid}" >"${dir}/committs-xid.txt"
	log "commit-ts probe on ${node}: xid ${xid} committed at ${ts}"
}

proc_committs_probe_after() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local xid ts

	if ! xid="$(cat "${dir}/committs-xid.txt")"; then
		say "commit-ts probe: no recorded xid for ${node}"
		return 1
	fi

	# An xid outside the new cluster's commit-ts range comes back as NULL on
	# every supported major, but an error would mean the same thing -- the
	# timestamp is gone -- so both are accepted here and only a *retrievable*
	# timestamp counts as the document being wrong.
	if ! ts="$(psql_on "${node}" -At -c "
			SELECT coalesce(pg_xact_commit_timestamp('${xid}'::text::xid)::text, 'NULL');" \
			2>>"${PROC_LOG}")"; then
		ts="ERROR"
	fi

	case "${ts}" in
		NULL | ERROR)
			log "commit-ts: ${node} no longer has a timestamp for pre-upgrade xid ${xid} (${ts}), as the document states"
			printf 'commit-ts on %s: xid %s -> %s (as documented)\n' \
				"${node}" "${xid}" "${ts}" >>"${PROC_LOG}" ;;
		*)
			proc_finding "${node}: the commit timestamp for pre-upgrade xid ${xid} survived pg_upgrade (${ts}); the document states it cannot" ;;
	esac
}

# ---------------------------------------------------------------------------
# Part 2, Fence: steps 2, 3 and 4
# ---------------------------------------------------------------------------

# Step 2 -- emit a sync event on N, wait for every peer to apply it, then
# wait for N's own slots to confirm past it.
_do_proc_step2_fence() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local lsn0 peer

	if ! lsn0="$(proc_q "${node}" "SELECT spock.sync_event();")"; then
		echo "step 2: spock.sync_event() failed on ${node}"
		return 1
	fi
	if [ -z "${lsn0}" ]; then
		echo "step 2: spock.sync_event() on ${node} returned nothing"
		return 1
	fi
	printf '%s\n' "${lsn0}" >"${dir}/lsn0.txt"
	echo "step 2: ${node} emitted a sync event at LSN0=${lsn0}"

	local budget
	for peer in $(proc_peers "${node}"); do
		# The wait happens on the peer, so the budget is the peer's -- which
		# during a rolling upgrade may still be a 5.x node with no
		# spock.sync_timeout at all.  proc_sync_budget copes with that; what
		# it must not do is read the fenced node's setting and apply it to
		# somebody else's wait.
		budget="$(proc_sync_budget "${peer}")" || return 1
		echo "step 2: waiting up to ${budget}s for ${peer} to apply LSN0"
		# A timeout is passed on purpose.  wait_for_sync_event defaults to 0,
		# which means wait forever: a peer that never confirms would hang
		# this step and step 5 would never be reached.
		psql_on "${peer}" -c "
			DO \$w\$
			DECLARE r bool;
			BEGIN
				CALL spock.wait_for_sync_event(
					r, '${node}'::name, '${lsn0}'::pg_lsn, ${budget});
				IF NOT r THEN
					RAISE EXCEPTION
						'sync event ${lsn0} from ${node} was not applied on ${peer} within ${budget}s';
				END IF;
			END
			\$w\$;" || return 1
	done

	proc_req5_slots_drained "${node}" "${lsn0}"
}

# Step 3 -- disable each subscription on N and wait for the workers to go.
_do_proc_step3_disable() {
	local node="$1"

	# sub_disable(..., false) -- deliberately not `immediate`.  An immediate
	# disable stops the apply worker mid-stream and strands whatever it had
	# not yet consumed, which is precisely what requirement 6 is waiting to
	# see finish.
	psql_on "${node}" -c "
		DO \$d\$
		DECLARE s record;
		BEGIN
			FOR s IN SELECT sub_name FROM spock.subscription ORDER BY sub_name LOOP
				RAISE NOTICE 'disabling %', s.sub_name;
				PERFORM spock.sub_disable(s.sub_name, false);
			END LOOP;
		END
		\$d\$;" || return 1

	proc_req6_workers_gone "${node}"
}

# Step 4 / requirement 7(a) -- N's inbound positions, one line per
# subscription.  The count must match spock.subscription, and a MISSING line
# means a subscription with no origin, which the document says must be
# diagnosed rather than upgraded.
_do_proc_step4_record_inbound() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local subs lines

	psql_on "${node}" -At -c "
		SELECT s.sub_name || '|' || s.sub_slot_name || '|' ||
		       coalesce(o.remote_lsn::text, 'MISSING')
		FROM spock.subscription s
		LEFT JOIN pg_replication_origin_status o
		       ON o.external_id = s.sub_slot_name
		ORDER BY 1;" >"${dir}/inbound.txt" || return 1

	if ! subs="$(proc_q "${node}" "SELECT count(*) FROM spock.subscription;")"; then
		return 1
	fi
	if [ "${subs}" = "0" ]; then
		echo "req 7(a) FAILS: ${node} has no subscriptions -- there is nothing to fence"
		return 1
	fi

	lines="$(wc -l <"${dir}/inbound.txt" | tr -d ' ')"
	if [ "${lines}" != "${subs}" ]; then
		echo "req 7(a) FAILS on ${node}: ${lines} recorded line(s) for ${subs} subscription(s)"
		cat "${dir}/inbound.txt"
		return 1
	fi
	if grep -q '|MISSING$' "${dir}/inbound.txt"; then
		echo "req 7(a) FAILS on ${node}: a subscription has no replication origin:"
		grep '|MISSING$' "${dir}/inbound.txt"
		return 1
	fi

	echo "req 7(a) ok: ${lines} inbound position(s) recorded for ${node}"
	cat "${dir}/inbound.txt"
}

# Step 4 / requirement 7(b) -- the definition of the subscription each peer
# will drop and recreate in step 9, recorded from the peer itself.
#
# Recorded in the peer's own dialect: Spock 5 has no sub_skip_schema column
# and Spock 6 does, and during a rolling upgrade the peers may be on either.
# The record says NOCOLUMN when the peer cannot describe that field at all,
# which is different from the peer describing it as empty.
_do_proc_step4_record_peers() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local peer subname has_col cols out

	for peer in $(proc_peers "${node}"); do
		subname="sub_${node}_${peer}"

		if ! has_col="$(proc_q "${peer}" "
				SELECT count(*) FROM pg_attribute
				WHERE attrelid = 'spock.subscription'::regclass
				  AND attname = 'sub_skip_schema'
				  AND NOT attisdropped;")"; then
			return 1
		fi

		# The document states twice that Spock 5 has neither the
		# sub_skip_schema column nor the skip_schema argument.  It is wrong:
		# sql/spock--5.0.1--5.0.2.sql adds both, so every 5.x from 5.0.2
		# onward has them.  Probing rather than assuming is still the right
		# design -- it is what the document itself prescribes -- but probing
		# quietly absorbed the error instead of reporting it, and the branches
		# written for the claim are dead code.  Report it once per peer that
		# contradicts the document.
		if [ "${has_col}" != "0" ]; then
			local peer_spock
			peer_spock="$(proc_q "${peer}" "
				SELECT coalesce(extversion, '?') FROM pg_extension
				WHERE extname = 'spock';")" || peer_spock="?"
			case "${peer_spock}" in
				5.*) proc_finding "${peer} runs spock ${peer_spock} and does have sub_skip_schema; the document states Spock 5 has no such column (and no skip_schema argument). Both were added in spock--5.0.1--5.0.2.sql." ;;
			esac
		fi

		# coalesce on every array: sub_create cannot be handed a NULL, and a
		# NULL rendered as the empty string would come back as a cast error
		# in step 9 rather than as the missing value it is.
		cols="coalesce(sub_replication_sets::text, '{}'),"
		cols="${cols} coalesce(sub_forward_origins::text, '{}'),"
		cols="${cols} sub_apply_delay::text,"
		cols="${cols} sub_force_text_transfer::text,"
		cols="${cols} sub_enabled::text,"
		cols="${cols} sub_skip_lsn::text,"
		if [ "${has_col}" != "0" ]; then
			cols="${cols} coalesce(sub_skip_schema::text, '{}')"
		else
			cols="${cols} 'NOCOLUMN'"
		fi

		if ! out="$(psql_on "${peer}" -At -F '|' -c "
				SELECT ${cols} FROM spock.subscription
				WHERE sub_name = '${subname}';" 2>&1)"; then
			echo "req 7(b) FAILS: could not read ${subname} on ${peer}: ${out}"
			return 1
		fi
		if [ -z "${out}" ]; then
			echo "req 7(b) FAILS: ${peer} has no subscription ${subname} to record"
			return 1
		fi
		printf '%s\n' "${out}" >"${dir}/peersub-${peer}.txt"
		echo "req 7(b) ok: ${peer}/${subname} -> ${out}"

		# sub_skip_lsn is recorded for information only: sub_create has no
		# parameter for it and recreation resets it to 0/0.  Say so here
		# rather than let a non-zero value disappear quietly in step 9.
		case "${out}" in
			*'|0/0|'*) ;;
			*) echo "NOTE: ${peer}/${subname} carries a non-zero sub_skip_lsn;" \
			        "step 9 cannot restore it and it must be re-applied by hand"
			   printf 'skip-lsn %s %s\n' "${peer}" "${out}" \
			        >>"${dir}/manual-followup.txt" ;;
		esac
	done
}

# Step 5 -- STOP AND VERIFY.  Every check in Part 1, run again, together.
_do_proc_step5_verify() {
	local node="$1" rc=0 peer lsn0
	local dir; dir="$(proc_fence_dir "${node}")"

	if ! lsn0="$(cat "${dir}/lsn0.txt")"; then
		echo "step 5: no LSN0 was recorded for ${node}"
		return 1
	fi

	proc_req1_forward_origins                       || rc=1
	proc_req2_ddl_off                               || rc=1
	proc_req3_wal_keep       "${node}"              || rc=1
	proc_req4_off_write_path "${node}"              || rc=1
	proc_req5_slots_drained  "${node}" "${lsn0}" 30 || rc=1
	proc_req6_workers_gone   "${node}" 30           || rc=1

	# Requirement 7 was verified as it was recorded, in step 4; re-checked
	# here so that step 5 really is "run every check in Part 1".
	if [ ! -s "${dir}/inbound.txt" ]; then
		echo "req 7(a) FAILS: no fence record for ${node}"
		rc=1
	fi
	for peer in $(proc_peers "${node}"); do
		if [ ! -s "${dir}/peersub-${peer}.txt" ]; then
			echo "req 7(b) FAILS: no recorded definition for sub_${node}_${peer} on ${peer}"
			rc=1
		fi
	done

	if [ "${rc}" -eq 0 ]; then
		echo "step 5: every Part 1 requirement holds for ${node}"
	fi
	return "${rc}"
}

# ---------------------------------------------------------------------------
# Part 2, Upgrade: steps 6 and 7
# ---------------------------------------------------------------------------

# Step 7 -- "Spock upgrades its own catalog on startup, so no manual
# ALTER EXTENSION spock UPDATE is needed."  Checked by not running one and
# waiting to see whether pg_extension.extversion catches up on its own.
_do_proc_step7_extension_self_update() {
	local node="$1" timeout="$2"
	local deadline got
	deadline=$(( $(date +%s) + timeout ))
	while :; do
		if ! got="$(proc_q "${node}" "
				SELECT coalesce(extversion, 'NONE') FROM pg_extension
				WHERE extname = 'spock';")"; then
			echo "step 7: could not read pg_extension on ${node}"
			return 1
		fi
		if [ "${got}" = "${SPOCK_V6_VERSION}" ]; then
			echo "step 7 ok: ${node} reports spock ${got} with no manual ALTER EXTENSION"
			return 0
		fi
		if [ "$(date +%s)" -ge "${deadline}" ]; then
			echo "step 7: ${node} still reports spock '${got}' after ${timeout}s;" \
			     "the library is ${SPOCK_V6_VERSION}"
			return 1
		fi
		sleep 3
	done
}

# ---------------------------------------------------------------------------
# Part 2, Restore: steps 8, 9 and 10
# ---------------------------------------------------------------------------

# Step 8 -- recreate each origin on N and put it back exactly where the
# record says it was, then confirm each one landed.
_do_proc_step8_restore_origins() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local subname slot lsn existed got bad=0
	local recorded done_n=0 checked=0

	# grep -c '' counts lines and exits 1 on an empty file; an empty fence
	# record must not read as "nothing to restore, so nothing went wrong".
	recorded="$(grep -c '' "${dir}/inbound.txt")" || recorded=0
	if [ "${recorded}" = "0" ]; then
		echo "step 8 FAILS: the fence record for ${node} is empty"
		return 1
	fi
	rm -f "${dir}/origin-survived"

	# `|| [ -n "${subname}" ]` so a final line with no trailing newline is
	# still processed.  psql -At always terminates its last line, but a
	# fence record silently one origin short is the single worst way for
	# this step to fail, so it does not rest on that.
	while IFS='|' read -r subname slot lsn || [ -n "${subname}" ]; do
		[ -n "${subname}" ] || continue
		if ! existed="$(proc_q "${node}" "
				SELECT count(*) FROM pg_replication_origin
				WHERE roname = '${slot}';")"; then
			return 1
		fi
		if [ "${existed}" != "0" ]; then
			# The document says the origin does not survive.  If it did, the
			# create would fail and following the document literally would
			# stop here -- so record it and carry on with the advance, which
			# is the step that actually matters.
			echo "STEP 8: origin ${slot} already existed after pg_upgrade"
			printf '%s\n' "${slot}" >>"${dir}/origin-survived"
		else
			psql_on "${node}" -c \
				"SELECT pg_replication_origin_create('${slot}');" || return 1
		fi
		psql_on "${node}" -c \
			"SELECT pg_replication_origin_advance('${slot}', '${lsn}'::pg_lsn);" \
			|| return 1
		done_n=$(( done_n + 1 ))
	done <"${dir}/inbound.txt"

	if [ "${done_n}" != "${recorded}" ]; then
		echo "step 8 FAILS: ${done_n} origin(s) restored from a ${recorded}-line record"
		return 1
	fi

	echo "----- origins on ${node} after step 8 -----"
	psql_on "${node}" -c \
		"SELECT external_id, remote_lsn FROM pg_replication_origin_status
		 ORDER BY 1;" || return 1

	# Confirm each landed where the record says.  The document asks for this
	# explicitly, and by eye is how a mistyped LSN reaches production.
	#
	# Compared as pg_lsn and not as text.  PostgreSQL 18 changed how pg_lsn is
	# rendered -- the low half is zero-padded to eight hex digits, so the
	# position PG17 prints as 0/1C99C30 comes back from PG19 as 0/01C99C30 --
	# and this step reads a record written on the old major back on the new
	# one.  A text comparison therefore fails on every origin of a correctly
	# restored cluster, which is a rig bug; but the document prescribes exactly
	# that eyeball comparison, so the trap is reported as well as avoided.
	local rendering_noted=0
	while IFS='|' read -r subname slot lsn || [ -n "${subname}" ]; do
		[ -n "${subname}" ] || continue
		checked=$(( checked + 1 ))
		if ! got="$(proc_q "${node}" "
				SELECT coalesce(max(remote_lsn)::text, 'NONE')
				FROM pg_replication_origin_status
				WHERE external_id = '${slot}';")"; then
			return 1
		fi
		# The value question, asked of the server so that neither major's
		# text convention enters into it.  A word rather than a boolean:
		# `boolean::text` renders as 'true'/'false' while psql -At renders an
		# uncast boolean column as 't'/'f', and comparing against the wrong
		# one of those pairs is how this check first failed on a cluster that
		# was in fact correct.  MISSING is a third answer, and a distinct
		# one -- the origin has no status row at all.
		local same
		# An aggregate over no rows still returns one row, so the NULL arm is
		# what reports an origin with no status entry; a coalesce around the
		# subquery would never fire and MISSING would be unreachable.
		if ! same="$(proc_q "${node}" "
				SELECT CASE
				         WHEN max(remote_lsn) IS NULL THEN 'MISSING'
				         WHEN max(remote_lsn) = '${lsn}'::pg_lsn THEN 'SAME'
				         ELSE 'DIFFERENT'
				       END
				FROM pg_replication_origin_status
				WHERE external_id = '${slot}';")"; then
			return 1
		fi
		if [ "${same}" != "SAME" ]; then
			echo "step 8 FAILS: origin ${slot} is at ${got}, the record says ${lsn} (compared as pg_lsn: ${same})"
			bad=1
			continue
		fi
		if [ "${got}" != "${lsn}" ]; then
			echo "step 8: origin ${slot} is at the recorded position, but it renders" \
			     "as ${got} here and was recorded as ${lsn}"
			if [ "${rendering_noted}" -eq 0 ]; then
				rendering_noted=1
				proc_finding "${node}: an inbound position recorded on the old major renders differently on the new one (recorded ${lsn}, reads back as ${got}) -- the same pg_lsn value, zero-padded since PostgreSQL 18. The document's step 8 says to confirm the origins landed by reading remote_lsn back and looking at it; across a major boundary that comparison has to be made as pg_lsn, or every correctly restored origin looks wrong."
			fi
		fi
	done <"${dir}/inbound.txt"

	if [ "${bad}" -ne 0 ]; then
		return 1
	fi
	if [ "${checked}" != "${recorded}" ]; then
		echo "step 8 FAILS: ${checked} of ${recorded} recorded origin(s) were verified"
		return 1
	fi
	echo "step 8 ok: all ${checked} origin(s) on ${node} are back at their recorded positions"
}

# The preamble claims the outbound position "cannot be preserved: a slot can
# only be created at the current position", and step 9 that "the slot that
# lived on N died with it, and nothing recreates it".  From a PG17-or-later old
# cluster pg_upgrade migrates logical slots -- and the default old
# major IS 17 -- so in the configuration under test the claim may simply be
# false.  Measured rather than assumed, exactly as the origin claim is.
_do_proc_slot_census() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local n

	if ! n="$(proc_q "${node}" "SELECT count(*) FROM pg_replication_slots;")"; then
		echo "could not count the slots on ${node}"
		return 1
	fi
	printf '%s\n' "${n}" >"${dir}/slots-after-upgrade.txt"
	echo "${node}: ${n} replication slot(s) survived pg_upgrade"
	psql_on "${node}" -c \
		"SELECT slot_name, plugin, active, confirmed_flush_lsn
		 FROM pg_replication_slots ORDER BY 1;"
}

# Does the slot that came through pg_upgrade actually carry data?
#
# _do_proc_slot_census counts slots.  A slot that exists -- even one whose
# pg_replication_slots row says active=true -- is not evidence that a change
# made on N now reaches the peer, and that is precisely the question step 9
# turns on.  The document says the outbound position "cannot be preserved" and
# that the slot "died with it"; from a PG17-or-later old cluster pg_upgrade
# migrates the slot instead, and the interesting follow-up is whether the
# migrated slot WORKS or merely exists.
#
# So: emit a sync event on N and see whether each peer applies it.
#
# Safe on a fenced node.  spock.sync_event(false) emits a non-transactional
# logical WAL message -- LogLogicalMessage in spock_create_sync_event() -- and
# writes no row in any table, so it cannot put user data on N or create
# divergence with anybody.  The document's own step 2 emits one on N while N
# is fenced, for the same reason.
#
# Measurement, not a gate: at this point in the procedure the document EXPECTS
# the peers' subscriptions to be dead, so non-delivery is the documented
# outcome and delivery is the surprise.  The verdict is folded into the slot
# census finding rather than raised separately.
#
# Writes DELIVERED / NOT-DELIVERED / NO-SUBSCRIPTION per peer to
# <fence dir>/slot-delivery.txt, and the overall word to stdout.
_do_proc_verify_surviving_slot() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local peer lsn budget subname status delivered=0 attempted=0

	: >"${dir}/slot-delivery.txt"

	if ! lsn="$(proc_q "${node}" "SELECT spock.sync_event();")"; then
		echo "could not emit a sync event on ${node}"
		return 1
	fi
	if [ -z "${lsn}" ]; then
		echo "spock.sync_event() on ${node} returned nothing"
		return 1
	fi
	echo "${node}: emitted a post-upgrade sync event at ${lsn}"

	for peer in $(proc_peers "${node}"); do
		subname="sub_${node}_${peer}"

		# A peer with no enabled subscription cannot apply anything, and
		# waiting on it would just burn the budget to learn what the catalog
		# already says.
		# bool_or and a CASE, not max(sub_enabled): PostgreSQL has no
		# max(boolean) aggregate at all, so the obvious spelling of this made
		# every peer come back as "could not read".
		#
		# And a failed read is recorded as PROBE-FAILED, not as
		# NO-SUBSCRIPTION.  Mapping it to "no subscription" is what turned a
		# broken query into the reassuring conclusion "there was nothing to
		# deliver to" -- and that conclusion then propagated all the way into
		# the finding text.
		if ! status="$(proc_q "${peer}" "
				SELECT CASE
				         WHEN count(*) = 0        THEN 'NONE'
				         WHEN bool_or(sub_enabled) THEN 'ENABLED'
				         ELSE 'DISABLED'
				       END
				FROM spock.subscription WHERE sub_name = '${subname}';")"; then
			echo "  ${peer}: could not read ${subname} -- the probe failed, which is not the same as there being nothing to deliver to"
			printf '%s PROBE-FAILED\n' "${peer}" >>"${dir}/slot-delivery.txt"
			continue
		fi
		if [ "${status}" != "ENABLED" ]; then
			echo "  ${peer}: ${subname} is ${status} -- nothing to deliver to"
			printf '%s NO-SUBSCRIPTION\n' "${peer}" >>"${dir}/slot-delivery.txt"
			continue
		fi

		attempted=$(( attempted + 1 ))
		# The peer does the waiting, so the budget is the peer's.  Bounded
		# tighter than a full synchronisation wait on purpose: this is a
		# single logical message on an otherwise idle edge, and the answer
		# "it did not arrive" is as useful as "it did".
		budget="$(proc_sync_budget "${peer}")" || return 1
		[ "${budget}" -gt 60 ] && budget=60
		echo "  ${peer}: waiting up to ${budget}s for ${lsn}"
		# stderr is kept, and it decides which of two very different answers
		# this is.  The RAISE below is the intended negative -- the event was
		# not applied in time.  Anything else (no such function, connection
		# refused) means the probe did not run, which is PROBE-FAILED and not
		# evidence about the slot.  Discarding stderr made the two identical,
		# and PROBE-FAILED was unreachable as a result.
		local probe_err
		if probe_err="$(psql_on "${peer}" -c "
				DO \$w\$
				DECLARE r bool;
				BEGIN
					CALL spock.wait_for_sync_event(
						r, '${node}'::name, '${lsn}'::pg_lsn, ${budget});
					IF NOT r THEN
						RAISE EXCEPTION 'not applied within ${budget}s';
					END IF;
				END
				\$w\$;" 2>&1)"; then
			echo "  ${peer}: DELIVERED -- the surviving slot really does carry data"
			printf '%s DELIVERED\n' "${peer}" >>"${dir}/slot-delivery.txt"
			delivered=$(( delivered + 1 ))
		elif printf '%s' "${probe_err}" | grep -q 'not applied within'; then
			echo "  ${peer}: NOT DELIVERED within ${budget}s"
			printf '%s NOT-DELIVERED\n' "${peer}" >>"${dir}/slot-delivery.txt"
		else
			echo "  ${peer}: the delivery probe could not run:"
			printf '%s\n' "${probe_err}" | sed 's/^/      /'
			printf '%s PROBE-FAILED\n' "${peer}" >>"${dir}/slot-delivery.txt"
		fi
	done

	echo "post-upgrade delivery from ${node}: ${delivered} of ${attempted} live subscription(s) applied the event"
	if grep -q 'PROBE-FAILED' "${dir}/slot-delivery.txt"; then
		printf 'PROBE-FAILED\n' >"${dir}/slot-delivery-verdict.txt"
	elif [ "${attempted}" -eq 0 ]; then
		printf 'NONE-LIVE\n' >"${dir}/slot-delivery-verdict.txt"
	elif [ "${delivered}" -eq "${attempted}" ]; then
		printf 'ALL\n' >"${dir}/slot-delivery-verdict.txt"
	elif [ "${delivered}" -eq 0 ]; then
		printf 'NONE\n' >"${dir}/slot-delivery-verdict.txt"
	else
		printf 'SOME\n' >"${dir}/slot-delivery-verdict.txt"
	fi
}

# Step 9 -- on each peer, drop and recreate the one subscription that pulled
# from N, from the requirement 7(b) record rather than from sub_create's
# defaults.
# Between step 5 and step 6 -- drop each peer's subscription to N.
#
# The document has no such step.  It leaves every peer subscribed to N for the
# whole upgrade window and rebuilds the subscriptions afterwards in step 9, so
# from the moment N is fenced until step 9 runs, every peer's apply worker is
# retrying N's address in a loop.  Three reasons that is worth changing, and
# the third is the one that decides it:
#
#   - The fence is half a fence.  Step 3 stops N applying; nothing stops the
#     peers pulling from N.
#   - Whatever comes up at N's address collects those connections.  Here that
#     was the short-lived server pg_upgrade starts, whose slot check then
#     failed with `replication slot "..." is active for PID` -- intermittently,
#     depending on whether a reconnect landed inside the check window.  In
#     production it is the upgraded instance itself, reached before step 8 has
#     restored anything.
#   - spock.sub_drop() drops the slot on the provider, but only while it can
#     still reach it: spock_drop_remote_slot() in src/spock_functions.c logs
#     `could not drop slot "%s" on provider, you will probably have to drop it
#     manually` and carries on.  Dropping after N is down therefore leaves the
#     slot behind and mentions it only in passing.  Dropping while N is up
#     removes it, and N enters pg_upgrade with no logical slots at all.
#
# Nothing is lost by dropping this early.  Step 2 drove every peer's debt on N
# to zero -- the document's own precondition for rebuilding a slot at the
# current position -- and step 4 has already recorded the definitions step 9
# rebuilds from.
_do_proc_fence_drop_peer_subs() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local peer subname left

	for peer in $(proc_peers "${node}"); do
		subname="sub_${node}_${peer}"
		# Refuse to drop what step 9 would have nothing to rebuild from.
		[ -f "${dir}/peersub-${peer}.txt" ] 			|| { echo "no recorded definition for ${subname}; not dropping it"; return 1; }
		echo "----- ${peer}: sub_drop(${subname}), ${node} still up -----"
		psql_on "${peer}" -c "SELECT spock.sub_drop('${subname}');" || return 1
	done

	# Asserted, not assumed: sub_drop warns rather than fails when it cannot
	# reach the provider, so "it returned" is not "the slot is gone".  A slot
	# left here is one a peer could still attach to.
	left="$(psql_on "${node}" -At -c "
		SELECT count(*) FROM pg_replication_slots
		WHERE slot_name LIKE 'spk\\_%';")" || return 1
	if [ "${left}" != "0" ]; then
		echo "${node} still has ${left} spock slot(s) after every peer subscription was dropped:"
		psql_on "${node}" -c \
			"SELECT slot_name, active, confirmed_flush_lsn
			 FROM pg_replication_slots ORDER BY 1;"
		return 1
	fi
	echo "${node}: no spock replication slots remain -- nothing for a peer to reconnect to"
}

_do_proc_step9_recreate_peer_subs() {
	local node="$1"
	local dir; dir="$(proc_fence_dir "${node}")"
	local peer subname rec has_arg args
	local repsets fwd delay force enabled skiplsn skipschema

	for peer in $(proc_peers "${node}"); do
		subname="sub_${node}_${peer}"
		if ! rec="$(cat "${dir}/peersub-${peer}.txt")"; then
			echo "step 9: no recorded definition for ${subname}"
			return 1
		fi
		# skiplsn is read to reach skipschema and then reported, not used:
		# sub_create has no such argument, so it cannot be restored.
		IFS='|' read -r repsets fwd delay force enabled skiplsn skipschema <<<"${rec}"
		echo "step 9: recorded sub_skip_lsn for ${subname} = ${skiplsn:-(none)} (not restorable)"

		if [ -z "${repsets}" ] || [ -z "${fwd}" ] || [ -z "${delay}" ] \
			|| [ -z "${force}" ]; then
			echo "step 9: the record for ${subname} is incomplete: ${rec}"
			return 1
		fi

		# The subscription was dropped before the upgrade, by
		# _do_proc_fence_drop_peer_subs.  Dropped again only if it somehow
		# survived that, because sub_create fails on a duplicate name and the
		# useful message would be lost behind it.
		local still
		still="$(proc_q "${peer}" "
			SELECT count(*) FROM spock.subscription
			WHERE sub_name = '${subname}';")" || return 1
		if [ "${still}" != "0" ]; then
			echo "----- ${peer}: ${subname} unexpectedly still present, dropping -----"
			psql_on "${peer}" -c "SELECT spock.sub_drop('${subname}');" || return 1
		fi

		# Ask the peer what its sub_create accepts rather than assuming a
		# fixed list, exactly as the document prescribes: Spock 5 has no
		# skip_schema argument and Spock 6 does.
		if ! has_arg="$(proc_q "${peer}" "
				SELECT count(*) FROM pg_proc p
				JOIN pg_namespace n ON n.oid = p.pronamespace
				WHERE n.nspname = 'spock'
				  AND p.proname = 'sub_create'
				  AND p.proargnames @> ARRAY['skip_schema'];")"; then
			return 1
		fi

		# The five replication options come from the record; the last three
		# are fixed by the procedure.  Passing sub_create's literal defaults
		# instead is the quiet way to lose data here.
		args="subscription_name     := '${subname}',
			provider_dsn          := '$(dsn_for_node "${node}")',
			replication_sets      := '${repsets}'::text[],
			forward_origins       := '${fwd}'::text[],
			apply_delay           := '${delay}'::interval,
			force_text_transfer   := '${force}'::boolean,
			synchronize_structure := false,
			synchronize_data      := false,
			enabled               := true"

		if [ "${has_arg}" != "0" ] && [ "${skipschema}" != "NOCOLUMN" ]; then
			args="${args},
			skip_schema           := '${skipschema}'::text[]"
		elif [ "${skipschema}" != "NOCOLUMN" ] && [ "${skipschema}" != "{}" ]; then
			# The peer recorded a non-empty skip_schema but its own
			# sub_create cannot take one back.  That is a real loss, not a
			# formatting detail.
			echo "step 9: ${peer} recorded skip_schema=${skipschema} but its" \
			     "sub_create has no such argument -- it cannot be restored"
			printf 'skip-schema %s %s\n' "${peer}" "${skipschema}" \
				>>"${dir}/manual-followup.txt"
			return 1
		fi

		# 'true'/'false', not 't'/'f': the record is written with
		# sub_enabled::text.  Compared against 't' this note fired on every
		# healthy subscription in every run, announcing that an enabled
		# subscription had been recorded as disabled.
		if [ "${enabled}" != "true" ]; then
			echo "NOTE: ${subname} was recorded as disabled (sub_enabled=${enabled})" \
			     "but the procedure recreates it enabled"
		fi

		echo "----- ${peer}: sub_create(${subname}) from the recorded definition -----"
		echo "      record: ${rec}"
		psql_on "${peer}" -c "SELECT spock.sub_create(${args});" || return 1

		# What actually came back must match what was recorded, for the five
		# options the procedure claims to preserve.  Without this the whole
		# of step 9 is taken on trust.
		# The read-back compares MEMBERSHIP, not element order.
		#
		# It used to compare sub_replication_sets as raw text, and that is a
		# comparison of the wrong thing in both directions: a subscription can
		# record {ddl_sql,default,default_insert_only} while sub_create's default
		# produces {default,default_insert_only,ddl_sql}, so a step 9 that
		# threw the record away entirely was caught -- by the ordering, not by
		# anything that mattered -- while a step 9 that dropped one set and
		# kept the order would have passed.  Measured, not reasoned about: a
		# step 9 rigged to discard the record was reported as caught purely
		# because the two arrays were the same three names in a different
		# order.
		#
		# Both sides are sorted, so ordering cannot mask or manufacture a
		# finding, and the seeded set (see proc_seed_nondefault_repset) is what
		# makes the membership actually differ when the record is ignored.
		local back want
		if ! back="$(psql_on "${peer}" -At -F '|' -c "
				SELECT coalesce((SELECT array_agg(x ORDER BY x)::text
				                 FROM unnest(sub_replication_sets) x), '{}'),
				       coalesce((SELECT array_agg(x ORDER BY x)::text
				                 FROM unnest(sub_forward_origins) x), '{}'),
				       sub_apply_delay::text,
				       sub_force_text_transfer::text
				FROM spock.subscription WHERE sub_name = '${subname}';" 2>&1)"; then
			echo "step 9: could not read back ${subname} on ${peer}: ${back}"
			return 1
		fi
		# The recorded arrays are sorted the same way, by the peer that holds
		# the record, so the two sides are canonicalised identically rather
		# than by two different sorts that could disagree on collation.
		if ! want="$(psql_on "${peer}" -At -F '|' -c "
				SELECT coalesce((SELECT array_agg(x ORDER BY x)::text
				                 FROM unnest('${repsets}'::text[]) x), '{}'),
				       coalesce((SELECT array_agg(x ORDER BY x)::text
				                 FROM unnest('${fwd}'::text[]) x), '{}'),
				       '${delay}'::interval::text,
				       '${force}'::boolean::text;" 2>&1)"; then
			echo "step 9: could not canonicalise the record for ${subname}: ${want}"
			return 1
		fi
		if [ "${back}" != "${want}" ]; then
			echo "step 9 FAILS: ${subname} came back as '${back}'," \
			     "the record canonicalises to '${want}'"
			return 1
		fi
		echo "step 9 ok: ${subname} recreated with its recorded options (${back})"
	done
}

# Step 10 -- re-enable N's subscriptions.
_do_proc_step10_enable() {
	local node="$1"
	psql_on "${node}" -c "
		DO \$e\$
		DECLARE s record;
		BEGIN
			FOR s IN SELECT sub_name FROM spock.subscription ORDER BY sub_name LOOP
				RAISE NOTICE 'enabling %', s.sub_name;
				PERFORM spock.sub_enable(s.sub_name, true);
			END LOOP;
		END
		\$e\$;" || return 1
	psql_on "${node}" -c \
		"SELECT sub_name, sub_enabled FROM spock.subscription ORDER BY sub_name;"
}

# ---------------------------------------------------------------------------
# Step 12: verify before moving on
# ---------------------------------------------------------------------------

# Drive a sync event across every directed edge and wait for it.
#
# An edge that does not deliver is itself the finding: swallowing it would
# leave the comparison below measuring two nodes that are simply not talking.
_do_proc_sync_roundtrip() {
	local provider subscriber lsn rc=0 budget
	for provider in ${NODES}; do
		if ! lsn="$(proc_q "${provider}" "SELECT spock.sync_event();")"; then
			echo "${provider}: spock.sync_event() failed"
			rc=1
			continue
		fi
		if [ -z "${lsn}" ]; then
			echo "${provider}: spock.sync_event() returned nothing"
			rc=1
			continue
		fi
		echo "${provider}: sync event at ${lsn}"
		for subscriber in ${NODES}; do
			[ "${subscriber}" = "${provider}" ] && continue
			# Read from the subscriber: it is the node doing the waiting.
			if ! budget="$(proc_sync_budget "${subscriber}")"; then
				echo "  ${provider} -> ${subscriber}: could not read the sync budget"
				rc=1
				continue
			fi
			if psql_on "${subscriber}" -c "
					DO \$w\$
					DECLARE r bool;
					BEGIN
						CALL spock.wait_for_sync_event(
							r, '${provider}'::name, '${lsn}'::pg_lsn, ${budget});
						IF NOT r THEN
							RAISE EXCEPTION 'not applied within ${budget}s';
						END IF;
					END
					\$w\$;"; then
				echo "  ${provider} -> ${subscriber}: delivered"
			else
				echo "  ${provider} -> ${subscriber}: NOT DELIVERED within ${budget}s"
				rc=1
			fi
		done
	done
	return "${rc}"
}

# Step 12, in full: every subscription replicating, a sync event round trip
# on every edge, then a content comparison across all nodes.
proc_step12_verify() {
	local tag="$1"
	local rc=0 node bad wait_budget

	# "Waiting for a subscription to start replicating" is one of the three
	# waits spock.sync_timeout is documented to bound, so this loop is bounded
	# by it as well -- by the largest budget in the cluster, since the loop
	# spans every node and so has no single one to read from.
	if ! wait_budget="$(proc_sync_budget_max)"; then
		proc_failure "${tag}: could not read the synchronisation budget from the cluster"
		return 1
	fi

	if ! wait_for_mesh_replicating "${wait_budget}"; then
		proc_failure "${tag}: not every subscription reached 'replicating' within ${wait_budget}s"
		print_subscription_state "${tag}"
		rc=1
	fi

	# A node with no subscriptions trivially has none that are not
	# replicating, so count them too.
	for node in ${NODES}; do
		if ! bad="$(proc_q "${node}" "SELECT count(*) FROM spock.subscription;")"; then
			proc_failure "${tag}: could not count subscriptions on ${node}"
			rc=1
			continue
		fi
		if [ "${bad}" != "${PROC_SUBS_PER_NODE}" ]; then
			proc_failure "${tag}: ${node} has ${bad} subscription(s), expected ${PROC_SUBS_PER_NODE}"
			rc=1
		fi
	done

	if ! run_phase cluster "proc-syncevent-${tag}" _do_proc_sync_roundtrip; then
		proc_failure "${tag}: a sync event did not round-trip on every edge (see ${LOG_DIR}/cluster-proc-syncevent-${tag}.log)"
		rc=1
	fi

	if ! proc_compare_witness "${tag}"; then
		proc_failure "${tag}: the nodes do not hold the same witness rows"
		rc=1
	fi

	if ! proc_capture_divergence "${tag}"; then
		proc_failure "${tag}: the content comparison could not be taken"
		rc=1
	elif ! proc_check_no_new_divergence "${tag}"; then
		proc_failure "${tag}: replicated tables diverged beyond the requirement-0 baseline"
		rc=1
	fi

	# The configuration half of requirement 0 -- spock-diff's job.  Step 9
	# retypes the replication_sets array by hand, and a subscription that
	# comes back carrying less than it did replicates perfectly while quietly
	# dropping tables.  Row counts cannot see that until somebody writes to
	# one of the dropped tables, which may be days later.
	if ! proc_capture_config "${tag}"; then
		proc_failure "${tag}: the spock configuration snapshot could not be taken"
		rc=1
	elif ! proc_compare_config "${tag}"; then
		proc_failure "${tag}: a node's spock configuration changed across the procedure"
		rc=1
	fi

	# Re-application, which every count- and digest-based check above is blind
	# to: last_update_wins resolves a replayed row to identical content.
	if ! proc_resolutions_since "${tag}" baseline; then
		proc_failure "${tag}: conflicts were resolved during the procedure -- rows may have been applied twice (see ${PROC_LOG})"
		rc=1
	fi
	if ! proc_conflicts_since "${tag}" baseline; then
		proc_failure "${tag}: spock counted conflicts during the procedure -- rows may have been applied twice (see ${PROC_LOG})"
		rc=1
	fi

	# The document's step 12, as written: ACE again, compared against the
	# requirement-0 baseline.  "The question is whether the upgrade changed
	# anything, not whether the cluster is perfect", so the verdict is the
	# DELTA against the baseline, not the absolute count.
	if ! proc_ace_run "${tag}"; then
		proc_failure "${tag}: ACE could not complete its comparison -- the document's own check did not run (see ${LOG_DIR}/cluster-ace-*-${tag}.log)"
		rc=1
	else
		local base now
		base="$(proc_ace_counts baseline)"
		now="$(proc_ace_counts "${tag}")"
		say "ACE (${tag}): config ${base% *} -> ${now% *} mismatching pair(s), data ${base#* } -> ${now#* } differing table(s)"
		printf 'ACE %s: config %s -> %s, data %s -> %s\n' \
			"${tag}" "${base% *}" "${now% *}" "${base#* }" "${now#* }" >>"${PROC_LOG}"
		case "${base}${now}" in
			*'?'*)
				proc_failure "${tag}: ACE's counts could not be read for the baseline or for now (${base} / ${now})"
				rc=1 ;;
			*)
				if [ "${now% *}" -gt "${base% *}" ]; then
					proc_failure "${tag}: ACE spock-diff reports ${now% *} mismatching node pair(s), up from ${base% *} at the baseline -- the procedure changed the replication configuration. This is what step 9 gets wrong when the replication_sets array is retyped by hand."
					rc=1
				fi
				if [ "${now#* }" -gt "${base#* }" ]; then
					proc_failure "${tag}: ACE repset-diff reports ${now#* } differing table(s), up from ${base#* } at the baseline -- new data divergence, which is what the fence exists to prevent."
					rc=1
				fi ;;
		esac
	fi

	# A table the procedure has newly pulled into an extension is a table
	# pg_dump will stop dumping.  Attributable, unlike the baseline count, so
	# this one is a finding.
	if ! proc_capture_absorption "${tag}" >/dev/null; then
		proc_failure "${tag}: extension ownership could not be read"
		rc=1
	elif ! proc_check_absorption "${tag}"; then
		proc_finding "${tag}: the procedure left user table(s) as members of an extension that were not members at the baseline; pg_dump omits extension members and DROP EXTENSION would remove them (see ${PROC_LOG})"
	fi

	return "${rc}"
}

# ---------------------------------------------------------------------------
# One node, end to end
# ---------------------------------------------------------------------------

# proc_upgrade_one_node NODE [STOP_AFTER_STEP]
#
# One node through the document's Part 2.  STOP_AFTER_STEP is normally empty,
# meaning all of it; pass 7 to return once the node is up on the new major with
# its catalog self-updated and the post-upgrade measurements taken -- i.e. at
# the end of the document's "Upgrade" section, before "Restore" begins.
#
# The node is then deliberately mid-procedure: origins not restored, its
# subscriptions still disabled, and each peer still holding the subscription
# step 9 has yet to recreate.  That is a state worth being able to stop in and
# look at, which is what --stop-after upgrade is for; it is not a state to
# leave a real cluster in.
proc_upgrade_one_node() {
	local node="$1"
	local stop_after="${2:-}"
	local dir; dir="$(proc_fence_dir "${node}")"
	local peer old_variant

	mkdir -p "${dir}"
	old_variant="$(node_to_old_variant "${node}")"

	say "=== procedure: ${node} (${old_variant} -> ${NEW_VARIANT}) ==="
	printf '\n===== node %s =====\n' "${node}" >>"${PROC_LOG}"

	# --- step 1: take N off the write path -------------------------------
	# The rig is the only writer, so this is a decision rather than a
	# configuration change; PROC_WRITE_PATH_OFF is what requirement 4 checks
	# it against, and nothing writes to N again until step 11.
	PROC_WRITE_PATH_OFF="${node}"
	log "step 1: ${node} is off the write path"
	say "${node}: step 1 -- off the write path"

	# The commit-timestamp probe has to be the last thing committed on N
	# while it is still on the old cluster.
	proc_committs_probe_before "${node}" \
		|| fail "${node}: the commit-timestamp probe could not be set up" 20

	# --- step 2: sync event, then drain ----------------------------------
	run_phase "${node}" proc-step2-fence _do_proc_step2_fence "${node}" \
		|| fail "${node}: step 2 failed -- requirement 5 does not hold" 20

	# --- step 3: disable subscriptions -----------------------------------
	run_phase "${node}" proc-step3-disable _do_proc_step3_disable "${node}" \
		|| fail "${node}: step 3 failed -- requirement 6 does not hold" 20

	# --- step 4: record the fence ----------------------------------------
	run_phase "${node}" proc-step4-inbound _do_proc_step4_record_inbound "${node}" \
		|| fail "${node}: step 4 / requirement 7(a) failed" 20
	run_phase "${node}" proc-step4-peersubs _do_proc_step4_record_peers "${node}" \
		|| fail "${node}: step 4 / requirement 7(b) failed" 20

	# --- step 5: STOP AND VERIFY -----------------------------------------
	run_phase "${node}" proc-step5-verify _do_proc_step5_verify "${node}" \
		|| fail "${node}: step 5 -- a Part 1 requirement does not hold, so the procedure says stop" 20

	# --- not in the document: finish the fence from the peer side --------
	run_phase "${node}" proc-fence-peersubs \
		_do_proc_fence_drop_peer_subs "${node}" \
		|| fail "${node}: the peers' subscriptions to it could not be dropped before the upgrade" 20
	proc_finding "${node}: the document never stops the peers pulling FROM the node being upgraded. Step 3 disables only N's own subscriptions; the peers stay subscribed and their apply workers retry N's address for the whole upgrade window, so whatever comes up there collects them -- pg_upgrade's own short-lived server during the check (observed: 'replication slot ... is active for PID'), or the upgraded instance before step 8 has restored anything. This rig drops them here instead, which is safe because step 2 already drove the debt to zero and step 4 already recorded what step 9 rebuilds from, and which also lets spock.sub_drop() remove the slot on N while N is still reachable."

	# Writes on the peers while N is away.  This is what the fence exists
	# for: these rows have to reach N through the origins restored in step 8,
	# and nothing else in this rig would notice if they never did.
	for peer in $(proc_peers "${node}"); do
		proc_witness_write "${peer}" "during-${node}" \
			|| fail "${peer}: could not write witness rows while ${node} was fenced" 20
	done

	# --- step 6: stop N cleanly and upgrade ------------------------------
	adapt_for_target "${node}" "${NEW_VARIANT}" \
		|| fail "${node}: could not adapt the old cluster for a cross-major upgrade" 15

	stop_node "${node}" "${old_variant}"
	prepare_new_datadir "${node}"

	# The offline --check first: it is the only mode that verifies the
	# logical slots have caught up, which is what requirement 5 bought.
	# Exit 20, not 15.  "pg_upgrade --check rejects a cluster the document's
	# fence declared ready" is the most interesting result this mode can
	# produce -- it says a Part 1 requirement is not sufficient -- and 15 is
	# documented as a rig failure, so CI keying on the 10-15 band would file
	# it as "the rig broke".
	run_phase "${node}" proc-upgrade-check _do_pg_upgrade "${node}" --check \
		|| fail "${node}: pg_upgrade --check rejected the fenced cluster, so requirement 5 as the document defines it is not sufficient" 20

	run_phase "${node}" proc-pg-upgrade _do_pg_upgrade "${node}" "" \
		|| fail "${node}: pg_upgrade failed (see ${LOG_DIR}/pg_upgrade-${node}/)" 15

	# More peer writes, still inside the window: N is upgraded but its
	# subscriptions are not back yet, so these exercise the same path.
	for peer in $(proc_peers "${node}"); do
		proc_witness_write "${peer}" "upgraded-${node}" \
			|| fail "${peer}: could not write witness rows after ${node} was upgraded" 20
	done

	start_node "${node}" "${NEW_VARIANT}"
	wait_for_ready "${node}" \
		|| fail "${node}: the ${NEW_VARIANT} cluster never became ready" 12

	# pg_upgrade carries no configuration, and prepare_new_datadir rewrote
	# postgresql.conf from scratch, so the cluster-wide requirements have to be
	# put back before anything checks them again.
	run_phase "${node}" proc-reestablish-settings \
		_do_proc_reestablish_cluster_settings "${node}" \
		|| fail "${node}: requirements 2/3 could not be re-established after the upgrade" 20
	proc_finding "${node}: pg_upgrade left requirement 2 violated -- spock.enable_ddl_replication came back as 'on', because ALTER SYSTEM writes postgresql.auto.conf and pg_upgrade does not carry it. The document's steps 6 and 7 do not mention re-establishing the cluster-wide settings on the new cluster."

	# --- step 7: Spock upgrades its own catalog on startup ---------------
	if run_phase "${node}" proc-step7-extension \
			_do_proc_step7_extension_self_update "${node}" "${PROC_EXTENSION_TIMEOUT}"; then
		log "step 7: ${node} self-updated its spock catalog"
	else
		proc_finding "${node}: spock did not bring pg_extension.extversion up to ${SPOCK_V6_VERSION} on its own within ${PROC_EXTENSION_TIMEOUT}s; the document says no manual ALTER EXTENSION is needed"
		# Do it by hand so the rest of the procedure can still be measured.
		extension_update "${node}" \
			|| fail "${node}: ALTER EXTENSION spock UPDATE also failed" 20
	fi

	# The new data directory got the same postgresql.conf, so the budget
	# should be unchanged across the upgrade -- reported rather than assumed,
	# because the nodes still to be fenced will wait on this one.
	say "${node}: synchronisation budget is now $(proc_report_sync_budget "${node}")s"

	proc_committs_probe_after "${node}" \
		|| fail "${node}: the commit-timestamp probe could not be read back" 20

	# Before step 9 drops and recreates them, record whether N's outbound
	# slots came through the upgrade at all.
	run_phase "${node}" proc-slot-census _do_proc_slot_census "${node}" \
		|| fail "${node}: the slot census could not be taken" 20
	local slots_after
	slots_after="$(cat "${dir}/slots-after-upgrade.txt")" || slots_after=""
	if [ -n "${slots_after}" ] && [ "${slots_after}" != "0" ]; then
		# A surviving slot is only half the story.  Ask whether it actually
		# delivers, so the finding rests on data having moved rather than on a
		# row in pg_replication_slots.
		local delivery="UNKNOWN"
		if run_phase "${node}" proc-slot-delivery \
				_do_proc_verify_surviving_slot "${node}"; then
			delivery="$(cat "${dir}/slot-delivery-verdict.txt" 2>/dev/null)" \
				|| delivery="UNKNOWN"
		fi
		case "${delivery}" in
			ALL)
				proc_finding "${node}: ${slots_after} outbound replication slot(s) survived pg_upgrade, AND a sync event emitted on ${node} afterwards was applied by every peer whose subscription was still live -- so the migrated slot carries data, it does not merely exist. The document states the outbound position cannot be preserved and that the slot 'died with it'; from a PG17-or-later old cluster pg_upgrade migrates logical slots, so step 9's premise does not hold in this matrix." ;;
			SOME)
				proc_finding "${node}: ${slots_after} outbound replication slot(s) survived pg_upgrade, and a post-upgrade sync event reached SOME but not all peers with a live subscription (see ${dir}/slot-delivery.txt). Step 9's premise -- that the slot died with the node -- does not hold here, and the surviving slots are not uniformly usable either, which is the worst of both." ;;
			NONE)
				proc_finding "${node}: ${slots_after} outbound replication slot(s) survived pg_upgrade but a sync event emitted afterwards reached NO peer, so the slot exists without carrying data. The document says the slot died with the node; here it is neither dead nor working, which step 9 does not describe." ;;
			NONE-LIVE)
				proc_finding "${node}: ${slots_after} outbound replication slot(s) survived pg_upgrade. No peer had a live subscription to ${node} at that moment, so whether the migrated slot delivers was not established. The document states the outbound position cannot be preserved and that the slot 'died with it' -- from a PG17-or-later old cluster pg_upgrade migrates logical slots, so step 9's premise does not hold in this matrix." ;;
			*)
				proc_finding "${node}: ${slots_after} outbound replication slot(s) survived pg_upgrade; the delivery probe could not be run, so only their existence is established. Step 9's premise does not hold in this matrix." ;;
		esac
	fi

	# The document's "Upgrade" section ends here.  Everything above answers
	# "did pg_upgrade and Spock's own catalog upgrade work"; everything below
	# is the Restore section putting the replication plumbing back.
	if [ "${stop_after}" = "7" ]; then
		say "${node}: stopping after step 7 -- upgraded, catalog self-updated, plumbing NOT yet restored"
		printf '\nSTOPPED AFTER STEP 7 on %s: the Restore section (steps 8-10) has not run.\n' \
			"${node}" >>"${PROC_LOG}"
		return 0
	fi

	# --- step 8: recreate and reposition the origins ---------------------
	run_phase "${node}" proc-step8-origins _do_proc_step8_restore_origins "${node}" \
		|| fail "${node}: step 8 failed -- the inbound positions were not restored" 20
	if [ -s "${dir}/origin-survived" ]; then
		proc_finding "${node}: $(wc -l <"${dir}/origin-survived" | tr -d ' ') replication origin(s) survived pg_upgrade; the document states none do, and pg_replication_origin_create would have failed if the procedure were followed literally"
	fi

	# --- step 9: peers drop and recreate their subscription from N -------
	run_phase "${node}" proc-step9-peersubs _do_proc_step9_recreate_peer_subs "${node}" \
		|| fail "${node}: step 9 failed -- a peer subscription could not be recreated from the record" 20

	# --- step 10: re-enable N's subscriptions ----------------------------
	run_phase "${node}" proc-step10-enable _do_proc_step10_enable "${node}" \
		|| fail "${node}: step 10 failed -- subscriptions could not be re-enabled" 20

	# --- step 11: back on the write path ---------------------------------
	PROC_WRITE_PATH_OFF=""
	log "step 11: ${node} is back on the write path"
	say "${node}: step 11 -- back on the write path"
	proc_witness_write "${node}" "after-${node}" \
		|| fail "${node}: could not write witness rows after returning to the write path" 20

	# --- step 12: verify before moving on --------------------------------
	if proc_step12_verify "after-${node}"; then
		say "${node}: step 12 -- verified, moving on"
	else
		say "${node}: step 12 -- FAILED (recorded; the run continues to the next node)"
	fi
	print_subscription_state "after procedure on ${node}"
}

# ---------------------------------------------------------------------------
# The whole rolling upgrade
# ---------------------------------------------------------------------------

# Re-establish requirements 2 and 3 on a node that has just come up on the new
# major.
#
# They are set with ALTER SYSTEM, which lands in postgresql.auto.conf of the
# OLD data directory -- and pg_upgrade carries no configuration files.  Worse,
# prepare_new_datadir initdb's the target and re-runs write_node_conf, which
# writes spock.enable_ddl_replication = on unconditionally.  So an upgraded
# node comes back with requirement 2 violated.
#
# Left unfixed this is not a subtle degradation, it is a stop: requirement 2
# is checked on *every* node, so the next node's step 5 reads the
# already-upgraded one, fails, and the run dies attributing the failure to the
# node being fenced.  The rolling procedure could never reach a third node.
#
# The document has the matching gap: step 6 and step 7 say nothing about
# re-establishing the cluster-wide settings on the new cluster.  Recorded as a
# finding so the document gets fixed rather than the rig quietly compensating.
_do_proc_reestablish_cluster_settings() {
	local node="$1"
	psql_on "${node}" -c "ALTER SYSTEM SET spock.enable_ddl_replication = off;" || return 1
	psql_on "${node}" -c "ALTER SYSTEM SET max_slot_wal_keep_size = -1;" || return 1
	psql_on "${node}" -c "SELECT pg_reload_conf();" || return 1
	# Read back: an ALTER SYSTEM that did not take effect would put us right
	# back where this function exists to rescue us from.
	local got
	got="$(psql_on "${node}" -At -c "SHOW spock.enable_ddl_replication;")" || return 1
	[ "${got}" = "off" ] \
		|| { echo "requirement 2 still violated on ${node}: ${got}"; return 1; }
	got="$(psql_on "${node}" -At -c "SHOW max_slot_wal_keep_size;")" || return 1
	[ "${got}" = "-1" ] \
		|| { echo "requirement 3 still violated on ${node}: ${got}"; return 1; }
	echo "requirements 2 and 3 re-established on ${node} after the upgrade"
}

# Requirements 2 and 3, set cluster-wide before the first node is fenced and
# put back in step 13.  Their previous values are recorded so step 13 can
# restore them rather than guess.
_do_proc_cluster_prepare() {
	local node prev
	for node in ${NODES}; do
		prev="$(psql_on "${node}" -At -c "SHOW spock.enable_ddl_replication;")" || return 1
		printf '%s\n' "${prev}" >"${REPORT_DIR}/prev-ddl-${node}.txt"
		psql_on "${node}" -c "ALTER SYSTEM SET spock.enable_ddl_replication = off;" || return 1

		prev="$(psql_on "${node}" -At -c "SHOW max_slot_wal_keep_size;")" || return 1
		printf '%s\n' "${prev}" >"${REPORT_DIR}/prev-walkeep-${node}.txt"
		psql_on "${node}" -c "ALTER SYSTEM SET max_slot_wal_keep_size = -1;" || return 1

		psql_on "${node}" -c "SELECT pg_reload_conf();" || return 1
		echo "${node}: ddl_replication was ${prev}, now off; max_slot_wal_keep_size now -1"

		echo "${node}: synchronisation budget is $(proc_report_sync_budget "${node}")s"
	done
}

# Step 13 -- restore both GUCs to what they were before the run.
_do_proc_cluster_finish() {
	local node ddl walkeep
	for node in ${NODES}; do
		ddl="$(cat "${REPORT_DIR}/prev-ddl-${node}.txt")" || return 1
		walkeep="$(cat "${REPORT_DIR}/prev-walkeep-${node}.txt")" || return 1
		psql_on "${node}" -c \
			"ALTER SYSTEM SET spock.enable_ddl_replication = ${ddl};" || return 1
		psql_on "${node}" -c \
			"ALTER SYSTEM SET max_slot_wal_keep_size = '${walkeep}';" || return 1
		psql_on "${node}" -c "SELECT pg_reload_conf();" || return 1
		echo "${node}: restored ddl_replication=${ddl} max_slot_wal_keep_size=${walkeep}"
	done
}

# Entry point.  Called from main() once step 3 has left a healthy mesh on the
# old majors; exits with the procedure's own verdict and never returns.
# Everything the documented procedure needs in place before the first node can
# be fenced: the version pre-flight, the witness table, the step-9 seed, all
# four requirement-0 baselines, and the cluster-wide requirements 1, 2 and 3.
#
# Factored out of proc_run_documented_upgrade so that --stop-after upgrade can
# reach the same starting state without a second copy of it.  A second copy is
# exactly what would drift: this block is where the procedure's preconditions
# live, and two implementations of a precondition eventually disagree about
# what the precondition is.
proc_prepare_for_procedure() {
	proc_init
	PROC_SUBS_PER_NODE=$(( NODE_COUNT - 1 ))

	# What is actually installed, asked of the running servers.
	#
	# spock.control's default_version is substituted from SPOCK_VERSION in
	# include/spock.h, so pg_extension.extversion is exactly the version of
	# the tree that was built.  Everything else about which Spock is in play
	# here is bookkeeping -- staged ref markers, build markers, reuse rules --
	# and bookkeeping is what quietly went wrong when a cached install from a
	# previous run was reused across a change of ref.  This asks the servers
	# instead, before any conclusion rests on the answer.
	local node got
	for node in ${NODES}; do
		if ! got="$(proc_q "${node}" "
				SELECT coalesce(extversion, 'NONE') FROM pg_extension
				WHERE extname = 'spock';")"; then
			fail "${node}: could not read the installed spock version" 20
		fi
		if [ "${got}" != "${SPOCK_V5_VERSION}" ]; then
			fail "${node} is running spock ${got}, but the old side was staged as ${SPOCK_V5_VERSION} from ${OLD_SPOCK_REF}; a stale build is installed. Remove cluster-upgrade/bin/ for that variant and re-run." 11
		fi
		log "${node}: running spock ${got} before the upgrade"
	done
	say "pre-flight: every node is running spock ${SPOCK_V5_VERSION} (${OLD_SPOCK_REF})"

	say "=== procedure: preparing the witness table ==="
	run_phase cluster proc-witness-create _do_proc_witness_create \
		|| fail "the witness table could not be created on ${FIRST_NODE}" 20
	run_phase cluster proc-witness-distribute _do_proc_witness_distribute \
		|| fail "the witness table did not reach every node" 20
	for node in ${NODES}; do
		proc_witness_write "${node}" "baseline" \
			|| fail "${node}: could not write the baseline witness rows" 20
	done

	# Let the baseline rows settle before anything is measured.
	run_phase cluster proc-syncevent-baseline _do_proc_sync_roundtrip \
		|| fail "the mesh does not round-trip a sync event before the procedure even starts" 20

	# Before the baseline is taken, so the baseline records the seeded state
	# and step 9 has something of its own to restore.
	say "=== procedure: seeding a non-default subscription option ==="
	proc_seed_nondefault_repset

	# The seed moved a table between replication sets on every node.  Prove
	# the mesh still round-trips afterwards, so a seed that broke replication
	# is attributed to the seed and not to the first node's fence.
	if [ -n "${PROC_SEED_REPSET}" ]; then
		run_phase cluster proc-syncevent-seeded _do_proc_sync_roundtrip \
			|| fail "the mesh stopped round-tripping a sync event after ${PROC_SEED_REPSET} was seeded" 20
	fi

	# --- requirement 0: the baseline -------------------------------------
	say "=== procedure: requirement 0 -- recording the baseline ==="
	proc_capture_divergence baseline \
		|| fail "the requirement-0 baseline could not be recorded" 20
	say "requirement 0: baseline records $(wc -l <"${REPORT_DIR}/divergence-baseline.txt" | tr -d ' ') relation(s) already out of step"
	proc_compare_witness baseline \
		|| fail "the nodes disagree about the witness table before the procedure starts" 20
	proc_capture_config baseline \
		|| fail "the requirement-0 configuration baseline could not be recorded" 20
	proc_report_absorption_baseline \
		|| fail "the extension-ownership baseline could not be recorded" 20
	proc_resolutions_mark baseline \
		|| fail "the conflict-resolution baseline could not be recorded" 20

	# The baseline the document actually asks for: ACE repset-diff for the data
	# and spock-diff for the configuration.  Convergence is NOT demanded here --
	# the document is explicit that pre-existing divergence passes through the
	# upgrade untouched -- so what ACE finds now is recorded as the reference,
	# and only a check that could not RUN is fatal.
	proc_ace_report_availability
	proc_ace_run baseline \
		|| fail "requirement 0: ACE could not take the baseline" 20
	local ace_base; ace_base="$(proc_ace_counts baseline)"
	say "requirement 0 (ACE): baseline is ${ace_base% *} mismatching config pair(s), ${ace_base#* } differing table(s)"
	printf 'ACE baseline: config-mismatch-pairs=%s data-differing-tables=%s\n' \
		"${ace_base% *}" "${ace_base#* }" >>"${PROC_LOG}"
	say "requirement 0: configuration baseline recorded for every node"

	# --- requirements 2 and 3: cluster-wide ------------------------------
	say "=== procedure: requirements 2 and 3 -- cluster-wide settings ==="
	run_phase cluster proc-cluster-prepare _do_proc_cluster_prepare \
		|| fail "requirements 2/3 could not be established cluster-wide" 20
	proc_req1_forward_origins >>"${PROC_LOG}" 2>&1 \
		|| fail "requirement 1 does not hold; see ${PROC_LOG}" 20

	# resolution it causes is unambiguously attributable to the window the
	# procedure runs in.

}

proc_run_documented_upgrade() {
	local node

	proc_prepare_for_procedure

	# --- the rolling upgrade ---------------------------------------------
	for node in ${NODES}; do
		proc_upgrade_one_node "${node}"
	done

	# --- step 13 ----------------------------------------------------------
	say "=== procedure: step 13 -- restoring cluster-wide settings ==="
	run_phase cluster proc-cluster-finish _do_proc_cluster_finish \
		|| fail "step 13 failed -- the cluster-wide settings were not restored" 20

	# A final pass over the whole cluster, now that every node is on the new
	# major, with fresh writes from every node so the last check is not
	# measuring a quiet system.
	say "=== procedure: final verification ==="
	for node in ${NODES}; do
		proc_witness_write "${node}" "final" \
			|| fail "${node}: could not write the final witness rows" 20
	done
	if proc_step12_verify final; then
		say "final verification: the cluster is consistent"
	fi

	for node in ${NODES}; do
		if ! check_node_health "${node}" 6 "${NODE_COUNT}" "${PROC_SUBS_PER_NODE}"; then
			proc_failure "final: ${node} failed its health check (see ${LOG_DIR}/${node}-health-*.log)"
		fi
	done

	# --- verdict ----------------------------------------------------------
	print_subscription_state_to_screen
	print_connection_params

	printf '=== Summary: documented upgrade procedure ===\n' >&2
	printf '  document ......... %s\n' "spock-upgrade-procedure-corrected.md" >&2
	printf '  matrix ........... PG%s -> PG%s, spock %s -> %s\n' \
		"${OLD_MAJORS%% *}" "${NEW_MAJOR}" \
		"${SPOCK_V5_VERSION}" "${SPOCK_V6_VERSION}" >&2
	printf '  procedure failures %s\n' "${PROC_FAILURES}" >&2
	printf '  document findings  %s\n' "${PROC_FINDINGS}" >&2
	printf '  detail ........... %s\n' "${PROC_LOG}"   >&2
	printf '  reports .......... %s\n' "${REPORT_DIR}" >&2
	printf '  logs ............. %s\n' "${LOG_DIR}"    >&2

	log "procedure summary: failures=${PROC_FAILURES} findings=${PROC_FINDINGS}"

	if [ "${PROC_FAILURES}" -ne 0 ]; then
		say "RESULT: FAIL (21) -- the procedure was followed and the cluster is not consistent"
		exit 21
	fi
	if [ "${PROC_FINDINGS}" -ne 0 ]; then
		say "RESULT: FAIL (22) -- the cluster is consistent, but ${PROC_FINDINGS} claim(s)"
		say "        in the document did not hold; see ${PROC_LOG}"
		exit 22
	fi
	say "RESULT: PASS -- the documented procedure works as written"
	exit 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

# The one verdict resolved outside the documented procedure, which reports
# through PROC_FAILURES and PROC_FINDINGS instead.
VERDICT_NODE_DATA=PASS          # do the nodes agree after step 3?

# ---------------------------------------------------------------------------
# --stop-after: hand the cluster over
# ---------------------------------------------------------------------------
#
# The deliverable of this mode is not a verdict, it is a running cluster plus
# enough information to use it.  So the report is written to a FILE as well as
# the terminal: the run prints a few hundred lines before it gets here, and
# the connection details are the part somebody will want again tomorrow.
setup_only_readme() { echo "${BASE_DIR}/CLUSTER-README.md"; }

# One node's psql invocation, as something that can be pasted.
_setup_only_psql_cmd() {
	local node="$1"
	printf '%s/bin/psql -h %s -p %s -U %s -d %s' \
		"$(prefix_for "$(node_variant "${node}")")" \
		"${SOCK_DIR}" "$(node_to_port "${node}")" "${DBUSER}" "${DBNAME}"
}

_do_setup_only_report() {
	local out; out="$(setup_only_readme)"
	local node payload

	payload="the core PostgreSQL regression database, from make installcheck"

	{
		if [ "${SETUP_STAGE}" = "upgrade" ]; then
			printf '# Cluster left MID-PROCEDURE, after step 7\n\n'
			printf 'Built by `tests/run-cluster-upgrade.sh --stop-after upgrade` on %s.\n\n' "$(date)"
		else
			printf '# Spock %s cluster, left running\n\n' "${SPOCK_V5_VERSION}"
			printf 'Built by `tests/run-cluster-upgrade.sh --stop-after join` on %s.\n\n' "$(date)"
		fi

		printf '%s\n' 'What it is'
		printf '%s\n\n' '-----------'
		if [ "${SETUP_STAGE}" = "upgrade" ]; then
			printf -- '- %s node(s), listed one by one below because they are no longer\n' \
				"${NODE_COUNT}"
			printf -- '  alike -- one of them has been upgraded and the others have not:\n'
			for node in ${NODES}; do
				printf -- '    - `%s`: %s, spock %s%s\n' \
					"${node}" "$(node_variant "${node}")" \
					"$(psql_on "${node}" -At -c "SELECT coalesce(extversion,'?') FROM pg_extension WHERE extname='spock';" 2>/dev/null || echo '?')" \
					"$( [ "${node}" = "${SETUP_UPGRADED_NODE}" ] && printf '  <- UPGRADED' )"
			done
		else
			printf -- '- %s node(s), all PostgreSQL %s with spock %s (%s).\n' \
				"${NODE_COUNT}" "${OLD_MAJORS%% *}" "${SPOCK_V5_VERSION}" "${OLD_SPOCK_REF}"
		fi
		printf -- '- Database `%s`, owner `%s`. Payload: %s.\n' \
			"${DBNAME}" "${DBUSER}" "${payload}"
		printf -- '- Joined with `spock.node_create()` plus `spock.sub_create()`: one\n'
		printf -- '  subscription from `%s` with structure and data synchronised, then\n' "${FIRST_NODE}"
		printf -- '  `repset_add_all_tables` on the joiner, its replication sets mirrored\n'
		printf -- '  from `%s`, then the remaining edges with both sync flags off.\n' "${FIRST_NODE}"
		printf -- '- Every node subscribes to every other one, and every node has tables\n'
		printf -- '  in its own replication sets -- it publishes as well as subscribes.\n'
		if [ "${SETUP_STAGE}" != "upgrade" ]; then
			printf -- '- Replication is **proved**, not assumed: a `spock.sync_event()` was\n'
			printf -- '  emitted on every node and waited for on every other one, and all\n'
			printf -- '  %s directed edge(s) delivered. `status = replicating` alone would\n' \
				"$(( NODE_COUNT * (NODE_COUNT - 1) ))"
			printf -- '  only have meant the apply worker was connected. See\n'
			printf -- '  `log/cluster-setup-syncevent.log`.\n'
		fi
		if [ "${SETUP_STAGE}" = "upgrade" ]; then
			printf -- '- Old side built from `%s` (spock %s), new side from `%s` (spock %s).\n' \
				"${OLD_SPOCK_REF}" "${SPOCK_V5_VERSION}" \
				"${NEW_SPOCK_REF:-working tree}" "${SPOCK_V6_VERSION}"
		else
			printf -- '- Nothing has been upgraded. No v6 build was even made.\n'
		fi
		printf -- '- `spock.enable_ddl_replication` is **on**, so DDL you run replicates.\n'

		# Reported with the caveat, because the obvious way to check it comes
		# back empty and makes the rest of this file look untrustworthy.  On a
		# 5.x node spock.sync_timeout is not a registered GUC, only an
		# unreserved-prefix placeholder, and a placeholder is stamped
		# GUC_NO_SHOW_ALL -- so pg_settings has no row for it even though
		# postgresql.conf sets it and current_setting() returns it.
		printf -- '- `spock.sync_timeout` is set to %ss in every postgresql.conf.\n' \
			"${SPOCK_SYNC_TIMEOUT}"
		if proc_has_sync_timeout "${FIRST_NODE}"; then
			printf -- '  Read it back with `SHOW spock.sync_timeout` or from `pg_settings`.\n'
		else
			printf -- '  Spock %s does not register it as a real GUC, so it survives only as\n' \
				"${SPOCK_V5_VERSION}"
			printf -- '  an unreserved-prefix placeholder. `SHOW spock.sync_timeout` and\n'
			printf -- '  `current_setting()` both return it, but a placeholder is stamped\n'
			printf -- '  GUC_NO_SHOW_ALL, so it does NOT appear in `pg_settings` or in\n'
			printf -- '  `SHOW ALL` -- and anything that resolves the budget by querying\n'
			printf -- '  `pg_settings` finds nothing and silently falls back to its own\n'
			printf -- '  default. The rig reads it with `current_setting()` for exactly\n'
			printf -- '  this reason -- see `effective_sync_budget`.\n'
		fi
		printf -- '\n'

		# What is NOT replicated, and why.  Somebody poking at this cluster
		# will otherwise write to one of these tables, see nothing arrive on
		# the peer, and reasonably conclude replication is broken.
		local unrep
		if unrep="$(psql_on "${FIRST_NODE}" -At -c "
				SELECT count(*)
				FROM pg_class c
				JOIN pg_namespace n ON n.oid = c.relnamespace
				WHERE c.relkind = 'r' AND c.relpersistence = 'p'
				  AND n.nspname NOT IN ('pg_catalog','information_schema','spock')
				  AND n.nspname NOT LIKE 'pg\\_%'
				  AND n.nspname NOT LIKE 'spock\\_health%'
				  AND c.oid NOT IN (SELECT set_reloid FROM spock.replication_set_table);" \
				2>/dev/null)" && [ -n "${unrep}" ] && [ "${unrep}" != "0" ]; then
			printf -- '- **%s user table(s) are deliberately NOT in any replication set.**\n' \
				"${unrep}"
			printf -- '  Writes to those will not appear on the peer, and that is expected\n'
			printf -- '  rather than a fault. Tables with a generated column are excluded\n'
			printf -- '  because this spock cannot `COPY` them during initial sync, and any\n'
			printf -- '  table with a foreign key into an excluded one is excluded as well --\n'
			printf -- '  otherwise structure sync fails re-adding the constraint. Every\n'
			printf -- '  exclusion is named, with its reason, in\n'
			printf -- '  `log/%s-repset-add-all.log`.\n' "${FIRST_NODE}"
			printf -- '  List them with:\n\n'
			printf -- '        SELECT c.oid::regclass FROM pg_class c\n'
			printf -- '        JOIN pg_namespace n ON n.oid = c.relnamespace\n'
			printf -- '        WHERE c.relkind = '"'"'r'"'"' AND n.nspname = '"'"'public'"'"'\n'
			printf -- '          AND c.oid NOT IN (SELECT set_reloid FROM spock.replication_set_table)\n'
			printf -- '        ORDER BY 1;\n\n'
		fi

		# The whole point of stopping here is that the cluster is NOT in a
		# steady state.  Saying so, precisely, is more useful than any of the
		# connection detail below.
		if [ "${SETUP_STAGE}" = "upgrade" ]; then
			local n="${SETUP_UPGRADED_NODE}" dir peer
			dir="$(proc_fence_dir "${n}")"
			printf '\n%s\n' 'Where in the procedure this is'
			printf '%s\n\n' '-------------------------------'
			printf 'spock-upgrade-procedure-corrected.md, Part 2. Steps 1-7 have run for\n'
			printf -- '`%s` only. The **Restore** section has NOT run.\n\n' "${n}"
			printf 'Done:\n\n'
			printf -- '- 1-5  `%s` fenced: off the write path, sync event drained to LSN0,\n' "${n}"
			printf -- '       subscriptions disabled, apply workers gone, inbound positions and\n'
			printf -- '       peer subscription definitions recorded, every Part 1 requirement\n'
			printf -- '       re-verified.\n'
			printf -- '- 6    `pg_upgrade` to %s, after an offline `--check`.\n' "${NEW_VARIANT}"
			printf -- '- 7    Spock brought `pg_extension.extversion` up to %s on its own.\n\n' \
				"${SPOCK_V6_VERSION}"
			printf 'NOT done -- and this is why the cluster is not in a usable state:\n\n'
			printf -- '- 8    the replication origins on `%s` have NOT been recreated or\n' "${n}"
			printf -- '       repositioned, so it does not know how far it had applied.\n'
			printf -- '- 9    each peer still holds its OLD subscription to `%s`, not the\n' "${n}"
			printf -- '       one step 9 would have recreated from the record.\n'
			printf -- '- 10   the subscriptions on `%s` are still disabled.\n' "${n}"
			printf -- '- 11   `%s` is still off the write path. **Do not write to it.**\n' "${n}"
			printf -- '       If step 9 has yet to create a peer'"'"'s replacement slot, anything\n'
			printf -- '       written now precedes that slot and is skipped exactly as an\n'
			printf -- '       unfenced write would be.\n\n'

			# Measured, not asserted.  The first draft of this file said "expect
			# the subscriptions to be down", and on this cluster that was
			# simply false: pg_upgrade from a PG17-or-later old cluster
			# MIGRATES logical slots, so the peer reconnected to the surviving
			# slot and carried on replicating.  Stating the state is safe;
			# predicting it is not.
			local slots_survived peer_status
			slots_survived="$(cat "${dir}/slots-after-upgrade.txt" 2>/dev/null)" \
				|| slots_survived="?"
			printf 'What that actually looks like, read from the cluster just now:\n\n'
			printf -- '    %s: %s of its outbound replication slot(s) survived pg_upgrade\n' \
				"${n}" "${slots_survived}"
			for peer in $(proc_peers "${n}"); do
				peer_status="$(psql_on "${peer}" -At -c "
					SELECT coalesce(max(status), 'NO SUCH SUBSCRIPTION')
					FROM spock.sub_show_status()
					WHERE subscription_name = 'sub_${n}_${peer}';" 2>/dev/null)" \
					|| peer_status="(could not be read)"
				printf -- '    %s: sub_%s_%s is %s\n' \
					"${peer}" "${n}" "${peer}" "${peer_status}"
			done
			printf -- '\n'
			printf 'Those statuses are a snapshot taken at handover, seconds after the\n'
			printf -- 'upgrade. Where a slot survived, the peer'"'"'s apply worker reconnects to\n'
			printf -- 'it on its own within a few seconds, so a `down` here often reads\n'
			printf -- '`replicating` by the time you look. Re-check rather than trusting the\n'
			printf -- 'line above:\n\n'
			printf -- '        SELECT subscription_name, status FROM spock.sub_show_status();\n\n'
			if [ "${slots_survived}" != "0" ] && [ "${slots_survived}" != "?" ]; then
				printf 'Note what that means. The document says of step 9 that "the slot that\n'
				printf -- 'lived on N died with it, and nothing recreates it" -- but from a\n'
				printf -- 'PG17-or-later old cluster `pg_upgrade` migrates logical slots, so\n'
				printf -- 'here it did not die, and a peer may well still be replicating from\n'
				printf -- '`%s` over the migrated slot. Step 9'"'"'s premise does not hold in this\n' "${n}"
				printf -- 'matrix; from a pre-17 old cluster it would. Recorded as a finding in\n'
				printf -- '`log/procedure.log`.\n\n'
			else
				printf -- 'No slot survived, so each peer'"'"'s subscription to `%s` is dead until\n' "${n}"
				printf -- 'step 9 recreates it. That is the case the document describes.\n\n'
			fi
			printf -- 'Either way `%s` itself receives nothing while its own subscriptions\n' "${n}"
			printf -- 'are disabled, so replication is one-directional at best right now.\n\n'

			printf '%s\n' 'The fence record -- what step 8 and step 9 need'
			printf '%s\n\n' '-----------------------------------------------'
			printf 'Recorded before the upgrade, and the only place the pre-upgrade\n'
			printf 'positions now exist:\n\n'
			printf -- '    %s/inbound.txt\n' "${dir}"
			printf -- '        one line per subscription: sub_name|slot_name|remote_lsn\n'
			for peer in $(proc_peers "${n}"); do
				printf -- '    %s/peersub-%s.txt\n' "${dir}" "${peer}"
				printf -- '        %s'"'"'s definition of sub_%s_%s, for step 9\n' \
					"${peer}" "${n}" "${peer}"
			done
			printf -- '    %s/lsn0.txt        the drained-to LSN\n' "${dir}"
			printf -- '\n'
			printf 'Current contents of the inbound record:\n\n'
			if [ -s "${dir}/inbound.txt" ]; then
				sed 's/^/        /' "${dir}/inbound.txt"
			else
				printf -- '        (empty -- which would itself be a problem)\n'
			fi
			printf -- '\n'
			printf 'Compare LSNs as `pg_lsn`, not as text: PostgreSQL 18 zero-pads the low\n'
			printf 'half, so a position recorded on the old major reads back differently on\n'
			printf 'the new one while being the same value.\n\n'

			printf '%s\n' 'Continuing by hand'
			printf '%s\n\n' '-------------------'
			printf -- 'On `%s`, for each line of inbound.txt (step 8):\n\n' "${n}"
			printf -- '        SELECT pg_replication_origin_create('"'"'<slot_name>'"'"');\n'
			printf -- '        SELECT pg_replication_origin_advance('"'"'<slot_name>'"'"', '"'"'<remote_lsn>'"'"');\n\n'
			printf -- 'On each peer (step 9), from the recorded definition and NOT from\n'
			printf -- 'sub_create'"'"'s defaults:\n\n'
			printf -- '        SELECT spock.sub_drop('"'"'sub_%s_<peer>'"'"');\n' "${n}"
			printf -- '        SELECT spock.sub_create(subscription_name := '"'"'sub_%s_<peer>'"'"',\n' "${n}"
			printf -- '            provider_dsn := '"'"'%s'"'"',\n' "$(dsn_for_node "${n}")"
			printf -- '            replication_sets := <recorded>, forward_origins := <recorded>,\n'
			printf -- '            apply_delay := <recorded>, force_text_transfer := <recorded>,\n'
			printf -- '            synchronize_structure := false, synchronize_data := false,\n'
			printf -- '            enabled := true);\n\n'
			printf -- 'Then on `%s` (step 10): `SELECT spock.sub_enable(<name>, true);`\n' "${n}"
			printf -- 'for each subscription, and only then put it back on the write path.\n\n'
			printf 'Or just let the rig do all of it:\n\n'
			# getconf and not nproc: this file is read on macOS as often as on
			# Linux, and nproc is not there.
			printf -- '        ACE_SRC=<ace checkout> tests/run-cluster-upgrade.sh\n\n'
			printf 'Findings so far are in `log/procedure.log` (%s recorded).\n\n' \
				"${PROC_FINDINGS}"
		fi

		printf '%s\n' 'How to connect'
		printf '%s\n\n' '---------------'
		printf 'The servers listen on a unix socket only -- there is no TCP listener --\n'
		printf 'so `-h %s` is not optional.\n\n' "${SOCK_DIR}"
		for node in ${NODES}; do
			printf -- '    # %s  (%s, port %s)\n' \
				"${node}" "$(node_variant "${node}")" "$(node_to_port "${node}")"
			printf -- '    %s\n\n' "$(_setup_only_psql_cmd "${node}")"
		done
		printf 'Or set the environment once and use the bare client names:\n\n'
		printf -- '    export PATH="%s/bin:$PATH"\n' \
			"$(prefix_for "$(node_variant "${FIRST_NODE}")")"
		printf -- '    export PGHOST=%s PGUSER=%s PGDATABASE=%s\n' \
			"${SOCK_DIR}" "${DBUSER}" "${DBNAME}"
		printf -- '    psql -p %s      # %s\n\n' \
			"$(node_to_port "${FIRST_NODE}")" "${FIRST_NODE}"

		printf '%s\n' 'Where the logs are'
		printf '%s\n\n' '-------------------'
		printf -- '    %s\n' "${LOG_DIR}"
		printf -- '\n'
		printf -- '- `main.log` -- the whole run, one line per step.\n'
		printf -- '- `<node>-<variant>-server.log` -- the PostgreSQL server log for one\n'
		printf -- '  node. This is where a spock worker error appears; `log_min_messages`\n'
		printf -- '  is `warning`, so ERROR and WARNING are both in there.\n'
		printf -- '- `<node>-join-seed-sub.log` -- the one subscription that carries the\n'
		printf -- '  schema and the data across, and the wait for its initial sync.\n'
		printf -- '  First place to look at a join problem.\n'
		printf -- '- `<node>-join-edges.log` -- the remaining subscriptions, both\n'
		printf -- '  directions, created with no synchronisation.\n'
		printf -- '- `<node>-mirror-repsets.log` -- every replication-set membership that\n'
		printf -- '  had to be corrected against the source, and the read-back proving it\n'
		printf -- '  took.\n'
		printf -- '- `<node>-repset-add-all.log` -- which tables went into which\n'
		printf -- '  replication set, and which were excluded and why.\n'
		printf -- '- `<node>-installcheck.log` -- the regression run.\n'
		printf -- '- `<node>-health-*.log` -- one file per health check.\n'
		printf -- '- `<node>-spock-bootstrap.log` -- CREATE EXTENSION and node_create.\n'
		printf -- '\n'
		printf -- 'Relation and row-count snapshots: %s\n\n' "${REPORT_DIR}"
		printf 'The regression suite reports many failed tests here and that is\n'
		printf 'expected, not a problem: auto-DDL prints an extra `INFO:  DDL statement\n'
		printf 'replicated.` line after every DDL statement, so every test that creates\n'
		printf 'an object differs from its expected output. The diffs are in\n\n'
		printf -- '    %s/src/test/regress/regression.diffs\n\n' \
			"$(pgsrc_for "$(node_variant "${FIRST_NODE}")")"

		printf '%s\n' 'Data directories'
		printf '%s\n\n' '-----------------'
		for node in ${NODES}; do
			printf -- '    %-4s %s\n' "${node}" "$(data_for "${node}" "$(node_variant "${node}")")"
		done
		printf -- '\n'

		printf '%s\n' 'Stopping it'
		printf '%s\n\n' '------------'
		printf 'The servers outlive this script. Stop them with:\n\n'
		for node in ${NODES}; do
			printf -- '    %s/bin/pg_ctl -D %s -m fast stop\n' \
				"$(prefix_for "$(node_variant "${node}")")" \
				"$(data_for "${node}" "$(node_variant "${node}")")"
		done
		printf -- '\n'
		printf 'Note that any other run of this rig begins by stopping every server under\n'
		printf -- '%s,\n' "${BASE_DIR}"
		printf 'so starting one will take this cluster down.\n\n'

		printf '%s\n' 'State at handover'
		printf '%s\n\n' '------------------'
	} >"${out}" || return 1

	# Appended with psql rather than composed by hand, so what the file claims
	# is what the cluster said.
	for node in ${NODES}; do
		printf -- '    -- %s\n' "${node}" >>"${out}"
		psql_on "${node}" -c "
			SELECT subscription_name, status, provider_node
			FROM spock.sub_show_status() ORDER BY 1;" >>"${out}" 2>&1 \
			|| printf '    (subscription status could not be read)\n' >>"${out}"
		psql_on "${node}" -c "
			SELECT set_name, count(*) AS tables
			FROM spock.replication_set r
			JOIN spock.replication_set_table t ON t.set_id = r.set_id
			GROUP BY 1 ORDER BY 1;" >>"${out}" 2>&1 \
			|| printf '    (replication sets could not be read)\n' >>"${out}"
	done

	cat "${out}"
}

main() {
	# A previous --stop-after run leaves its servers up, and they hold the same
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
	# Reported here so the crash is named before the health check buries it
	# among the other probes; that check is what decides the verdict, so a
	# non-zero return is logged rather than acted on.
	report_crash_markers "${FIRST_NODE}" \
		|| log "${FIRST_NODE}: crash markers reported; the health check below is the authority"

	# Must happen before anything replicates or upgrades this database; see
	# normalise_regress_probin() for why.
	normalise_regress_probin "${FIRST_NODE}"

	# Mapped explicitly: an unchecked failure here exits 1, which is not one
	# of the documented verdicts, so the run reports a status the header does
	# not explain.  A replication set that could not be populated is a step-2
	# problem.
	repset_add_all_tables "${FIRST_NODE}" \
		|| fail "${FIRST_NODE}: could not populate the replication sets (see ${LOG_DIR}/${FIRST_NODE}-repset-add-all.log)" 13

	local n1_rels n1_rc=0
	n1_rels="$(capture_signature "${FIRST_NODE}" "${FIRST_NODE}-populated" all)" || n1_rc=$?
	[ "${n1_rc}" -eq 0 ] \
		|| fail "${FIRST_NODE}: the payload snapshot could not be taken (rc=${n1_rc}) -- see ${MAIN_LOG}" 13
	[ "${n1_rels}" -gt 0 ] \
		|| fail "${FIRST_NODE}: the ${DBNAME} database has no user relations -- nothing to test" 13
	say "${FIRST_NODE}: ${DBNAME} holds ${n1_rels} user relations"

	if ! check_node_health "${FIRST_NODE}" 5 1 0; then
		fail "${FIRST_NODE} failed its health check with no replication active (see ${HEALTH_LOG})" 13
	fi
	say "step 2 done: ${first_variant} node has ${n1_rels} relations, no replication active"

	# Checked here, while there is still time for the answer to matter: the
	# documented procedure resolves every one of its waits from this budget,
	# and discovering it was never in force three steps later only explains a
	# timeout that has already happened.  Step 3's own initial sync does not
	# use it -- JOIN_TIMEOUT bounds that from outside.
	assert_sync_budget_visible "${FIRST_NODE}"
	say "step 3: each node's initial sync capped at ${JOIN_TIMEOUT}s by the rig"

	# =====================================================================
	# Step 3: join every remaining node to n1.
	# =====================================================================
	# `attached` grows as nodes come in: each joiner is wired to every node
	# already present, not just to the source.
	local joiner joiner_variant attached="${FIRST_NODE}"
	for joiner in ${NODES}; do
		[ "${joiner}" = "${FIRST_NODE}" ] && continue
		joiner_variant="$(node_to_old_variant "${joiner}")"

		say "=== step 3: add ${joiner_variant} node ${joiner} ==="

		init_node  "${joiner}" "${joiner_variant}"
		start_node "${joiner}" "${joiner_variant}"
		wait_for_ready "${joiner}" || fail "${joiner} never became ready" 12

		create_db_for_node "${joiner}"
		setup_spock_node   "${joiner}" yes
		sync_roles "${FIRST_NODE}" "${joiner}" \
			|| fail "${joiner}: the source's roles could not be copied over, so the structure sync would fail on a missing role" 14

		# The joiner is typically a newer major than the source, and spock's
		# structure sync pg_restores the source's schema into it.  Anything the
		# newer major no longer accepts has to go first, or the restore fails
		# and the join times out waiting for a sync that could not have
		# happened, with no indication of why.  See adapt_for_target().
		adapt_for_target "${FIRST_NODE}" "${joiner_variant}" \
			|| fail "${FIRST_NODE}: could not adapt its schema for ${joiner_variant}" 14

		attach_node "${FIRST_NODE}" "${joiner}" ${attached} \
			|| { dump_replication_diagnostics "join-failed-${joiner}"
			     fail "could not attach ${joiner} to the mesh (see ${LOG_DIR}/${joiner}-join-*.log)" 14; }
		attached="${attached} ${joiner}"
	done

	wait_for_mesh_replicating "${WAIT_REPLICATING_TIMEOUT}" \
		|| { print_subscription_state "step 3 timeout"
		     dump_replication_diagnostics step3-timeout
		     print_subscription_state_to_screen
		     fail "subscriptions did not reach 'replicating' within ${WAIT_REPLICATING_TIMEOUT}s" 14; }

	print_subscription_state "after step 3"

	# A full mesh of N nodes gives every node N-1 subscriptions.
	local subs_per_node=$(( NODE_COUNT - 1 ))
	for node in ${NODES}; do
		check_node_health "${node}" 5 "${NODE_COUNT}" "${subs_per_node}" \
			|| fail "${node} unhealthy after step 3 (see ${HEALTH_LOG})" 14
	done
	say "step 3 OK: ${NODE_COUNT}-node mesh replicating"

	# Do the nodes actually agree on the replicated tables?  Diagnostic only --
	# step 3's verdict is subscription state -- but a divergence is reported
	# and does colour the exit code.  Compared against the first node, which
	# is where the data originated.
	capture_signature "${FIRST_NODE}" "${FIRST_NODE}-after-join" repset >/dev/null \
		|| fail "${FIRST_NODE}: the post-join snapshot could not be taken" 14
	for node in ${NODES}; do
		[ "${node}" = "${FIRST_NODE}" ] && continue
		capture_signature "${node}" "${node}-after-join" repset >/dev/null \
			|| fail "${node}: the post-join snapshot could not be taken" 14
		compare_signatures "${FIRST_NODE}-after-join" "${node}-after-join" \
			"replicated tables agree between ${FIRST_NODE} and ${node}" \
			|| VERDICT_NODE_DATA=FAIL
	done

	# =====================================================================
	# --stop-after: stop here and hand the cluster over
	# =====================================================================
	# Everything the other modes do next either upgrades a node or fences one.
	# This mode exists for the state that has just been reached: a Spock 5
	# mesh, populated by the real regression suite, replicating.  So it reports
	# how to use it and leaves it up -- KEEP_RUNNING is forced on by the flag,
	# so the EXIT trap will not stop the servers.
	if [ "${SETUP_ONLY}" -eq 1 ]; then
		# --stop-after upgrade: carry on into the document's own Part 1 and
		# Part 2, for ONE node, and stop where the "Upgrade" section ends.
		#
		# Driven through proc_prepare_for_procedure and proc_upgrade_one_node,
		# the same two functions the full run uses, rather than a second
		# rendering of the same steps.  The document is the thing under test;
		# a mode that tested its own paraphrase of the document would be
		# measuring the paraphrase.
		if [ "${SETUP_STAGE}" = "upgrade" ]; then
			say "=== stop-after upgrade: following the document as far as step 7 ==="
			proc_prepare_for_procedure
			proc_upgrade_one_node "${FIRST_NODE}" 7
			SETUP_UPGRADED_NODE="${FIRST_NODE}"
		fi

		# Before claiming the mesh replicates, prove it.
		#
		# Up to here the claim rested on two things that can both be true of a
		# mesh that moves no data: sub_show_status() saying 'replicating',
		# which means the apply worker is connected rather than that anything
		# arrived, and a row-count comparison between snapshots taken at
		# different instants with no barrier in between, which on an idle
		# cluster compares two copies of the same quiet state.  A sync event
		# driven across every directed edge and waited for is the actual
		# evidence, and it is the mechanism the document itself uses.
		#
		# Skipped for the `upgrade` stage, where it could not succeed by
		# construction: that node's own subscriptions are disabled, so nothing
		# can reach it and a full round trip is not the right question there.
		# _do_proc_verify_surviving_slot asks the question that IS right.
		if [ "${SETUP_STAGE}" != "upgrade" ]; then
			proc_init
			say "=== ${SETUP_STAGE}: proving replication with a sync event on every edge ==="
			run_phase cluster setup-syncevent _do_proc_sync_roundtrip \
				|| fail "the mesh reports 'replicating' but a sync event did not cross every edge (see ${LOG_DIR}/cluster-setup-syncevent.log)" 14
		fi

		say "=== ${SETUP_STAGE}: stopping here, cluster left running ==="
		print_subscription_state "stop-after-${SETUP_STAGE} handover"
		run_phase cluster setup-only-report _do_setup_only_report \
			|| fail "the handover report could not be written" 14
		# To the terminal as well as the file: the file is for tomorrow, the
		# terminal is for the next thirty seconds.
		cat "$(setup_only_readme)" >&2

		if [ "${VERDICT_NODE_DATA}" = "FAIL" ]; then
			say "RESULT: FAIL (5) -- the cluster is up and replicating, but the nodes"
			say "        do not agree on the replicated tables.  See ${REPORT_DIR}."
			exit 5
		fi
		if [ "${SETUP_STAGE}" = "upgrade" ]; then
			# The findings are the point of this stage, so they colour the exit
			# code exactly as they do in a full run.  PROC_FAILURES cannot
			# be non-zero here -- nothing in steps 1-7 calls proc_failure, and
			# a step that fails calls fail() and never returns -- but it is
			# checked rather than assumed.
			if [ "${PROC_FAILURES}" -ne 0 ]; then
				say "RESULT: FAIL (21) -- ${PROC_FAILURES} procedure failure(s); see ${PROC_LOG}"
				exit 21
			fi
			if [ "${PROC_FINDINGS}" -ne 0 ]; then
				say "RESULT: (22) -- ${SETUP_UPGRADED_NODE} upgraded and left mid-procedure;"
				say "        ${PROC_FINDINGS} claim(s) in the document did not hold. See ${PROC_LOG}."
				say "        instructions and log locations: $(setup_only_readme)"
				exit 22
			fi
			say "RESULT: PASS -- ${SETUP_UPGRADED_NODE} upgraded per steps 1-7, left mid-procedure"
			say "        instructions and log locations: $(setup_only_readme)"
			exit 0
		fi
		say "RESULT: PASS -- ${NODE_COUNT} spock ${SPOCK_V5_VERSION} nodes replicating, left running"
		say "        instructions and log locations: $(setup_only_readme)"
		exit 0
	fi

	# =====================================================================
	# The documented rolling upgrade
	# =====================================================================
	# Steps 1-3 above have built exactly what
	# spock-upgrade-procedure-corrected.md assumes: a healthy mesh on the old
	# majors holding a complex database.  Everything past this point is the
	# document's own procedure, and it reaches its own verdict and exits.
	proc_run_documented_upgrade
}

main "$@"
