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
echo "Fetching PostgreSQL core typedefs from buildfarm..."
> "$TMPFILE"
for branch in $PG_BRANCHES; do
    echo "  $branch"
    curl -sf "$BUILDFARM_URL?branch=$branch" >> "$TMPFILE" || {
        echo "ERROR: failed to fetch typedefs for $branch from $BUILDFARM_URL" >&2
        exit 1
    }
done
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
echo "Extracting Spock typedefs from source..."
xargs -0 awk '
    $1 == "typedef" &&
    ($2 == "struct" || $2 == "enum" || $2 == "union") &&
    $0 !~ /{/ && $3 != "" { print $3 }

    /^[[:space:]]*typedef[[:space:]]+(struct|enum|union)([[:space:]]+[A-Za-z_][A-Za-z0-9_]*)?[[:space:]]*$/ { pending = 1; next }
    pending && match($0, /^}[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*;/, m) { print m[1]; pending = 0 }
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
