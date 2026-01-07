## Running pgindent on Spock source files

### Quick start

```bash
cd utils/pgindent
./run-pgindent.sh          # format all .c/.h files
./run-pgindent.sh --check  # dry-run: exit 1 if any file would change
```

### What the script does

1. Fetches PostgreSQL core typedefs from the buildfarm for PG 16, 17,
   and 18.  PG 15 is excluded because its typedefs are a subset of
   PG 16's.  This ensures that types introduced in any supported release
   are recognized by pgindent.
2. Extracts Spock-specific typedefs (`typedef struct/enum/union`) from the
   source tree.
3. Merges, deduplicates, and writes the result to `typedefs.list`.
4. Runs `pgindent` on all `.c` and `.h` files.

### Prerequisites

Both tools come from the PostgreSQL source tree:

- **pg_bsd_indent** — build from `src/tools/pg_bsd_indent/` (available in
  PG 16+; not present in PG 15):
  ```bash
  cd /path/to/postgresql/src/tools/pg_bsd_indent
  make && make install prefix=/usr/local
  ```
- **pgindent** — add `src/tools/pgindent/` to your `PATH`, or symlink:
  ```bash
  ln -s /path/to/postgresql/src/tools/pgindent/pgindent /usr/local/bin/
  ```

Use PG 16 or later for building these tools.  The indent binary is
stable across versions; the typedef differences are handled by fetching
per-branch lists from the buildfarm.

### Cross-version typedefs

Different PostgreSQL major versions define different structs and enums.
Running pgindent with only one version's typedefs produces formatting
that differs from another version.  The script solves this by merging
typedef lists from all supported PG branches:

```text
https://buildfarm.postgresql.org/cgi-bin/typedefs.pl?branch=REL_16_STABLE
https://buildfarm.postgresql.org/cgi-bin/typedefs.pl?branch=REL_17_STABLE
https://buildfarm.postgresql.org/cgi-bin/typedefs.pl?branch=REL_18_STABLE
```

When Spock adds or drops support for a PG major version,
update the `PG_BRANCHES` variable in `run-pgindent.sh`.

### CI

The GitHub Actions workflow `.github/workflows/pgindent.yml` runs
`./run-pgindent.sh --check` on every pull request to `main`.  It builds
`pg_bsd_indent` from a pinned PG version (currently PG 18) and fetches
typedefs for all supported branches.

### Files

- `run-pgindent.sh` — the main script
- `typedefs.list` — committed to track changes in the combined typedef set
