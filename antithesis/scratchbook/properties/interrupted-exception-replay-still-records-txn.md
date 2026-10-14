# interrupted-exception-replay-still-records-txn — A failing transaction whose replay is interrupted is still handled by policy

## Synthesis note

Merged from `interrupted-exception-replay-still-records-txn` (F3) and
`interrupted-exception-replay-resends-transaction` (F9). Same lead (L7):
`AbortOutOfAnyTransaction()` in the first-exception branch advances the session
origin to T's `commit_lsn` before replay; whether T is resent after an exit
during replay rests on the strict decoding skip test and on feedback never
passing T. Both use a poison transaction (a local-only trigger or CHECK that
fails on one subscriber) and assert the documented outcome: TRANSDISCARD
leaves exception_log rows for T's remote xid and none of T's rows;
SUB_DISABLE leaves the subscription disabled with T applied once after fix and
`sub_enable`. F3 adds a SUT-side `AlwaysOrUnreachable` on keepalive flush
during replay (overlaps `feedback-never-confirms-undurable-apply`); F9 adds
`Sometimes` markers for exit during replay and spill-file read-back. Both chose
`Always`.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW2, implementability CW6); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: worker exit during replay, partition, node kill

- Evaluation note (2026-10-13): poison transactions go to dedicated poison tables and are recorded in the expected-exception registry (origin, remote xid, table), so the "no exception rows" checks of other properties ignore them.

## Gap-fill cross-reference (2026-10-13)

The SUB_DISABLE outcome without interrupts, its bound, and lead L27 (the
disable written into a still-open remote transaction and rolled back at
exit) are owned by `sub-disable-error-ends-disabled-and-recorded`, which
also defines the `sub_disable` run variant this property's SUB_DISABLE half
needs.

## Open questions

- Is a second set of exception_log rows for the same T (after a crash once
  the replay committed, via L1) acceptable? `(needs human input)`

## Resolved (code-checked on PG 18.3 with the Spock patches applied)

The boundary the property rests on holds on PG18, so this is a **regression
guard**, not a known bug. The invariant and assertion types do not change.

- **Abort advances the session origin to `commit_lsn`.** PG18
  `RecordTransactionAbort` (`xact.c:1775-1845`) calls
  `replorigin_session_advance(replorigin_session_origin_lsn, XactLastRecEnd)`
  when a session origin is set and the transaction has an xid. No Spock patch
  touches this function (`patches/18/pg18-025-logical_commit_clock.diff`
  changes only `StartTransaction`, commit-record and redo code). So the
  first-pass `AbortOutOfAnyTransaction()` at `src/spock_apply.c:4065` moves the
  origin to T's `commit_lsn` (only if the failed attempt got an xid; with no
  xid nothing moves). Note: the comment at `src/spock_apply.c:3888` says
  "RecordTransactionAbort does not advance replorigin"; that is true only on
  the rethrow path, because `spock_apply_worker_shmem_exit` clears the session
  origin before `ShutdownPostgres` aborts. It is not true for the in-process
  abort at `:4065`.
- **A restart at exactly `commit_lsn` resends T.** PG18
  `SnapBuildXactNeedsSkip` is still `ptr < start_decoding_at`
  (`snapbuild.c:304-306`), `DecodeTXNNeedSkip` passes the commit record start
  (`decode.c:1296-1302`), and the start point is max(requested,
  `confirmed_flush`) (`logical.c:556-576`). Spock requests
  `replorigin_session_get_progress()` (`src/spock_apply.c:4751`). Equal is
  not skipped, so T comes again.
- **Keepalive feedback cannot confirm past T while T is unrecorded.** The
  walsender's keepalive position is `sentPtr`, which is updated only after a
  whole WAL record is decoded (`walsender.c:3465`); T is sent while its commit
  record is being decoded, so keepalives during T carry at most `commit_lsn`.
  The only keepalive with a different LSN is for skipped transactions
  (`walsender.c:1695-1699`), which precede T. Keepalives sent after T follow
  T's 'C' in the same TCP stream, and the subscriber reads no stream messages
  while replaying from the queue, so T's commit is handled first. Change
  messages carry `change->lsn` in their 'w' header, BEGIN carries
  `first_lsn` (`logical.c:857, 1116`), so `last_received` stays below
  `commit_lsn` until the 'C' message arrives. The `AlwaysOrUnreachable` on
  keepalive flush stays as a cheap guard against a change in walsender
  behaviour.
- **SUB_DISABLE resume at `commit_lsn` is the documented design.**
  `docs/configuring.md:172-181`: "when the subscription is enabled,
  replication will resume with the transaction that caused the exception".
  `handle_commit` keeps the origin at BEGIN's `commit_lsn` under SUB_DISABLE
  (`src/spock_apply.c:997-1009`) and the strict skip test above resends it.
  Covered by this property and by `sub-disable-enable-cycle-loses-and-duplicates-nothing`.

## Source: `interrupted-exception-replay-still-records-txn` (F3 Failure Recovery)

### What the property says

When a remote transaction T fails apply on subscriber S with a real data
error, Spock enters in-process exception replay. If that replay is cut short
(worker SIGTERM, provider disconnect, apply idle timeout, subscriber crash),
T is not lost from the stream: once S recovers, T is handled under the
configured policy exactly as if the replay had not been interrupted.

Concretely, with a "poison" transaction design:

- **TRANSDISCARD:** after quiesce, S's `spock.exception_log` has at least one
  row with `remote_xid = T's xid` and `remote_origin = provider id`, and none
  of T's rows are present on S. (A second set of rows for T is allowed: a
  crash after the replay commit can make S see T again.)
- **SUB_DISABLE:** after quiesce, the subscription is disabled, the
  subscription origin on S is below T's end LSN, and T's rows are absent;
  after the poison is removed and the sub re-enabled, T and every later
  transaction from that provider apply exactly once.

"Lost" means: T is absent on S and S has no exception_log row for T and the
subscription is enabled. That combination must never be observed.

### Why (lead L7, replay origin advance)

- First-pass failure handling: `AbortOutOfAnyTransaction()` at
  `src/spock_apply.c:4065` runs while `replorigin_session_origin` is still the
  remote node id and `replorigin_session_origin_lsn` is BEGIN's `commit_lsn`
  (`:686`). Stock `RecordTransactionAbort()` (PG17 `xact.c:1779-1808`)
  advances the **session** origin (slot origin) to `commit_lsn` in memory when
  the aborted transaction had an xid.
- So during replay the subscription origin already sits at T's commit record
  start. If the worker exits gracefully now, the next worker requests
  `START_REPLICATION ... commit_lsn`.
- The d286f3df comment (and `spock_apply_worker_shmem_exit`, `:2305-2325`)
  says an origin advanced to the in-flight `final_lsn` "silently skip[s] that
  txn on reconnect". The decoding skip rule is strict:
  `SnapBuildXactNeedsSkip()` returns `ptr < start_decoding_at`
  (PG17 `snapbuild.c:445`), and `ptr` is the commit record start, which is
  exactly `commit_lsn`. So by code reading, a restart at `commit_lsn` resends
  T. That makes this property a regression guard, not a known bug, unless
  the slot's `confirmed_flush` passed T (see next point).
- `confirmed_flush` during replay: `send_feedback()` reports
  `flush = recvpos` when `lsn_mapping` has nothing pending (`:3265-3272`).
  T never adds an `lsn_mapping` entry. The end-of-batch feedback is suppressed
  while `use_try_block` is set under TRANSDISCARD/SUB_DISABLE (`:3803-3845`),
  but the keepalive handler (`c == 'k'`, `:3741-3750`) calls `send_feedback`
  unconditionally. Keepalive `endpos` is the walsender's `sentPtr`, which
  during T's transmission is at or below T's commit record start (sentPtr is
  advanced after the record is processed). Safe by code reading, but it rests
  on walsender internals; a keepalive that reports a position past T while T
  is unrecorded would lose T for good, crash or not.
- Marker survival decides the second attempt: a graceful exit during replay
  keeps the shmem marker (`clear_transient_exception_state` returns early when
  `use_try_block` is set, `:422-428`), so the resent T goes straight to
  replay. A postmaster crash wipes the marker, so T goes through a first pass
  again and fails again. Both must end in "recorded".

### Failure scenario to explore

1. n1 commits T: 500 ledger rows plus one poison row near the end.
2. n2 applies T, hits the poison error, enters replay.
3. During replay: SIGTERM n2's apply worker / partition n1-n2 / pause n1 past
   `apply_idle_timeout` / kill n2.
4. Faults stop, quiesce, barrier n1->n2.
5. Check the invariant above.

### How to make a poison row (workload)

The workload must not use DDL during faults and must not rely on
divergent schemas. A local-only `ENABLE ALWAYS` trigger on the target node
that raises for a payload marker is the simplest choice: the trigger exists
on n2 only (created in setup before faults, AutoDDL off), fires in the apply
worker (session_replication_role=replica) because it is ALWAYS, and raises
`P0001` (a data error, not on the transient list). Origin node keeps T.
This poison design produces a known, explained divergence and exception_log
rows, so other convergence properties must exclude poison transactions.

### Assertions

- **Workload-side:** `Always("poison transaction is either applied-nowhere-and-logged
  or subscription disabled on every target node")` evaluated after quiesce for
  every poison T. Always: each evaluation must hold.
- **SUT-side (missing, no existing assertions):**
  - `Sometimes(replay interrupted before commit)` at the replay exit paths
    (`"error during exception handling"` rethrow at `:4049-4056`, SIGTERM
    break, idle timeout during `use_try_block`) so the run confirms the
    interesting state was reached.
  - `AlwaysOrUnreachable("keepalive feedback during replay never confirms past
    the failing txn")`: in the `'k'` branch, when `MyApplyWorker->use_try_block`
    and the marker's `commit_lsn` is valid, assert the flush position about to
    be sent is `<= exception_log_ptr[my_exception_log_index].commit_lsn`.
    This catches the one way the strict skip rule would not save T.

### Fault requirements

- Graceful exits: SIGTERM / `pg_terminate_backend` on apply (custom fault),
  network partition between provider and subscriber, process pause of the
  provider longer than `apply_idle_timeout` (120 s in the harness).
- Node termination for the crash variant.
- Large T so replay lasts long enough to be interrupted.

### Related properties

- `exception-replay-only-after-recorded-error` (the opposite direction: no
  replay of a transaction that did not fail).
- `sub-disable-enable-cycle-loses-and-duplicates-nothing` (SUB_DISABLE
  resume, without interruption during replay).

### Original open-question notes

Resolved; see "Resolved" above. The duplicate-rows question stays open (top
of file). If duplicates are not acceptable, tighten the Always to "exactly one
set of rows per T".

## Source: `interrupted-exception-replay-resends-transaction` (F9 Idempotency)

### What the property says

If a remote transaction T hits a real data error on subscriber S and the
in-process exception replay of T is cut short (worker exit by connection
loss, SIGTERM, `apply_idle_timeout`, FATAL, or a postmaster crash) before the
replay commits, then T is delivered again and ends in exactly one documented
outcome on S:

- `transdiscard`: T's rows are absent on S **and** `spock.exception_log` on S
  has rows for T (matched by `remote_xid` / `remote_commit_ts`);
- `sub_disable`: the subscription is disabled and its origin is below T's end,
  so T is re-applied after the fix and `sub_enable`.

T must never be silently missing (no exception_log row and no disable).

### Why it matters

The first-exception path calls `AbortOutOfAnyTransaction()`
(`src/spock_apply.c:4065`) while `replorigin_session_origin` (the origin node
id) and `replorigin_session_origin_lsn` (T's BEGIN `commit_lsn`, set at `:686`)
are still set. Stock `RecordTransactionAbort` advances the session origin to
`replorigin_session_origin_lsn` when an origin is set and the transaction has
an xid (sut-analysis Assumption 1; discovery W3 cites PG `xact.c:1805-1808`).
So the shared origin moves to T's `commit_lsn` before the replay has done
anything.

Spock's own comment on `spock_apply_worker_shmem_exit`
(`src/spock_apply.c:2305-2325`) says an abort that advances the origin to the
in-flight transaction's LSN means "silently skipping that txn on reconnect",
and fixes it for the worker-exit path only. The in-process path does not clear
the origin first.

Whether the skip really happens depends on one boundary:

- The origin is at T's `commit_lsn` = start of T's commit record on the
  provider (BEGIN carries the commit record start).
- On restart the provider starts at max(origin, `confirmed_flush`), and
  decoding skips T only if `commit_lsn < start` (strict).
- So if `confirmed_flush <= T.commit_lsn`, T **is** re-sent (no loss); see
  `feedback-never-confirms-undurable-apply` for why feedback should
  never pass T. If anything moves `confirmed_flush` or the origin one byte
  further, T is lost silently.

That makes this a boundary-condition property: it holds only because two
separate rules (abort advances to the commit start, skip test is strict) line
up exactly. Discovery F8/W3 disagree on whether it holds; sut-analysis L7 and
Open Question 2 leave it open. (Settled since: both rules hold on PG17 and
PG18, so T is resent; see "Resolved" at the top.)

Second effect worth recording: after a graceful exit during replay, the shmem
marker still holds T's `commit_lsn` (`clear_transient_exception_state` is a
no-op when `use_try_block` is set, `:418-436`), so the re-sent T is replayed
under the policy again on the next BEGIN (`handle_begin` case 4). That is the
intended outcome. After a postmaster crash the marker is gone and T is first
applied normally, fails again, and is replayed — also fine, but
`exception_log` may then hold two sets of rows for T if the first replay had
committed (L1 redelivery). Two sets is acceptable; zero is not.

### Workload design

- Poison table: `poison(id text primary key, v int)`, replicated. On one
  subscriber S only, add a local CHECK constraint (`v <> 13`) **with AutoDDL
  off** so it is not replicated. Any transaction from another node inserting
  `v = 13` fails on S with 23514, a permanent data error.
- Writers on other nodes occasionally commit a transaction that writes several
  ledger rows plus one poison row with `v = 13`; make some of them large
  (thousands of rows, above `spock.exception_replay_queue_size`, default 4 MB,
  so the spill file path is used too). Record each such transaction's tag.
- Interrupt the replay: test command that, on S, calls
  `pg_terminate_backend` on the apply worker, or a partition P<->S, or kill -9
  of S's postmaster, timed shortly after a poisoned transaction commits on P.
- Check after quiescence: for each poisoned tag, on S
  `Always((no ledger rows of the tag) AND (exception_log has >= 1 row with that
  remote_xid))` under `transdiscard`. Under `sub_disable` runs: the
  subscription is disabled with `exception_log` rows, and after the workload
  drops the local CHECK and calls `sub_enable`, all rows of the tag appear
  once.
- Other nodes: all rows of the tag present (they have no CHECK).

### Assertion choice

`Always` in the workload: a silently missing poisoned transaction is a
violation every time.

Supporting reachability (separate messages, SUT-side, **missing**):

- `Sometimes("apply worker exited during in-process exception replay")` in
  the PG_CATCH "error during exception handling" branch and in the SIGTERM
  exit path when `use_try_block` is true. Without this the `Always` above can
  pass vacuously.
- `Sometimes("exception replay read entries from the spill file")` in
  `apply_replay_queue_next_entry` disk branch.

### Fault requirements

- A real data error (workload-made, above).
- Graceful single-worker exits (SIGTERM / `pg_terminate_backend`, partition
  -> connection error, `apply_idle_timeout`) during replay. A postmaster
  kill is the control case (shmem wiped).
- Large transactions and slow I/O / thread pausing stretch the replay.

### Original open-question notes

Resolved; see "Resolved" above.

### Investigation Log

_Entries carried over from `interrupted-exception-replay-still-records-txn`:_

#### Does restart at commit_lsn skip or resend the transaction?

- Examined: `src/spock_apply.c:686, 2305-2325, 4063-4070`; PG17 `xact.c`
  `RecordTransactionAbort` `:1733-1808`; PG17 `snapbuild.c:445`
  (`SnapBuildXactNeedsSkip`); `src/spock_proto_native.c:230` (BEGIN carries
  `final_lsn`).
- Found: abort advances session origin to `commit_lsn`; skip test is
  `ptr < start_decoding_at` with `ptr` = commit record start = `commit_lsn`.
- Not found: PG18 snapbuild/decode source.
- Conclusion: resend expected on PG17; partial.

_Second pass (G3 investigation, PG 18.3 tree `~/dev/pgedge/postgresql`, Spock
patches applied):_

- Examined: PG18 `src/backend/replication/snapbuild.c:304-306`,
  `logical/decode.c:1296-1302`, `logical/logical.c:556-576`; Spock
  `src/spock_apply.c:4751`.
- Found: same strict `<` test on PG18; start point is the origin LSN or
  `confirmed_flush`, whichever is later.
- Conclusion: resolved. Restart at `commit_lsn` resends T on PG17 and PG18.

#### Does RecordTransactionAbort in PG18 advance the session origin on abort?

- Examined: PG18 `src/backend/access/transam/xact.c:1775-1845`,
  `src/backend/replication/logical/origin.c:1242-1253`
  (`replorigin_session_advance`, forward-only), `patches/18/*.diff` hunk lists.
- Found: yes, when a session origin is set and an xid was assigned; no Spock
  patch changes it. `replorigin_session_origin_lsn` is not reset by abort
  (only by origin.c session functions), so it still holds T's `commit_lsn`.
- Conclusion: resolved. The `:3888` comment is accurate only for the rethrow
  path.

#### Can a keepalive's endpos exceed T's commit LSN while T is being sent?

- Examined: PG18 `walsender.c:1545-1556` (`WalSndPrepareWrite` header),
  `:1663-1700` (`WalSndUpdateProgress`), `:3440-3470` (`XLogSendLogical`,
  `sentPtr` update), `:4094` (`WalSndKeepalive`); `logical.c` `write_location`
  assignments; Spock `src/spock_apply.c:3700-3770` ('w' and 'k' handling),
  `:3237-3290` (`send_feedback`), `:4973-5010` (queue replay does not read
  the stream); Spock output plugin has no streaming callbacks.
- Found: no; keepalive LSN during T is at most `commit_lsn`, and later
  keepalives are read only after T's 'C'.
- Not found: nothing; this relies on walsender internals, hence the guard
  assertion.
- Conclusion: resolved.

#### Is the sub_disable resume-at-commit_lsn design meant to rely on the same strict skip test?

- Examined: `docs/configuring.md:160-185`, `src/spock_apply.c:977-1009`,
  `src/spock_exception_handler.c:230-275` (skip_lsn reported).
- Found: resuming with the failed transaction is documented; the mechanism is
  origin = `commit_lsn` plus the strict skip test.
- Conclusion: resolved.

#### Is a second set of exception_log rows for the same T acceptable?

- Examined: `sql/spock--6.0.0.sql:54-73` (`spock.exception_log` primary key
  includes `retry_errored_at`, so the schema allows repeats), docs on
  exception_log, sut-analysis L1.
- Found: nothing says whether repeats are expected; the schema does not forbid
  them.
- Conclusion: `(needs human input)`.
