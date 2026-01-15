#!/bin/bash

# Fetch PostgreSQL core typedefs from buildfarm
curl https://buildfarm.postgresql.org/cgi-bin/typedefs.pl > typedefs.list

# Extract Spock-specific typedefs from source code and append them
# Exclude spockctrl (standalone CLI utility, not PostgreSQL extension code)
grep -nri "typedef struct" ../../ --include="*.c" --include="*.h" --exclude-dir=spockctrl | grep -v "{" | awk '{print $3}' >> typedefs.list
grep -nri "typedef enum" ../../ --include="*.c" --include="*.h" --exclude-dir=spockctrl | grep -v "{" | awk '{print $3}' >> typedefs.list
grep -nri "typedef union" ../../ --include="*.c" --include="*.h" --exclude-dir=spockctrl | grep -v "{" | awk '{print $3}' >> typedefs.list

# Remove duplicates and sort
sort typedefs.list | uniq > typedefs.list.tmp && mv typedefs.list.tmp typedefs.list

find ../../ -type f \( -name "*.c" -o -name "*.h" \) \
  -not -path "../../utils/spockctrl/*" -print0 \
  | xargs -0 pgindent --typedefs typedefs.list


