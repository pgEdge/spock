# sync-event-barrier-implies-visible — A satisfied sync barrier means the provider's earlier commits are visible

## Synthesis note

Merged from `sync-event-barrier-implies-visible` (F4) and
`sync-barrier-true-implies-rows-visible` (F1). Same contract: when
`wait_for_sync_event(P, L)` returns true on S, S sees every P-originated row
committed before `sync_event()` was called. Same mechanism: the procedure polls
`pg_replication_origin_status.remote_lsn`, which stock
`RecordTransactionCommit` advances before `ProcArrayEndTransaction`.

F1 adds the "re-read after 1 s" step to separate a visibility race from a
drop, and the question whether a barrier passed only because a transaction was
discarded should report true. F4 adds the exception_log explanation clause,
the separate message for DML inside a `sync_event(true)` caller's own
transaction, and the `Sometimes` companion. All kept; both chose `Always`.

Every convergence oracle in this catalog relies on this barrier, so it is
scored P0 even though the likely failure is a short race rather than loss.

## Investigation update (2026-10-13)

The visibility race (weak spot 1) and the out-of-order marker LSN (weak spot 0)
can only hide rows written **inside the marker's own transaction T** (a
`sync_event(true)` call in a transaction that also writes). For rows whose
transactions committed before `sync_event()` was called, the code gives the
guarantee:

- Their commit records sit before the marker record in P's WAL, so they are
  decoded, sent and applied before the marker or before any later
  transaction U.
- The single apply worker finishes each `CommitTransactionCommand()`
  (including `ProcArrayEndTransaction`) before it reads the next message.
  The origin can reach L only through the marker itself (non-transactional:
  `handle_message`; T with no DML: the empty-transaction branch of
  `handle_commit`) or through the commit of T or a later U. Each of those
  happens after every earlier transaction is already visible.

So the main `Always` (rows committed before the call) is a guard that is
expected to hold, with TRANSDISCARD/DISCARD as the only documented way out.
The separately named assertion for T's own rows is where a firing is
expected under concurrency; whether that is a bug is the remaining human
question. The old question "origin reached vs visible" collapses into it.

Side finding: the C comment on `spock_create_sync_event` says "In both modes,
an explicit WAL flush is performed". On PG17+ the 5-argument
`LogLogicalMessage` flushes only when `!transactional` (PG18 `message.c`), so
a transactional marker is flushed by T's own commit, not by the call. Doc
nit; no effect on this property.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW9); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: CPU modulation, worker exit (thread pausing reaches the own-transaction window only if core `xact.c` is instrumented)

- Thread pausing acts only on instrumented code; the own-transaction window is in core commit, so only CPU modulation and luck reach it unless core `xact.c` is instrumented in a later image.

## Open questions

- Is DML in the transaction that calls `sync_event(true)` meant to be covered by the barrier? `(needs human input)` `(partial: code cannot guarantee it — a concurrent commit after the marker record can move the origin past L before T arrives, and T's own commit advances the origin before T is visible; rows committed before the call are covered)`
- Should the barrier report true when the origin passed L only because a transaction was discarded? `(needs human input)` `(partial: handle_commit advances the origin on DISCARD/TRANSDISCARD on purpose and the docs describe discard as "skip the failed transaction and continue"; nothing says what a barrier should report)`

## Source: `sync-event-barrier-implies-visible` (F4 Protocol)

### Summary

Spock claims a `true` result from `spock.wait_for_sync_event(origin, lsn)`
means "all changes up to [LSN] on the provider have been received and applied"
(`docs/monitoring/spock_sync_event.md`), and for `sync_event(transactional :=
true)` that "all DML committed before the marker has also been applied"
(`src/spock_functions.c:3983-4012`). The workload's own convergence checks and
ZODAN both depend on this barrier. The property: once the barrier returns
`true`, a fresh snapshot on the subscriber sees every effect of every provider
transaction that committed before the marker, or an `exception_log` row
accounts for it.

### Code paths

- `spock_create_sync_event` `src/spock_functions.c:4014-4045`: non-transactional
  (default) `LogLogicalMessage(..., flush=true)`; returns the record's end LSN
  (`XLogInsert` return value). Decoding passes `buf->endptr` as `message_lsn`
  (PG18 `decode.c logicalmsg_decode`), so the two agree.
- Provider: `pg_decode_message` `src/spock_output_plugin.c:742-835`. A
  non-transactional message is emitted when its WAL record is decoded; every
  transaction whose commit record is earlier in WAL has already been sent.
- Subscriber: `handle_message` `src/spock_apply.c:2901-2974`: for a
  non-transactional marker, `replorigin_session_advance(lsn, Invalid)` (shared
  memory only). Transactional marker: origin set to `end_lsn` in
  `handle_commit` (`:1002-1009`), or the empty-transaction branch
  (`:1112-1128`).
- Waiter: `spock.wait_for_sync_event` `sql/spock--6.0.0.sql:685-780`: polls
  `pg_replication_origin_status.remote_lsn` for the slot-named origin every
  200 ms; returns true when `remote_lsn >= lsn`.

### Weak spots found

0. **A transactional marker's LSN is not its transaction's commit LSN.**
   `sync_event(true)` returns the end of the *message record*, which is written
   when the function is called, inside the caller's transaction T. T's commit
   record comes later. Any other transaction U on P that commits between the
   marker record and T's commit has `U.end_lsn > marker`, is decoded and sent
   first (commit order), and moves S's origin past the marker. The barrier
   then returns `true` before T has even been received. With concurrent
   writers on P this is easy to reach. It matters only when T also carries the
   caller's DML (the case the docs describe as "preserving order with the
   caller's DML"); ZODAN calls `sync_event(true)` on its own
   (`samples/Z0DAN/zodan.sql:1892`), so ZODAN is not exposed. The function
   comment promises only "DML committed before the marker", so T's own DML
   may be outside the contract — see open questions.
1. **Origin is visible before the commit is.** Stock PG
   `RecordTransactionCommit` (`xact.c:1468` in PG18) calls
   `replorigin_session_advance` well before `ProcArrayEndTransaction`
   (`xact.c:2419`); with a sync standby on the subscriber, `SyncRepWaitForLSN`
   (`:1573`) also sits in between. `pg_replication_origin_status` reads the
   shared state directly. For a **transactional** marker in the same transaction
   as user DML, the waiter can see `remote_lsn >= lsn` and return while the
   DML is not yet visible to new snapshots. This is the same shape as fix
   dcbba6bb ("origin updated before ProcArrayEndTransaction -> loss on new
   node"). The non-transactional marker is not exposed: its advance happens
   after the previous transaction's `CommitTransactionCommand` returned.
2. **TRANSDISCARD advances the origin past discarded transactions**
   (`handle_commit` `:1002-1009`). The barrier then returns true with data
   missing; documented behaviour, so the property accepts it only when an
   `exception_log` row names that transaction.
3. **Mesh scope.** With default `forward_origins='{}'`, the barrier P->S covers
   only transactions that originated on P. Rows P received from Q are not
   forwarded and are not covered.
4. `wait_for_sync_event` picks the subscription by `(sub_origin, sub_target)`
   with `SELECT ... INTO`; with two subscriptions to the same provider it
   picks one arbitrarily. Not reachable in v1.

### Invariant and instrumentation

Workload-side `Always` ("sync_event barrier true implies provider commits
visible"):

- Before calling `sync_event()` on P, the workload records the ledger rows
  whose transactions it has seen commit on P (insert-only ledger keyed by
  `(origin_node, seq)`).
- After `wait_for_sync_event(P, lsn, timeout)` returns `true` on S, open a new
  transaction on S and check every recorded row is present, or that
  `spock.exception_log` has a row with `remote_origin = P` and the row's
  transaction xid/commit ts.
- Randomise `transactional` (half the barriers issued as
  `BEGIN; INSERT ledger...; SELECT spock.sync_event(true); COMMIT`).
- The main assertion covers rows whose transactions committed before the
  `sync_event()` call (the contract stated in both the docs and the C
  comment). The rows written inside the marker's own transaction T get a
  separate assertion message ("transactional sync_event covers its own
  transaction's DML"), kept apart until the open question about intent is
  answered, so a firing there is not confused with the main contract.
- Companion `Sometimes`: "transactional barrier satisfied in the same apply
  transaction as ledger rows" so the risky case is known to be exercised.

SUT-side (missing): in `handle_commit` after `CommitTransactionCommand`,
nothing needed; the bug is in timing, so the workload check is the oracle.

### Antithesis angle

Thread pausing / CPU starvation of the subscriber's apply worker between WAL
insert and procarray update; network delay so the waiter polls at the right
moment; TRANSDISCARD exceptions interleaved with barriers.

### Original open-question notes (detail for the combined list above)
- Is returning `true` before the marker transaction is visible considered a
  bug, or is the contract "origin progress reached" only? Changes whether
  weak spot 1 is a finding. `(needs human input)`
- For `sync_event(true)` called in a transaction with DML, is that DML meant
  to be covered by the barrier? If yes, weak spot 0 is a contract bug and the
  workload should assert it as written (T's rows included). If no, the
  workload must record only rows committed before the `sync_event()` call and
  the docs need a sentence. `(needs human input)`
- Does the workload rely on barriers with `timeout=0`? A hang there is
  liveness, not this property; use a timeout of at least
  `apply_idle_timeout + restart_delay_default`.

## Source: `sync-barrier-true-implies-rows-visible` (F1 Data Integrity)

### What the property says

If `CALL spock.wait_for_sync_event(result, P_id, L, timeout)` on subscriber S
returns `true`, where L is the LSN returned by `spock.sync_event()` on
provider P, then a query on S issued after the call returns sees every row
that was committed on P before `sync_event()` was called (for tables in the
subscription's replication sets, in a conflict-free workload).

### Claimed guarantee

`docs/monitoring/spock_sync_event.md`: a `true` result means "all changes up
to [LSN] on the provider have been received and applied". The ZODAN tutorial
leans on it ("`wait_for_sync_event` completion guarantees receipt",
`docs/modify/zodan/zodan_tutorial.md:615-618`). sut-analysis S14. Every
convergence check in this catalog uses this barrier, so if it is wrong, other
properties report false failures or miss real ones.

### Mechanism (code-checked)

- The procedure (`sql/spock--6.0.0.sql:685-762`) polls
  `pg_replication_origin_status.remote_lsn` for the subscription's slot-named
  origin every 200 ms and returns true when `remote_lsn >= L`.
- `remote_lsn` is the in-memory session state of the apply worker's origin.
  For a normal applied transaction it is advanced inside
  `RecordTransactionCommit` (stock PG), i.e. **after** the commit WAL record is
  inserted but **before** `ProcArrayEndTransaction` makes the transaction
  visible. For empty transactions and the non-transactional sync_event
  marker it is advanced by `replorigin_session_advance` in `handle_commit`
  (`src/spock_apply.c:1113-1131`) and the marker path (`:2955-2964`).

### Ways it could break

1. **Visibility race (sut-analysis L18 note)**: between the origin advance and
   `ProcArrayEndTransaction` in the apply worker, a poller can see
   `remote_lsn >= L` and return true while the last transaction before the
   marker is not yet visible. The window is small in normal running but
   Antithesis thread pausing / CPU modulation can stretch it. Commit dcbba6bb
   fixed a data-loss bug of this exact shape (origin updated before
   `ProcArrayEndTransaction`) on the add-node path; the barrier has the same
   ordering.
2. **TRANSDISCARD drop**: a dropped transaction still advances the origin
   (`src/spock_apply.c:996-1009`), so the barrier returns true with rows
   missing. In a conflict-free workload any drop is itself a bug (see
   `committed-ledger-row-reaches-every-node`); record which happened.
3. **Crash after true**: the apply commit runs with `synchronous_commit=off`,
   so a subscriber crash right after `true` can lose the last applied
   transactions and the origin progress together; they are re-sent later.
   This is **not** a violation of this property (the property only covers the
   moment after the call). L18 adds that for empty/marker transactions the
   origin advance has no WAL, so after a crash `remote_lsn` can sit below a
   marker already reported reached until the next real transaction. Oracles
   must re-run barriers after any crash.
4. **Wrong origin row**: `external_id = sub_slot` assumes one origin per
   subscription; slot-group names (L10) or a stale origin from a dropped
   subscription with the same slot name could make the poll read the wrong
   row.

### Oracle design

- Writers keep committing ledger rows on P.
- Barrier task: on P, record the set C of ledger rows the workload saw
  committed on P; then `SELECT spock.sync_event()` -> L. On S, call
  `wait_for_sync_event(NULL, P_id, L, timeout)`. If true, immediately (new
  statement, READ COMMITTED) read the ledger rows of C on S.
- `Always(if barrier returned true, all of C is visible on S)`. On failure,
  re-read after 1 s and report whether the rows appeared (race, item 1) or
  stayed missing (drop, item 2).
- Run this barrier check repeatedly during the fault phase, not only at the
  end, so faults (pauses, CPU throttling) overlap the window.

`Always`: the doc promises it every time the call returns true.

### Fault requirements

- Thread pausing / CPU modulation on the subscriber (widens item 1).
- Graceful apply exits and partitions (item 2).
- Node termination of S (item 3; checks that the workload handles it, not a
  property violation).

### SUT-side instrumentation (missing)

- A test-only injection point or `SPOCK_WORKER_DELAY()`-style delay right
  after `CommitTransactionCommand()` in `handle_commit` is not enough, because
  the window is inside core `CommitTransaction`. Antithesis pausing should
  reach it without code changes; a `Reachable("apply committed a transaction
  just before a sync_event marker")` in `handle_message` for the marker helps
  confirm coverage.

### Original open-question notes (detail for the combined list above)
- Is the visibility race accepted, with the docs meaning "received and
  committed" rather than "visible"? If accepted, the property should re-read
  with a short retry and assert eventual visibility (a weaker form); if not,
  the fix is to compare against a visibility-safe LSN and this property
  guards it.
- Should `wait_for_sync_event` return false (or raise) when the origin has
  passed L only because a transaction was discarded? Today it returns true;
  the docs do not say.

### Investigation Log

_Entries carried over from `sync-event-barrier-implies-visible`:_

#### Does the origin advance before the commit becomes visible?

- Examined: PG18 source `src/backend/access/transam/xact.c` (
  `RecordTransactionCommit` 1331-1580, `CommitTransaction` 2419).
- Found: `replorigin_session_advance` at 1468 runs inside
  `RecordTransactionCommit`; `ProcArrayEndTransaction` at 2419 runs later.
- Not found: any Spock-side wait between apply commit and returning control.
- Conclusion: mechanism present; the question of intent stays open.

#### Is "origin reached" the whole contract, or must the transaction be visible?

- Examined: `src/spock_apply.c` `handle_commit` (:960-1137, empty branch
  :1113-1128), `handle_message` (:2901-2974), `apply_work` message loop
  (:3680-3770); `sql/spock--6.0.0.sql:685-762`; PG18
  `xact.c` `RecordTransactionCommit` (:1450-1452) and `CommitTransaction`
  (`ProcArrayEndTransaction` :2389); commit dcbba6bb.
- Found: messages are applied one at a time; every commit finishes before
  the next message is read. The origin passes L only via the marker, T's
  commit, or a later commit, all after earlier transactions are visible.
  The race window exists only for the transaction whose commit is advancing
  the origin (T or a later U).
- Not found: any parallel apply for one subscription in v1 (slot groups
  aside).
- Conclusion: for rows committed before `sync_event()`, visibility is
  guaranteed by ordering; the question only matters for T's own rows and is
  merged into the T-DML question.

#### Is DML in the `sync_event(true)` transaction covered?

- Examined: `src/spock_functions.c:3982-4045`;
  `docs/monitoring/spock_sync_event.md`; PG18 `message.c`
  `LogLogicalMessage`.
- Found: the returned LSN is the message record's end, written at call
  time, before T's commit. The C comment says "preserving order with the
  caller's DML" and "all DML committed before the marker"; the user doc only
  says the marker is visible to subscribers if T commits.
- Not found: any statement that T's own DML is covered.
- Conclusion: `(needs human input)`, keep the separate assertion message.

#### Should a barrier pass on a discarded transaction?

- Examined: `handle_commit` origin-advance comment (:981-1009);
  `docs/spock_release_notes.md:118`; `docs/configuring.md`,
  `docs/troubleshooting.md`.
- Found: origin advance on DISCARD/TRANSDISCARD is deliberate; docs call it
  skipping.
- Not found: any doc tying discards to `wait_for_sync_event`.
- Conclusion: `(needs human input)`; property keeps the exception_log escape.
