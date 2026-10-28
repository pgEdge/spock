---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-14
---

# Setup Notes

Decisions made by `antithesis-setup`, and what the workload skill needs to
know about the harness.

## Files

| Path | What |
|---|---|
| `antithesis/Dockerfile` | stages `build` (PG18 + pgEdge patches + Spock), `node`, `workload` |
| `antithesis/node/node-entrypoint.sh` | initdb on an empty volume, writes `antithesis.conf`, restart loop |
| `antithesis/workload/workload-entrypoint.sh` | builds the n1-n3 mesh, prepares n4, emits `setup_complete` |
| `antithesis/config/docker-compose.yaml` | 5 services; amd64 only |
| `antithesis/local-validate.sh` | native-arch build (`:local` tags) + `snouty validate` |
| `include/spock_antithesis.h`, `src/spock_antithesis.c` | SUT-side assertions (fallback SDK) and coverage hooks |

## Instrumentation inventory

| Component | Language | Instrumented | SDK | Symbols | Bootstrap property |
|---|---|---|---|---|---|
| `spock.so` | C | yes: clang `-fsanitize-coverage=trace-pc-guard` (no `pc-table`: the SDK header lacks the `__sanitizer_cov_pcs_init` hook it needs, so `spock.so` would not load), hooks from `antithesis_instrumentation.h` (C++ SDK v0.5.0, C-compatible) | fallback SDK: JSONL writer in `src/spock_antithesis.c` | `/symbols/spock.so` → unstripped `spock.so` | `Reachable: "spock manager worker started"` in `spock_manager_main`; also `Sometimes: "supervisor shutdown drain timed out with apply workers still attached"` in `spock_supervisor_on_exit` |
| `spock_output.so` | C | no: it would need its own copy of the hooks; small (output plugin glue) | none | none | none |
| PostgreSQL core | C | no: keeps the coverage signal on Spock (deployment-topology) | none | none | none |
| workload | bash now, Python later | cataloging only (Python) | `antithesis==0.4.0` installed for Python 3.12 | n/a; `/opt/antithesis/catalog` → `/opt/antithesis/test/v1` | none (setup emits `setup_complete` via `setup-complete.sh`) |

**Why the fallback SDK, not the C++ SDK.** There is no C SDK. The C++ SDK
would mean C++20 and libstdc++ inside a Postgres backend, and a C++ exception
must never cross a PostgreSQL `longjmp`. The fallback writer is about 150
lines of C, has no palloc and no elog, and is safe in error paths and
critical sections.

**Build switches** (Makefile): `ANTITHESIS=1` compiles the assertions
(`-DUSE_ANTITHESIS`). Adding `ANTITHESIS_SDK_INCLUDE=<dir>` also adds coverage
flags to every `spock.so` object except `spock_antithesis.o`, which defines
the hooks and has to stay uninstrumented. A normal build is unchanged: the
macros compile to nothing.

**Hidden hooks.** PGXS builds with `-fvisibility=hidden`, so
`__sanitizer_cov_trace_pc_guard*` and `antithesis_load_libvoidstar` are local
symbols (`t` in `nm`, not `T`). `spock.so` calls its own copies, which is the
intent. Check in the first run that the report says "Software was
instrumented".

## Adding a SUT-side assertion

1. Add a `SPOCK_ANT_ASSERTION(id, KIND, "message", "src/file.c", "function")`
   line to `SPOCK_ANT_CATALOG` in `include/spock_antithesis.h`.
2. Call `SPOCK_ANT_ALWAYS(id, cond, details)`, `SPOCK_ANT_SOMETIMES(...)`,
   `SPOCK_ANT_REACHABLE(id, details)` or `SPOCK_ANT_UNREACHABLE(id, details)`
   at that site. `details` is `NULL` or a JSON object string.

Every catalog entry is declared from `_PG_init` (once, in the postmaster), so
a `Sometimes` or `Reachable` that never fires still shows up and fails. Each
process sends only the first true and the first false evaluation of each
assertion.

## Node container

- Data on a named volume per node at `/data` (`/data/pgdata` is PGDATA).
- The restart wrapper keeps state in `/data/state`: `boot_count`,
  `last_exit`, `exits.log`, and a `stay_down` flag file.
- `antithesis.conf` (included from `postgresql.conf`) is rewritten on every
  container start from `SPOCK_*` env vars, so run variants are compose env
  changes: `SPOCK_CAPACITY`, `SPOCK_WAL_SENDER_TIMEOUT`,
  `SPOCK_APPLY_IDLE_TIMEOUT`, `SPOCK_EXCEPTION_BEHAVIOUR`,
  `SPOCK_PAUSE_TIMEOUT`, `SPOCK_EXTRA_CONF` (raw lines, e.g. for
  `antithesis.conflict_free` or `max_prepared_transactions`).
- The server log is `/data/pgdata/log/postgresql.log` (no rotation) and is
  also copied to container stdout.
- Graceful stop: `stop_signal: SIGINT` (fast shutdown) and
  `stop_grace_period: 90s`. In local testing a fast shutdown with peers
  already down hung after the workers detached, until Docker's 10s grace
  period killed it (exit 137). It looks like walsenders waiting to send to
  dead receivers, bounded by `wal_sender_timeout`. Not confirmed; it may be
  worth a liveness property ("fast shutdown finishes within
  `wal_sender_timeout` + margin").
- Superuser `admin`, database `demo`, trust auth, port 5432.
- Node-side test commands (pg_ctl stop, kill -9 postmaster) can go in
  `antithesis/test/v1/<template>/`, but the node image does not copy the
  whole tree (a command present in several containers may run in any of
  them, and node images have no Python). Node-side commands live in
  `antithesis/node/test/v1/<template>/` and the node stage copies that tree
  (first one: `parallel_driver_graceful_restart.sh`). Workload commands use `python3.12` (the system
  `python3` is 3.9 and has neither psycopg nor the SDK).

## Workload container

- Spock node `nX` is host `spock-nX` (`NODE_HOST_PREFIX=spock-`).
- Cluster setup: `spock.node_create` on n1-n3 with tiebreakers 1-3, six
  subscriptions `sub_<to>_<from>` with default replication sets and no
  structure or data sync, waits until all are `replicating`. n4 gets the
  `spock` and `dblink` extensions and `zodan.sql`, and no Spock node.
- **No test schema is created at setup.** The workload skill owns the tables.
- Z0DAN sources are at `/opt/spock/Z0DAN/`.

## Architecture

Antithesis runs x86-64. The committed compose pins `linux/amd64`. The
development host is aarch64 without amd64 emulation, so local validation
builds native arm64 images under `:local` tags (`local-validate.sh`). The
images for submission (`:latest`, amd64) have to be built on an x86-64 host
or with qemu emulation registered, before `antithesis-launch`.

## Not done yet (by design)

- Clock-fault image (Spock + 4e0988de): clock faults are off for now.
- Test-only PG patch with core markers: later phase.
- Run variants (`v2/small-capacity`, `v2/slot-groups`, `sub_disable`, ...):
  env changes on the compose, added with the templates that need them.
