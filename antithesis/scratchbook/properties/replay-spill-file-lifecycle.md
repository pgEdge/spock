# replay-spill-file-lifecycle

## Summary

Every remote transaction the apply worker receives is queued for a possible
in-process replay. Once the queued bytes pass `spock.exception_replay_queue_size`
(default 4 MB, `src/spock.c:1406-1418`), later messages are written to a
temporary `BufFile` (`BufFileCreateTemp(true)`, `src/spock_apply.c:5041-5063`).
So **every large remote transaction creates a temp file on every subscriber**,
not only failed ones. The queue and file are released in
`apply_replay_queue_reset` (`:4935-4962`) from `handle_commit` (`:1248`).
On replay after an exception, entries are read back from the file
(`apply_replay_spill_read_entry`, `:4876-4925`).

This code is new and marked unproven: "XXX: keep DEBUG1 logging until
spill-to-disk code is proven stable" (`:4984, 4994, 5055, 5103`). It already
had a use-after-free (`f84b853d`) and a CodeRabbit fix round (`1a4d76dc`).
Lead L29.

Resource concerns:

- **Lifetime**: a spill file must not outlive its transaction. `interXact=true`
  temp files are not tied to a resource owner. They are removed by
  `BufFileClose` (reset), at process exit (`AtProcExit_Files`), or by
  `RemovePgTempFiles` at postmaster restart (if
  `remove_temp_files_after_crash=on`, the default). Checked 2026-10-13: every
  COMMIT that `handle_commit` processes reaches `apply_replay_queue_reset`
  (`:1248`) unless it raises the SUB_DISABLE ERROR (`:1083`) or exits the
  process (`:1238`), and every way out of `apply_work`'s loop either ends the
  process or re-enters it to replay the **same** transaction. So in a live
  worker the file cannot outlive its transaction (see the Investigation Log).
- **Size**: the file is as large as the transaction (minus 4 MB). With
  `temp_file_limit` set, an oversize transaction raises 53400
  (`ERRCODE_CONFIGURATION_LIMIT_EXCEEDED`); on a full disk, 53100. Both are
  class 53, so the classifier treats them as transient: retry every 5 s, for
  ever, re-streaming the same transaction each time. That is safe for data but
  a liveness trap that nothing reports. The retry-for-ever is deliberate (the
  class 53 comment at `src/spock_apply.c:~3990` says so), but no user doc says
  a transaction larger than `temp_file_limit` stalls its subscription, and the
  release notes (`docs/spock_release_notes.md:108-111`) still say an
  allocation failure "falls back to `spock.exception_behaviour`", which the
  class 53 rethrow no longer does. A short write leaves
  `apply_replay_spill_count` higher than the records written (the counter goes
  up before the write, `:4863`). On replay, a short read raises
  `elog(ERROR, "corrupt replay spill file")` with SQLSTATE XX000
  (`:4894, 4908`), which is **not** transient, so under SUB_DISABLE the
  subscription is disabled for a disk problem.

## Property

Replay spill files exist only while their transaction is being applied. After
the cluster quiesces, no apply-worker temp files remain, and the spill and
read-back path is exercised under faults without reporting a corrupt file.

## Assertions (all missing)

1. Workload-side `Always(n == 0, "no apply-worker temp files after quiesce")`:
   on each node, `SELECT count(*) FROM pg_ls_tmpdir() t JOIN pg_stat_activity
   a ON t.name LIKE 'pgsql_tmp' || a.pid || '.%' WHERE a.backend_type LIKE
   'spock apply%'`, after every subscription has passed a `sync_event` barrier.
   Checked: Spock leaves `bgw_type` empty, so PG18 copies `bgw_name` into it
   (`bgworker.c:692-695`), and `backend_type` is `spock apply <db>:<subid>` /
   `spock sync <table> <db>:<subid>` (`src/spock_worker.c:170-191`).
   `application_name` is set to the same string. Include `spock sync%` too:
   sync workers spill in catch-up through the same `apply_work`.
2. SUT-side `Reachable("replay queue spilled to disk")` at `:5051` and
   `Reachable("replay read back a spilled entry")` at `:4922`. These are
   exploration markers, so a run that never spills, or never replays from a
   spill, is visible as a coverage gap.
3. SUT-side `Unreachable("corrupt replay spill file")` at `:4894` and `:4908`
   (two messages, header and body). Corruption without a disk fault is a bug.
   With disk-fault injection, scope it out or tie it to the injected fault.

## Fault requirements

- Large transactions (> 4 MB of change data; or lower the GUC to 1 MB as the TAP
  harness does in `SpockTest.pm`) that hit a real data error, so replay reads
  the spill file back.
- Partition / provider restart / SIGTERM during a large transaction (temp file
  open when the worker reconnects or exits).
- Optional: disk-full or `temp_file_limit` variant for the class 53 retry loop.

## Open questions

- None remaining. Both questions were resolved on 2026-10-13; see the
  Investigation Log. A doc gap remains (no user doc says an oversize
  transaction stalls its subscription; release notes describe the old
  allocation-failure behaviour), which is a note for the docs, not this
  property.

### Investigation Log

#### Is retrying a spill-induced 53100/53400 for ever the intended behaviour?

- Examined: `apply_work` PG_CATCH class 53 branch (`src/spock_apply.c:~3975-3995`),
  PG18 `errcodes.txt` (53100 `disk_full`, 53400
  `configuration_limit_exceeded`), `docs/configuring.md:201-212`,
  `docs/spock_release_notes.md:98-120`.
- Found: the code comment says resource exhaustion is retried on purpose and
  names this case: "A shortage that never clears -- a disk kept full by a bulk
  load -- retries indefinitely instead of discarding: human intervention, but
  a restarting worker rather than data loss." Both 53100 and 53400 are class
  53. User docs do not mention `temp_file_limit` or the stall, and the release
  notes still say allocation failure falls back to `exception_behaviour`.
- Conclusion: resolved. Intended behaviour. The property is unchanged. The
  stale release-note line and the missing "oversize transaction stalls" note
  are doc gaps.

#### Can the worker leave `apply_work`'s inner loop and come back (same process) with a spill file still open?

- Examined: `apply_work` (`:3398-4160`), the idle-timeout path (`:3548-3562`),
  `handle_commit` (`:911-1260`) for early returns, `apply_replay_queue_reset`
  (`:4934-4962`), `apply_replay_queue_next_entry` (`:4970-5010`), the SUB_DISABLE
  return in PG_CATCH.
- Found: the idle timeout raises `ERRCODE_CONNECTION_FAILURE`, which PG_CATCH
  rethrows, so the process exits. Other ways out (`got_SIGTERM`, postmaster
  death, connection loss, class 40P01/55P03/53 rethrow, "error during exception
  handling" rethrow, SUB_DISABLE `return`) all end the process. The only
  same-process re-entry is `goto stream_replay` after the first data error,
  which replays the same transaction from the queue. `handle_commit` has no
  early return before the reset except the SUB_DISABLE ERROR (process then
  exits) and the sync-worker `proc_exit(0)`. When the queue drains,
  `apply_replay_queue_next_entry` only clears `apply_replay_mode`; the file is
  closed at the following COMMIT. On exit, PG closes and deletes `interXact`
  temp files at process exit, and the postmaster removes leftovers after a
  crash restart.
- Not found: any path that keeps the file across two remote transactions in
  one process.
- Conclusion: resolved: no. After quiesce (every worker past a COMMIT and
  idle) assertion 1 should see zero apply/sync temp files. A hit means a real
  lifetime bug.
