# causally-deleted-row-stays-deleted

## What the property says

If a row is inserted on node A, the insert reaches every node (barrier), and
then a **different** node B deletes it, the row is absent on every node after
quiescence. No crash, restart or reconnect may bring it back.

This is a redelivery oracle for **plain rows**. Other catalog properties note
that a re-applied INSERT or UPDATE on a plain row mostly re-converges (same
origin, equal commit ts -> apply remote again). That is true only when nothing
else touched the row in between. When a later change from another origin
removed the row, a re-applied INSERT has nothing to conflict with and
re-creates it. There are no tombstones, so nothing stops it.

## Why it matters

- Spock claims the resume point after a restart is handled by stock logical
  replication (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:26`)
  and only admits at-least-once delivery for forwarded origins (401197ab,
  comment on `maybe_advance_forwarded_origin`, `src/spock_apply.c:5150-5165`:
  "last_update_wins handles the duplicate").
- That comment is the assumption this property tests. LUW does not handle a
  duplicate INSERT once the row was deleted by another origin: the result is a
  row that exists on one node only, with no `exception_log` row and no
  `resolutions` row. Users see it as "deleted data came back on one node".

## Mechanism (code-checked)

1. Redelivery source (lead L1, code-checked by synthesis and by
   `ledger-row-applied-exactly-once-per-peer`): `handle_origin` sets
   `replorigin_session_origin = remote_origin_id` (the origin **node id**,
   `src/spock_apply.c:1332`), while the session state belongs to the
   slot-named origin set up at worker start (`:4745-4750`). The commit record
   therefore carries the node id. Crash redo advances the node-id-numbered
   origin (stock `xact_redo_commit`, `XLogRecGetOrigin(record)`), not the
   subscription's. After kill -9 of the subscriber between checkpoints, the
   subscription origin falls back to its checkpointed value. The provider
   restarts at max(origin, slot `confirmed_flush`) and re-sends every
   transaction committed on the subscriber but not yet confirmed.
   `src/spock_progress_recovery.c:120-132` confirms that `pg_commit_ts` on the
   subscriber records the publisher's node id, i.e. the commit record origin is
   the node id. Checked in the pgEdge-patched PG 18.3 tree too
   (`xact.c:6255-6259`, see the exactly-once property's log): L1 exists on
   the PG18 target.
2. Apply of the re-sent INSERT (`spock_apply_heap_insert`,
   `src/spock_apply_heap.c:837-930`): `FindReplTupleInLocalRel` does not find
   the row (deleted by B's transaction, which was applied and survived), so it
   runs `ExecSimpleRelationInsert`. No conflict is reported because there is no
   local row to conflict with.
3. Order across subscriptions after restart is not fixed. The A->S
   subscription and the B->S subscription both restart. If B's DELETE was
   already confirmed (not re-sent), or is re-sent and applied **before** A's
   INSERT, the row ends up present on S. If B's DELETE is re-sent and applied
   after A's INSERT, it converges. That is a race Antithesis is good at.

Same-origin pairs (A inserts, A deletes) are safe: they are re-sent in order on
one stream.

## Failure scenario

1. n1 inserts row r (T1). n1->n2 applies T1 on n2. Barrier passes on all nodes.
2. n3 deletes r (T3). n3->n2 applies T3 on n2.
3. Before n2 confirms T1 to n1 (feedback lags local flush;
   `synchronous_commit=off` on apply), n2's postmaster is killed. No checkpoint
   since T1.
4. n2 restarts. n1->n2 origin is back before T1; n1 re-sends T1. If T3 is not
   re-sent (already confirmed to n3) or is re-sent first, r is re-inserted on n2
   only.
5. n1 and n3 have no r; n2 has r forever.

Note the barrier in step 1 does not protect: `wait_for_sync_event` reads the
in-memory origin (`pg_replication_origin_status.remote_lsn`), which is exactly
what rewinds.

## Workload design

- Table `lifecycle(id text primary key, created_on text, payload text)`; ids
  are `(node, seq)` strings so there are no insert/insert conflicts.
- Step A: insert on node A; record committed ids.
- Step B: barrier from A to every node (sync_event + wait_for_sync_event), or
  simply poll every node until the row is visible.
- Step C: delete on a randomly chosen node B != A; record committed deletes.
- Nothing else writes these rows (keeps clear of the documented no-tombstone
  cases in sut-analysis §12: there is no concurrent UPDATE/DELETE).
- Check after quiescence and barriers on every ordered pair:
  `Always(no deleted id is present on any node)`. On failure, record which node
  has it, its `xmin` commit ts and origin (`pg_xact_commit_timestamp_origin`),
  so triage can see it was re-inserted by an apply of A's change after B's
  delete.

Ambiguous outcomes: a delete whose client commit result is unknown (connection
lost at COMMIT) must be excluded or checked by reading B after reconnect.

## Assertion choice

`Always` in the workload: one resurrected row is a violation.

## Fault requirements

- **Node termination (kill -9 postmaster) of the subscriber S** between
  checkpoints. Use a large `checkpoint_timeout` / `max_wal_size` so checkpoints
  do not close the window.
- Restart on the same PGDATA (named volume, per deployment-topology.md).
- Network faults and latency between B and S widen the race (B's delete
  applied on S but not yet confirmed to B).

## SUT-side instrumentation (missing; no existing assertions)

- `Sometimes("apply inserted a row whose key had a committed delete from another origin")`
  is not cheaply checkable in C. Prefer the workload check. The L1 detector
  suggested in `ledger-row-applied-exactly-once-per-peer` (BEGIN `commit_lsn`
  below the session origin progress) is the root-cause marker.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1, wildcard W2, implementability CW4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: node kill between checkpoints, latency

- Evaluation note (2026-10-13): split into "resurrected row on a node that crashed since the delete and shows a node-id origin state" (explained by L1) and "resurrected row, unexplained". The kill must land within the unconfirmed window after a burst on A followed by quiet; the workload drives it with the crash helper rather than waiting for a random kill.

## Open questions

- Does the team treat at-least-once as acceptable for direct subscriptions? If yes, this property documents a consequence they may not have accounted for (LUW does not absorb this duplicate). `(needs human input)`

Resolved (see Investigation Log): PG18 redo behaves like PG17, so L1 exists on
the target; the unconfirmed window after a burst on an idle provider is up to
`wal_sender_timeout / 2` (30 s by default), and only a few hundred ms while
the provider keeps writing WAL.

## Fault and timing notes from the investigation

- To make this fire often, kill S's postmaster within `wal_sender_timeout/2`
  after a burst that ends with the B-delete, while A is quiet. A test command
  "burst then kill" is still useful, but a quiet provider alone gives a
  window of tens of seconds.
- Do not lower `wal_sender_timeout` in this template; a shorter value
  shrinks the window.

### Investigation Log

#### Does redo in the patched PG18 tree advance `XLogRecGetOrigin(record)`?

- Examined: see the same entry in
  `ledger-row-applied-exactly-once-per-peer.md` (patched 18.3 tree,
  `xact.c:6255-6259`, `:6421-6470`, `:5940`; `xloginsert.c:842-846`;
  `pg18-025-logical_commit_clock.diff`).
- Conclusion: resolved, yes. The expected outcome in this run is that the
  property can fail via L1.

#### How wide is the unconfirmed window during idle periods?

- Examined: Spock `send_feedback`, `src/spock_apply.c:3237-3320` (reports
  only flushed local commits via `get_flush_position`; with `force=false`
  it sends nothing when write/flush did not move); callers `:3767` (on every
  walsender keepalive, `force = reply_requested`) and `:3842` (after each
  message batch); the apply wait loop `:3492-3562` (1 s latch timeout used
  only for `apply_idle_timeout` and resolutions cleanup, no feedback).
  PG18 walsender: `WalSndWaitForWal` `walsender.c:1909-1912` (before
  sleeping, sends a no-reply keepalive when `flush < sentPtr`);
  `WalSndComputeSleeptime` `:2735-2763` (next wake at last reply +
  `wal_sender_timeout/2`); `WalSndKeepaliveIfNecessary` (reply-requested ping
  at that point).
- Found: after a burst, the walsender pings once when caught up. Spock replies
  at once, but its async apply commits are usually not yet flushed (walwriter
  delay), so the reply reports an older flush. Later pings with nothing new
  get no reply (force is false and nothing moved), and the walsender then
  sleeps until `last_reply + wal_sender_timeout/2`. The next feedback that
  carries the flushed position comes from that reply-requested ping or from
  the next transaction on that provider.
- Conclusion: resolved. On a quiet provider the window is up to
  `wal_sender_timeout/2` (30 s default); with steady provider WAL it is
  roughly the walwriter flush delay. Not measured; derived from code.

#### Is at-least-once acceptable for direct subscriptions?

- Examined: as in the exactly-once property's log (only forwarded-origin
  at-least-once is admitted, `src/spock_apply.c:5157-5161`).
- Conclusion: `(needs human input)`. The property is valid either way: even
  under at-least-once, a resurrected row is a divergence no Spock tool
  reports (no `exception_log`, no `resolutions` row).
