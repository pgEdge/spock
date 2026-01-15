## Running pgindent on spock files

1. Run `./run-pgindent.sh` to format all code. This script will:
   - Pull the latest PostgreSQL typedefs from buildfarm
   - Extract Spock-specific typedefs by scanning the source code
   - Run pgindent on all .c and .h files (excluding spockctrl)

2. Prerequisites:
   - Install pg_bsd_indent: navigate to src/tools/pg_bsd_indent in your postgres source code and run:
     ```
     make install prefix=/usr/local
     ```
   - Ensure pgindent is in your PATH (from PostgreSQL source: src/tools/pgindent/pgindent)

3. File typedefs.list stays in repository to log changes in the struct set of the core and the Spock.
