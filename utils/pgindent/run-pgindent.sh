#!/bin/bash
set -euo pipefail

# Fetch PostgreSQL core typedefs from buildfarm and append to existing list
# (preserves manually-added entries like RepOriginId which is missing from buildfarm)
curl -fsSL https://buildfarm.postgresql.org/cgi-bin/typedefs.pl >> typedefs.list

# Extract Spock-specific typedefs from source code and append them
grep -nri "typedef struct" ../../ --include="*.c" --include="*.h" | grep -v "{" | awk '{print $3}' >> typedefs.list || true
grep -nri "typedef enum" ../../ --include="*.c" --include="*.h" | grep -v "{" | awk '{print $3}' >> typedefs.list || true
grep -nri "typedef union" ../../ --include="*.c" --include="*.h" | grep -v "{" | awk '{print $3}' >> typedefs.list || true

# Remove duplicates and sort
sort typedefs.list | uniq > typedefs.list.tmp && mv typedefs.list.tmp typedefs.list

find ../../ -type f \( -name "*.c" -o -name "*.h" \) -print0 \
  | xargs -0 pgindent --typedefs typedefs.list


