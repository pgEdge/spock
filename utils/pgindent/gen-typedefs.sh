#!/bin/bash

curl https://buildfarm.postgresql.org/cgi-bin/typedefs.pl > typedefs.list

grep -nri "typedef struct" ../../ --include="*.c" --include="*.h" | grep -v "{" | awk '{print $3}' >> typedefs.list
grep -nri "typedef enum" ../../ --include="*.c" --include="*.h" | grep -v "{" | awk '{print $3}' >> typedefs.list

find ../../ -type f \( -name "*.c" -o -name "*.h" \) -print0 \
  | xargs -0 pgindent --typedefs typedefs.list


