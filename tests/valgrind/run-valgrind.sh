#!/usr/bin/env bash
#
# tests/valgrind/run-valgrind.sh
#
# Run the spock test suites with every PostgreSQL server process under
# Valgrind memcheck, then turn the raw output into a readable report.
#
# How it works
# ------------
# A shim bin directory is created under the output directory.  It holds a
# symlink to every binary of the PostgreSQL install under test, except:
#
#   postgres   a wrapper that execs the real server under valgrind, writing
#              one XML file per process (the postmaster and every backend it
#              forks) into <output>/raw/;
#   pg_config  a wrapper that reports the shim directory as --bindir and
#              delegates everything else to the real pg_config.
#
# `make regresscheck PG_CONFIG=<shim>/pg_config` then makes pg_regress start
# the server from the shim, and the TAP harness (SpockTest.pm) picks the
# shim up from PATH, so both suites run every postmaster and backend under
# memcheck without touching the Makefile or the tests.
#
# Afterwards valgrind-report.py groups the raw XML by error signature and
# writes report.md, report.html, summary.md and summary.json next to it.
#
# Requirements
# ------------
# Linux with valgrind on PATH.  The spock extension must already be built
# and installed into the PostgreSQL install that PG_CONFIG points at.  For
# useful results that install should be built with -DUSE_VALGRIND, -O0 and
# -g (see .github/workflows/valgrind-weekly.yml); the script warns when it
# is not, but still runs.
#
# Usage
# -----
#   tests/valgrind/run-valgrind.sh [options]
#
# Options:
#   --suite regress|tap|all   which suite(s) to run           (default: regress)
#   --regress-tests "A B ..." regression tests to run, by name
#                                              (default: the Makefile's REGRESS list)
#   --tap-tests "A B ..."     TAP tests for --suite tap|all, by name without
#                             the .pl suffix        (default: tests/tap/schedule)
#   --pg-src DIR              PostgreSQL source tree, for src/tools/valgrind.supp
#   --output DIR              raw XML, logs and the report  (default: tests/valgrind/output)
#   --leak-check no|summary|full                             (default: no)
#   --track-origins yes|no    slower, says where uninitialised values came from
#                                                            (default: yes)
#   --fail-on-errors          exit 1 when the report lists unsuppressed errors
#   --title TEXT              report title
#   -h, --help                this text
#
# Environment:
#   PG_CONFIG        pg_config of the install to test      (default: from PATH)
#   VALGRIND         valgrind binary                        (default: valgrind)
#   VALGRIND_EXTRA   extra valgrind flags, appended last
#   PGCTLTIMEOUT     how long pg_regress and pg_ctl wait for a server
#                    (default: 900, since startup under valgrind is slow)
#
# Exit status:
#   0  suites ran and the report was written (errors found or not)
#   1  a suite failed, or --fail-on-errors was given and errors were found
#   2  bad usage or a missing prerequisite

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SUITE=regress
REGRESS_TESTS=""
TAP_TESTS=""
PG_SRC=""
OUTPUT="$SCRIPT_DIR/output"
LEAK_CHECK=no
TRACK_ORIGINS=yes
FAIL_ON_ERRORS=no
TITLE=""
VALGRIND="${VALGRIND:-valgrind}"
export PGCTLTIMEOUT="${PGCTLTIMEOUT:-900}"

usage() {
	# The header comment up to the first blank line is the whole help text.
	sed -n '3,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

die() {
	echo "run-valgrind: $1" >&2
	exit "${2:-2}"
}

log() {
	echo "[run-valgrind] $*"
}

while [ $# -gt 0 ]; do
	case "$1" in
		--suite) SUITE="$2"; shift 2 ;;
		--regress-tests) REGRESS_TESTS="$2"; shift 2 ;;
		--tap-tests) TAP_TESTS="$2"; shift 2 ;;
		--pg-src) PG_SRC="$2"; shift 2 ;;
		--output) OUTPUT="$2"; shift 2 ;;
		--leak-check) LEAK_CHECK="$2"; shift 2 ;;
		--track-origins) TRACK_ORIGINS="$2"; shift 2 ;;
		--fail-on-errors) FAIL_ON_ERRORS=yes; shift ;;
		--title) TITLE="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) die "unknown option: $1 (try --help)" ;;
	esac
done

case "$SUITE" in
	regress|tap|all) ;;
	*) die "--suite must be regress, tap or all" ;;
esac
case "$LEAK_CHECK" in
	no|summary|full) ;;
	*) die "--leak-check must be no, summary or full" ;;
esac
case "$TRACK_ORIGINS" in
	yes|no) ;;
	*) die "--track-origins must be yes or no" ;;
esac

# -----------------------------------------------------------------------------
# Prerequisites
# -----------------------------------------------------------------------------
command -v "$VALGRIND" >/dev/null 2>&1 \
	|| die "valgrind not found (set VALGRIND or install it); this only works on Linux"
command -v python3 >/dev/null 2>&1 \
	|| die "python3 is needed for the report"

PG_CONFIG="${PG_CONFIG:-$(command -v pg_config || true)}"
[ -n "$PG_CONFIG" ] && [ -x "$PG_CONFIG" ] \
	|| die "pg_config not found; set PG_CONFIG or put it on PATH"
PG_CONFIG="$(cd "$(dirname "$PG_CONFIG")" && pwd)/$(basename "$PG_CONFIG")"

REAL_BINDIR="$("$PG_CONFIG" --bindir)"
REAL_POSTGRES="$REAL_BINDIR/postgres"
[ -x "$REAL_POSTGRES" ] || die "no postgres binary at $REAL_POSTGRES"
PG_VERSION="$("$PG_CONFIG" --version)"

if "$PG_CONFIG" --cppflags --cflags 2>/dev/null | grep -q -- '-DUSE_VALGRIND'; then
	USE_VALGRIND_BUILD=yes
else
	USE_VALGRIND_BUILD=no
	log "WARNING: this PostgreSQL was not built with -DUSE_VALGRIND."
	log "         palloc'd memory is then invisible to memcheck, so most"
	log "         use-after-free and uninitialised-read bugs will be missed."
fi

# Suppressions: spock's own, plus PostgreSQL's when a source tree is given.
SUPPRESSIONS=("$REPO_ROOT/spock.supp")
[ -f "$REPO_ROOT/spock.supp" ] || die "missing $REPO_ROOT/spock.supp"
if [ -n "$PG_SRC" ]; then
	[ -f "$PG_SRC/src/tools/valgrind.supp" ] \
		|| die "no src/tools/valgrind.supp under --pg-src $PG_SRC"
	SUPPRESSIONS+=("$PG_SRC/src/tools/valgrind.supp")
else
	log "WARNING: no --pg-src given; running without PostgreSQL's own"
	log "         suppressions (src/tools/valgrind.supp), expect noise."
fi

# -----------------------------------------------------------------------------
# Output layout
# -----------------------------------------------------------------------------
mkdir -p "$OUTPUT"
OUTPUT="$(cd "$OUTPUT" && pwd)"
RAW_DIR="$OUTPUT/raw"
SHIM_DIR="$OUTPUT/shim"
SHIM_BIN="$SHIM_DIR/bin"
rm -rf "$RAW_DIR" "$SHIM_DIR"
mkdir -p "$RAW_DIR" "$SHIM_BIN"

# -----------------------------------------------------------------------------
# Valgrind arguments
# -----------------------------------------------------------------------------
# fork()ed backends are always followed, and %p gives each of them its own
# XML file.  --trace-children=no keeps programs the server exec()s, such as
# the pg_dump an apply worker runs for structure sync, out of the report.
# Never add --child-silent-after-fork: that would hide every backend.
#
# In --xml mode memcheck writes leak records at exit even with
# --leak-check=no, so the leak kinds are switched off explicitly as well,
# and the report drops any Leak_* record that still gets through (spock's
# own VALGRIND_DO_LEAK_CHECK requests, for one).
#
# --gen-suppressions=all puts a ready-made suppression block into the XML
# for every error, which the report shows next to the error.
VALGRIND_ARGS=(
	--tool=memcheck
	--xml=yes
	--trace-children=no
	--track-origins="$TRACK_ORIGINS"
	--malloc-fill=8f
	--free-fill=9f
	--num-callers=30
	--error-limit=no
	--gen-suppressions=all
	--vgdb=no
)
if [ "$LEAK_CHECK" = no ]; then
	VALGRIND_ARGS+=(--leak-check=no --show-leak-kinds=none --errors-for-leak-kinds=none)
else
	VALGRIND_ARGS+=(--leak-check="$LEAK_CHECK" --show-leak-kinds=definite)
fi
for s in "${SUPPRESSIONS[@]}"; do
	VALGRIND_ARGS+=(--suppressions="$s")
done
if [ -n "${VALGRIND_EXTRA:-}" ]; then
	# shellcheck disable=SC2206  # word splitting is the point here
	VALGRIND_ARGS+=($VALGRIND_EXTRA)
fi

# -----------------------------------------------------------------------------
# Shim bin directory
# -----------------------------------------------------------------------------
for f in "$REAL_BINDIR"/*; do
	[ -f "$f" ] || continue
	ln -s "$f" "$SHIM_BIN/$(basename "$f")"
done
rm -f "$SHIM_BIN/postgres" "$SHIM_BIN/pg_config"

{
	echo "# Generated by run-valgrind.sh; sourced by the shim wrappers."
	printf 'REAL_POSTGRES=%q\n' "$REAL_POSTGRES"
	printf 'REAL_PG_CONFIG=%q\n' "$PG_CONFIG"
	printf 'VALGRIND=%q\n' "$VALGRIND"
	printf 'RAW_DIR=%q\n' "$RAW_DIR"
	printf 'VALGRIND_ARGS=('
	printf '%q ' "${VALGRIND_ARGS[@]}"
	printf ')\n'
} > "$SHIM_DIR/valgrind.env"

cat > "$SHIM_BIN/postgres" <<'EOF'
#!/usr/bin/env bash
# Generated by run-valgrind.sh: runs the real postgres under valgrind.
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/../valgrind.env"

# pg_ctl, pg_regress and spock's Makefile probe the binary about itself
# (version, config, a GUC's value).  Those runs are short-lived, produce no
# interesting memory traffic and would only slow things down, so bypass
# valgrind for them.
for arg in "$@"; do
	case "$arg" in
		-V|--version|--describe-config|-C|--help|'-?')
			exec "$REAL_POSTGRES" "$@"
			;;
	esac
done

# The start time in the name keeps a later postmaster from overwriting the
# log of an earlier process that happened to get the same PID.
exec "$VALGRIND" "${VALGRIND_ARGS[@]}" --xml-file="$RAW_DIR/$(date +%s)-%p.xml" \
	"$REAL_POSTGRES" "$@"
EOF
chmod +x "$SHIM_BIN/postgres"

cat > "$SHIM_BIN/pg_config" <<'EOF'
#!/usr/bin/env bash
# Generated by run-valgrind.sh: a pg_config whose --bindir is the shim.
set -eu
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$here/../valgrind.env"
if [ $# -eq 1 ] && [ "$1" = "--bindir" ]; then
	echo "$here"
	exit 0
fi
exec "$REAL_PG_CONFIG" "$@"
EOF
chmod +x "$SHIM_BIN/pg_config"

# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
SPOCK_COMMIT="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
SPOCK_BRANCH="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
VALGRIND_VERSION="$("$VALGRIND" --version)"
STARTED="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
[ -n "$TITLE" ] || TITLE="spock under Valgrind ($SPOCK_BRANCH @ $SPOCK_COMMIT)"

log "PostgreSQL: $PG_VERSION ($REAL_BINDIR)"
log "spock:      $SPOCK_BRANCH @ $SPOCK_COMMIT"
log "valgrind:   $VALGRIND_VERSION, leak-check=$LEAK_CHECK, track-origins=$TRACK_ORIGINS"
log "USE_VALGRIND build: $USE_VALGRIND_BUILD"
log "suite:      $SUITE"
log "output:     $OUTPUT"

REGRESS_STATUS=skipped
TAP_STATUS=skipped
SUITE_FAILED=no

if [ "$SUITE" = regress ] || [ "$SUITE" = all ]; then
	MAKE_ARGS=(regresscheck PG_CONFIG="$SHIM_BIN/pg_config")
	if [ -n "$REGRESS_TESTS" ]; then
		for t in $REGRESS_TESTS; do
			[ -f "$REPO_ROOT/tests/regress/sql/$t.sql" ] \
				|| die "no regression test tests/regress/sql/$t.sql"
		done
		MAKE_ARGS+=(REGRESS="$REGRESS_TESTS")
		log "running ${REGRESS_TESTS// /, } from the regression suite (make regresscheck)"
	else
		log "running the regression suite (make regresscheck)"
	fi
	set +e
	( cd "$REPO_ROOT" \
		&& PATH="$SHIM_BIN:$PATH" make "${MAKE_ARGS[@]}" ) \
		2>&1 | tee "$OUTPUT/regress.log"
	rc=${PIPESTATUS[0]}
	set -e
	if [ "$rc" -eq 0 ]; then
		REGRESS_STATUS=passed
	else
		REGRESS_STATUS="failed (exit $rc)"
		SUITE_FAILED=yes
		# Keep what pg_regress left behind in its --outputdir: the diffs
		# say what went wrong, and log/ has the server log.
		REGRESS_OUT="$REPO_ROOT/tests/regress/regression_output"
		mkdir -p "$OUTPUT/regress"
		for f in regression.diffs regression.out; do
			[ -f "$REGRESS_OUT/$f" ] && cp "$REGRESS_OUT/$f" "$OUTPUT/regress/"
		done
		[ -d "$REGRESS_OUT/log" ] && cp -r "$REGRESS_OUT/log" "$OUTPUT/regress/"
	fi
	log "regression suite: $REGRESS_STATUS"
fi

if [ "$SUITE" = tap ] || [ "$SUITE" = all ]; then
	if [ -z "$TAP_TESTS" ]; then
		TAP_TESTS="$(awk '/^[[:space:]]*test:/ {print $2}' "$REPO_ROOT/tests/tap/schedule" | tr '\n' ' ')"
	fi
	TAP_FILES=()
	for t in $TAP_TESTS; do
		t="${t%.pl}"
		[ -f "$REPO_ROOT/tests/tap/t/$t.pl" ] || die "no TAP test tests/tap/t/$t.pl"
		TAP_FILES+=("t/$t.pl")
	done
	log "running ${#TAP_FILES[@]} TAP test(s) with prove"
	log "NOTE: TAP tests wait a fixed time for servers and replication;"
	log "      under valgrind some of them may time out rather than fail."
	mkdir -p "$OUTPUT/tap-logs"
	set +e
	( cd "$REPO_ROOT/tests/tap" \
		&& TESTDIR="$REPO_ROOT" TESTLOGDIR="$OUTPUT/tap-logs" \
		   PATH="$SHIM_BIN:$PATH" PG_CONFIG="$SHIM_BIN/pg_config" \
		   prove -I t -v --timer "${TAP_FILES[@]}" ) \
		2>&1 | tee "$OUTPUT/tap.log"
	rc=${PIPESTATUS[0]}
	set -e
	if [ "$rc" -eq 0 ]; then
		TAP_STATUS=passed
	else
		TAP_STATUS="failed (exit $rc)"
		SUITE_FAILED=yes
	fi
	log "TAP suite: $TAP_STATUS"
fi

# -----------------------------------------------------------------------------
# Report
# -----------------------------------------------------------------------------
log "writing the report from $(find "$RAW_DIR" -name '*.xml' | wc -l | tr -d ' ') valgrind log(s)"
REPORT_ARGS=(
	--raw "$RAW_DIR"
	--out "$OUTPUT"
	--title "$TITLE"
	--source-root "$REPO_ROOT"
	--meta "PostgreSQL=$PG_VERSION"
	--meta "spock=$SPOCK_BRANCH @ $SPOCK_COMMIT"
	--meta "valgrind=$VALGRIND_VERSION"
	--meta "USE_VALGRIND build=$USE_VALGRIND_BUILD"
	--meta "leak-check=$LEAK_CHECK"
	--meta "track-origins=$TRACK_ORIGINS"
	--meta "regression suite=$REGRESS_STATUS"
	--meta "TAP suite=$TAP_STATUS"
	--meta "started=$STARTED"
	--meta "finished=$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
)
[ "$FAIL_ON_ERRORS" = yes ] && REPORT_ARGS+=(--fail-on-errors)
[ "$LEAK_CHECK" = no ] && REPORT_ARGS+=(--ignore-leaks)

set +e
python3 "$SCRIPT_DIR/valgrind-report.py" "${REPORT_ARGS[@]}"
report_rc=$?
set -e

log "report: $OUTPUT/report.md (also report.html, summary.md, summary.json)"

if [ "$SUITE_FAILED" = yes ]; then
	log "a test suite failed; see the logs under $OUTPUT"
	exit 1
fi
if [ "$report_rc" -ne 0 ]; then
	# 3 means "errors found" with --fail-on-errors; anything else is a bug.
	[ "$report_rc" -eq 3 ] && exit 1
	die "valgrind-report.py failed with exit $report_rc" 2
fi
exit 0
