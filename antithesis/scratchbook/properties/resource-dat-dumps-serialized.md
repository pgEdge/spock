# resource-dat-dumps-serialized

## What led here

Concurrency note F6, sut-analysis lead L16 and V7. Re-read at HEAD 69d9228f.
Not run.

## Code path

`spock_group_resource_dump` (`src/spock_group.c:534-611`):

1. `OpenTransientFile("$PGDATA/spock/resource.dat.tmp", O_CREAT|O_WRONLY|O_TRUNC)`
   — one fixed temp name for every writer.
2. `apply_group_master_lock` **SHARED** while writing header and entries
   (`:576-590`). Two dumpers can hold it at once.
3. `pg_fsync`, close, `durable_rename(tmp, resource.dat, LOG)`; on failure
   `ereport(ERROR, "could not rename ...")` (`:605-610`).

Callers (different processes):

- supervisor on exit (`src/spock.c:895`);
- `spock_group_progress_update_list` (`src/spock_group.c:714-741`) from
  `copy_tables_data` (`src/spock_sync.c:1309`) — every COPY finish, both table
  resync (sync worker) and initial sync (apply worker);
- `spock_group_progress_force_set_list` (`src/spock_group.c:755-823`) from
  initial sync of an add_node subscription (`src/spock_sync.c:1736`).

Interleavings:

- A and B both open the temp file (same inode). B's `O_TRUNC` cuts A's partial
  write; each fd keeps its own offset, so the file ends up correct only once
  both finish. A renames it to `resource.dat` while B is still writing. A
  postmaster crash at that moment leaves a short `resource.dat`.
- B's rename then fails (ENOENT) -> ERROR **after** B's COPY committed. In a
  sync worker this is inside `PG_ENSURE_ERROR_CLEANUP` (drops slot and origin;
  status stays `d`, which turns into FAILED or a disabled subscription on
  restart).
- Hash content can change between A's and B's walks (exclusive updates between
  them), so A may rename a file whose header count disagrees with the entries
  B later wrote over it.

Load (`spock_group_resource_load`, `src/spock_group.c:621-704`) runs in
`shmem_startup_hook` in the postmaster. `read_buf` (`src/spock_common.c:604-640`)
raises ERROR on a short read ("could not read file ... read X of Y"), which in
the postmaster at startup stops the node from starting until someone deletes the
file. No CRC (`XXX: Do we need any kind of CRC here?`).

## Invariant

- Suggested SUT-side assertion (**missing**): a shared atomic "dumpers inside"
  counter incremented on entry to `spock_group_resource_dump` and decremented
  on exit; `Always(counter_after_increment == 1, "resource.dat dump has a single
  writer")`. `Always` because the temp-file protocol is only safe with one
  writer.
- Suggested SUT-side `Unreachable("resource.dat temp rename failed")` at the
  `durable_rename` failure branch (`:606`).
- Suggested SUT-side `Unreachable("resource.dat short read at startup")` at the
  short-read path when the file name is `resource.dat` (or in
  `spock_group_resource_load` around `read_buf`).
- Workload-side `Always("node restarts after kill")` is shared with the
  restartability property (V7); this property only adds the dump-side
  assertions.

## Fault / timing requirements

- Concurrent dumpers on one node. The v1 add_node runs a single initial sync on
  n4, so it alone does not produce two dumpers. Reaching it needs one of:
  - two table resyncs on the same node finishing together (e.g. n1 resyncs one
    table from n2 and another from n3 at once);
  - a node shutdown (supervisor dump) while a resync's COPY is finishing;
  - an add_node whose initial sync finishes while a table resync runs on n4.
- Node termination shortly after, to turn a short file into a startup failure.

## Findings from open-question investigation (HEAD 69d9228f, code read, not run)

- **`resource.dat` is a startup seed, not the source of truth.** The design
  note `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`
  ("Design overview" and "Startup flow") and the header comment of
  `src/spock_group.c:11-45` say replication origins are authoritative for
  `remote_commit_lsn`; each apply worker reconciles its entry against its
  origin at start (`reconcile_progress_with_origin`), clearing stale
  timestamps and recovering `remote_commit_ts` from `pg_commit_ts`. The file
  only preserves timestamps across a clean restart and seeds entries. Missing
  file is treated as normal ("normal on first boot or after crash"), and
  version / system-id mismatches are skipped with a WARNING
  (`src/spock_group.c:646-680`).
- **So a short file stopping the node is inconsistent with the design.**
  A truncated file still raises ERROR from `read_buf`
  (`src/spock_common.c:604-640`). The load runs in `shmem_startup_hook` in the
  postmaster, where there is no error handler, so the ERROR becomes FATAL and
  the node does not start until someone deletes the file. The
  `Unreachable("resource.dat short read at startup")` therefore stands as a
  plain bug, regardless of how important the content is.
- **A further consequence of interleaved writers.** If the hash grew between
  two dumpers' walks, the file can hold entries from both at the same offsets,
  including the same key twice. The loader then hits `Assert(!ret)`
  (`src/spock_group.c:697`) — in a cassert build that aborts the postmaster at
  startup. Non-cassert logs a WARNING.
- **Rename failure during initial sync disables the subscription.** The dump
  from `copy_tables_data` (`src/spock_sync.c:1309`) and from
  `spock_group_progress_force_set_list` (`:1736`) run inside the sync's
  `PG_ENSURE_ERROR_CLEANUP`. During add_node, an ERROR there leaves the
  subscription in status `d`, so the next apply-worker start disables it as a
  "nonrecoverable step" (`initial-sync-ends-ready-or-visibly-disabled`). In a
  table resync it ends as FAILED.
- **Shutdown overlap is narrowed but not removed.** The supervisor's exit
  callback waits up to 5 s for apply/sync workers to detach before dumping
  (`src/spock.c:862-897`). A sync worker that keeps running past that (e.g.
  slow fsync, paused process) can still overlap.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (value underestimated), wildcard W7); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (admin-churn phase with concurrent resyncs) · Faults: concurrent resyncs, node kill, graceful stop

- Priority note: raised from P2 in evaluation: two writers to one fixed temp file plus a kill right after is a race plus crash timing that TAP cannot place, and the outcome is a node that will not restart without manual file removal. Conditional on the admin-churn phase running concurrent resyncs on two subscriptions of one node (throwaway subscriptions with their own tables).

## Open questions

- How often do two dumps on one node actually overlap (two table syncs
  finishing within the few milliseconds a dump takes)? Only one sync worker
  runs per subscription at a time (`process_syncing_tables` starts one only
  when none is running, `src/spock_apply.c:4615-4628`), so overlap needs two
  subscriptions on the same node resyncing at once. Needs a run to measure.
  `(partial: reachable by design with two concurrent resyncs on different subscriptions of one node; frequency unmeasured)`
- Does Antithesis node termination drop unfsynced writes (page cache)? If it keeps them, a short
  `resource.dat` and fsync-ordering mistakes in `durable_rename` are reachable only when the
  dumping process itself is killed mid-write, and power-loss style bugs cannot be reached.
  `(partial: docs say a restarted node may lose modified data or boot fresh from its image; page-cache behaviour not stated; ask the Antithesis contact)`

### Investigation Log

#### Is resource.dat monitoring-only or crash-durable dedupe state?

- Examined: `src/spock_group.c` header and load/dump, design spec
  `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md`,
  `docs/spock_release_notes.md:61-68`, `src/spock_progress_recovery.c`.
- Found: origins are authoritative; the file is a seed for timestamps and
  entries, reconciled at apply start; absent or mismatched files are
  tolerated, short files are not.
- Conclusion: resolved. Not dedupe state. A bad file should be skipped with a
  WARNING like the other mismatch cases; stopping the node is the bug.

#### How often do two table syncs on one node finish together?

- Examined: dump call sites, `process_syncing_tables` worker limit,
  supervisor shutdown drain.
- Found: one sync worker per subscription; overlap needs several
  subscriptions resyncing on one node, or a shutdown drain timeout.
- Not found: any lock that serialises dumpers (only the shared
  `apply_group_master_lock`).
- Conclusion: `(partial: reachable; frequency unmeasured, needs a run)`.
