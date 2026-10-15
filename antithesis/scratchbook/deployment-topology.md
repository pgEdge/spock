---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Deployment Topology

> **As built (2026-10-14, `setup-notes.md`):** containers and hosts are
> `spock-n1`..`spock-n4` and `spock-workload`; Spock node names stay
> `n1`..`n4`. Workload setup does not create a test schema (the workload
> skill owns it). The node fault helpers (pg_ctl stop, postmaster kill) are
> not written yet; the node image carries `/opt/antithesis/test/` for them.

## Summary

The topology is three Spock nodes in a full mesh, one spare node that the
workload joins with Z0DAN `add_node` during the run, and one workload client.
That makes five containers. Each Postgres node gets its own container so that
Antithesis can partition, pause and kill each node independently, since nodes
fail one at a time in production.

Updated after property evaluation (2026-10-13, `evaluation/synthesis.md`):
timeout settings, the node container wrapper, required fault helpers, the SDK
route (there is no C SDK), log access, image choice for clock faults, and
separate configurations for small capacity and slot groups.

```text
                         +--------------------------+
                         | workload (client)        |
                         | test template + psql/SDK |
                         +-----+------+------+------+
                               |      |      |      \  (add_node driver,
                  SQL (libpq)  |      |      |       \  convergence checks)
                               v      v      v        v
   +-----------+   logical   +-----------+  logical  +-----------+      +-----------+
   |   n1      |<----------->|   n2      |<--------->|   n3      |      |   n4      |
   | PG+spock  |<------------------------------------->| PG+spock  |      | PG+spock  |
   +-----------+   (full mesh: 6 subscriptions)       +-----------+      | (spare,   |
         ^                                                   ^           | not yet   |
         +-------------------- add_node joins n4 ------------+---------->| joined)   |
                                                                         +-----------+
```

## Components

### n1, n2, n3: Spock nodes (service, 3 replicas)

| Field | Value |
|---|---|
| Container names | `n1`, `n2`, `n3` (hostname matches the container name) |
| Image | New `antithesis/` Dockerfile adapted from `tests/docker/Dockerfile-step-1.el9`. It builds pgEdge-patched PostgreSQL (`patches/<ver>/*`) and then Spock, with the SUT assertion shim (see "SDK and Instrumentation Plan") and coverage instrumentation compiled into `spock.so`. `ps` (procps) must be installed |
| Role | Service (the SUT) |
| Runs | A small wrapper loop (PID 1 under `init: true`) that starts one `postgres` postmaster with `shared_preload_libraries=spock` and restarts it when it exits. Spock's supervisor, manager, apply and sync workers and the walsenders run as the postmaster's children |
| Connections | Every node subscribes to the other two (6 subscriptions: n1←n2, n1←n3, n2←n1, …) over libpq on port 5432. The workload connects to every node |
| PG version | 18 (pgEdge-patched). The failover-slots worker only exists on PG<18 and is out of the first scope; see Open Questions |
| Compose | `stop_signal: SIGINT` (fast shutdown) so a graceful container stop does not turn into a smart shutdown that waits on client and dblink sessions until Docker's grace period kills it. No restart policy (Antithesis docs advise none); the wrapper does the restarting |

**Why three.** Several of the top leads only show up with three or more nodes:

- divergence when the tiebreak compares the applying node with the sender
- `update_missing` when an UPDATE arrives before the INSERT it depends on, because they came from different upstreams
- forwarded-origin handling
- pausing apply across peers during add-node

Two nodes cannot reach those states, and a fourth always-on node adds state space without adding new kinds of state.

**Required node configuration** (main configuration; from the SUT analysis,
`tests/docker/entrypoint.sh` and the evaluation):

- `wal_level=logical`, `track_commit_timestamp=on`, `shared_preload_libraries='spock'`
- `max_worker_processes`, `max_replication_slots`, `max_wal_senders` and, on
  PG18, `max_active_replication_origins` of 32 or more (L1 crash redo
  creates node-id origin states that each take one and cannot be dropped).
  The small-capacity values belong to their own configuration (below)
- `output_plugin_libraries='pgoutput, test_decoding, spock_output'` (only when the GUC exists; probe with `postgres --describe-config` as the entrypoint does)
- `spock.conflict_resolution='last_update_wins'`, `spock.save_resolutions=on`
- `spock.resolutions_retention_days = 0`, so the daily cleanup cannot delete
  rows the end-of-run oracles read after a forward clock skip (the cleanup
  runs only when the value is above 0, `src/spock_apply.c:3572`)
- `spock.exception_behaviour` set explicitly per run. The default is `transdiscard`; see Open Questions
- `spock.exception_logging = all` (the default; must not be changed, the
  explained-divergence oracle needs every row)
- **Timeouts.** `wal_sender_timeout = 60s` and
  `spock.apply_idle_timeout = 120s`. The apply worker's idle timer resets
  only when a message arrives (`src/spock_apply.c:3548-3562`, reset at
  `:3686`), Spock sends no timed feedback, and an idle walsender sends a
  keepalive only after about `wal_sender_timeout / 2` without a reply. So
  `apply_idle_timeout` must be well above `wal_sender_timeout / 2`, or idle
  links reconnect over and over and a transaction whose decode takes longer
  than the idle timeout may never apply. The earlier plan of about 30 s was
  at that boundary. Liveness bounds become about `60 + 120 + 5
  (restart_delay_default) + 30 (connect_timeout)` seconds plus catch-up
  margin, so plan quiet periods of 4-5 minutes. This replaces both the
  earlier 30 s plan and the `wal_sender_timeout = '5min'` line in
  sut-analysis §15, which comes from `docs/configuring.md` and would stretch
  every bound by four minutes. **One run variant uses the documented values**
  (`wal_sender_timeout = '5min'`, `spock.apply_idle_timeout = 300`), so that
  findings involving timeouts cannot be dismissed as an unsupported
  configuration; its quiet periods are about 8 minutes
- `spock.pause_timeout = 1` (USERSET; each apply worker reads its own value).
  Needed to open the add_node pause window
  (`add-node-pause-held-until-progress-read`)
- `checkpoint_timeout = '5min'` and large `max_wal_size` (sustained writes
  trigger checkpoints through `max_wal_size` too). The L1 properties need
  applied commits since the last checkpoint at kill time, and the workload
  issues no manual CHECKPOINT. `checkpoint_timeout` was `1d` until
  2026-10-15: WAL stayed under `max_wal_size`, so no checkpoint ran, no WAL
  was removed, and run
  9705b08734ec5df06d6637244b6466ed-63-13 filled the disk (spock-n1 PANIC on
  a WAL write, then could not restart). Five minutes still leaves most kills
  between checkpoints
- `logging_collector = on`, fixed `log_directory` and `log_line_prefix`, and
  `lc_messages = 'C'`. The workload reads server logs as superuser with
  `pg_ls_logdir()` / `pg_read_file()` (Assert TRAP lines go to stderr, which
  the collector captures). `spock.exception_log` stores only message text, no
  SQLSTATE, so text matches need a fixed language
- Pinned DateStyle, TimeZone, `extra_float_digits` on every node
- Placeholder GUCs for SUT-side mode flags, set per configuration (for
  example `antithesis.conflict_free = on` in templates without poison
  transactions)
- `pg_hba.conf` `trust` on the container network

**PGDATA must survive a node restart.** Put it on a named volume per node.
Antithesis node termination may drop non-durable filesystem state, and Spock's
crash-recovery properties are only meaningful if the data directory survives
the kill. The existing `tests/docker` setup does not use a volume, so this is
a change.

**No cluster setup in the entrypoint.** Unlike `tests/docker/entrypoint.sh`,
the node entrypoint only runs `initdb` (on an empty volume), writes the
config and starts the wrapper. It does not create Spock nodes and does not
run Z0DAN. All cluster setup moves to the workload container, so a restarted
node just comes back up on its existing PGDATA.

**Node wrapper loop (required).** Postgres must not be the container's main
process, or `pg_ctl stop` and `kill -9 <postmaster>` would end the container
and nothing would bring the node back. The wrapper:

1. starts postgres and waits for it to exit;
2. records how it exited (clean or not) and increments a boot counter, in a
   file outside PGDATA that the workload can read (for example through a
   symlink under the data directory or a file `pg_read_file` can reach);
3. restarts postgres unless a "stay down" flag file exists.

The workload uses the boot counter and `pg_postmaster_start_time()` to find
windows touched by a kill (Antithesis does not announce kills), and compares
`pg_control_system().system_identifier` across checks to detect a node that
came back fresh from its image (the docs allow that); such a check is
skipped and reported with `Sometimes`, not asserted.

### n4: spare node (service, 1)

| Field | Value |
|---|---|
| Container name | `n4` |
| Image | Same image as n1–n3 |
| Role | Service |
| Runs | `postgres` (under the same wrapper) with Spock loaded and `CREATE EXTENSION spock` done, but **no Spock node and no subscriptions** at startup |
| Connections | None until the workload runs Z0DAN `spock.add_node` (from `samples/Z0DAN/zodan.sql` over dblink) to join it to the mesh while n1–n3 take writes |

**Why include it.** Add-node is one of the highest-risk areas:

- Several independent leads point to new-node data loss:
  - the `spock.pause_timeout` self-resume
  - the pause check that treats a worker with no xid as paused
  - the progress-lookup fallback to `pg_current_wal_lsn()`
- Past fixes in this area (`dcbba6bb`, the 5.0.7 and 6.0 data-loss fix) show it has broken before.

Joining a node to a running cluster can only be tested if there is a node
waiting to join. One spare is enough. The workload decides when to join it,
and possibly when to remove it and join it again.

**Re-adding n4.** `add_node` refuses a database that has user tables and
checks that the new node has every role the source has
(`samples/Z0DAN/zodan.sql:1577-1595`). Before a re-add the workload drops
n4's user tables (or recreates the database) and creates the source's roles
on n4. Stale `spock.progress` rows from n4's first life stay visible either
way; that is what `zodan-readd-node-progress-not-stale` checks.

**Cost.** One more container's state space, and time: one add_node under
writes takes minutes (fixed `pg_sleep(5)` calls, a lag monitor, 180 s
waits). Add-node and node-churn properties run in their own test template,
and add_node runs in its own test command with a client-side timeout so a
hang does not block other checks.

### workload: client (1)

| Field | Value |
|---|---|
| Container name | `workload` |
| Image | New Dockerfile under `antithesis/`. It needs the PG client tools (`psql`, `libpq`) for the same major version, the workload language runtime, and the Antithesis SDK for that language |
| Role | Client |
| Runs | The entrypoint waits for n1–n4 to accept connections, then creates the cluster on n1–n3: `CREATE EXTENSION spock`, `spock.node_create` with unique `tiebreaker` values, and `spock.sub_create` for all 6 directions. It creates the test schema, waits for every subscription to report `replicating`, emits `setup_complete`, and then sleeps. The test commands live in `/opt/antithesis/test/v1/<template>/` |
| Connections | libpq to n1, n2, n3 and n4 |

**Why cluster setup lives in the client, not in Z0DAN at boot.**

- The first run should start from a clean, known mesh.
- Z0DAN `add_node` is a test target with its own faults. If n2 and n3 joined through it during setup, a setup failure would look like a SUT failure before `setup_complete`.
- Creating subscriptions directly with `sub_create` is how the TAP tests build meshes (`SpockTest.pm`).

**Workload language.** This is left to the `antithesis-workload` skill.
Python (psycopg plus the Antithesis Python SDK) is the simplest fit for SQL
drivers and for checking convergence. Go also works. The workload needs a
per-row record of what it wrote, for example a ledger of insert-only rows
keyed by `(node, seq)`, so that every row it saw committed can be checked for
on every node, and an expected-exception registry (origin, remote xid,
table) for the poison transactions it injects.

**Test templates.** Main (conflict-free checked tables plus registered poison
tables), classifier (cancel and `terminate_active_transactions` commands,
kept out of the main template until those findings are fixed or accepted),
add-node and node churn. Test commands may also live in the node containers
(Antithesis allows sharing a template across containers); the `pg_ctl` and
postmaster-kill helpers must, because the workload container cannot run
`pg_ctl` on another container.

## Dependencies

There are none outside the SUT. dblink (used by Z0DAN) is a Postgres contrib
extension that must be built and installed in the node image. lolor and
spockbench are not needed for the first topology.

## Image builds

- **Clock-fault image:** Spock from main plus commit 4e0988de (SPOC-688,
  branch `task/SPOC-688/apply-clock-skew-fix`; merges onto 69d9228f without
  conflicts). On the HEAD cassert build any backward clock skip trips the
  Assert at `src/spock_apply.c:1173-1174` on every node and crash-loops the
  cluster. A non-cassert build of HEAD is the other option.
- **HEAD image without 4e0988de:** run with clock faults off.
- Either image keeps cassert on unless stated; an Assert-driven postmaster
  restart is a finding.
- The Phase 7 `last_updated_ts` marker for `zodan-readd-node-progress-not-stale`
  is a change to `samples/Z0DAN/zodan.sql` in the image.

## SDK and Instrumentation Plan (for setup)

- **Spock C extension.** There is no Antithesis C SDK (the docs page says to
  ask about availability; `antithesis_sdk.h` is the C++ SDK: header-only,
  C++20, Clang 16+). Two routes:
  1. **C++ SDK shim:** one small C++ file compiled into `spock.so` that
     exposes `extern "C"` wrappers for each assertion kind. Needs clang++
     and libstdc++ linked into a backend module; C++ exceptions must never
     cross a PostgreSQL `longjmp`.
  2. **Fallback SDK writer:** a small C writer that appends one JSONL line per
     `write()` on an `O_APPEND` descriptor to
     `$ANTITHESIS_OUTPUT_DIR/sdk.jsonl` (many forked backends write at once).
     `ANTITHESIS_OUTPUT_DIR` must reach the postmaster's environment.

  Either way, **declare every SUT-side assertion at `_PG_init`** (runs once
  in the postmaster under `shared_preload_libraries`) with `hit: false`, so a
  `Sometimes`/`Reachable` that never fires still appears and can fail.
- **Coverage:** LLVM coverage instrumentation (`-fsanitize-coverage=trace-pc-guard` via clang) for `spock.so`.
- **Cassert** turns an `Assert` failure into a whole-instance restart, which Antithesis sees as a crash. Keep cassert on, but treat a postmaster restart caused by an Assert as a finding.
- **Postgres core:** not instrumented at first, which keeps the coverage
  signal on Spock. Thread pausing acts only on instrumented code, so windows
  inside core (`xact.c` commit, `execReplication.c` unique check,
  `snapbuild.c`) are reached only by CPU modulation and whole-node pause.
  Option for a later image: a test-only PG patch next to `patches/18/` with
  SDK markers in `xact_redo_commit` (redo origin id with no catalog entry,
  the L1 signal) and in the patch 025 commit-clock hook (local-bump branch;
  first call after startup), plus instrumentation of those core files. PG is
  already built from source, so the cost is small.
- **Workload:** the SDK for whichever language it is written in.

## Fault Requirements

| Fault | Needed for | Default? |
|---|---|---|
| Network partitions / bad nodes / congestion | reconnect, keepalive and idle-timeout paths, divergence under partitions, add-node under partition | Usually on |
| Node hang (pause) | SIGSTOP-like stalls detected only by `apply_idle_timeout`; Z0DAN dblink calls with no timeout | Usually on |
| **Node termination** | crash-recovery leads: replication origin advanced on the wrong id after crash redo, commit clock not restart-safe, sync-worker death, `resource.dat` collisions, Z0DAN orchestrator death | **Often off; must be confirmed** |
| **Clock jitter** | last-update-wins ordering, commit clock across restarts, manager restart scheduling on wall time, `wait_for_sync_event` timeouts | **Often off; must be confirmed**; only with the clock-fault image |
| Thread pausing / CPU modulation | widening timing windows in apply, sync and walsender | CPU modulation works without instrumentation; thread pausing only in instrumented code |

**Required fault helpers** (not fallbacks; many P0/P1 properties cannot fail
without them):

- **Single-worker exits over SQL.** Spock workers show in
  `pg_stat_activity.backend_type` as `spock apply <dboid>:<subid>`,
  `spock sync <rel> <dboid>:<subid>`, `spock manager <dboid>`
  (`src/spock_worker.c:170-191`). The workload, as superuser, uses
  `pg_cancel_backend` / `pg_terminate_backend` on those pids.
- **Signals over SQL.** `COPY (SELECT 1) TO PROGRAM 'kill -<SIG> <pid>'`
  runs as the postgres OS user on the target node (trust auth, superuser):
  SIGKILL of one apply, sync or walsender pid (an in-container crash restart:
  shared memory wiped, page cache kept), SIGSTOP/SIGCONT of one walsender (a
  silent one-direction stall of one pair), SIGTERM of a sync worker in COPY.
  SIGSTOP of a backend holding an LWLock can stall the whole node; liveness
  results in those windows are scoped. Not a safe route for `pg_ctl`
  (the child of a backend is signalled at shutdown).
- **Node-container test commands:** `pg_ctl stop -m fast -t <bound>`,
  `kill -9 <postmaster>`, and `ps` checks for leftover processes. The
  wrapper loop restarts postgres afterwards.
- **Workload-driven crash helper:** one custom fault or node-container test
  command that does an action and then kills the postmaster after a random
  0-300 ms delay (for example: terminate the apply worker, then kill;
  `sub_drop` on a throwaway subscription, then kill; stop a provider's
  writers, apply a marker, then kill the subscriber). Antithesis schedules
  its own node faults independently of the workload, so properties that need
  a kill within milliseconds to about `wal_sender_timeout / 2` of a workload
  step use this helper; the workload decides with SDK randomness whether to
  call it at each point. Antithesis node termination stays on for kills at
  unplanned moments.
- **Optional custom fault:** per-node clock offset with libfaketime
  preloaded in the node containers, reading an offset file the fault writes,
  if Antithesis clock skips are too small to reach L3 (see Open Questions).
  It also gives per-node skew, which the global skip cannot.

## Configurations beyond the main one

- **Documented-defaults variant:** `wal_sender_timeout = '5min'`,
  `spock.apply_idle_timeout = 300`; otherwise the main configuration.
- **`v2/small-capacity`:** `max_worker_processes` and
  `max_active_replication_origins` about 10, fresh-name churn, **node kills
  off** (a restart resets the exception-log table, and with 10 origin states
  a crash with L1 states present may stop a node starting, which would fire
  `crashed-node-returns-to-streaming` for a sizing reason). Capacity 32
  everywhere else.
- **`v2/slot-groups`:** subscription/slot names ending in `_<digit>`; hosts
  `readonly-all-never-commits-remote-txn`.
- **`sub_disable` run variant:** `spock.exception_behaviour = sub_disable`
  on every node; hosts `sub-disable-error-ends-disabled-and-recorded` and
  the SUB_DISABLE half of `interrupted-exception-replay-still-records-txn`.
  The app table of `every-divergence-explained-by-spock-records` is off in
  this variant.
- **Two-phase writers (workload option):** `max_prepared_transactions > 0`
  on every node for `prepared-commit-ts-matches-sent-ts`; the writer always
  finishes what it prepares.
- **Optional phantom sync standby (`v2/phantom-sync-standby`):** one subscriber with
  `synchronous_standby_names = 'phantom'` and no standby; clients on that node
  use `synchronous_commit = local`. Spock's hold path checks only that sync
  standbys are defined, so the hold list grows and the provider slot should
  never advance; L9 (`get_flush_position` resetting `flushpos = recvpos`)
  would advance it. Probably deterministic: confirm with TAP first. Hosts
  `sync-standby-hold-freezes-provider-confirmed-flush`. Keep `v2/standby`
  (n1-n3 plus a sync physical standby of n2, `sync_replication_slots = on`,
  a sixth container) for `promoted-subscriber-standby-has-every-confirmed-txn`.
- **Soak or `v2/standby`:** `apply-worker-memory-bounded`.
- Existing plans: `v2/mixed-version`, `v2/mixed-pg-major`, `v2/cascade`,
  `v2/colliding-names`.

## Assumptions

- PG18 with the pgEdge patches is the target build. The user's notes say
  pg18a is the patched local build, and the version-switching TAP tests need
  PG18.
- The base image `ghcr.io/pgedge/base-test-image` can be pulled at build time,
  or the Rocky 9 base in `tests/docker/Dockerfile-base.el9` can be built
  locally. The image is built before submission, so network access during the
  Antithesis run is not needed.
- PG source and pinned patches can be fetched at image build time. The
  existing Dockerfile clones the PG tag over the network, and spockbench is
  cloned from master without a pinned version.
- Whether Antithesis "node stop" (graceful termination) sends the compose
  `stop_signal` is not stated in the docs; `stop_signal: SIGINT` is set on
  that assumption.

## Open Questions

- **Are node termination and clock jitter enabled for this tenant?** The
  highest-value crash and clock leads depend on them. The test-command and
  custom-fault helpers above are required either way, but without node
  termination the only kills are the ones the workload chooses.

  Human answer: Not yet, but should be done in a later phase

- **What does node termination do to the filesystem?** Does it keep writes
  that were fsynced, and does it drop writes that were not (page cache)? If
  unfsynced data survives a kill, a short `resource.dat`, fsync-ordering
  mistakes and the async-commit window are reachable only when the process
  itself dies mid-write, and power-loss style bugs cannot be reached. The L1
  redo path does not depend on this.

  Human answer: We expect fsynced WAL to be able to be replayed

- **What clock-skip sizes and durations does Antithesis use?** The docs show
  only a 65 ms jump undone one second later. L3 needs a backward skip larger
  than a restart plus crash recovery plus one write (several seconds); equal
  timestamps and the Assert need only small skips. If skips are small, build
  the libfaketime custom fault.

  Human answer: Claude decision

- **Which `exception_behaviour` should runs use?** The default `transdiscard`
  silently drops whole transactions on a misclassified error, which is itself a
  property target. `sub_disable` makes such errors visible but stops
  replication. A reasonable plan: run with `transdiscard` and assert that
  `spock.exception_log` gets no rows outside the expected-exception registry,
  plus a planned `sub_disable` variant. This needs human input.

  Human answer: transdiscard should be the default, later also test sub_disable.

- **Should Spock reject or warn when `apply_idle_timeout <= wal_sender_timeout / 2`,
  or send its own periodic feedback?** A user who raises
  `wal_sender_timeout` beyond the documented 5 minutes gets the same
  reconnect churn in production. Question for the team.

  Human answer: it is expected to not be perfect, but the "/ 2" gives us some
  reasonable cushion.

- **SUT assertion route:** C++ SDK shim or fallback JSONL writer?

- **Is a physical standby (failover slots, sync-standby feedback hold) in
  scope?** It would add a sixth container. The leads are real (the
  sync-standby hold is overwritten in `send_feedback()`), but they are a
  different subsystem. The suggestion is a later, separate topology; the
  phantom sync-standby setting above probes L9 without one.
- **Should a second test configuration use subscription or slot names ending
  in `_<digit>`** to reach the slot-group code path? Users can hit it by
  accident, but it splits one stream across walsenders. Planned as
  `v2/slot-groups`.

  Human answer: post-v1 here we can use physical standbys
