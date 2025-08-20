#!/bin/bash

curl https://buildfarm.postgresql.org/cgi-bin/typedefs.pl > typedefs.list

grep -nri "typedef struct" ../ --include="*.c" --include="*.h" | awk '{print $3}' >> typedefs.list



