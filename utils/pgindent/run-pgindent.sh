#!/bin/bash
#
# run-pgindent.sh — Format Spock source code with pgindent.
#
# Fetches PostgreSQL core typedefs from the buildfarm for every supported
# major version, extracts Spock-specific typedefs from the source tree,
# merges them into a single typedefs.list, and runs pgindent on all .c/.h
# files.
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

# Supported PostgreSQL major versions for typedef fetching.  PG 15 is
# excluded because its typedefs are a subset of PG 16's.  Update this
# list when Spock adds or drops support for a major version.
PG_BRANCHES="REL_16_STABLE REL_17_STABLE REL_18_STABLE"

BUILDFARM_URL="https://buildfarm.postgresql.org/cgi-bin/typedefs.pl"
TYPEDEFS="$SCRIPT_DIR/typedefs.list"
TMPFILE=$(mktemp)

trap 'rm -f "$TMPFILE" "$TMPFILE".* 2>/dev/null' EXIT

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

# ------------------------------------------------------------------
# 2. Extract Spock-specific typedefs from source code
# ------------------------------------------------------------------
echo "Extracting Spock typedefs from source..."
for keyword in "typedef struct" "typedef enum" "typedef union"; do
    grep -rn "$keyword" "$SPOCK_ROOT" \
        --include="*.c" --include="*.h" \
    | grep -v "{" \
    | awk '{print $3}' >> "$TMPFILE" || true
done

# ------------------------------------------------------------------
# 3. Merge, deduplicate, and clean up
# ------------------------------------------------------------------
# Remove empty lines, comment fragments, and duplicates
grep -v '^$' "$TMPFILE" | grep -v '^/\*' | sort -u > "$TYPEDEFS"
echo "Generated $(wc -l < "$TYPEDEFS") typedefs in typedefs.list"

# ------------------------------------------------------------------
# 4. Run pgindent
# ------------------------------------------------------------------
PGINDENT_ARGS=(--typedefs "$TYPEDEFS")

if [[ "${1:-}" == "--check" ]]; then
    echo "Running pgindent in check mode..."
    PGINDENT_ARGS+=(--check --diff)
fi

find "$SPOCK_ROOT" -type f \( -name "*.c" -o -name "*.h" \) \
    -print0 \
  | xargs -0 pgindent "${PGINDENT_ARGS[@]}"

echo "Done."
