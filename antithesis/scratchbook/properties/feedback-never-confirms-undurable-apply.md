# feedback-never-confirms-undurable-apply — Flush feedback never confirms a transaction the subscriber has not durably applied

## Synthesis note

Merged from `feedback-never-confirms-undurable-apply` (F4) and
`feedback-never-confirms-past-inflight-transaction` (F9). Both state one rule
for `send_feedback()`: the flush position reported to the provider must never
pass a provider transaction that is not durably committed on the subscriber.
F9 checks the in-flight case (inside an uncommitted remote transaction,
keepalive `endpos` reported as flush); F4 checks the committed-but-unflushed
case (async apply commit, and the new worker's initial report of
`origin_startpos` read without a flush after a graceful worker exit) and the
sync-standby hold (L9, needs a standby).

Kept as one property with three distinctly named SUT-side `Always` checks in
`send_feedback()` / `request_initial_status_update()`: (1) in-flight
transaction not passed, (2) no `lsn_mapping` entry with unflushed `local_end`
passed, (3) initial report's origin `local_lsn` is flushed. Companions:
`Sometimes("feedback sent while inside a remote transaction")` and
`Sometimes("apply worker restarted while its origin local_lsn was unflushed")`.
Both focuses chose `Always`. F9 expects (1) to hold (guard); F4 suspects (3)
fails after a graceful exit followed quickly by a node kill.

## Investigation update (2026-10-13)

- **Stock-PG assumptions confirmed on PG18.** `REL_18_STABLE`
  `snapbuild.c:306` (`ptr < builder->start_decoding_at`, strict) and
  `decode.c` `DecodeTXNNeedSkip` (:1296-1300) test the commit record's
  start (`buf->origptr`), which is the `commit_lsn` Spock sends in BEGIN.
  `walsender.c` `XLogSendLogical` sets `sentPtr = EndRecPtr` only after
  `LogicalDecodingProcessRecord` returns (:3485-3487); keepalives use
  `sentPtr` (:4116-4125). The pgEdge PG18 patches do not touch
  `snapbuild.c`, `decode.c` or `walsender.c`. So check (1) is a guard that
  should hold.
- **Stock PG18 apply has the same empty-mapping behaviour.** `worker.c`
  `send_feedback` (:3878-3885: `if (!have_pending_txes) flushpos = writepos
  = recvpos`) and `origin_startpos = replorigin_session_get_progress(false)`
  (:4593). Spock adds only the explicit `request_initial_status_update`
  report on top.
- **No flush on the restart path.** `grep XLogFlush src/*.c` finds only
  `spock_apply.c:1221` (replay stop), `spock_sync.c:1937`, `spock_rmgr.c:248`
  and the PG15/16 branch of `spock_create_sync_event`; none runs between a
  worker exit and the next worker's initial report
  (`spock_apply_main` :4699-4778). Worker exit (`before_shmem_exit`,
  `ShutdownPostgres`) does not flush either.
- **The hazard depends on a setting.** `spock.synchronous_commit`
  (default `false`, `src/spock.c:1231-1237`) maps to `synchronous_commit =
  local` when true (`spock_apply.c:4700-4702`). With it on, apply commits
  are flushed before `handle_commit` returns and check (3) cannot fail.
  The workload should keep the default (or randomise it and only expect
  firings with it off).
- **Keepalive during replay is safe by stream order.** Replay reads only the
  local replay queue (`apply_work` :3693-3700); 'k' is processed only from
  the live socket, in stream order, so a keepalive whose `endpos` passes T's
  commit is read only after T's COMMIT message has been handled.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability (property finding), antithesis-fit CW3, wildcard W8); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 (sync-standby part: v2/standby) · Faults: worker exit then node kill within flush delay, thread pause

- Evaluation note (2026-10-13): check (3) needs the old worker's async apply commits still unflushed when the new worker starts; client commits on S with `synchronous_commit = on` flush them, and a clean exit restarts only after `restart_delay_default` (5 s). So: a phase with no client writes on S, `sub_disable` then `sub_enable` back to back as the exit (enable wakes the manager), a run variant with `wal_writer_delay` raised (5-10 s), and the follow-up kill from the crash helper. The sync-standby part of check (2) can be reached without a standby container: `synchronous_standby_names = 'phantom'` on one subscriber (clients there use `synchronous_commit = local`); confirm with TAP first.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-c-provider-dml.md` and `evaluation/synthesis.md`.

- L9 has a second path: every apply worker start sends
  `request_initial_status_update(origin_startpos)` as flushed
  (`src/spock_apply.c:4778`) with no sync-standby check, and the in-memory
  hold list is gone after a restart. The SUT-side held-entry check of
  check (2) cannot see that path. Both paths are owned by
  `sync-standby-hold-freezes-provider-confirmed-flush` (phantom standby
  variant, no sixth container); the end-to-end failover outcome is
  `promoted-subscriber-standby-has-every-confirmed-txn` (`v2/standby`).
  Check (2) here stays as the SUT-side detector for path 1.

## Open questions

- Is there any WAL flush between the old worker's last commit and the new worker's initial feedback report? `(partial: none in spock's exit/start path or in PG18 worker exit; only spock.synchronous_commit=on closes the window; not yet shown in a run)`
- Is `flush = recvpos` with an empty mapping right after a worker restart accepted (it matches stock PG18 worker.c), limiting a fix to the explicit initial report? `(needs human input)`
- Is unconditional keepalive feedback during `sub_disable` replay intended? `(needs human input)` `(partial: safe by stream order — keepalives are read only from the live socket, after earlier messages)`

## Source: `feedback-never-confirms-undurable-apply` (F4 Protocol)

### Summary

The flush position an apply worker reports to the provider's walsender
(standby status update `'r'`) becomes the provider slot's `confirmed_flush`.
Once confirmed, the provider never resends anything at or below it. So the
subscriber must never report a flush position at or past the end LSN of a
provider transaction whose local commit is not yet durable on the subscriber
(and, with a synchronous standby on the subscriber, not yet on that standby).
If it does, a subscriber crash in the window loses that transaction for good,
with no `exception_log` row.

### Code paths

- `send_feedback()` `src/spock_apply.c:3237-3325`. Called after every batch of
  messages (`:3832-3845`, suppressed under `use_try_block` for
  TRANSDISCARD/SUB_DISABLE) and on every keepalive `'k'` (`:3758-3769`, never
  suppressed).
- `get_flush_position()` `:3082-3118`: walks per-process `lsn_mapping`
  (local_end, remote_end) pushed by `handle_commit` (`:1104-1110`); entries
  whose `local_end <= GetFlushRecPtr()` are reported and removed. If the list
  is empty it returns true and `send_feedback` reports `flush = recvpos`
  (`:3260-3267`), i.e. the latest LSN received from the provider.
- Sync-standby hold: `append_feedback_position()` `:3141-3178`,
  `get_feedback_position()` `:3187-3234` — lead L9 in sut-analysis: the hold's
  result is overwritten by the following `get_flush_position()` call.
- **New observation (this focus): `request_initial_status_update()`
  `:3352-3375`, called at `:4778` right after `START_REPLICATION`, sends
  `write = flush = apply = origin_startpos`.** `origin_startpos` comes from
  `replorigin_session_get_progress(false)` (`:4751`). In stock PG
  (`origin.c` `replorigin_session_get_progress`, checked in a PG18 source tree)
  `flush=false` means it does **not** `XLogFlush(local_lsn)`; it returns the
  in-shared-memory `remote_lsn`. The walsender handles any `'r'` with
  `LogicalConfirmReceivedLocation(flushPtr)` (`walsender.c`
  `ProcessStandbyReplyMessage`).
- Apply runs with `synchronous_commit=off` (`src/spock_apply.c:4699-4716`), so
  a committed apply transaction's WAL may sit unflushed for up to about
  3 x `wal_writer_delay`.
- Introduced by 2f9a686c (removed the checkpoint hook; added the forced
  keepalive "on apply-worker reconnect").

### Failure scenario (new lead, unconfirmed)

1. Apply worker W1 commits remote txn T (async commit). The origin's shared
   memory state now has `remote_lsn = T.end_lsn`, `local_lsn = T's local commit
   end`, which is not yet flushed.
2. W1 exits without a postmaster restart: connection-class error (restart after
   `restart_delay_default` 5 s), SIGTERM from `sub_disable`/`sub_enable`,
   `apply_idle_timeout`, readonly FATAL, or an unclassified ERROR after BEGIN
   (restart after about 1 ms, lead L23). Replication origin state lives in
   shared memory and survives the worker exit.
3. Manager starts W2. W2 reads `origin_startpos = T.end_lsn` and immediately
   sends `flush = T.end_lsn`. The provider confirms it.
   - The same thing happens on W2's first keepalive even without step 3's
     explicit message: `lsn_mapping` is per-process and empty, so
     `flush = recvpos` (the provider's `sentPtr`, at or past `T.end_lsn`).
4. The subscriber postmaster crashes before the walwriter flushes T's commit.
   Crash recovery does not have T. The subscription origin goes back below
   T.end. W3 asks to start at the old origin; the provider starts at
   max(requested, `confirmed_flush`) = past T. T is never applied. No
   exception, no log line.

The window is narrow (worker restart and postmaster crash both inside the
walwriter flush delay), which is the kind of timing Antithesis can hit with
node kill plus CPU/I/O slowdowns. It belongs to bug-history Pattern B ("LSN from
the wrong stream or wrong end"), same family as 5f654e34 (sync standby sent a
non-durable LSN as confirmed_flush -> loss after failover).

Stock PG's own apply worker has the empty-`lsn_mapping` behaviour in its
`send_feedback`; whether that is accepted upstream is not known. Spock adds the
explicit initial report on top of it.

### Invariant and instrumentation (all missing; no Antithesis assertions exist)

- SUT-side `Always` in `send_feedback()` just before `PQputCopyData`:
  "reported flush is below every pending local commit": for every entry in
  `lsn_mapping` with `local_end > GetFlushRecPtr(NULL)`,
  `flushpos < entry.remote_end`; and if `SYNC_STANDBY_DEFINED`, for every entry
  still held in `sync_replica_lsn`, `flushpos < entry.remote_recvpos`.
- SUT-side `Always` in `request_initial_status_update()` and on the first
  `send_feedback()` of a process whose `lsn_mapping` is empty: the session
  origin's `local_lsn` (readable via `SELECT local_lsn FROM
  pg_replication_origin_status WHERE external_id = <slot>` inside the startup
  transaction) is `<= GetFlushRecPtr(NULL)`. This is exactly the condition
  `replorigin_session_get_progress(true)` would enforce.
- `Sometimes(apply worker restarted while its origin local_lsn was unflushed)`
  to prove the window is reached.
- Workload-side effect check is the exactly-once/no-loss ledger (S4); this
  property gives the direct cause.

### Fault requirements

- Graceful apply-worker exit (`pg_terminate_backend` on the apply pid, toggling
  `sub_disable/sub_enable`, provider disconnect) followed within a short window
  by subscriber postmaster kill (node termination).
- Slow I/O or CPU starvation widening the async-commit flush delay.
- L9 sub-case needs a physical sync standby on the subscriber (not in the v1
  topology).

### Original open-question notes (detail for the combined list above)
- Does a bgworker exit or the manager's restart path flush WAL anywhere before
  the new worker reads the origin? Code reading found no `XLogFlush` in the
  apply start path (`grep XLogFlush src/*.c`: only `:1221` replay-stop and
  sync paths). If something does flush, the new lead closes and only L9
  remains. Worth a targeted TAP test (terminate apply backend, then
  `pg_ctl stop -m immediate` within 100 ms, with `wal_writer_delay=10s`).
- Is reporting `flush = recvpos` with an empty mapping right after a worker
  restart considered acceptable (it matches stock PG)? If yes, the fix scope is
  only the explicit initial report; if no, the empty-mapping branch also needs a
  durable floor.

## Source: `feedback-never-confirms-past-inflight-transaction` (F9 Idempotency)

### What the property says

While an apply (or table-sync catch-up) worker is inside a remote transaction
it has not yet committed, the flush position it reports to the provider is
never at or beyond that transaction's commit record. Equivalently: the
provider is never told to skip a transaction the subscriber has not applied.

This is the guard on the "origin LSN skip rule" side of redelivery. The
provider resumes at max(requested start, slot `confirmed_flush`), and logical
decoding skips a transaction when its commit record LSN is **strictly less**
than the start point. Spock's at-least-once delivery depends on
`confirmed_flush` never passing an unapplied commit.

### Why it matters

A flush report that passes an in-flight transaction turns any later
reconnect, worker restart or crash into **silent loss** of that transaction:
no exception_log row, no conflict, and the origin moves past it as soon as the
next transaction commits. Spock's feedback code is a copy of stock PG's
pattern with extra paths (sync-standby hold, exception-replay suppression,
keepalive handling in replay mode, slot groups), and lead L9 already shows the
sync-standby hold being overwritten in this function.

### Code paths (code-checked)

- `send_feedback` (`src/spock_apply.c:3237-3300`): if `get_flush_position`
  finds no outstanding `lsn_mapping` entries, it reports
  `flushpos = writepos = recvpos` (`:3260-3268`).
- Callers:
  - after every received batch with `last_received` (`:3842`), unless
    `use_try_block` and not DISCARD;
  - on every walsender keepalive 'k' with the keepalive's `endpos`
    (`:3767`), **unconditionally**, including during exception replay and in
    the middle of a remote transaction.
- `last_received` grows from each 'w' header (`:3700-3710`); for a change
  message that is the change's LSN, which is below the commit record.
- Keepalive `endpos` is the walsender's `sentPtr`. For a logical walsender
  `sentPtr` is updated only after `LogicalDecodingProcessRecord` returns, so
  while the commit record of T is being decoded and T's changes are being
  written, `sentPtr` is still the end of the previous record, which is
  `<= T.commit_lsn`. A flush report of `T.commit_lsn` does not skip T because
  the skip test is strict. **The property depends on both of these stock-PG
  details** (sut-analysis Assumption 2).
- `lsn_mapping` entries are pushed in `handle_commit` only after commit
  (`:1102-1108`); the sync-standby path keeps separate entries
  (`append_feedback_position`, `get_feedback_position`, `:3142-3236`).
- Slot groups (L10) change what the walsender sends (members skip
  transactions claimed by another member), so a `sentPtr` beyond an unsent
  transaction is possible there; v1 avoids slot-group names.

### Failure scenario (what the assertion would catch)

- A keepalive arrives mid-transaction with an `endpos` beyond T's commit (for
  example from a walsender path that updates `sentPtr` early, a PG minor-version
  change, or a skipped/filtered transaction keepalive), `lsn_mapping` is empty,
  and `send_feedback` reports it as flushed. The provider's slot moves past T.
  Then a partition or worker restart before T commits: T is never re-sent.

### Assertion

SUT-side, **missing** (no existing assertions). In `send_feedback`, just
before building the reply:

`Always("feedback flush position does not pass the in-flight remote transaction")`
with condition
`!in_remote_transaction || flushpos <= replorigin_session_origin_lsn`
(in `handle_begin`, `replorigin_session_origin_lsn` holds T's BEGIN
`commit_lsn`, `:686`; it is changed to `end_lsn` only in `handle_commit`).

`Always` fits: the condition must hold on every feedback message.

A companion `Sometimes("feedback sent while inside a remote transaction")`
(missing) shows the interesting state is reached, so a passing `Always` is not
vacuous.

### Antithesis angle

- Large transactions (many rows, above `logical_decoding_work_mem`) keep the
  walsender in its write loop where it sends keepalives
  (`WalSndKeepaliveIfNecessary` when the output buffer is full).
- Network latency / congestion and thread pausing make the output buffer fill,
  so keepalives interleave with the transaction's changes.
- Exception replay (a real data error in a large transaction) exercises the
  replay-mode 'k' path.

### Original open-question notes (detail for the combined list above)
- Is the strict skip test (`commit ptr < start_decoding_at`) and the late
  `sentPtr` update the same in the patched PG18 tree? Assumed from stock PG;
  not re-read here. If either differs, this property may fail without any
  Spock change, which is still worth knowing.
- During SUB_DISABLE replay, feedback from batches is suppressed but 'k'
  feedback is not. Is that intended? Under the reasoning above it is safe;
  confirm with the owner. `(needs human input)`

### Investigation Log

_Entries carried over from `feedback-never-confirms-undurable-apply`:_

#### Is `origin_startpos` durable when it is reported?

- Examined: `src/spock_apply.c:4745-4778`, `:3352-3375`; stock PG18
  `src/backend/replication/logical/origin.c:1260-1276`,
  `walsender.c:2434-2516`.
- Found: `replorigin_session_get_progress(false)` returns shared-memory
  `remote_lsn` without flushing `local_lsn`; the value is reported as flush
  with `replyRequested=1`; walsender confirms it.
- Not found: any flush between the previous worker's last commit and this
  report.
- Conclusion: mechanism present in code; reachability under faults unconfirmed.

#### Are the strict decoding skip test and the late `sentPtr` update unchanged in patched PG18?

- Examined: `~/dev/pg/postgresql` `origin/REL_18_STABLE`: `snapbuild.c:306`,
  `decode.c:1296-1300`, `walsender.c:3450-3528, 4116-4125`;
  `patches/18/*.diff` file list.
- Found: strict `<` against the commit record start; `sentPtr` updated after
  the record is processed; patches do not touch these files.
- Conclusion: resolved; assumption holds on PG18.

#### Any WAL flush between old worker's last commit and new worker's report?

- Examined: `grep XLogFlush src/*.c`; `spock_apply_main`
  (`src/spock_apply.c:4690-4778`); `spock_apply_worker_shmem_exit`
  (:2305-2325); `spock.synchronous_commit` GUC (`src/spock.c:1231`).
- Found: no flush on the path; `spock.synchronous_commit=on` would close it.
- Not found: a run showing the loss.
- Conclusion: still partial (reachability).

#### Is `flush = recvpos` with an empty mapping accepted?

- Examined: PG18 `worker.c` `get_flush_position` / `send_feedback`
  (:3499-3540, :3865-3885), `run_apply_worker` (:4593).
- Found: identical behaviour in stock PG.
- Conclusion: `(needs human input)`; stock parity noted.

#### Is keepalive feedback during `sub_disable` replay intended?

- Examined: `apply_work` (`src/spock_apply.c:3680-3770`).
- Found: replay reads queued 'w' entries only; 'k' comes from the socket in
  order.
- Conclusion: safe by reasoning; intent still `(needs human input)`.
