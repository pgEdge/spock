# Running the spock tests under Valgrind

`run-valgrind.sh` runs the regression suite, the TAP suite or both with
every PostgreSQL server process under Valgrind memcheck, and
`valgrind-report.py` turns the raw output into a report that groups the
errors by where they happen and separates spock's own code from the rest.

The weekly GitHub workflow `.github/workflows/valgrind-weekly.yml` does
this on `main` every Sunday and can be dispatched by hand for another
PostgreSQL major, the TAP suite or leak checking.

## What you need

- Linux with `valgrind` and `python3` on `PATH`.  Valgrind does not run on
  current macOS.  The `valgrind` package also provides the header that
  `-DUSE_VALGRIND` needs; `pkg-config` and `libicu-dev` are needed for
  PostgreSQL's default configure.
- A PostgreSQL install built for Valgrind, with spock built and installed
  into it.  The flags that matter:

  ```sh
  ./configure --prefix=$PG_PREFIX --enable-debug --enable-cassert \
      --enable-tap-tests \
      CFLAGS="-O0 -g -fno-omit-frame-pointer" CPPFLAGS="-DUSE_VALGRIND"
  ```

  `-DUSE_VALGRIND` is the important one.  Without it PostgreSQL's memory
  contexts hide almost every use-after-free and uninitialised read from
  memcheck.  The script still runs on a stock build, but warns.
- The PostgreSQL source tree, for its suppressions file
  `src/tools/valgrind.supp`.  Without it expect a lot of noise from the
  server itself.

## Running it

```sh
export PG_CONFIG=$PG_PREFIX/bin/pg_config
tests/valgrind/run-valgrind.sh --pg-src /path/to/postgres
```

That runs the regression suite and writes everything under
`tests/valgrind/output/`:

| file | what |
|---|---|
| `report.md` | the full report: summary tables, then every unique error with its stack and a ready-made suppression |
| `report.html` | the same as a page |
| `summary.md` | the headline tables only; the workflow puts this in the job summary |
| `summary.json` | the counts, for scripts |
| `raw/<pid>.xml` | Valgrind's own output, one file per server process |
| `regress.log`, `tap.log` | the suite output |

Useful options:

```sh
--regress-tests "preseed init basic"   # a subset of the regression suite
--suite tap --tap-tests "001_basic 002_create_subscriber"
--suite all
--leak-check full          # off by default: backends never free everything
--track-origins no         # faster, but no "where did this value come from"
--fail-on-errors           # exit 1 when the report lists any error
--output /somewhere/else
```

`VALGRIND_EXTRA` adds raw valgrind flags, and `PGCTLTIMEOUT` (default 900)
is how long pg_regress and pg_ctl wait for a server to come up, which is
slow under memcheck.

## How it works

The script builds a shim `bin` directory full of symlinks to the real
PostgreSQL binaries, with two exceptions.  `postgres` is a wrapper that
execs the real server under valgrind, and `pg_config` reports the shim as
its `--bindir`.  Running `make regresscheck PG_CONFIG=<shim>/pg_config`
makes pg_regress start the server from the shim, and the TAP harness
picks the shim up from `PATH`.  Every postmaster and every backend it
forks is then under memcheck, each writing its own XML file.

The wrapper bypasses valgrind for the server's self-describing calls
(`--version`, `--describe-config`, `-C`), which pg_ctl and the Makefile
use to probe the binary.  `pg_ctl` is wrapped too: it looks for `postgres`
next to its own resolved path, which for a symlink is the real bin
directory, so the wrapper adds `-p <shim>/postgres` to `start` and
`restart` unless the caller gave its own.

The script exits 1 when a suite fails, when `--fail-on-errors` is set and
the report lists an error, or when a valgrind log could not be parsed and
the report is therefore incomplete; 2 is a usage or setup problem.

## Reading the report

Errors are grouped by kind and the top six frames of the stack, so one bug
hit by many backends shows once, with its occurrence and process counts.
An error is "in spock code" when one of the top six frames is in
`spock.so`, `spock_output.so` or a `spock*.c` file.  Deeper spock frames
do not count: spock is a hook on almost every backend's stack, and a
relcache allocation twenty frames above `spock_ProcessUtility` is
PostgreSQL's, not ours.  The "where" column names the spock frame and,
when it differs, the function at the top of the stack.  Errors in spock
code come first, ordered invalid writes, invalid reads, bad frees,
uninitialised values, then leaks.

Each error carries Valgrind's generated suppression, already named and
cut to its first eight frames with `...` for the rest.  When an error is
not ours, or is a known false positive, paste that block into
`spock.supp` at the repository root, and it disappears from the next run.

Leak checking is off by default and the report then drops any leak record
that memcheck's XML output still writes at exit.  Expect a lot of noise
with `--leak-check full`: backends never free their memory contexts
before exiting, and with `-DUSE_VALGRIND` every palloc chunk is tracked
on its own.

## Limits

- TAP tests wait a fixed time for servers and replication.  Under memcheck
  some will time out rather than fail, so the weekly run covers only the
  regression suite by default.  Pick individual TAP tests with
  `--tap-tests`.
- A server stopped with `pg_ctl stop -m immediate` is killed with SIGQUIT,
  and its XML file ends mid-stream.  The report keeps the errors that were
  written and counts the file as cut short.
- Only server processes are traced.  Programs the server execs, such as
  the `pg_dump` an apply worker runs for structure sync, run natively.
  The bootstrap backend that initdb starts also runs natively, since
  initdb resolves the shim's symlink to the real binary.
