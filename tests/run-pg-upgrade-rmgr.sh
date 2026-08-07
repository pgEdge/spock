#!/usr/bin/env bash
#
# tests/run-pg-upgrade-rmgr.sh
#
# Regression test for "resource manager with ID 144 not registered":
# pg_upgrade of a Spock 6 node out of a PG17-or-later old cluster.
#
# From PG17 on, pg_upgrade proves every logical slot is drained by calling
# binary_upgrade_logical_slot_has_caught_up(), which decodes the slot's WAL
# from confirmed_flush to the end of WAL.  Logical decoding resolves the
# resource manager of *every* record it walks past, whether or not that rmgr
# has a decode callback.  Spock registers a custom rmgr (id 144) and writes
# records with it -- among them the SPOCK_DUMP_SHUTDOWN forensic snapshot,
# emitted by the supervisor's before_shmem_exit hook, i.e. after the slot's
# last confirmed_flush and therefore always inside the decoded range.
#
# If spock_rmgr_init() is not reached in the throwaway servers pg_upgrade
# starts (it used to sit *below* the IsBinaryUpgrade early return in
# _PG_init), GetRmgr() raises
#
#     ERROR:  resource manager with ID 144 not registered
#
# and pg_upgrade dies at the consistency-check stage.
#
# What this script does:
#   1. builds PG_OLD (default 17) and PG_NEW (default 18) from source with
#      the spock patches from patches/<ver>/ applied, and builds Spock
#      against each;
#   2. brings up a two-node Spock mesh (n1, n2) on PG_OLD, replicates a
#      table both ways, and confirms the round trip with spock.sync_event();
#   3. shuts both nodes down cleanly, so n1's supervisor emits its
#      SPOCK_DUMP_SHUTDOWN records past n2's confirmed_flush, and uses
#      pg_waldump to assert a spock rmgr record really does sit in the range
#      pg_upgrade is about to decode;
#   4. runs `pg_upgrade --check` and then the real pg_upgrade of n1 from
#      PG_OLD to PG_NEW, and fails the test if either reports the rmgr
#      error;
#   5. starts the upgraded node and checks Spock survived: extension
#      present, spock.node intact, replicated data intact, and the logical
#      slot carried over by pg_upgrade.
#
# Compatible with bash 3.2 (macOS /bin/bash) -- no associative arrays.
#
# Layout (under BASE_DIR, default <spock-repo>/pg-upgrade-rmgr):
#   src/pg<ver>            PG source clone, per major
#   bin/pg<ver>            PG install (configure --prefix), per major
#   spock-build/pg<ver>    Spock source copy + build artefacts, per major
#   pgdata/n1, n2          PGDATA of the old-cluster nodes
#   pgdata/n1-new          PGDATA of the upgraded node
#   upgrade-run/           pg_upgrade's cwd (its pg_upgrade_output.d lands
#                          in pgdata/n1-new from PG15 on)
#   log/                   per-instance log files
#   sock/                  unix-socket dir shared by all nodes
#
# Usage:
#   tests/run-pg-upgrade-rmgr.sh [--base-dir DIR] [--pg-old N] [--pg-new N]
#                                [--negative-control] [--keep] [--force]
#                                [--jobs N]
#
# --negative-control reverts the fix in the *build copy* of src/spock.c
# (moving spock_rmgr_init() back below the IsBinaryUpgrade return), rebuilds
# Spock, and inverts the verdict: the run passes only if pg_upgrade fails
# with the rmgr error.  It leaves the repository untouched.  Use it to prove
# the rig actually exercises the bug.
#
# Existing PG installs (bin/postgres present) and Spock installs
# (extension/spock.control present) are reused by default to speed up
# re-runs.  Pass --force to rebuild everything from scratch.
#
# Exit status:
#   0  pg_upgrade --check and pg_upgrade both succeeded, no rmgr error
#      anywhere in their logs, and the upgraded node still has Spock,
#      its node record, its data and its logical slot.
#      (Under --negative-control: pg_upgrade failed *with* the rmgr error.)
#   2  the test failed -- see the reason printed on the terminal.
#   >2 build / setup error.
#

# Deliberately NOT using `-E` (errtrace): with -E the ERR trap leaks into
# command substitutions and a single transient psql failure could shut
# everything down.
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPOCK_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"

BASE_DIR="${SPOCK_SRC}/pg-upgrade-rmgr"
KEEP_RUNNING=0
FORCE_REBUILD=0
NEGATIVE_CONTROL=0
JOBS_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

# PG16 old clusters are deliberately *not* supported here: pg_upgrade does
# not migrate or check logical slots from a pre-17 old cluster, so nothing
# decodes anything and the bug cannot appear.
PG_OLD=17
PG_NEW=18

OLD_NODES="n1 n2"

DBNAME=regression
DBUSER=regression

# Read the id out of the header rather than hardcoding it, so a change to
# SPOCK_RMGR_ID cannot leave this test silently looking for the wrong thing.
SPOCK_RMGR_ID="$(sed -n \
	's/^#define[[:space:]]\{1,\}SPOCK_RMGR_ID[[:space:]]\{1,\}\([0-9]\{1,\}\).*/\1/p' \
	"${SPOCK_SRC}/include/spock_rmgr.h" | tail -n 1)"
[ -n "${SPOCK_RMGR_ID}" ] || {
	echo "could not read SPOCK_RMGR_ID from ${SPOCK_SRC}/include/spock_rmgr.h" >&2
	exit 3
}

# The error this whole rig exists to catch, and the name pg_waldump prints
# for records of an unloaded custom rmgr ("custom###", zero-padded to 3).
RMGR_ERROR_RE="resource manager with ID ${SPOCK_RMGR_ID} not registered"
WALDUMP_RMGR_NAME="$(printf 'custom%03d' "${SPOCK_RMGR_ID}")"

PG_GIT_REMOTES="https://git.postgresql.org/git/postgresql.git https://github.com/postgres/postgres.git"

# ---------------------------------------------------------------------------
# Bash-3-safe lookup helpers (no `declare -A`)
# ---------------------------------------------------------------------------

# Ports deliberately differ from the other rigs (57516..57518, 57601..57603)
# so all of them can run simultaneously.
node_to_port() {
	case "$1" in
		n1)     echo 57701 ;;
		n2)     echo 57702 ;;
		n1-new) echo 57703 ;;
		*)      return 1 ;;
	esac
}

# ---------------------------------------------------------------------------
# Logging / error trap
# ---------------------------------------------------------------------------

# log() writes only to disk -- the terminal stays clean.  Output goes to
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

fail() { say "FATAL: $1"; log "FATAL: $1"; exit "${2:-3}"; }

# run_phase LABEL PHASE CMD ARGS...
#   Runs CMD with stdout+stderr captured to ${LOG_DIR}/<label>-<phase>.log
#   and emits a single end-of-phase OK/FAILED line on the terminal.
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

trap 'on_err $? $LINENO' ERR

on_err() {
	local rc=$1 line=$2
	log "Aborted: exit ${rc} at line ${line}"
	say "see ${LOG_DIR}/ for per-instance log files"
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
		--base-dir)         [ "$#" -ge 2 ] || fail "--base-dir requires a value" 4
		                    BASE_DIR="$2"; shift 2 ;;
		--pg-old)           [ "$#" -ge 2 ] || fail "--pg-old requires a value" 4
		                    PG_OLD="$2"; shift 2 ;;
		--pg-new)           [ "$#" -ge 2 ] || fail "--pg-new requires a value" 4
		                    PG_NEW="$2"; shift 2 ;;
		--negative-control) NEGATIVE_CONTROL=1; shift ;;
		--keep)             KEEP_RUNNING=1; shift ;;
		--force)            FORCE_REBUILD=1; shift ;;
		--jobs)             [ "$#" -ge 2 ] || fail "--jobs requires a value" 4
		                    JOBS_TOTAL="$2"; shift 2 ;;
		-h|--help)          usage; exit 0 ;;
		*)                  fail "unknown argument: $1" 4 ;;
	esac
done

case "${PG_OLD}" in ''|*[!0-9]*) fail "--pg-old must be numeric" 4 ;; esac
case "${PG_NEW}" in ''|*[!0-9]*) fail "--pg-new must be numeric" 4 ;; esac
[ "${PG_OLD}" -ge 17 ] \
	|| fail "--pg-old must be 17 or later: pg_upgrade does not check logical slots on older majors, so the rmgr bug cannot appear" 4
[ "${PG_NEW}" -gt "${PG_OLD}" ] \
	|| fail "--pg-new (${PG_NEW}) must be greater than --pg-old (${PG_OLD})" 4

# initdb and the servers refuse to run as root, and pg_upgrade inherits that.
[ "$(id -u)" -ne 0 ] \
	|| fail "refusing to run as root: initdb/postgres will not start; re-run as an unprivileged user" 4

mkdir -p "${BASE_DIR}/src"          \
         "${BASE_DIR}/bin"          \
         "${BASE_DIR}/spock-build"  \
         "${BASE_DIR}/pgdata"       \
         "${BASE_DIR}/upgrade-run"  \
         "${BASE_DIR}/log"          \
         "${BASE_DIR}/sock"
BASE_DIR="$(cd "${BASE_DIR}" && pwd)"
SOCK_DIR="${BASE_DIR}/sock"
LOG_DIR="${BASE_DIR}/log"
UPGRADE_RUN_DIR="${BASE_DIR}/upgrade-run"

# Fresh log directory per run; src/, bin/, spock-build/ are preserved so
# reuse-on-rerun still works.  pgdata/ and upgrade-run/ are rebuilt from
# scratch below -- a half-upgraded data dir must never be reused.
rm -rf "${LOG_DIR}" "${UPGRADE_RUN_DIR}"
mkdir -p "${LOG_DIR}" "${UPGRADE_RUN_DIR}"

MAIN_LOG="${LOG_DIR}/main.log"
: >"${MAIN_LOG}"

log "BASE_DIR         = ${BASE_DIR}"
log "SPOCK_SRC        = ${SPOCK_SRC}"
log "JOBS_TOTAL       = ${JOBS_TOTAL}"
log "PG_OLD           = ${PG_OLD}"
log "PG_NEW           = ${PG_NEW}"
log "NEGATIVE_CONTROL = ${NEGATIVE_CONTROL}"

# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

prefix_for()      { echo "${BASE_DIR}/bin/pg$1"; }
src_for()         { echo "${BASE_DIR}/src/pg$1"; }
spock_build_for() { echo "${BASE_DIR}/spock-build/pg$1"; }
pg_config_for()   { echo "${BASE_DIR}/bin/pg$1/bin/pg_config"; }

OLD_PREFIX="$(prefix_for "${PG_OLD}")"
NEW_PREFIX="$(prefix_for "${PG_NEW}")"

data_for() { echo "${BASE_DIR}/pgdata/$1"; }

# Which install serves a given node.  n1/n2 are the old cluster; n1-new is
# the upgraded one.
prefix_of_node() {
	case "$1" in
		n1-new) echo "${NEW_PREFIX}" ;;
		*)      echo "${OLD_PREFIX}" ;;
	esac
}

# DSN that talks over the shared Unix socket directory.
dsn_for_node() {
	local node="$1"
	local port; port="$(node_to_port "${node}")"
	echo "host=${SOCK_DIR} port=${port} dbname=${DBNAME} user=${DBUSER}"
}

psql_on() {
	local node="$1"; shift
	local port;   port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_of_node "${node}")"
	PGPASSWORD="" "${prefix}/bin/psql" \
		-X -v ON_ERROR_STOP=1 \
		-h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -d "${DBNAME}" \
		"$@"
}

# ---------------------------------------------------------------------------
# Build pipeline: clone + patch + build PG + build Spock, once per major
# ---------------------------------------------------------------------------

# Pick the first reachable mirror.  Reachability is checked generically
# (HEAD), not by looking up a ref, because the configured ref may be a raw
# commit SHA rather than a ref name; a bad ref is caught by the fetch below.
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

# fetch + checkout (not clone --branch) so an explicit commit-SHA pin works
# as well as a branch or tag name.
_do_clone_pg() {
	local remote="$1" src="$2" ref="$3"
	rm -rf "${src}" && \
	git init "${src}" && \
	git -C "${src}" remote add origin "${remote}" && \
	git -C "${src}" fetch --depth 1 origin "${ref}" && \
	git -C "${src}" checkout --detach FETCH_HEAD && \
	printf '%s\n' "${ref}" > "${src}/.spock-pg-ref"
}

clone_pg() {
	local ver="$1"
	local src; src="$(src_for "${ver}")"
	local ref

	# tag | branch | explicit pin, per tests/postgres-build.conf.
	ref="$("${SCRIPT_DIR}/resolve-pg-ref.sh" "${ver}")" \
		|| fail "PG${ver}: could not resolve PostgreSQL ref from config" 5

	# A cached checkout built for a different ref forces a full rebuild of
	# this major, so the new ref reaches the pg-build and spock-build phases
	# too.  A moved branch tip (same ref name, new commits) is deliberately
	# NOT detected here; use --force for that.
	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ -d "${src}/.git" ] \
		&& [ "$(cat "${src}/.spock-pg-ref" 2>/dev/null)" != "${ref}" ]; then
		log "pg${ver}: [pg-clone] cached source is for a different ref;" \
			"rebuilding for ${ref}"
		FORCE_REBUILD=1
	fi

	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ -d "${src}/.git" ] \
		&& [ -f "${src}/src/test/regress/parallel_schedule" ]; then
		log "pg${ver}: [pg-clone] source for ${ref} already present, skipping"
		return 0
	fi

	local remote
	remote="$(pick_pg_remote)" \
		|| fail "PG${ver}: no reachable git remote for ${ref}" 5

	log "pg${ver}: [pg-clone] ${ref} from ${remote}"
	run_phase "pg${ver}" pg-clone _do_clone_pg "${remote}" "${src}" "${ref}"
}

# Spock needs Postgres with per-version patches applied; patches live in
# patches/<ver>/ in the spock tree, applied in lexical order via `git apply`.
# A marker file makes the phase idempotent.
_do_patch_pg() {
	local src="$1" patch_dir="$2"
	if [ ! -d "${patch_dir}" ]; then
		echo "no patch directory ${patch_dir} -- nothing to do"
		return 0
	fi
	local p any=0
	for p in "${patch_dir}"/*.diff "${patch_dir}"/*.patch; do
		[ -f "${p}" ] || continue
		any=1
		echo "----- applying $(basename "${p}") -----"
		( cd "${src}" && git apply --whitespace=nowarn -p1 "${p}" )
	done
	if [ "${any}" -eq 0 ]; then
		echo "no .diff/.patch files in ${patch_dir}"
	fi
	touch "${src}/.spock-patches-applied"
}

patch_pg() {
	local ver="$1"
	local src; src="$(src_for "${ver}")"

	if [ -f "${src}/.spock-patches-applied" ]; then
		log "pg${ver}: [pg-patch] patches already applied (marker present), skipping"
		return 0
	fi
	run_phase "pg${ver}" pg-patch _do_patch_pg "${src}" "${SPOCK_SRC}/patches/${ver}"
}

_do_configure_pg() {
	local src="$1" prefix="$2"
	cd "${src}"
	./configure --prefix="${prefix}" --enable-debug --enable-cassert \
		--with-icu --with-openssl --with-readline --with-zstd --with-lz4
}

_do_build_pg() {
	local src="$1" jobs="$2"
	make -C "${src}" -s -j"${jobs}"
	make -C "${src}" -s -j"${jobs}" install
}

build_pg() {
	local ver="$1"
	local src;    src="$(src_for "${ver}")"
	local prefix; prefix="$(prefix_for "${ver}")"

	if [ "${FORCE_REBUILD}" -eq 0 ] && [ -x "${prefix}/bin/postgres" ]; then
		log "pg${ver}: [pg-build] reusing existing install at ${prefix}"
		return 0
	fi

	run_phase "pg${ver}" pg-configure _do_configure_pg "${src}" "${prefix}"
	run_phase "pg${ver}" pg-build     _do_build_pg     "${src}" "${JOBS_TOTAL}"
}

# --negative-control only: put spock_rmgr_init() back *below* the
# IsBinaryUpgrade early return in the throwaway build copy, reproducing the
# pre-fix code.  The repository itself is never touched.  The substitution
# is asserted to fire exactly once, so a future refactor of _PG_init turns
# the negative control into a loud build failure rather than a silent
# false pass.
_do_revert_rmgr_fix() {
	local file="$1"
	perl -0777 -i -pe '
		my $n = s/\tspock_rmgr_init\(\);\n\n\tif \(IsBinaryUpgrade\)\n\t\treturn;\n/\tif (IsBinaryUpgrade)\n\t\treturn;\n\n\tspock_rmgr_init();\n/;
		die "negative control: expected exactly 1 substitution in _PG_init, made $n\n"
			unless $n == 1;
	' "${file}"
	echo "reverted the rmgr fix in ${file}:"
	grep -n -A3 'if (IsBinaryUpgrade)' "${file}"
}

# Spock builds in its own copy of the source tree.  `make clean` after the
# rsync evicts any build artefacts a manual `make` in the repo root may have
# left behind (objects compiled against the wrong PG headers would otherwise
# be installed verbatim).
_do_build_spock() {
	local build="$1" pg_config="$2" jobs="$3"
	rm -rf "${build}"
	mkdir -p "${build}"
	rsync -a \
		--exclude='/pg-upgrade-rmgr' \
		--exclude='/single-pg18-installcheck' \
		--exclude='/.git' \
		--exclude='.DS_Store' \
		"${SPOCK_SRC}/" "${build}/"
	if [ "${NEGATIVE_CONTROL}" -eq 1 ]; then
		_do_revert_rmgr_fix "${build}/src/spock.c"
	fi
	make -C "${build}" PG_CONFIG="${pg_config}" clean
	make -C "${build}" PG_CONFIG="${pg_config}" -j"${jobs}"
	make -C "${build}" PG_CONFIG="${pg_config}" install
}

build_spock() {
	local ver="$1"
	local build;     build="$(spock_build_for "${ver}")"
	local pg_config; pg_config="$(pg_config_for "${ver}")"

	# The negative control differs only in Spock's own source, so an install
	# cached from a normal run would silently defeat it: always rebuild.
	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ "${NEGATIVE_CONTROL}" -eq 0 ] \
		&& [ -f "$("${pg_config}" --sharedir)/extension/spock.control" ]; then
		log "pg${ver}: [spock-build] reusing existing install"
		return 0
	fi

	run_phase "pg${ver}" spock-build _do_build_spock \
		"${build}" "${pg_config}" "${JOBS_TOTAL}"
}

build_stack() {
	local ver="$1"
	clone_pg    "${ver}"
	patch_pg    "${ver}"
	build_pg    "${ver}"
	build_spock "${ver}"
}

# ---------------------------------------------------------------------------
# Per-node initdb + start
# ---------------------------------------------------------------------------

# pg_upgrade insists the two clusters agree on things initdb decides, and
# those defaults drift between majors -- PG18 turns data checksums on by
# default, PG17 does not.  Spell out everything pg_upgrade compares
# (checksums, encoding, locale, locale provider) so the rig is not at the
# mercy of the next default flip.  -k and --locale-provider are accepted by
# every major this script supports.
_do_initdb() {
	local prefix="$1" data="$2"
	"${prefix}/bin/initdb" -D "${data}" -U "${DBUSER}" \
		--encoding=UTF8 --locale=C --locale-provider=libc -k
}

# The GUCs must match on both sides of the upgrade: wal_level=logical and
# enough max_replication_slots for pg_upgrade to carry the slots over, and
# spock in shared_preload_libraries so the extension's _PG_init runs at all
# -- including in the throwaway servers pg_upgrade starts.
write_conf() {
	local data="$1" port="$2"
	cat >>"${data}/postgresql.conf" <<-EOF
		# --- pg_upgrade rmgr test rig ---
		listen_addresses = ''
		unix_socket_directories = '${SOCK_DIR}'
		port = ${port}
		max_connections = 100

		wal_level = logical
		track_commit_timestamp = on
		max_worker_processes = 16
		max_replication_slots = 16
		max_wal_senders = 16

		log_min_messages = 'log'
		log_statement = 'none'
		logging_collector = off

		shared_preload_libraries = 'spock'
		spock.conflict_resolution = 'last_update_wins'
		spock.exception_behaviour = 'discard'
	EOF

	# Trust on the shared Unix socket; no TCP listener so this is local-only.
	cat >>"${data}/pg_hba.conf" <<-EOF
		local all all trust
		local replication all trust
	EOF
}

init_node() {
	local node="$1"
	local data;   data="$(data_for "${node}")"
	local port;   port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_of_node "${node}")"

	if [ -d "${data}" ]; then
		log "${node}: [initdb] clearing existing data dir"
		rm -rf "${data}"
	fi
	run_phase "${node}" initdb _do_initdb "${prefix}" "${data}"
	write_conf "${data}" "${port}"
}

_do_pg_ctl_start() {
	local prefix="$1" data="$2" server_log="$3"
	"${prefix}/bin/pg_ctl" -D "${data}" -l "${server_log}" -w -t 60 start
}

start_node() {
	local node="$1"
	local data;   data="$(data_for "${node}")"
	local prefix; prefix="$(prefix_of_node "${node}")"
	run_phase "${node}" pg-start _do_pg_ctl_start \
		"${prefix}" "${data}" "${LOG_DIR}/${node}-server.log"
}

# A *clean* shutdown is what makes this test meaningful: it is the clean
# shutdown that runs spock_supervisor_on_exit() and so emits the
# SPOCK_DUMP_SHUTDOWN records past n2's confirmed_flush.  pg_upgrade also
# refuses to touch a cluster that was not shut down cleanly.
stop_node() {
	local node="$1"
	local data;   data="$(data_for "${node}")"
	local prefix; prefix="$(prefix_of_node "${node}")"
	if [ -f "${data}/postmaster.pid" ]; then
		log "${node}: pg_ctl stop"
		"${prefix}/bin/pg_ctl" -D "${data}" -m fast -w -t 60 stop || true
	fi
}

stop_all_nodes() {
	local node
	for node in ${OLD_NODES} n1-new; do stop_node "${node}"; done
}

# Bound to EXIT so node shutdown runs on normal completion AND on every
# failure path -- including the ERR trap, which exit()s before main()'s tail
# is reached.  stop_node is a no-op for nodes that never started.
cleanup_nodes() {
	if [ "${KEEP_RUNNING}" -eq 0 ]; then
		stop_all_nodes
	else
		log "--keep set: leaving nodes running. Sockets under ${SOCK_DIR}"
	fi
}
trap cleanup_nodes EXIT

wait_for_ready() {
	local node="$1"
	local port;   port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_of_node "${node}")"
	local deadline=$(( $(date +%s) + 60 ))
	while [ "$(date +%s)" -lt "${deadline}" ]; do
		if "${prefix}/bin/pg_isready" -q \
				-h "${SOCK_DIR}" -p "${port}" -d "${DBNAME}" -U "${DBUSER}"; then
			log "${node}: pg_isready OK"
			return 0
		fi
		sleep 1
	done
	log "${node}: pg_isready did not become ready within 60s"
	return 1
}

# ---------------------------------------------------------------------------
# DB + Spock bootstrap on the old cluster
# ---------------------------------------------------------------------------

_do_createdb() {
	local prefix="$1" port="$2"
	"${prefix}/bin/createdb" -h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -O "${DBUSER}" "${DBNAME}"
}

create_db_for_node() {
	local node="$1"
	local port;   port="$(node_to_port "${node}")"
	local prefix; prefix="$(prefix_of_node "${node}")"
	run_phase "${node}" createdb _do_createdb "${prefix}" "${port}"
}

setup_spock_node() {
	local node="$1"
	local logf="${LOG_DIR}/${node}-spock-bootstrap.log"
	log "${node}: [spock-bootstrap] CREATE EXTENSION + node_create  -> ${logf}"
	{
		psql_on "${node}" -c "CREATE EXTENSION IF NOT EXISTS spock;"
		psql_on "${node}" <<-SQL
			SELECT spock.node_create(
				node_name := '${node}',
				dsn       := '$(dsn_for_node "${node}")'
			);
		SQL
	} >>"${logf}" 2>&1
}

create_subscription() {
	local provider="$1" subscriber="$2"
	local subname="sub_${provider}_${subscriber}"
	local provider_dsn; provider_dsn="$(dsn_for_node "${provider}")"
	local logf="${LOG_DIR}/${subscriber}-spock-bootstrap.log"

	log "${subscriber}: [spock-bootstrap] sub_create ${subname} <- ${provider}"
	psql_on "${subscriber}" >>"${logf}" 2>&1 <<-SQL
		SELECT spock.sub_create(
			subscription_name     := '${subname}',
			provider_dsn          := '${provider_dsn}',
			synchronize_structure := false,
			synchronize_data      := false,
			forward_origins       := '{}'::text[],
			enabled               := true
		);
	SQL
}

wire_mesh() {
	local subscriber provider
	for subscriber in ${OLD_NODES}; do
		for provider in ${OLD_NODES}; do
			[ "${provider}" = "${subscriber}" ] && continue
			create_subscription "${provider}" "${subscriber}"
		done
	done
}

WAIT_REPLICATING_TIMEOUT=60

wait_for_mesh_replicating() {
	local deadline node n not_replicating
	deadline=$(( $(date +%s) + WAIT_REPLICATING_TIMEOUT ))
	while [ "$(date +%s)" -lt "${deadline}" ]; do
		not_replicating=0
		for node in ${OLD_NODES}; do
			n="$(psql_on "${node}" -At -c \
				"SELECT count(*) FROM spock.sub_show_status() \
				 WHERE status IS DISTINCT FROM 'replicating';" \
				2>/dev/null)" || n=999
			if [ "${n}" -ne 0 ]; then
				not_replicating=1
				break
			fi
		done
		if [ "${not_replicating}" -eq 0 ]; then
			log "all subscriptions reached status='replicating'"
			return 0
		fi
		sleep 1
	done
	log "timed out after ${WAIT_REPLICATING_TIMEOUT}s waiting for subs to reach 'replicating'"
	return 1
}

# ---------------------------------------------------------------------------
# Workload: give the mesh real apply progress to snapshot at shutdown
# ---------------------------------------------------------------------------

# spock_rmgr_log_resource_dump() returns early when SpockGroupHash is empty,
# so the SHUTDOWN records are only emitted if apply actually happened.  The
# table is created on both nodes with DDL replication off, then rows are
# inserted on each side and the round trip is confirmed with sync_event.
TEST_ROWS=200
SYNC_EVENT_TIMEOUT="${SYNC_EVENT_TIMEOUT:-60}"

_do_workload() {
	local node

	for node in ${OLD_NODES}; do
		psql_on "${node}" -c "
			CREATE TABLE public.t_upgrade (
				id     bigint PRIMARY KEY,
				origin text NOT NULL,
				payload text
			);"
		psql_on "${node}" -c \
			"SELECT spock.repset_add_table('default', 'public.t_upgrade');"
	done

	psql_on n1 -c "
		INSERT INTO public.t_upgrade
		SELECT g, 'n1', repeat('x', 64) FROM generate_series(1, ${TEST_ROWS}) g;"
	psql_on n2 -c "
		INSERT INTO public.t_upgrade
		SELECT ${TEST_ROWS} + g, 'n2', repeat('y', 64)
		FROM generate_series(1, ${TEST_ROWS}) g;"
}

run_workload() {
	run_phase mesh workload _do_workload
}

_wait_one_sync_event() {
	local provider="$1" subscriber="$2" lsn="$3"
	psql_on "${subscriber}" -q -c "
		DO \$check\$
		DECLARE
			r bool;
		BEGIN
			CALL spock.wait_for_sync_event(
				r, '${provider}'::name, '${lsn}'::pg_lsn,
				${SYNC_EVENT_TIMEOUT});
			IF NOT r THEN
				RAISE EXCEPTION
					'sync_event from ${provider} did not arrive on ${subscriber} within ${SYNC_EVENT_TIMEOUT}s';
			END IF;
		END
		\$check\$;
	"
}

_do_sync_mesh() {
	local provider subscriber lsn
	for provider in ${OLD_NODES}; do
		lsn="$(psql_on "${provider}" -At -c "SELECT spock.sync_event();")"
		[ -n "${lsn}" ] || { echo "${provider}: sync_event() returned nothing"; return 1; }
		echo "${provider}: emitted sync_event @ ${lsn}"
		for subscriber in ${OLD_NODES}; do
			[ "${subscriber}" = "${provider}" ] && continue
			_wait_one_sync_event "${provider}" "${subscriber}" "${lsn}"
			echo "${provider} -> ${subscriber}: sync_event delivered"
		done
	done
}

sync_mesh() {
	run_phase mesh sync-event _do_sync_mesh
}

# Row counts must match on both nodes before we freeze the cluster, so the
# post-upgrade count check has an unambiguous expected value.
verify_replicated_rows() {
	local node cnt
	local expected=$(( TEST_ROWS * 2 ))
	for node in ${OLD_NODES}; do
		cnt="$(psql_on "${node}" -At -c "SELECT count(*) FROM public.t_upgrade;")"
		log "${node}: t_upgrade has ${cnt} rows (expected ${expected})"
		[ "${cnt}" = "${expected}" ] \
			|| { say "${node}: expected ${expected} rows in t_upgrade, found ${cnt}"; return 1; }
	done
	return 0
}

# ---------------------------------------------------------------------------
# Freeze the old cluster and prove the decoded range is non-empty
# ---------------------------------------------------------------------------

# Recorded before shutdown, compared against the old cluster's shutdown
# checkpoint afterwards.  If no WAL had been written past confirmed_flush,
# pg_upgrade's slot check would decode nothing and the test would pass
# vacuously.
SLOT_CONFIRMED_BEFORE=
SLOT_NAME=

record_slot_position() {
	SLOT_NAME="$(psql_on n1 -At -c \
		"SELECT slot_name FROM pg_replication_slots
		 WHERE slot_type = 'logical' AND database = current_database()
		 ORDER BY slot_name LIMIT 1;")"
	[ -n "${SLOT_NAME}" ] \
		|| { say "n1 has no logical replication slot -- mesh never came up"; return 1; }

	SLOT_CONFIRMED_BEFORE="$(psql_on n1 -At -c \
		"SELECT confirmed_flush_lsn FROM pg_replication_slots
		 WHERE slot_name = '${SLOT_NAME}';")"
	log "n1: slot ${SLOT_NAME} confirmed_flush=${SLOT_CONFIRMED_BEFORE} before shutdown"
	[ -n "${SLOT_CONFIRMED_BEFORE}" ]
}

# Normalise an LSN to a fixed-width hex string so plain string comparison
# orders it correctly: 0/19C4F80 -> 00000000019C4F80... .  Each half is at
# most 8 hex digits, well inside shell arithmetic range.  awk is avoided
# here on purpose: strtonum() is a gawk extension and mawk (the default awk
# on Debian/Ubuntu) silently has no hex support at all.
lsn_norm() {
	local hi="${1%%/*}" lo="${1##*/}"
	printf '%08X%08X' "$((16#${hi}))" "$((16#${lo}))"
}

# lsn_gt A B -- true when A is strictly after B.
lsn_gt() {
	local a b
	a="$(lsn_norm "$1")"
	b="$(lsn_norm "$2")"
	[ "${a}" \> "${b}" ]
}

# Two things must hold for this test to mean anything, and both are checked
# against the frozen old cluster:
#
#   1. WAL exists past the slot's confirmed_flush, so
#      binary_upgrade_logical_slot_has_caught_up() decodes a non-empty range
#      at all;
#   2. at least one Spock record is inside that range, so the decoder really
#      does look up rmgr SPOCK_RMGR_ID.
#
# pg_waldump cannot describe a custom rmgr's payload -- it does not load
# shared_preload_libraries -- but it does name the records "custom<id>",
# which is all (2) needs.
assert_spock_wal_in_decode_range() {
	local data; data="$(data_for n1)"
	local dump="${LOG_DIR}/n1-waldump-after-confirmed-flush.log"
	local ckpt

	ckpt="$("${OLD_PREFIX}/bin/pg_controldata" -D "${data}" \
		| sed -n 's/^Latest checkpoint location: *//p')"
	log "n1: shutdown checkpoint at ${ckpt}, slot confirmed_flush was ${SLOT_CONFIRMED_BEFORE}"

	if ! lsn_gt "${ckpt}" "${SLOT_CONFIRMED_BEFORE}"; then
		say "no WAL was written past the slot's confirmed_flush (${SLOT_CONFIRMED_BEFORE} >= ${ckpt});"
		say "the pg_upgrade slot check would decode nothing, so this run proves nothing"
		return 1
	fi

	# Reading to the end of WAL always ends in a complaint about the
	# incomplete record past the last one, so the exit status is ignored and
	# the grep below is the verdict.
	"${OLD_PREFIX}/bin/pg_waldump" -p "${data}/pg_wal" \
		--start="${SLOT_CONFIRMED_BEFORE}" >"${dump}" 2>&1 || true

	if ! grep -q "rmgr: ${WALDUMP_RMGR_NAME}" "${dump}"; then
		say "no ${WALDUMP_RMGR_NAME} (spock rmgr ${SPOCK_RMGR_ID}) record in WAL past"
		say "${SLOT_CONFIRMED_BEFORE}; the slot check would never look the rmgr up,"
		say "so this run proves nothing (see ${dump})"
		return 1
	fi
	log "n1: $(grep -c "rmgr: ${WALDUMP_RMGR_NAME}" "${dump}") spock rmgr record(s) past confirmed_flush"
	return 0
}

# ---------------------------------------------------------------------------
# pg_upgrade
# ---------------------------------------------------------------------------

PG_UPGRADE_CHECK_LOG="${LOG_DIR}/pg_upgrade-check.log"
PG_UPGRADE_RUN_LOG="${LOG_DIR}/pg_upgrade-run.log"

# --retain is not optional here: without it pg_upgrade deletes
# pg_upgrade_output.d on success, and that directory holds the old-cluster
# server log this test reads to prove the slot check really decoded.
_run_pg_upgrade() {
	local logf="$1"; shift
	local rc=0
	(
		cd "${UPGRADE_RUN_DIR}"
		"${NEW_PREFIX}/bin/pg_upgrade" \
			--old-bindir="${OLD_PREFIX}/bin" \
			--new-bindir="${NEW_PREFIX}/bin" \
			--old-datadir="$(data_for n1)" \
			--new-datadir="$(data_for n1-new)" \
			--username="${DBUSER}" \
			--socketdir="${SOCK_DIR}" \
			--retain \
			"$@"
	) >"${logf}" 2>&1 || rc=$?
	return ${rc}
}

# pg_upgrade puts pg_upgrade_output.d inside the *new* data directory from
# PG15 on, and in its own cwd before that.  Print whichever exist; a caller
# greps across all of them.
pg_upgrade_output_dirs() {
	local d
	for d in "$(data_for n1-new)/pg_upgrade_output.d" \
	         "${UPGRADE_RUN_DIR}/pg_upgrade_output.d"; do
		[ -d "${d}" ] && printf '%s\n' "${d}"
	done
	return 0
}

# The rmgr error surfaces in pg_upgrade's own stdout, but it originates in
# the throwaway old-cluster server, so scan its logs under
# pg_upgrade_output.d as well -- that is where the failing statement and the
# decoding trace live.
rmgr_error_seen() {
	local dirs
	if grep -qE "${RMGR_ERROR_RE}" "${PG_UPGRADE_CHECK_LOG}" "${PG_UPGRADE_RUN_LOG}" 2>/dev/null; then
		return 0
	fi
	dirs="$(pg_upgrade_output_dirs)"
	[ -n "${dirs}" ] || return 1
	# shellcheck disable=SC2086 -- word splitting is what we want here.
	grep -rqE "${RMGR_ERROR_RE}" ${dirs} 2>/dev/null
}

# Proof that the slot check actually decoded: pg_upgrade's old-cluster
# server logs "starting logical decoding for slot" when
# binary_upgrade_logical_slot_has_caught_up() runs.  Absent that line the
# run says nothing about the rmgr, whatever its exit status.
slot_decode_attempted() {
	local dirs
	dirs="$(pg_upgrade_output_dirs)"
	[ -n "${dirs}" ] || return 1
	# shellcheck disable=SC2086 -- word splitting is what we want here.
	grep -rq 'starting logical decoding for slot' ${dirs} 2>/dev/null
}

# ---------------------------------------------------------------------------
# Post-upgrade verification
# ---------------------------------------------------------------------------

verify_upgraded_node() {
	local rc=0 out
	local expected=$(( TEST_ROWS * 2 ))

	out="$(psql_on n1-new -At -c \
		"SELECT extversion FROM pg_extension WHERE extname = 'spock';")"
	if [ -z "${out}" ]; then
		say "upgraded node: the spock extension is missing"
		rc=1
	else
		log "upgraded node: spock extension version ${out}"
	fi

	out="$(psql_on n1-new -At -c \
		"SELECT count(*) FROM spock.node WHERE node_name = 'n1';")" || out=0
	if [ "${out}" != "1" ]; then
		say "upgraded node: spock.node has no row for n1"
		rc=1
	else
		log "upgraded node: spock.node row for n1 present"
	fi

	out="$(psql_on n1-new -At -c "SELECT count(*) FROM public.t_upgrade;")" || out=-1
	if [ "${out}" != "${expected}" ]; then
		say "upgraded node: t_upgrade has ${out} rows, expected ${expected}"
		rc=1
	else
		log "upgraded node: t_upgrade has ${expected} rows"
	fi

	# PG17+ pg_upgrade migrates logical slots.  Losing the slot here would
	# be a different (and also serious) problem, so check it explicitly
	# rather than let it pass unnoticed.
	out="$(psql_on n1-new -At -c \
		"SELECT count(*) FROM pg_replication_slots
		 WHERE slot_type = 'logical' AND slot_name = '${SLOT_NAME}';")" || out=0
	if [ "${out}" != "1" ]; then
		say "upgraded node: logical slot ${SLOT_NAME} did not survive pg_upgrade"
		rc=1
	else
		log "upgraded node: logical slot ${SLOT_NAME} survived"
	fi

	return ${rc}
}

# ---------------------------------------------------------------------------
# Verdicts
# ---------------------------------------------------------------------------

# Under --negative-control the expected outcome is inverted: the run passes
# only when pg_upgrade fails *and* the rmgr error is the reason.  Anything
# else means the rig no longer reproduces the bug and so proves nothing
# about the fix.
verdict_negative_control() {
	local check_rc="$1"

	if ! slot_decode_attempted; then
		say "RESULT: FAIL -- pg_upgrade never decoded a logical slot;"
		say "        the rig does not exercise the bug (see ${PG_UPGRADE_CHECK_LOG})"
		return 2
	fi
	if [ "${check_rc}" -eq 0 ]; then
		say "RESULT: FAIL -- pg_upgrade --check succeeded with the fix reverted;"
		say "        the rig no longer reproduces the bug"
		return 2
	fi
	if ! rmgr_error_seen; then
		say "RESULT: FAIL -- pg_upgrade --check failed (rc=${check_rc}) but not with"
		say "        '${RMGR_ERROR_RE}' (see ${PG_UPGRADE_CHECK_LOG})"
		return 2
	fi
	say "RESULT: PASS (negative control) -- with spock_rmgr_init() below the"
	say "        IsBinaryUpgrade return, pg_upgrade --check fails with the rmgr error"
	return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	build_stack "${PG_OLD}"
	build_stack "${PG_NEW}"

	local node
	for node in ${OLD_NODES}; do
		init_node  "${node}"
		start_node "${node}"
	done
	for node in ${OLD_NODES}; do
		wait_for_ready "${node}" || fail "${node} never became ready" 6
	done

	for node in ${OLD_NODES}; do create_db_for_node "${node}"; done
	for node in ${OLD_NODES}; do setup_spock_node   "${node}"; done

	wire_mesh
	wait_for_mesh_replicating || fail "the mesh never reached 'replicating'" 6

	run_workload
	sync_mesh
	verify_replicated_rows || fail "the two nodes did not converge" 6

	record_slot_position || fail "could not read n1's slot position" 6

	# n2 first: with n1 still up its walsender drains cleanly, so n2's slot
	# on n1 has a well-defined confirmed_flush when n1 then shuts down and
	# writes its SHUTDOWN snapshot past it.
	stop_node n2
	stop_node n1

	assert_spock_wal_in_decode_range \
		|| fail "the old cluster does not exercise the spock rmgr lookup" 6

	# Fresh, empty target cluster.  No CREATE EXTENSION here -- pg_upgrade
	# restores the schema, spock included, from the old cluster's dump.
	init_node n1-new

	local check_rc=0
	_run_pg_upgrade "${PG_UPGRADE_CHECK_LOG}" --check || check_rc=$?
	log "pg_upgrade --check exited ${check_rc}"

	if [ "${NEGATIVE_CONTROL}" -eq 1 ]; then
		tail -n 20 "${PG_UPGRADE_CHECK_LOG}" >&2 || true
		verdict_negative_control "${check_rc}"
		return $?
	fi

	if [ "${check_rc}" -ne 0 ]; then
		say "pg_upgrade --check FAILED (rc=${check_rc}); tail of its output:"
		tail -n 20 "${PG_UPGRADE_CHECK_LOG}" >&2 || true
		if rmgr_error_seen; then
			say "RESULT: FAIL -- ${RMGR_ERROR_RE}: spock_rmgr_init() is not reached"
			say "        under IsBinaryUpgrade (see ${PG_UPGRADE_CHECK_LOG})"
		else
			say "RESULT: FAIL -- pg_upgrade --check failed for another reason"
			say "        (see ${PG_UPGRADE_CHECK_LOG})"
		fi
		return 2
	fi
	say "pg_upgrade --check ok"

	local run_rc=0
	_run_pg_upgrade "${PG_UPGRADE_RUN_LOG}" || run_rc=$?
	if [ "${run_rc}" -ne 0 ]; then
		say "pg_upgrade FAILED (rc=${run_rc}); tail of its output:"
		tail -n 20 "${PG_UPGRADE_RUN_LOG}" >&2 || true
		if rmgr_error_seen; then
			say "RESULT: FAIL -- ${RMGR_ERROR_RE} during the upgrade proper"
		else
			say "RESULT: FAIL -- pg_upgrade failed for another reason (see ${PG_UPGRADE_RUN_LOG})"
		fi
		return 2
	fi
	say "pg_upgrade ok"

	# A green pg_upgrade only means something if the slot check really ran;
	# otherwise the rmgr was never looked up and the run is vacuous.
	if ! slot_decode_attempted; then
		say "RESULT: FAIL -- pg_upgrade succeeded but never decoded a logical slot,"
		say "        so it did not exercise the rmgr lookup (see"
		say "        $(data_for n1-new)/pg_upgrade_output.d)"
		return 2
	fi
	if rmgr_error_seen; then
		say "RESULT: FAIL -- pg_upgrade exited 0 but its logs contain"
		say "        '${RMGR_ERROR_RE}'"
		return 2
	fi

	start_node     n1-new
	wait_for_ready n1-new || fail "the upgraded node never became ready" 6

	local verify_rc=0
	verify_upgraded_node || verify_rc=$?
	if [ "${verify_rc}" -ne 0 ]; then
		say "RESULT: FAIL -- the upgraded node lost Spock state (see above)"
		return 2
	fi

	say "RESULT: PASS -- PG${PG_OLD}+spock -> PG${PG_NEW}+spock upgraded with the"
	say "        logical slot decoded and no rmgr error; Spock state intact"
	return 0
}

main "$@"
