# apply-worker-memory-bounded

## Summary

An apply worker is a long-lived process. Every message it receives is allocated
per message (`MessageContext`, `ApplyOperationContext`), per transaction
(`ApplyReplayContext`, the replay queue), or for the life of the process
(`TopMemoryContext`). Memory growth in this process has been a real bug before:
`4cb409cb` "spock_apply: bound per-message memory" fixed exception-log JSON and
tuple allocations piling up in `TopTransactionContext` (about 800 MB at 200k
rows per its TAP test `tests/tap/t/022_apply_mem_context.pl:131-152`). Related
fixes: `5147a87a`, `eb30df11`, `51ae2d84`, `dc8da680`, `f84b853d`. TAP 022 runs
one scenario on one instance with no faults. Antithesis can drive the same
process through reconnects, in-process replays, spills and long uptimes.

## Remaining growth paths found by code reading (HEAD 69d9228f)

- **Sync-standby hold list** `sync_replica_lsn` (`src/spock_apply.c:231,
  3147-3236`): `append_feedback_position` pallocs one `RemoteSyncPosition` in
  `TopMemoryContext` **per applied transaction** whenever the subscriber has
  `synchronous_standby_names` set (`handle_commit`, `:1067-1068`). Entries are
  released only when the subscriber's sync standby flush LSN passes them. Apply
  runs with `synchronous_commit=off`, so apply does not slow down while the
  standby is down or paused, and the list grows with no limit.
  `get_feedback_position` walks the **whole list** (it does not stop at the
  first entry still waiting) under `SyncRepLock` EXCLUSIVE on every
  `send_feedback`, which runs for every keepalive and after every batch of
  received messages (`:3254, 3767, 3842`). So the cost also grows: O(n) per
  feedback while holding a lock that every committing backend on that node
  needs for sync rep. Each entry is a 48-byte struct (`:218-225`), about 64
  bytes with allocator overhead, so 256 MB takes about 4 million transactions
  applied while the standby is down. Only reachable with a standby container
  (phase 2 topology). The hold list exists for failover safety: it stops the
  publisher's slot from advancing past what the subscriber's sync standby has
  flushed (`5f654e34`, #491, with TAP `020_sync_standby_feedback_lsn.pl`).
- **Spilled replay entries on the error path**: when the replay queue spills,
  each entry struct is copied into `TopMemoryContext` and the libpq buffer is
  kept, both "caller must free" after `replication_handler` returns
  (`:3725-3745`, `:5066-5090`). If `replication_handler` raises an ERROR, the
  `PG_CATCH` path (`:4040-4125`) does not free that entry. That is one leaked
  message per caught exception, which adds up in a worker that sees many data
  errors on large transactions and never restarts.
- **`lsn_mapping`** (`:173, 1109, 3085-3117`): one entry per commit until the
  local WAL flush passes it. Bounded by the flush delay, but it grows during a
  node-level I/O stall or pause.
- `remote_origin_name` and relation-cache entries in `TopMemoryContext`
  (`:690, 2569-2580`): freed or bounded by the number of relations. Recorded,
  not expected to grow.
- Replay queue: in memory up to `spock.exception_replay_queue_size` (default
  4 MB), then spills to disk (`:5041-5063`). `0` means unlimited in-memory
  queueing for any transaction size. That is an allowed configuration, so the
  harness should not set it to 0.

## Property

Under sustained load, faults, and in-process exception replays, an apply
worker's process-lifetime memory stays below a fixed bound that does not grow
with the number of transactions applied.

## Assertions (all missing)

1. SUT-side `AlwaysOrUnreachable(MemoryContextMemAllocated(TopMemoryContext,
   true) < APPLY_MEM_BOUND, "apply worker memory stays bounded")` in
   `handle_commit` after `CommitTransactionCommand()` (`:~1061`), where
   per-transaction contexts have just been reset. Suggested bound 256 MB, well
   above the 4 MB replay queue plus caches, and well below the 800 MB the
   pre-`4cb409cb` leak reached. Rate-limit the check (for example every 1000th
   commit), because `MemoryContextMemAllocated` walks the whole context tree.
   `AlwaysOrUnreachable` because some runs may not commit enough through one
   worker to evaluate it meaningfully.
2. SUT-side `AlwaysOrUnreachable(dlist length of sync_replica_lsn <
   SYNC_HOLD_BOUND, "sync-standby hold list bounded")` in
   `append_feedback_position`. Phase 2 topology only (subscriber with a sync
   standby). Expected to fire when the standby is paused for long enough.
3. Workload-side backup: sample `ps -o rss` for `spock apply` processes on
   each node (as TAP 022 does) and report
   `Always(rss_growth_kb < 500000, "apply worker RSS growth bounded")` over each
   worker's lifetime (key by PID; reset on PID change). RSS counts shared
   buffer pages the worker touches, so keep `shared_buffers` well under the
   500 MB bound in the harness config, or this check measures buffer warm-up
   rather than leaks.

## Fault requirements

- None needed for the base check. Sustained load and long uptime matter more.
- Data-error transactions larger than the spill threshold (the harness can lower
  `spock.exception_replay_queue_size` to 1 MB as TAP does) for the replay-leak
  path.
- Pause (SIGSTOP) of the subscriber's sync standby for the hold-list path.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (assertion type vs v1), wildcard W8); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: soak run or v2/standby (not v1 coverage) · Faults: long runs, data errors on large transactions, standby pause

- Evaluation note (2026-10-13): the hold-list mechanism needs a standby and about 4M transactions per worker to reach 256 MB, far beyond Antithesis workload throughput under faults; the general RSS check is a soak test. A `synchronous_standby_names = 'phantom'` subscriber grows the hold list without a standby container, but still needs a long run.
- Moved out of v1 to a soak run or `v2/standby`.

## Open questions

- Is the sync-standby hold list meant to keep growing while the standby is down,
  or should apply stop (or fall back) after some limit? If unbounded growth is
  accepted, assertion 2 becomes a capacity note and the O(n) walk under
  `SyncRepLock` becomes the main concern. `(needs human input)`
- What memory bound would the team accept for an apply worker? `(partial: TAP 022 accepts TopTransactionContext < 5 MB during exception replay and RSS growth < 500 MB, noting a legitimate ~270 MB RSS peak; no in-process bound is stated)`

### Investigation Log

#### Is the sync-standby hold list meant to grow while the standby is down?

- Examined: `append_feedback_position` / `get_feedback_position` /
  `send_feedback` (`src/spock_apply.c:3141-3265`), callers (`:1060-1061,
  3767, 3842`), `git log -S"queued sync-hold"` (commit `5f654e34`, #491),
  `docs/` for `synchronous_standby_names` (only `spock_sub_create.md` /
  `sub_mgmt.md`, about monitoring, nothing on the hold list).
- Found: the list's purpose is failover safety: feedback to the publisher is
  held until the local sync standby has flushed the matching local commit, so
  the publisher keeps the WAL. There is no limit, no fallback and no log line
  when it gets long. The walk does not stop at the first unreleased entry.
  Feedback runs once per keepalive and once per received batch, not per
  message (corrected in the Summary).
- Not found: any statement of how long the standby may be away, or of a cap.
- Conclusion: the growth follows from the design; whether a cap or fallback
  is wanted is an owner decision. Tagged `(needs human input)`.

#### What memory bound would the team accept for an apply worker?

- Examined: `tests/tap/t/022_apply_mem_context.pl:15-45, 131-200`; commit
  `4cb409cb`.
- Found: TAP 022 sets two limits: `TopTransactionContext` under 5 MB while a
  use_try_block worker applies 200k rows, and apply-worker RSS growth under
  500 MB, with a comment that the legitimate post-fix RSS peak is about 270 MB
  on a CI runner ("heap + index buffers, catalog cache, MessageContext growth
  that is only reset on commit"), and a note to tighten it later. The
  pre-fix leak was in `TopTransactionContext`, a child of `TopMemoryContext`,
  so assertion 1 (recursive `MemoryContextMemAllocated(TopMemoryContext)`)
  would have seen it. Measured right after the commit in `handle_commit`,
  per-transaction contexts are already reset, so 256 MB in-process is well
  above normal and below the old leak.
- Not found: a stated in-process bound.
- Conclusion: `(partial: ...)`. Keep 256 MB for assertion 1 and 500 MB for the
  RSS check (matches TAP 022). Owners may want to confirm.
