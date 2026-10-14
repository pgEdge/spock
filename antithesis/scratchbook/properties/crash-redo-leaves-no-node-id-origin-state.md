# crash-redo-leaves-no-node-id-origin-state

## What the property says

After any crash recovery of a Spock node, the replication-origin progress that
recovery restores belongs to real replication origins (the slot-named
subscription origins and the origins ZODAN creates). No progress entry appears
for a RepOriginId that has no row in `pg_replication_origin`. Checked as:

```sql
SELECT s.local_id, s.remote_lsn
FROM pg_replication_origin_status s
LEFT JOIN pg_replication_origin o ON o.roident = s.local_id
WHERE o.roident IS NULL;
```

which must return zero rows on every node at every check.

This is the direct, cheap detector for lead L1. It does not depend on whether
a duplicate apply happens to become visible in the data.

## Mechanism (lead L1, re-checked for this focus)

Spock side, HEAD 69d9228f:

- At worker start the session replication state is set up for the
  slot-named origin: `replorigin_session_setup(originid)` with
  `originid = replorigin_by_name(MySubscription->slot_name)`
  (`src/spock_apply.c:4746-4750`).
- `handle_origin()` then overwrites `replorigin_session_origin =
  remote_origin_id` (a Spock node id, 16-bit hash of the node name)
  (`src/spock_apply.c:1331-1332`), and keeps it for the rest of the
  transaction.
- `handle_begin()` sets `replorigin_session_origin_lsn = commit_lsn`
  (BEGIN carries `txn->final_lsn`, `src/spock_proto_native.c:230`), and
  `handle_commit()` sets it to `end_lsn` before `CommitTransactionCommand()`
  (`src/spock_apply.c:~1004-1007`).

Stock PostgreSQL side (checked in a local REL_17_10+ tree at
`~/dev/pg/postgresql`, `src/backend/access/transam/xact.c`; the pgEdge PG18
patches do not touch these functions):

- `RecordTransactionCommit()` (`:1404-1442`): the commit record is tagged
  with `replorigin_session_origin` (the node id), then
  `replorigin_session_advance(replorigin_session_origin_lsn, XactLastRecEnd)`
  advances the **session state**, which is the slot-named origin. In memory
  only.
- `RecordTransactionAbort()` (`:1779-1808`) does the same for aborts that
  have an xid.
- Redo: `xact_redo_commit()` / `xact_redo_abort()` call
  `replorigin_advance(origin_id = XLogRecGetOrigin(record), ...)`
  (`:6162, :6285, :6325-6374`). That is the **node id**, not the slot origin.
- `replorigin_advance()` (`src/backend/replication/logical/origin.c:888ff`)
  does not check the catalog; it finds or allocates a free in-memory state for
  that id, and errors with "could not find free replication state slot for
  replication origin with ID %d" (`:955`) if none is free.
- `CheckPointReplicationOrigin()` writes every in-memory state with a valid
  id, so once created the node-id state is persisted and reloaded at every
  start (`StartupReplicationOrigin`, error at `:798` if it does not fit).

So after a crash between checkpoints:

1. The slot-named origin falls back to its value at the last checkpoint.
2. A new progress state appears whose id is the provider's Spock node id.

Supporting evidence that the team has seen the symptom without naming the
cause: the progress design doc notes for TAP 008/022 that "without [a
CHECKPOINT before SIGKILL], walwriter-cadence races could leave recovery's
origin LSN at batch-1" (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:233`).
That is the L1 regression; it was blamed on the walwriter.

## When does the regression become a duplicate apply?

Narrower than "every crash". The provider starts at
max(requested origin LSN, slot `confirmed_flush`). `confirmed_flush` only
covers subscriber commits that were flushed locally and then reported by
`send_feedback()` (`src/spock_apply.c:3237ff`; flush is the newest
`lsn_mapping.remote_end` whose `local_end <= GetFlushRecPtr()`). Duplicates
need one of:

- **Feedback lag:** subscriber commit flushed locally (async commit,
  walwriter within `wal_writer_delay`) but feedback not yet processed by the
  walsender when the subscriber dies. Feedback is sent at the end of each
  read batch, about once per wakeup (1 s loop). So the window is around a
  second under load, which random kills will hit.
- **Provider also restarts later** while the subscriber's origin is still
  regressed: a logical slot's `confirmed_flush` is only saved to disk at
  checkpoint or when restart_lsn/xmin move, so it can fall back too. The
  regressed subscriber origin lasts only until the next applied commit, so
  this is a smaller window.

Without L1, the redo would advance the slot origin to the last flushed commit
and neither case would resend anything.

Secondary effects:

- State-slot use: each subscriber node gains one extra persistent origin
  state per provider node id. PG18 caps them with
  `max_active_replication_origins`; `docs/sizing.md:188-203` does not count
  them. Node churn with new node names (new ids) keeps adding states that
  nothing removes (no catalog row means `pg_replication_origin_drop` cannot
  name them). Exhaustion shows up at redo or at startup as an ERROR in the
  startup process: the node does not come back.
- If a provider's node id equals the roident of an unrelated local origin,
  redo advances that origin into another LSN space (sut-analysis L1/L24).
  Not reachable with the planned names unless chosen on purpose.

## Assertions

- **Workload-side (primary):** after each node restart, and in every
  quiet-period check, run the query above on every node.
  `Unreachable("pg_replication_origin_status has a progress row with no
  pg_replication_origin entry")` when it returns rows. Unreachable fits: the
  state is never legitimate; any hit is the defect.
- **SUT-side (missing, no existing assertions):** in `spock_apply_main()`
  right after `replorigin_session_get_progress()` (`src/spock_apply.c:~4752`),
  scan the replication-state array (`pg_show_replication_origin_status`
  equivalent) for ids with no catalog row and `Unreachable` with the id and
  LSN in details. This places the signal at the first moment Spock could
  notice it.
- Companion SUT instrumentation (missing): `Sometimes(origin_startpos <
  provider confirmed_flush)` is not observable from the subscriber; instead
  log/`Reachable` the walsender LOG "has already been streamed, forwarding to"
  on the provider to show the restart was raised to `confirmed_flush`.

## Fault requirements

- Node termination (SIGKILL of the subscriber postmaster or any backend that
  causes a crash-restart) between checkpoints. Keep `checkpoint_timeout`
  large (for example 15-30 min) and avoid manual CHECKPOINT in the workload so
  the window stays open.
- Write load on the providers so commits are being applied when the kill
  lands.
- If node termination is off for the tenant, a test command can
  `pg_ctl stop -m immediate` or kill -9 a backend (deployment-topology
  fallback).

## Related properties

- `replication-origin-states-do-not-leak` (written in parallel by another
  focus) covers the same orphan states from the resource-leak side, with an
  `Always` after quiescence and an `Unreachable` on "state table full". The
  two should be merged at catalog time; this file adds the analysis of when
  the regression turns into a duplicate apply (feedback-lag window) and the
  SUT-side check at apply start.
- `ledger-row-applied-exactly-once-per-peer`,
  `delta-counter-equals-committed-increments` (data-level effect of the same
  lead; this property mentions the probe in its evidence as an idea, this file
  makes it a catalog entry).

## Synthesis note (2026-10-13)

Kept separate from `replication-origin-states-do-not-leak` after review. The
invariants differ: this property is a direct, cheap detector of the L1
mechanism (any origin progress row without a `pg_replication_origin` entry
after a crash), checked right after every restart. The leak property is about
capacity (the state table filling up) and also covers two leak sources that
have nothing to do with crash redo (table-sync origins left on the FAILED
path; origins left by `sub_drop` / `remove_node`). The "no unnamed origin
states" check that F5 listed in the leak property is the same check as this
one; the catalog assigns it here, and the leak property keeps the "state table
full" and "no orphan named origins" checks. If L1 is confirmed, this property
predicts `ledger-row-applied-exactly-once-per-peer`,
`delta-counter-equals-committed-increments` and
`causally-deleted-row-stays-deleted` failures in the same timeline.

## Investigation update (2026-10-13): L1 confirmed at code level on PG18

The key question was whether stock PG crash redo of an apply commit advances
an origin numbered by the Spock node id (set by `handle_origin`,
`src/spock_apply.c:1331-1332`) instead of the slot-named session origin,
and whether Spock compensates. Answer: yes it does, and no, nothing
compensates.

PG18 (`~/dev/pg/postgresql`, `origin/REL_18_STABLE`):

- `XactLogCommitRecord` adds `XACT_XINFO_HAS_ORIGIN` with
  `origin_lsn = replorigin_session_origin_lsn` whenever
  `replorigin_session_origin != InvalidRepOriginId` (`xact.c:5909-5914`),
  and `XLogInsert` writes `replorigin_session_origin` (the node id) into the
  record header (`xloginsert.c:841-845`).
- `RecordTransactionCommit` then calls `replorigin_session_advance()`
  (`xact.c:1450-1453`), which moves the **session** state, i.e. the
  slot-named origin, in shared memory only. `RecordTransactionAbort` does
  the same for aborts with an xid (`:1800-1828`).
- Redo: `xact_redo` passes `XLogRecGetOrigin(record)` (`:6377, 6386, 6400,
  6409, 6426`) and `xact_redo_commit` calls
  `replorigin_advance(origin_id, parsed->origin_lsn, lsn, false, false)`
  (`:6211-6214`). `replorigin_advance` (`origin.c:~910-1010`) has no catalog
  check: it finds or allocates a state for that id, or raises "could not
  find free replication state slot for replication origin with ID %d"
  (hint: increase `max_active_replication_origins`).
- `pg_show_replication_origin_status` lists every in-memory state and
  leaves `external_id` NULL when `replorigin_by_oid(..., true)` finds no
  row, so the property's query (or simply `external_id IS NULL`) sees the
  orphan.
- pgEdge PG18 patches: only `pg18-025-logical_commit_clock.diff` touches
  `xact.c`, adding a timestamp hook around `XLogInsert` in
  `XactLogCommitRecord`; redo and origin tagging are unchanged.

Spock side, HEAD 69d9228f:

- `src/spock_rmgr.c` `spock_rmgr_redo` only `elog(LOG)`s resource-dump
  records; it does not touch origins.
- `spock_init_progress_state` / `reconcile_progress_with_origin`
  (`src/spock_progress_recovery.c:70-275`) run at worker start, read the
  slot origin's (regressed) value and treat it as truth; they adjust
  `spock.progress`, never the origin.
- `maybe_advance_forwarded_origin` (`src/spock_apply.c:5165-5183`) WAL-logs
  an advance only for forwarded transactions (`remote_origin_id !=
  MySubscription->origin->id`), and of a different origin. Direct
  transactions get no WAL-logged advance of the slot origin.
- The team's own tests assume the opposite: TAP
  `tests/tap/t/022_rmgr_progress_post_checkpoint_crash.pl:17-18` says
  "WAL recovery advances pg_replication_origin to its durable post-commit
  value (via xact_redo_commit -> replorigin_advance...)", and both 008 and
  022 run `CHECKPOINT` before SIGKILL, which persists the slot origin and
  hides L1. The design doc's "walwriter-cadence races" note
  (`docs/internals-doc/specs/spock-progress-no-checkpoint-hook-design.md:233`)
  is this symptom.

Implication: the `Unreachable` should fire on the first subscriber crash
with at least one applied (or aborted-with-xid) remote transaction since the
last checkpoint. Not run on a live cluster. Priority stays as catalogued;
this is now a likely finding rather than a guard.

Counting states for the planned topology (n1..n3 full mesh, n4 added by
ZODAN): each node holds N-1 slot-named origins (2-3), plus up to N-1
node-id states after crashes (one per provider node id, reused when a node
is re-added under the same name, never removable because there is no
catalog row), plus short-lived table-sync origins. Roughly 6-8 of PG18's
default 10 (`max_active_replication_origins`; `docs/sizing.md:196-201`
suggests setting it to `max_replication_slots`). Exhaustion needs several
concurrent table syncs or node churn under new names.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1, implementability (property finding), wildcard W2/W6); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: node kill between checkpoints

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): confirm by TAP (kill -9 without CHECKPOINT). Keep it in Antithesis as the root signal for the L1 cluster only while the consequence properties use their "explained by L1" split; otherwise it fires every run and hides second causes. Workload-side `Sometimes("subscriber restarted with applied remote commits since its last checkpoint")`. A test-only PG patch can add a marker in `xact_redo_commit` when the record's origin id has no catalog entry.
- Workload probe asserts only on a NULL-name row seen in two samples a few seconds apart (a dropped origin shows the same NULL for a moment). The SUT-side version would need SPI on the same view (`replication_states` is static in `origin.c`), or is dropped in favour of the workload probe.

## Open questions

- Is the node-id origin state an intended side effect? `(partial: TAP 022's header and the no-checkpoint-hook design doc both assume redo restores the slot-named origin, and no doc mentions node-id states; looks unintended)`
- Should the workload rotate node names (or run many concurrent table resyncs) to push origin-state use toward `max_active_replication_origins`? `(partial: steady state is about 6-8 of the default 10 per node in the planned topology; exhaustion needs churn under new names)`

### Investigation Log

#### Does stock redo advance XLogRecGetOrigin(record) rather than the session origin?

- Examined: `~/dev/pg/postgresql` (REL_17_10-126) `xact.c` `RecordTransactionCommit`
  `:1404-1442`, `RecordTransactionAbort` `:1733-1808`, redo `:6162, 6285,
  6325-6374`; `origin.c` `replorigin_advance` `:888-960`.
- Found: commit and abort both advance the session state in memory; redo
  advances the record's origin id; replorigin_advance has no catalog check.
- Not found: the patched PG18 source (pg18a build tree not inspected).
- Conclusion: `(partial: confirmed on stock PG17, PG18 not inspected)`.

#### Does the patched PG18 tree tag the commit record and run redo as REL_17 does?

- Examined: `~/dev/pg/postgresql` `origin/REL_18_STABLE` `xact.c`
  (:1409-1470, :1765-1830, :5905-5916, :6205-6215, :6370-6430),
  `xloginsert.c:841-845`, `origin.c` (`replorigin_advance` ~:910-1010,
  `replorigin_session_setup` :1120-1195, `pg_show_replication_origin_status`);
  `patches/18/*.diff`.
- Found: identical to PG17; the only `xact.c` patch is the commit-clock hook.
- Not found: any change to redo origin handling.
- Conclusion: resolved — L1 applies on PG18 (code reading, not run).

#### Does Spock's own rmgr or progress recovery compensate?

- Examined: `src/spock_rmgr.c` (whole file), `src/spock_progress_recovery.c`
  (:50-275), `src/spock_apply.c` (`handle_commit` :960-1137,
  `maybe_advance_forwarded_origin` :5165-5183, `spock_apply_main`
  :4745-4752); `git log --grep=redo`.
- Found: rmgr redo logs only; reconcile trusts the origin; the only
  WAL-logged advance is for forwarded origins.
- Not found: any code that restores the slot origin after redo.
- Conclusion: resolved — no compensation.

#### Is the node-id state intended?

- Examined: TAP 022 header, TAP 008 notes in the design doc, docs search for
  node-id origin states.
- Found: the tests and design doc expect redo to restore the slot origin.
- Conclusion: partial — evidence points to unintended; team confirmation
  would close it.

#### How many origin states can a node accumulate?

- Examined: `docs/sizing.md:142-203`; `src/spock_node.c:368-371` (node id is
  `hash_any(name) & 0xffff`, so a re-added node with the same name gets the
  same id).
- Found: steady state fits the default of 10; node-id states are reused per
  node name and cannot be dropped through SQL.
- Conclusion: partial — exhaustion needs workload choices (name churn,
  parallel resyncs).
