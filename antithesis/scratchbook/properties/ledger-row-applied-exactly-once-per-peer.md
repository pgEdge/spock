# ledger-row-applied-exactly-once-per-peer — No transaction is applied twice on a peer

## Synthesis note

Merged from `ledger-row-applied-exactly-once-per-peer` (F1) and
`insert-once-keys-never-hit-insert-exists` (F11). Both check the same
guarantee (exactly-once apply on direct subscriptions) with two different
oracles that fail for the same events:

1. F1: a local, non-replicated `apply_audit` table filled by an `ENABLE
   ALWAYS` trigger under `session_replication_role = replica`; exactly one
   audit row per `(origin, seq)` per peer.
2. F11: `spock.resolutions` must hold no `insert_exists` row for the
   insert-once ledger tables. A redelivered INSERT becomes an `insert_exists`
   UPDATE with equal origin and timestamp, and the resolutions row commits in
   the same transaction as the duplicate (resolved in F11's investigation
   log), so it survives a crash exactly when the duplicate does. Costs no
   harness trigger; also catches add-node overlap (rows copied with `'epoch'`
   ts).

Kept as one property with two distinctly named `Always` messages, so a
failure in either oracle without the other also points at an oracle bug.
F3 noted the same `insert_exists` side channel in its areas-examined notes and
F9 named this property as its main outcome oracle. Main trigger: L1 (kill -9
of a subscriber between checkpoints).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability (audit trigger), wildcard W2/W14 and odd things, antithesis-fit CW1, implementability CW4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: node kill between checkpoints

- Evaluation note (2026-10-13): each of messages (1)-(3) is split by attribution: "... explained by L1" when S crashed since the row committed and S shows a node-id origin state (the `crash-redo-leaves-no-node-id-origin-state` probe), and "... unexplained" otherwise. Only the unexplained messages count as new findings while L1 is open. The kill must land inside the unconfirmed window after a burst, so the workload drives it with the crash helper and emits `Sometimes("subscriber killed within the unconfirmed window after an apply burst, no checkpoint since")`. Oracle (2) reads `spock.resolutions`: the harness sets `spock.resolutions_retention_days = 0` (or copies rows as they appear) so a forward clock skip cannot trigger the daily cleanup.
- The audit trigger is `ENABLE REPLICA` (the earlier text said `ENABLE ALWAYS` that fires only under replica, which is wrong: ALWAYS fires in every role; the body check in this file made it work, but `ENABLE REPLICA` is the simple form).

## Open questions

- Does the team intend exactly-once or at-least-once on direct subscriptions? `(needs human input)`

Resolved since discovery (details in the Investigation Log): the patched PG18
tree redoes origin advance on `XLogRecGetOrigin(record)` exactly as stock PG
(L1 confirmed at code level on PG18); redo of a node-id-numbered origin does
take a replication-state slot and fails recovery when none is free; a
redelivered transaction that was discarded under TRANSDISCARD shows only in
`spock.exception_log` (a second set of rows), never in `spock.resolutions`.

## Source: `ledger-row-applied-exactly-once-per-peer` (F1 Data Integrity)

### What the property says

Each committed ledger row from origin O is applied exactly once on each peer
S (S != O), across apply-worker restarts, subscriber crashes and reconnects.
"Applied" means an apply-worker write to that row on S: the first INSERT, or a
later re-apply (a duplicate INSERT turns into an `insert_exists` conflict and
is applied as an UPDATE).

### Why it matters

Spock claims the resume point after a restart is handled by stock logical
replication (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:26`),
and TAP 022's header claims WAL recovery advances `pg_replication_origin`.
For plain rows a duplicate is mostly invisible (same origin, equal ts ->
apply remote again, `src/spock_conflict.c:~150-156`), so loss of exactly-once
hides behind convergence checks. It does not hide for delta-apply columns
(double count, see `delta-counter-equals-committed-increments`) or for any
user trigger with side effects. This property finds the duplicate directly
and earlier, on a table without delta columns, so triage can tell "replayed
twice" from "delta arithmetic wrong".

### Main lead: L1 (crash redo advances the wrong origin)

- `handle_origin` sets `replorigin_session_origin = remote_origin_id`, the
  origin **node id** (`src/spock_apply.c:1331-1332`), while the session
  replication state belongs to the slot-named origin set up at worker start
  (`src/spock_apply.c:~4750`).
- During normal running, `RecordTransactionCommit` advances the session state
  in memory (slot origin, correct). The commit record carries the node id as
  its origin. At crash redo, stock `xact_redo_commit` calls
  `replorigin_advance(XLogRecGetOrigin(record), ...)`, i.e. advances an origin
  numbered by the node id, not the subscription's.
- So after kill -9 between checkpoints, the subscription origin falls back to
  its checkpointed value. The provider restarts at max(that, slot
  `confirmed_flush`). Transactions committed and flushed on S but not yet
  confirmed to P (feedback is per message but runs only every so often and is
  asynchronous) are sent again.
- TAP 022/027 run `CHECKPOINT` before SIGKILL, so this redo path is not tested.
- Checked in both a stock PG 17 tree and the pgEdge-patched PG 18.3 tree
  (`xact_redo_commit` -> `replorigin_advance(origin_id, ...)` with
  `origin_id = XLogRecGetOrigin(record)`; the pgEdge patches do not touch this
  path). See Investigation Log.
- The orphan node-id-numbered states are written by every later checkpoint
  and never dropped (there is no `pg_replication_origin` row to drop them
  by), and each one holds a slot of `max_active_replication_origins`
  (default 10 on PG18). Size it with headroom (e.g. 32) or recovery itself can
  fail first.

Secondary leads: L19 (forwarded-origin advance is a separate WAL record after
commit; only with `forward_origins`, out of v1 scope), L7 (exit during replay
at exactly `commit_lsn`; the decoding skip rule may resend).

### Oracle design (workload side)

- On every node, before the run, create (locally, not replicated: AutoDDL off,
  not in any repset) `apply_audit(origin_node text, seq bigint, op text,
  local_xid xid8, at timestamptz default clock_timestamp())`.
- On the ledger table, create a row trigger `AFTER INSERT OR UPDATE` that
  inserts into `apply_audit` when `current_setting('session_replication_role')
  = 'replica'`, and `ALTER TABLE ledger ENABLE REPLICA TRIGGER ...` (evaluation 2026-10-13: `ENABLE REPLICA` fires only in replica-role sessions; with `ENABLE ALWAYS` the body check above is what keeps local inserts out).
  Code check: Spock apply uses `ExecSimpleRelationInsert/Update`
  (`src/spock_apply_heap.c:922, 731`) with `AfterTriggerBeginQuery` /
  `AfterTriggerEndQuery` (`:164, :181`), so row triggers fire for applied
  changes when enabled ALWAYS (or REPLICA).
- The audit row is written in the same transaction as the applied change, so
  it is atomic with it: if the apply commit is lost in a crash, so is the
  audit row.
- After the check-phase barrier: `Always(for every committed (origin, seq),
  count(apply_audit rows on S) == 1 for every S != origin)`. Count 0 is the
  loss property's job; this property fails on count >= 2.
- Under `transdiscard` replay the transaction is read-only, so the trigger
  insert errors inside replay. Replay should only happen if another property
  already fails; record it, do not count it here.

`Always` because a single double apply is a violation.

### Fault requirements

- **Node termination (kill -9 postmaster) of a subscriber between
  checkpoints** is required. Use a large `checkpoint_timeout` (for example
  30 min) and `max_wal_size` so checkpoints do not hide the window.
- Restart on the same PGDATA.
- Network faults add reconnects (they should not cause duplicates; useful as a
  control).

### SUT-side instrumentation (all missing)

- In `handle_begin` (`src/spock_apply.c:~660`), after the session origin is
  set up: `Always("incoming commit_lsn is above the subscription origin's
  progress")` comparing BEGIN's `commit_lsn` to
  `replorigin_session_get_progress(false)`. A resend of an already applied
  transaction makes this false. Caveat: after a legitimate crash that lost an
  async apply commit, the origin also went back, so the check stays true;
  only the L1 shape (data present, origin behind) fails it. Confirm with the
  audit table.
- After crash recovery, `Unreachable("pg_replication_origin_status has a
  row whose roident equals a spock node id but no matching origin name")`
  could be a workload-side probe of L1's second effect (node-id-numbered
  origin states appearing).

### Original open-question notes (detail for the combined list above)
- (Resolved: PG18 redo advances `XLogRecGetOrigin(record)`; L1 exists there.)
- (Resolved: yes, each redo-created state needs a free slot; see log.)
- Is at-least-once acceptable to the team for direct subscriptions? The
  design doc wording reads as exactly-once; 401197ab admits at-least-once only
  for forwarded origins. If at-least-once is the intent, this property should
  be restricted to delta-apply tables (where duplicates are a visible bug).

## Source: `insert-once-keys-never-hit-insert-exists` (F11 Wildcard)

### Why this property exists

The natural exactly-once oracle is an append-only ledger keyed by
`(origin_node, seq)`: check every committed row is present on every node.
That oracle **cannot see duplicate delivery**. When a transaction is applied a
second time, the INSERT finds its own row, Spock treats it as an
`insert_exists` conflict and applies the remote row as an UPDATE with identical
values (`docs/conflict_types.md:46-49`). The data converges and the ledger
check passes.

The duplicate does leave one trace: `insert_exists` **is** written to
`spock.resolutions` (only `update_origin_differs` and `delete_origin_differs`
are excluded, `src/spock_conflict.c:393-419`). In a workload where each key is
inserted once in the whole cluster, there is no legitimate source of
`insert_exists`, so any such row means a transaction was delivered twice, or an
echo, or an overlapping add-node catch-up.

Focus 1's `ledger-row-applied-exactly-once-per-peer` counts duplicates with
an `ENABLE ALWAYS` audit trigger. This property is a lighter, complementary
check that needs no trigger, works on any insert-only table (including the
COPY-populated rows on a newly added node), and tells redelivery (same origin,
equal timestamp) apart from add-node overlap (epoch timestamp) by looking at
the recorded row. Keep both if the trigger is built; this one is the fallback
if it is not.

This turns an at-least-once bug (focus 9) into something a data-integrity
check (focus 1) can see, using an oracle that is already in the product.

### Code path (HEAD 69d9228f)

- `spock_apply_heap_insert`, `src/spock_apply_heap.c:837-905`: finds an
  existing tuple by PK and calls `spock_handle_conflict_and_apply(...,
  is_insert=true)`.
- `spock_report_conflict`, `src/spock_conflict.c:376-475`: the same-origin and
  "normal flow" exclusions apply only to `SPOCK_CT_UPDATE_EXISTS` and
  `SPOCK_CT_DELETE_ORIGIN_DIFFERS`. INSERT_EXISTS keeps
  `save_in_resolutions = true` and calls `spock_conflict_log_table` when
  `spock.save_resolutions=on`.
- `conflict_resolve_by_timestamp`, `src/spock_conflict.c:99-200`: a re-applied
  txn has equal ts and the same origin (local tuple origin is the node id that
  `handle_origin` stamped on the first apply), so the same-origin shortcut
  applies remote silently except for the resolutions row.
- Rows written by initial COPY carry the subscription's slot-named origin and
  ts `'epoch'` (`src/spock_sync.c:938-947`), so a duplicate of a copied row
  (add-node overlap) is also `insert_exists`, apply-remote, and recorded.

### Which bugs this detects

- L1 (crash redo advances node-id origin, subscription origin rolls back):
  redelivery after subscriber kill -9.
- L7 (restart at exactly `commit_lsn`), L18, L19 (forwarded origin advance
  lost on crash).
- S13 / L4 / L17 / re-add (properties/zodan-readd-node-progress-not-stale.md):
  add-node windows that overlap the COPY snapshot.
- S6 echo: a node receiving its own transaction back.

It does not detect duplicated UPDATE or DELETE (same-origin updates are not
recorded; duplicate deletes show as `delete_missing`, which the workload can
also count). Delta-counter tables cover duplicated updates.

### Property

In a workload where every replicated INSERT uses a key that no other INSERT in
the cluster ever uses (node-prefixed keys, no re-insert after delete),
`spock.resolutions` never contains a row with `conflict_type =
'insert_exists'` for the ledger tables, on any node.

- Workload-side `Always` after each quiescent check and periodically during
  the run: `SELECT count(*) FROM spock.resolutions WHERE relname IN (<ledger
  tables>) AND conflict_type = 'insert_exists'` is 0. Message: "no
  insert_exists on insert-once ledger". Also report details (local/remote
  origin, timestamps) to separate "same origin, equal ts" (redelivery) from
  "epoch ts" (add-node overlap).
- Companion `Always`: no `delete_missing` resolutions on tables the workload
  never deletes from twice.
- SUT-side (missing, no existing assertions): `Unreachable` in
  `conflict_resolve_by_timestamp` for the case `local_origin_id ==
  remote_origin_id && local_ts == remote_ts` reached from an INSERT. That is
  the precise "this exact transaction was applied before" condition, but a
  same-transaction insert/delete/insert of one key would also reach it, so it
  must be limited to the ledger tables or run only with this workload.

### Requirements

- `spock.save_resolutions = on` on every node (already in the planned config).
- Ledger tables: insert-only, PK `(origin_node, seq)`, never updated or
  deleted. Delete-based cleanup must not run during the test.
- The check must survive node crashes: `spock.resolutions` is a normal heap
  table written in the apply transaction, so it is crash-safe; PG18 pgstat
  conflict counters are not (reset after crash) and must not be used instead.
- `spock.resolutions_retention_days` default 100 days; cleanup will not remove
  rows during a run unless the clock jumps by months.

### Fault requirements

Node termination between checkpoints (L1), graceful exits during replay (L7),
add_node under load (S13). The property itself needs no faults; it only
reports.

### Confidence

High: the recording path and the conflict path were read; the reasoning that
an insert-once workload has no legitimate `insert_exists` holds as long as keys
are globally unique and no echo exists.

### Original open-question notes (detail for the combined list above)
- (Resolved: a redelivered transaction that was discarded the first time
  shows only as a second set of `spock.exception_log` rows; see log. Add a
  companion workload check: no two `exception_log` rows share
  `(remote_origin, remote_commit_ts, command_counter)`.)

### Investigation Log

_Entries carried over from `insert-once-keys-never-hit-insert-exists`:_

#### Is the resolutions row written in the same transaction as the applied change?

- Examined: `spock_conflict_log_table`, `src/spock_conflict.c:628-756`.
- Found: `table_open` + `CatalogTupleInsert` + `table_close` with no
  transaction start or commit of its own, so the row is part of the current
  apply transaction. It commits or aborts with the applied change.
- Conclusion: resolved. A crash cannot leave a resolutions row for a change
  that rolled back, and a committed duplicate always leaves its row.

_Entries added in the open-question investigation:_

#### Does crash redo in the patched PG18 tree advance `XLogRecGetOrigin(record)`?

- Examined: `~/dev/pgedge/postgresql` (REL_18_STABLE, 18.3, working tree
  has the pgEdge patches applied: `xact.c`, `xlog.c`, `commit_ts.c`
  modified). `src/backend/access/transam/xact.c:6255-6259`
  (`xact_redo_commit`: `if (parsed->xinfo & XACT_XINFO_HAS_ORIGIN)
  replorigin_advance(origin_id, parsed->origin_lsn, lsn, false, false)`),
  `:6421-6470` (`xact_redo` passes `XLogRecGetOrigin(record)`), `:5940`
  (`XACT_XINFO_HAS_ORIGIN` set from `replorigin_session_origin`),
  `xloginsert.c:842-846` (record origin = `replorigin_session_origin`),
  `xact.c:1431-1468` (normal-running advance goes to the session state).
  `patches/18/pg18-025-logical_commit_clock.diff` (only hooks `XLogInsert` for
  the commit timestamp; no origin change). Spock: `handle_origin`
  `src/spock_apply.c:1331-1332`; worker start `:4745-4750`; nothing in
  `src/spock_rmgr.c` re-advances the subscription origin at redo.
- Found: identical to stock PG17. Normal commit advances the slot-named
  session state in memory; the commit record carries the node id; redo
  advances the node-id-numbered state.
- Conclusion: resolved. L1 is real on the PG18 target. A kill -9 of the
  subscriber between checkpoints rolls the subscription origin back to its
  last checkpointed value; the provider restarts at max(that, slot
  `confirmed_flush`) and re-sends applied-but-unconfirmed transactions.

#### Does redo of node-id-numbered origins need spare replication-state slots?

- Examined: PG18 `replorigin_advance`,
  `src/backend/replication/logical/origin.c:~911-990`; GUC
  `max_active_replication_origins` (`guc_tables.c:3389-3397`, default 10).
- Found: `replorigin_advance` looks for an existing state with that id, else
  a free one; with none free it raises `ERROR "could not find free
  replication state slot for replication origin with ID %d"`. In the startup
  process an ERROR ends recovery (FATAL), so the node does not start.
  `CheckPointReplicationOrigin` saves every in-use state, so redo-created
  states persist and are reloaded on every later start; nothing drops them.
- Also found: if a node id happens to equal the `roident` of a real local
  origin (roidents are small integers from 1), redo would advance that other
  origin with an LSN from a different provider's WAL. Advance is forward-only,
  so the other subscription could jump ahead and skip transactions after the
  crash (loss, not duplication). Rare (node id is a 16-bit name hash), but the
  harness can log node ids and roidents at setup to rule it in or out.
- Conclusion: resolved. Per node, budget at least (N-1) subscription origins
  + (N-1) node-id states + concurrent table-sync origins + add_node headroom.
  Set `max_active_replication_origins` to 32 in the harness.

#### Under TRANSDISCARD, does a redelivered transaction that failed the first time show only in `exception_log`?

- Examined: `handle_commit`, `src/spock_apply.c:996-1047` (TRANSDISCARD
  commits the exception rows with the origin set to the node id via
  `handle_origin`, so the same L1 rollback applies); DML handlers
  `:1632-1660`, `:1810-1820`, `:1943-1950` (in replay, DML is skipped and only
  logged); `spock_exception_handler.c:145, 199` (`command_counter` per
  change, `retry_errored_at = GetCurrentTimestamp()` per row); PK of
  `spock.exception_log` = `(remote_origin, remote_commit_ts, command_counter,
  retry_errored_at)` (`sql/spock--6.0.0.sql:54-73`).
- Found: after a crash wipes shmem, the redelivered transaction is first
  tried normally. If it fails again, replay skips the DML and writes a second
  set of exception rows that differ only in `retry_errored_at`. Resolutions
  rows from the failed first try are rolled back with it, and replay does no
  conflict handling, so `spock.resolutions` gets nothing. If the first error
  was a misclassified transient one, the second try may succeed: the rows
  then appear late (not a duplicate).
- Conclusion: resolved. Add a workload `Always`: no two `exception_log` rows
  share `(remote_origin, remote_commit_ts, command_counter)`. In a
  conflict-free ledger run any exception row is already a failure of the loss
  property; this check makes redelivery of discarded transactions visible too.

#### Does the team intend exactly-once or at-least-once on direct subscriptions?

- Examined: `docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:26`
  ("where do I resume from" is "handled entirely by stock logical-replication
  protocol"); comment on `maybe_advance_forwarded_origin`,
  `src/spock_apply.c:5150-5165` (forwarded origins: "preserving at-least-once
  semantics. last_update_wins handles the duplicate; delta-apply idempotency
  is tracked separately"); `docs/` grep for exactly-once / at-least-once
  (no hits outside that comment).
- Found: at-least-once is admitted only for forwarded origins, and the same
  comment says delta-apply idempotency is a known separate concern. Nothing
  states the rule for direct subscriptions.
- Not found: a design statement for direct subscriptions.
- Conclusion: `(needs human input)`. The property stays as written; if the
  team accepts at-least-once, narrow it to delta-apply tables and the
  resurrection case (`causally-deleted-row-stays-deleted`), where duplicates
  are user-visible.
