#!/bin/bash
#
# run-pgindent.sh — Format Spock source code with pgindent.
#
# Fetches PostgreSQL core typedefs from the buildfarm for every supported
# major version, extracts Spock-specific typedefs from the source tree,
# merges them into a single typedefs.list, and runs pgindent on all .c/.h
# files.
#
# Only git-tracked files are considered.  The tree routinely contains
# untracked build artefacts — cluster-upgrade/bin/pg*/ holds complete
# PostgreSQL installations — and feeding core headers such as llvmjit.h
# or s_lock.h to pgindent produces spurious failures.
#
# Prerequisites:
#   - pg_bsd_indent in PATH (build from src/tools/pg_bsd_indent in PG source)
#   - pgindent in PATH (from src/tools/pgindent/pgindent in PG source)
#
# Usage:
#   ./run-pgindent.sh          # format all files
#   ./run-pgindent.sh --check  # dry-run: exit 1 if any file would change
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SPOCK_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if ! git -C "$SPOCK_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ERROR: $SPOCK_ROOT is not a git work tree; this script selects" >&2
    echo "       files via 'git ls-files' and cannot run without it." >&2
    exit 1
fi

# git ls-files reports paths relative to the repository root.
cd "$SPOCK_ROOT"

# Supported PostgreSQL major versions for typedef fetching.  PG 15 is
# excluded because its typedefs are a subset of PG 16's.  Update this
# list when Spock adds or drops support for a major version.
PG_BRANCHES="REL_16_STABLE REL_17_STABLE REL_18_STABLE REL_19_STABLE"

BUILDFARM_URL="https://buildfarm.postgresql.org/cgi-bin/typedefs.pl"
TYPEDEFS="$SCRIPT_DIR/typedefs.list"
TMPFILE=$(mktemp)
FILELIST="$TMPFILE.files"

trap 'rm -f "$TMPFILE" "$TMPFILE".*' EXIT

# ------------------------------------------------------------------
# 0. Collect the files to format
# ------------------------------------------------------------------
git ls-files -z -- '*.c' '*.h' > "$FILELIST"
NFILES=$(tr -dc '\0' < "$FILELIST" | wc -c | tr -d '[:space:]')
if [ "$NFILES" -eq 0 ]; then
    echo "ERROR: no tracked .c/.h files found under $SPOCK_ROOT" >&2
    exit 1
fi
echo "Formatting $NFILES tracked source files"

# ------------------------------------------------------------------
# 1. Fetch PostgreSQL core typedefs from buildfarm for each branch
# ------------------------------------------------------------------
# The buildfarm has answered with an empty list and a 200 status, which
# curl -f accepts, so check the size too.  On any failure, take the core
# typedefs from the committed typedefs.list instead.  It also holds the
# Spock typedefs from its last run, which only adds names that may no
# longer exist; the current ones are extracted again below.
MIN_BRANCH_TYPEDEFS=1000

echo "Fetching PostgreSQL core typedefs from buildfarm..."
> "$TMPFILE"
FETCH_OK=1
for branch in $PG_BRANCHES; do
    echo "  $branch"
    if ! curl -sf "$BUILDFARM_URL?branch=$branch" > "$TMPFILE.branch"; then
        echo "WARNING: failed to fetch typedefs for $branch from $BUILDFARM_URL" >&2
        FETCH_OK=0
        break
    fi
    BRANCH_COUNT=$(wc -l < "$TMPFILE.branch" | tr -d '[:space:]')
    if [ "$BRANCH_COUNT" -lt "$MIN_BRANCH_TYPEDEFS" ]; then
        echo "WARNING: buildfarm returned only $BRANCH_COUNT typedefs for $branch" >&2
        FETCH_OK=0
        break
    fi
    cat "$TMPFILE.branch" >> "$TMPFILE"
done

if [ "$FETCH_OK" -eq 0 ]; then
    COMMITTED_COUNT=0
    if [ -f "$TYPEDEFS" ]; then
        COMMITTED_COUNT=$(wc -l < "$TYPEDEFS" | tr -d '[:space:]')
    fi
    if [ "$COMMITTED_COUNT" -lt "$MIN_BRANCH_TYPEDEFS" ]; then
        echo "ERROR: no usable typedefs from the buildfarm or $TYPEDEFS" >&2
        exit 1
    fi
    echo "WARNING: using the core typedefs in the committed typedefs.list" >&2
    # Show the fallback in the pull request checks as well.
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
        echo "::warning::buildfarm typedefs unavailable; used the committed typedefs.list"
    fi
    cp "$TYPEDEFS" "$TMPFILE"
fi
CORE_COUNT=$(wc -l < "$TMPFILE" | tr -d '[:space:]')

# ------------------------------------------------------------------
# 2. Extract Spock-specific typedefs from source code
# ------------------------------------------------------------------
# Two forms are recognised:
#   - single-line: "typedef struct/enum/union Foo" with no brace on the
#     same line names Foo directly.
#   - multi-line: "typedef struct/enum/union" (optionally with a struct
#     tag) alone on its line opens a definition whose typedef name only
#     appears later, on its closing "} Foo;" line at column 0. Missing
#     this form silently drops every anonymous typedef enum/struct in
#     the tree, which is most of them.
#
# Keep this program to POSIX awk.  macOS ships the one true awk as
# /usr/bin/awk, which has no three-argument match() to capture a group
# with -- the name is peeled off the closing line with sub() instead.
echo "Extracting Spock typedefs from source..."
xargs -0 awk '
    $1 == "typedef" &&
    ($2 == "struct" || $2 == "enum" || $2 == "union") &&
    $0 !~ /{/ && $3 != "" { print $3 }

    /^[[:space:]]*typedef[[:space:]]+(struct|enum|union)([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:space:]]*$/ { pending = 1; next }
    pending && /^}[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*;/ {
        name = $0
        sub(/^}[[:space:]]*/, "", name)
        sub(/[[:space:]]*;.*$/, "", name)
        print name
        pending = 0
        next
    }
    /^}/ { pending = 0 }
' < "$FILELIST" >> "$TMPFILE"
SPOCK_COUNT=$(( $(wc -l < "$TMPFILE") - CORE_COUNT ))
if [ "$SPOCK_COUNT" -eq 0 ]; then
    echo "ERROR: no Spock typedefs extracted from $NFILES files;" >&2
    echo "       the typedef scan is broken, refusing to indent." >&2
    exit 1
fi
echo "  $SPOCK_COUNT Spock typedef names"

# ------------------------------------------------------------------
# 3. Merge, deduplicate, and clean up
# ------------------------------------------------------------------
# Remove empty lines, comment fragments, and duplicates
grep -v '^$' "$TMPFILE" | grep -v '^/\*' | sort -u > "$TYPEDEFS"
echo "Generated $(wc -l < "$TYPEDEFS" | tr -d '[:space:]') typedefs in typedefs.list"

# ------------------------------------------------------------------
# 4. Run pgindent
# ------------------------------------------------------------------
PGINDENT_ARGS=(--typedefs "$TYPEDEFS")

if [[ "${1:-}" == "--check" ]]; then
    echo "Running pgindent in check mode..."
    PGINDENT_ARGS+=(--check --diff)
fi

xargs -0 pgindent "${PGINDENT_ARGS[@]}" < "$FILELIST"

echo "Done."
