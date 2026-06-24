#!/usr/bin/env bash
#
# tests/run-single-pg18-installcheck.sh
#
# Build PostgreSQL REL_18_STABLE once, build the Spock extension against
# it once, then start THREE single-node clusters (n1..n3, all PG18,
# sharing the same install) wired into a full Spock mesh (6
# subscriptions, exception_behaviour='discard', auto-DDL on), run
# `make installcheck` against node n1, and verify every subscription is
# still enabled afterwards and that spock.sync_event() round-trips on
# every edge.
#
# Compatible with bash 3.2 (macOS /bin/bash) -- no associative arrays.
#
# There is only ONE build pipeline (clone PG, build PG, build Spock), so
# it runs in the foreground; only the three initdb+start steps are
# per-node.
#
# Layout (under BASE_DIR, default <spock-repo>/single-pg18-installcheck):
#   src/pg18               PG source clone
#   bin/pg18               PG install (configure --prefix)
#   spock-build/pg18       Spock source copy + build artefacts
#   pgdata/n1..n3          PGDATA per node
#   log/                   per-instance log files (build phases are logged
#                          under the pseudo-node name 'pg18')
#   sock/                  unix-socket dir shared by all nodes
#
# Node mapping (all PG18):
#   n1 -> port 57601
#   n2 -> port 57602
#   n3 -> port 57603
#
# Subscription naming:
#   sub_<provider>_<subscriber>; e.g. sub_n1_n2 lives on n2 and pulls from n1.
#
# Usage:
#   tests/run-single-pg18-installcheck.sh [--base-dir DIR] [--keep] \
#                                         [--force] [--jobs N]
#
# Existing PG installs (bin/postgres present) and Spock installs
# (extension/spock.control present) are reused by default to speed up
# re-runs.  Pass --force to rebuild everything from scratch.
#
# Exit status:
#   0  every Spock subscription on every node is still enabled
#      (sub_enabled = true)  AND  a spock.sync_event() fired on each
#      provider was applied on every other node within
#      SYNC_EVENT_TIMEOUT seconds.  Regression-suite pass/fail is
#      logged but does NOT influence the exit code -- the installcheck
#      workload is used as stress; the only success signal is the
#      surviving mesh.
#   2  one or more subscriptions ended up disabled, OR sync_event
#      failed to propagate on at least one edge within
#      SYNC_EVENT_TIMEOUT seconds.
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

# Default base dir lives inside the spock repo so all artefacts are
# contained next to the source.  Distinct from the multi-version rig's
# directory so the two can coexist.  Overridden by --base-dir.
BASE_DIR="${SPOCK_SRC}/single-pg18-installcheck"
# Default: stop every node we started on exit.  --keep flips this on.
KEEP_RUNNING=0
FORCE_REBUILD=0
JOBS_TOTAL="$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"

PG_VER=18
NODES="n1 n2 n3"

DBNAME=regression
DBUSER=regression
TARGET_NODE=n1   # node we run `make installcheck` against

PG_GIT_REMOTES="https://git.postgresql.org/git/postgresql.git https://github.com/postgres/postgres.git"

# ---------------------------------------------------------------------------
# Bash-3-safe lookup helpers (no `declare -A`)
# ---------------------------------------------------------------------------

# Ports deliberately differ from the multi-version rig (57516..57518)
# so both rigs can run simultaneously.
node_to_port() {
	case "$1" in
		n1) echo 57601 ;;
		n2) echo 57602 ;;
		n3) echo 57603 ;;
		*)  return 1 ;;
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
		--keep)             KEEP_RUNNING=1; shift ;;
		--force)            FORCE_REBUILD=1; shift ;;
		--jobs)             [ "$#" -ge 2 ] || fail "--jobs requires a value" 4
		                    JOBS_TOTAL="$2"; shift 2 ;;
		-h|--help)          usage; exit 0 ;;
		*)                  fail "unknown argument: $1" 4 ;;
	esac
done

mkdir -p "${BASE_DIR}/src"          \
         "${BASE_DIR}/bin"          \
         "${BASE_DIR}/spock-build"  \
         "${BASE_DIR}/pgdata"       \
         "${BASE_DIR}/log"          \
         "${BASE_DIR}/sock"
BASE_DIR="$(cd "${BASE_DIR}" && pwd)"
SOCK_DIR="${BASE_DIR}/sock"
LOG_DIR="${BASE_DIR}/log"

# Fresh log directory per run; src/, bin/, spock-build/, and pgdata/
# are preserved so reuse-on-rerun still works.
rm -rf "${LOG_DIR}"
mkdir -p "${LOG_DIR}"

MAIN_LOG="${LOG_DIR}/main.log"
: >"${MAIN_LOG}"

log "BASE_DIR   = ${BASE_DIR}"
log "SPOCK_SRC  = ${SPOCK_SRC}"
log "JOBS_TOTAL = ${JOBS_TOTAL}"
log "PG_VER     = ${PG_VER}"
log "NODES      = ${NODES}"

# ---------------------------------------------------------------------------
# Path helpers (single shared install)
# ---------------------------------------------------------------------------

PREFIX="${BASE_DIR}/bin/pg${PG_VER}"
SRC="${BASE_DIR}/src/pg${PG_VER}"
SPOCK_BUILD="${BASE_DIR}/spock-build/pg${PG_VER}"
PG_CONFIG="${PREFIX}/bin/pg_config"

data_for() { echo "${BASE_DIR}/pgdata/$1"; }

# DSN that talks over the shared Unix socket directory.
dsn_for_node() {
	local node="$1"
	local port; port="$(node_to_port "${node}")"
	echo "host=${SOCK_DIR} port=${port} dbname=${DBNAME} user=${DBUSER}"
}

# Run psql against a node (all nodes share the same client binaries).
psql_on() {
	local node="$1"; shift
	local port; port="$(node_to_port "${node}")"
	PGPASSWORD="" "${PREFIX}/bin/psql" \
		-X -v ON_ERROR_STOP=1 \
		-h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -d "${DBNAME}" \
		"$@"
}

# ---------------------------------------------------------------------------
# Build pipeline: clone + build PG + build Spock (once, shared by all nodes)
# ---------------------------------------------------------------------------

pick_pg_remote() {
	local r
	for r in ${PG_GIT_REMOTES}; do
		if git ls-remote --exit-code --heads "${r}" "REL_${PG_VER}_STABLE" \
				>/dev/null 2>&1; then
			echo "${r}"
			return 0
		fi
	done
	return 1
}

_do_clone_pg() {
	local remote="$1"
	local branch="REL_${PG_VER}_STABLE"
	rm -rf "${SRC}"
	git clone --depth=1 --single-branch --branch "${branch}" \
		"${remote}" "${SRC}"
}

clone_pg() {
	local branch="REL_${PG_VER}_STABLE"

	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ -d "${SRC}/.git" ] \
		&& [ -f "${SRC}/src/test/regress/parallel_schedule" ]; then
		log "pg${PG_VER}: [pg-clone] source already present, skipping"
		return 0
	fi

	local remote
	remote="$(pick_pg_remote)" \
		|| fail "PG${PG_VER}: no reachable git remote for ${branch}" 5

	log "pg${PG_VER}: [pg-clone] ${branch} from ${remote}"
	run_phase "pg${PG_VER}" pg-clone _do_clone_pg "${remote}"
}

# Spock needs Postgres with per-version patches applied; patches live
# in patches/<ver>/ in the spock tree, applied in lexical order via
# `git apply`.  A marker file makes the phase idempotent.
_do_patch_pg() {
	local patch_dir="$1"
	if [ ! -d "${patch_dir}" ]; then
		echo "no patch directory ${patch_dir} -- nothing to do"
		return 0
	fi
	local p any=0
	for p in "${patch_dir}"/*.diff "${patch_dir}"/*.patch; do
		[ -f "${p}" ] || continue
		any=1
		echo "----- applying $(basename "${p}") -----"
		( cd "${SRC}" && git apply --whitespace=nowarn -p1 "${p}" )
	done
	if [ "${any}" -eq 0 ]; then
		echo "no .diff/.patch files in ${patch_dir}"
	fi
	touch "${SRC}/.spock-patches-applied"
}

patch_pg() {
	local patch_dir="${SPOCK_SRC}/patches/${PG_VER}"

	if [ -f "${SRC}/.spock-patches-applied" ]; then
		log "pg${PG_VER}: [pg-patch] patches already applied (marker present), skipping"
		return 0
	fi
	run_phase "pg${PG_VER}" pg-patch _do_patch_pg "${patch_dir}"
}

_do_configure_pg() {
	cd "${SRC}"
	./configure --prefix="${PREFIX}" --enable-debug --enable-cassert \
		--with-icu --with-openssl --with-readline --with-zstd --with-lz4
}

_do_build_pg() {
	local jobs="$1"
	make -C "${SRC}" -s -j"${jobs}"
	make -C "${SRC}" -s -j"${jobs}" install
	# Install pg_regress so `make installcheck` later can find it via $bindir.
	make -C "${SRC}/src/test/regress" -s install
}

build_pg() {
	if [ "${FORCE_REBUILD}" -eq 0 ] && [ -x "${PREFIX}/bin/postgres" ]; then
		log "pg${PG_VER}: [pg-build] reusing existing install at ${PREFIX}"
		return 0
	fi

	run_phase "pg${PG_VER}" pg-configure _do_configure_pg
	run_phase "pg${PG_VER}" pg-build     _do_build_pg "${JOBS_TOTAL}"
}

# Spock builds in its own copy of the source tree.  `make clean` after
# the rsync evicts any build artefacts a manual `make` in the repo root
# may have left behind (objects compiled against the wrong PG headers
# would otherwise be installed verbatim).
_do_build_spock() {
	local jobs="$1"
	rm -rf "${SPOCK_BUILD}"
	mkdir -p "${SPOCK_BUILD}"
	rsync -a \
		--exclude='/single-pg18-installcheck' \
		--exclude='/.git' \
		--exclude='.DS_Store' \
		"${SPOCK_SRC}/" "${SPOCK_BUILD}/"
	make -C "${SPOCK_BUILD}" PG_CONFIG="${PG_CONFIG}" clean
	make -C "${SPOCK_BUILD}" PG_CONFIG="${PG_CONFIG}" -j"${jobs}"
	make -C "${SPOCK_BUILD}" PG_CONFIG="${PG_CONFIG}" install
}

build_spock() {
	if [ "${FORCE_REBUILD}" -eq 0 ] \
		&& [ -f "$("${PG_CONFIG}" --sharedir)/extension/spock.control" ]; then
		log "pg${PG_VER}: [spock-build] reusing existing install"
		return 0
	fi

	run_phase "pg${PG_VER}" spock-build _do_build_spock "${JOBS_TOTAL}"
}

# ---------------------------------------------------------------------------
# Per-node initdb + start
# ---------------------------------------------------------------------------

_do_initdb() {
	local data="$1"
	"${PREFIX}/bin/initdb" -D "${data}" -U "${DBUSER}" \
		--encoding=UTF8 --locale=C
}

init_node() {
	local node="$1"
	local data; data="$(data_for "${node}")"
	local port; port="$(node_to_port "${node}")"

	if [ -d "${data}" ]; then
		log "${node}: [initdb] clearing existing data dir"
		rm -rf "${data}"
	fi
	run_phase "${node}" initdb _do_initdb "${data}"

	cat >>"${data}/postgresql.conf" <<-EOF
		# --- single-PG18 installcheck test rig ---
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

		# Replicate DDL automatically across the mesh, and add any tables
		# created by that DDL to the default replication set.
		spock.enable_ddl_replication = on
		spock.include_ddl_repset    = on
		spock.allow_ddl_from_functions = on
	EOF

	# Trust on the shared Unix socket; no TCP listener so this is local-only.
	cat >>"${data}/pg_hba.conf" <<-EOF
		local all all trust
		local replication all trust
	EOF
}

_do_pg_ctl_start() {
	local data="$1" server_log="$2"
	"${PREFIX}/bin/pg_ctl" -D "${data}" -l "${server_log}" -w -t 60 start
}

start_node() {
	local node="$1"
	local data; data="$(data_for "${node}")"
	run_phase "${node}" pg-start _do_pg_ctl_start \
		"${data}" "${LOG_DIR}/${node}-server.log"
}

stop_node() {
	local node="$1"
	local data; data="$(data_for "${node}")"
	if [ -f "${data}/postmaster.pid" ]; then
		log "${node}: pg_ctl stop"
		"${PREFIX}/bin/pg_ctl" -D "${data}" -m fast -w -t 60 stop || true
	fi
}

stop_all_nodes() {
	local node
	for node in ${NODES}; do stop_node "${node}"; done
}

# Bound to EXIT so node shutdown runs on normal completion AND on every
# failure path -- including the ERR trap, which exit()s before main()'s tail
# is reached.  Skipped only when the user passed --keep.  stop_node is a
# no-op for nodes that never started, so this is safe at any exit point.
cleanup_nodes() {
	if [ "${KEEP_RUNNING}" -eq 0 ]; then
		stop_all_nodes
	else
		log "--keep set: leaving nodes running. Sockets under ${SOCK_DIR}"
	fi
}
trap cleanup_nodes EXIT

# ---------------------------------------------------------------------------
# pg_isready probe for each node
# ---------------------------------------------------------------------------

wait_for_ready() {
	local node="$1"
	local port; port="$(node_to_port "${node}")"
	local deadline=$(( $(date +%s) + 60 ))
	while [ "$(date +%s)" -lt "${deadline}" ]; do
		if "${PREFIX}/bin/pg_isready" -q \
				-h "${SOCK_DIR}" -p "${port}" -d "${DBNAME}" -U "${DBUSER}"; then
			log "${node}: pg_isready OK"
			return 0
		fi
		sleep 1
	done
	log "${node}: pg_isready did not become ready within 60s"
	return 1
}

wait_for_all_ready() {
	local node rc=0
	for node in ${NODES}; do
		wait_for_ready "${node}" || rc=1
	done
	return ${rc}
}

# ---------------------------------------------------------------------------
# DB + Spock bootstrap (after all servers are up)
# ---------------------------------------------------------------------------

_do_createdb() {
	local port="$1"
	"${PREFIX}/bin/createdb" -h "${SOCK_DIR}" -p "${port}" \
		-U "${DBUSER}" -O "${DBUSER}" "${DBNAME}"
}

create_db_for_node() {
	local node="$1"
	local port; port="$(node_to_port "${node}")"
	run_phase "${node}" createdb _do_createdb "${port}"
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

wire_full_mesh() {
	local subscriber provider
	for subscriber in ${NODES}; do
		for provider in ${NODES}; do
			[ "${provider}" = "${subscriber}" ] && continue
			create_subscription "${provider}" "${subscriber}"
		done
	done
}

# ---------------------------------------------------------------------------
# Run `make installcheck` against the target node
# ---------------------------------------------------------------------------

run_installcheck() {
	local node="${TARGET_NODE}"
	local port; port="$(node_to_port "${node}")"

	log "${node} (PG${PG_VER}): make installcheck-parallel"

	# --use-existing is critical: without it pg_regress tries DROP DATABASE
	# regression, which fails while Spock holds live replication slots into
	# that database.
	set +e
	(
		cd "${SRC}/src/test/regress"
		PATH="${PREFIX}/bin:${PATH}" \
		PGHOST="${SOCK_DIR}" PGPORT="${port}" \
		PGUSER="${DBUSER}" PGDATABASE="${DBNAME}" \
		make -k installcheck-parallel \
			USE_INSTALLED=1 \
			EXTRA_REGRESS_OPTS="--use-existing --host=${SOCK_DIR} --port=${port} --user=${DBUSER}"
	) >"${LOG_DIR}/installcheck.log" 2>&1
	local rc=$?
	set -e

	# Regression-suite failures are expected -- Spock's auto-DDL
	# replication will mangle the test fixtures.  Logged for diagnostics
	# only; the verdict comes from the surviving mesh.
	if [ ${rc} -ne 0 ]; then
		log "installcheck completed with regression failures (exit ${rc})"
		log "  see ${LOG_DIR}/installcheck.log and ${SRC}/src/test/regress/regression.diffs"
	else
		log "installcheck completed cleanly (no regression diffs)"
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Wait for every sub to report status='replicating'
# ---------------------------------------------------------------------------

WAIT_REPLICATING_TIMEOUT_PRE=60
WAIT_REPLICATING_TIMEOUT_POST=30

wait_for_mesh_replicating() {
	local timeout="${1:-${WAIT_REPLICATING_TIMEOUT_PRE}}"
	local deadline node not_replicating
	deadline=$(( $(date +%s) + timeout ))
	while [ "$(date +%s)" -lt "${deadline}" ]; do
		not_replicating=0
		for node in ${NODES}; do
			local n
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
			log "all 6 subscriptions reached status='replicating' (within ${timeout}s)"
			return 0
		fi
		sleep 1
	done
	log "timed out after ${timeout}s waiting for subs to reach 'replicating'"
	return 1
}

print_subscription_state() {
	local label="$1"
	local node
	for node in ${NODES}; do
		local nlog="${LOG_DIR}/${node}.log"
		{
			printf '\n--- subscription state (%s) on %s ---\n' "${label}" "${node}"
			psql_on "${node}" -P null='(null)' \
				-c "SELECT sub_name, sub_enabled FROM spock.subscription
				    ORDER BY sub_name;" \
				-c "SELECT subscription_name, status, provider_node, slot_name
				    FROM spock.sub_show_status()
				    ORDER BY subscription_name;"
		} >>"${nlog}" 2>&1 || true
	done
}

print_connection_params() {
	local node port
	printf '\n=== Connection parameters ===\n' >&2
	if [ "${KEEP_RUNNING}" -eq 1 ]; then
		printf '(servers are left running -- you can attach right now)\n' >&2
	else
		printf '(servers will be stopped on script exit; re-run with --keep to keep them up)\n' >&2
	fi
	for node in ${NODES}; do
		port="$(node_to_port "${node}")"
		printf '\n  %s  (PG%s)\n' "${node}" "${PG_VER}" >&2
		printf '    host    = %s\n' "${SOCK_DIR}" >&2
		printf '    port    = %s\n' "${port}"     >&2
		printf '    user    = %s\n' "${DBUSER}"   >&2
		printf '    dbname  = %s\n' "${DBNAME}"   >&2
		printf '    psql    = %s/bin/psql -h %s -p %s -U %s -d %s\n' \
			"${PREFIX}" "${SOCK_DIR}" "${port}" "${DBUSER}" "${DBNAME}" >&2
	done
	printf '\n' >&2
}

print_subscription_state_to_screen() {
	local node
	for node in ${NODES}; do
		printf '\n=== %s (PG%s) ===\n' "${node}" "${PG_VER}" >&2
		if ! psql_on "${node}" -At -c 'SELECT 1' >/dev/null 2>&1; then
			printf '  (not reachable -- server is stopped or socket is gone)\n' >&2
			continue
		fi
		psql_on "${node}" -P null='(null)' \
			-c "SELECT sub_name, sub_enabled
			    FROM spock.subscription
			    ORDER BY sub_name;" \
			-c "SELECT subscription_name, status, provider_node, slot_name
			    FROM spock.sub_show_status()
			    ORDER BY subscription_name;" \
			1>&2 2>&1 || true
	done
	printf '\n' >&2
}

# ---------------------------------------------------------------------------
# End-to-end propagation check using spock.sync_event / wait_for_sync_event
# ---------------------------------------------------------------------------

# Seconds to wait for a sync_event to propagate across the mesh.  This is the
# test's authoritative success signal and runs after run_installcheck, when the
# replication backlog is heaviest, so the default is generous (matching the
# pre-installcheck replicating wait).  Override via the environment on slow CI.
SYNC_EVENT_TIMEOUT="${SYNC_EVENT_TIMEOUT:-60}"

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

check_sync_event_propagation() {
	local fail=0 provider subscriber lsn
	local logf="${LOG_DIR}/sync-event-check.log"
	: >"${logf}"

	for provider in ${NODES}; do
		lsn="$(psql_on "${provider}" -At \
			-c "SELECT spock.sync_event();" 2>/dev/null)" \
			|| lsn=
		if [ -z "${lsn}" ]; then
			log "${provider}: spock.sync_event() emit failed"
			fail=1
			continue
		fi
		log "${provider}: emitted sync_event @ ${lsn}"

		for subscriber in ${NODES}; do
			[ "${subscriber}" = "${provider}" ] && continue
			if _wait_one_sync_event "${provider}" "${subscriber}" "${lsn}" \
					>>"${logf}" 2>&1; then
				log "${provider} -> ${subscriber}: sync_event delivered"
			else
				log "${provider} -> ${subscriber}: sync_event NOT delivered within ${SYNC_EVENT_TIMEOUT}s"
				fail=1
			fi
		done
	done
	return ${fail}
}

# ---------------------------------------------------------------------------
# Verify every subscription is still enabled
# ---------------------------------------------------------------------------

verify_subs_enabled() {
	local node out any_bad=0
	for node in ${NODES}; do
		out="$(psql_on "${node}" -At -c \
			"SELECT sub_name FROM spock.subscription WHERE NOT sub_enabled ORDER BY sub_name;" \
			2>/dev/null)" \
			|| { any_bad=1; log "${node}: NOT reachable -- treating as failure"; continue; }
		if [ -n "${out}" ]; then
			any_bad=1
			log "${node}: DISABLED subscriptions: $(echo "${out}" | tr '\n' ' ')"
		else
			log "${node}: all subscriptions still enabled"
		fi
	done
	return "${any_bad}"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
	# Single shared build pipeline -- no parallel builders needed.
	clone_pg
	patch_pg
	build_pg
	build_spock

	# Per-node initdb + start (cheap; sequential keeps the logs tidy).
	local node
	for node in ${NODES}; do
		init_node  "${node}"
		start_node "${node}"
	done

	wait_for_all_ready || fail "one or more nodes never became ready" 6

	for node in ${NODES}; do create_db_for_node   "${node}"; done
	for node in ${NODES}; do setup_spock_node     "${node}"; done

	wire_full_mesh

	local wait_rc=0
	wait_for_mesh_replicating "${WAIT_REPLICATING_TIMEOUT_PRE}" || wait_rc=$?

	print_subscription_state "before installcheck"

	if [ "${wait_rc}" -ne 0 ]; then
		say "WARNING: not all subscriptions reached 'replicating' before installcheck (see ${LOG_DIR}/<node>.log)"
	fi

	# Always run installcheck; its own pass/fail is logged but irrelevant
	# to the exit code -- the workload is stress, the mesh is the test.
	run_installcheck

	print_subscription_state "after installcheck"

	local post_wait_rc=0
	wait_for_mesh_replicating "${WAIT_REPLICATING_TIMEOUT_POST}" \
		|| post_wait_rc=$?
	if [ "${post_wait_rc}" -ne 0 ]; then
		log "diagnostic: status!='replicating' on some subs after ${WAIT_REPLICATING_TIMEOUT_POST}s (sync_event below is the authority)"
	fi

	local sync_rc=0
	check_sync_event_propagation || sync_rc=$?

	local verify_rc=0
	verify_subs_enabled || verify_rc=$?

	print_subscription_state_to_screen
	print_connection_params

	# node shutdown is handled by the cleanup_nodes EXIT trap

	if [ "${verify_rc}" -ne 0 ] || [ "${sync_rc}" -ne 0 ]; then
		local reason=
		[ "${verify_rc}" -ne 0 ] \
			&& reason="some subscriptions disabled"
		[ "${sync_rc}" -ne 0 ] \
			&& reason="${reason:+${reason}; }sync_event did not propagate on some edges (see ${LOG_DIR}/sync-event-check.log)"
		log "RESULT: ${reason}"
		say "RESULT: FAIL -- ${reason} (see output above)"
		return 2
	fi
	log "RESULT: every sub enabled, sync_event round-trips on every edge"
	say "RESULT: PASS -- mesh healthy after installcheck (sub_enabled + sync_event)"
	return 0
}

main "$@"
