# add-node-success-new-node-has-every-row — A successful add_node leaves the new node with exactly the committed rows

## Synthesis note

Merged from `add-node-success-new-node-has-every-row` (F7) and
`add-node-success-implies-complete-ledger-on-new-node` (F1). Same postcondition
of a successful ZODAN `spock.add_node` (S13, `zodan_tutorial.md`): n4 holds
exactly the committed ledger rows. F1 adds the duplicate side (each n4 ledger
row has exactly one `apply_audit` entry, since COPY in replica role also fires
ALWAYS triggers), the failed-add case (n1-n3 still satisfy the ledger
properties), the `Sometimes(add_node succeeded while writes were in flight on
all three nodes)` coverage marker, and NOTICE parsing for the
`pg_current_wal_lsn()` fallback. F7 adds the SUT-side `Reachable` in the pause
self-resume branch of `maybe_pause_for_slot_creation`. All kept; both chose
`Always`.

Cause vs outcome: `add-node-pause-held-until-progress-read` (L4) and
`add-node-after-peer-restart-captures-every-peer` (fallback) are mechanism
properties whose violation would usually show up here as missing rows. They
stay separate because they name the cause and can fire without a lost row
being observed.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (coverage-balance F5, implementability CW11, implementability (initial-sync finding)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 · Faults: pause of source, partition, node kill of source, long transactions

- Evaluation note (2026-10-13): add_node and node-churn properties run in their own test template (one add_node takes minutes: fixed `pg_sleep(5)` calls, a lag monitor that waits for zero lag, 180 s waits). Run add_node in its own test command with a client-side timeout so a hang does not block the quiet-period checks.
- The property now also checks n4's `counters` table (delta columns): value == initial + every committed increment, with increments in flight on all three nodes during add_node.

## Open questions

None remain open after the 2026-10-13 investigation (see Investigation Log).

## Findings that change the reading of this file (2026-10-13)

- **A successful add_node cannot have used the `pg_current_wal_lsn()`
  fallback at HEAD.** The fallback needs n4's `spock.progress` to have *no*
  row for X. But `spock.sub_create` on n4 (called by Phase 3 `create_sub`)
  always runs `spock_group_ensure_entry(MyDatabaseId, n4, X)`
  (`src/spock_functions.c:710`), so the row exists as soon as the disabled
  sub exists. If the Phase 3 `create_sub` failed (only a NOTICE), Phase 9
  `enable_disabled_subscriptions` loops over the same peers and calls
  `spock.sub_enable` for `sub_<X>_<n4>` (`samples/Z0DAN/zodan.sql:2144-2155`);
  `spock_alter_subscription_enable` uses `get_subscription_by_name(name,
  false)` (`src/spock_functions.c:912`), which raises, and Phase 9 turns any
  error into `RAISE EXCEPTION` (`:2207-2210`), which add_node does not catch
  (`:2882-2955`). n4 can't crash-restart during a successful add either:
  add_node runs in an n4 backend. So the fallback can only print in an
  add_node that then fails. The fallback itself is unsafe while X takes
  writes (it skips X's commits between src's snapshot and Phase 7), so the
  workload's "success that logged the fallback" check stays, as a pure
  regression guard.
- **If X is left out of `read_peer_progress` (source restart, INNER JOIN on
  `spock.progress`), the result is duplicates on n4, not loss.** n4's row
  for X is the zero row from `ensure_entry`, Phase 7 sees `0/0 <= slot
  restart_lsn` and skips the slot advance *and* the origin advance; when
  Phase 9 enables the sub, n4 receives everything X committed since the
  Phase 3 slot was created, part of which the COPY already holds. Insert-only
  ledger rows show this as `insert_exists`/a second apply_audit entry; a row
  deleted on a third node before the snapshot can come back on n4 only
  (the INSERT is resent, the DELETE is not). The "each n4 ledger row has one
  apply_audit entry" check is the one that catches this; keep it.
- **Correction to dependency (b) / L17:** no apply worker for key (n4, X)
  runs between the Phase 5 force-set and Phase 7, because `sub_<X>_<n4>` is
  still disabled; `reconcile_progress_with_origin` therefore cannot reset the
  force-set row before Phase 7 reads it in a normal run.
- **Dependency (c) is closed** by Phase 9 as above: a missing X->n4 sub
  fails add_node.
- So the live loss path for this property is L4 (the pause ending before the
  progress read; see `add-node-pause-held-until-progress-read`), including
  the no-xid window, which PG's snapshot builder does not cover.

## Source: `add-node-success-new-node-has-every-row` (F7 Distributed)

### What the property says

If `CALL spock.add_node(...)` (ZODAN, `samples/Z0DAN/zodan.sql:2882`) returns
without error while n1-n3 keep taking writes and faults are injected, then once
faults stop and barriers pass for every ordered pair including n4, n4's ledger
holds exactly the set of ledger rows acknowledged on n1, n2 and n3 (before,
during and after the add), with none missing and no extra rows. An add_node
that fails is acceptable (documented: partial adds may need cleanup,
`docs/modify/zodan/index.md:18-22`); one that succeeds with missing rows is a
bug.

### Claims

`docs/modify/zodan/zodan_tutorial.md`: "This ensures no data is missed or
duplicated" (:376), "starts from exactly this point, guaranteeing no data loss"
(:415), "This ensures no data is lost" (:444). sut-analysis S13.

### Cross-node coordination involved (each step runs on a different node)

1. Phase 3 (`create_disable_subscriptions_and_slots`, `:1794`): for every
   existing X other than src: create slot X->n4 on X; `sync_event(true)` on X;
   poll src's `spock.progress.remote_commit_lsn` for X until it passes that
   LSN (`:~1885-1960`); create a **disabled** sub X->n4 on n4. A failing
   `create_sub` is caught and only `RAISE NOTICE`d (`:2017-2036`), and add_node
   goes on.
2. Phase 5: `sub_create(src->n4, sync structure+data)`. n4's sync worker on src:
   `spock.pause_apply_workers()` on src (`src/spock_functions.c:4059-4125`),
   `CREATE_REPLICATION_SLOT` on src, import snapshot,
   `spock.read_peer_progress()` (returns `pg_replication_origin_status.remote_lsn`
   of each X->src subscription, live shared memory, `sql/spock--6.0.0.sql:127-215`;
   INNER JOIN on `spock.progress`), `resume_apply_workers()`; COPY; force-set
   n4's progress for each X (`spock_group_progress_force_set_list`,
   `src/spock_group.c:755-825`; key node_id is n4, `src/spock_sync.c:526-528`).
3. Phase 7 (`:2625-2680`): for each X, `target_lsn` = n4's
   `spock.progress.remote_commit_lsn` for X; if NULL, NOTICE "WARNING: No
   spock.progress entry ... falling back to pg_current_wal_lsn()" and use X's
   current WAL end; advance the X->n4 slot on X over dblink, then n4's origin.
4. Phases 9-10: enable the disabled subs on n4; create n4->X subs on X.

Correctness depends on: (a) the pause holding until `read_peer_progress` is
read, so live origin positions match the COPY snapshot (L4, a separate
mechanism property `add-node-pause-held-until-progress-read` exists);
(b) the progress entry for X still being the force-set value at Phase 7
(L17: `reconcile_progress_with_origin` at any apply start can reset it);
(c) every X having an X->n4 subscription (Phase 3 warn-and-continue);
(d) no fallback to `pg_current_wal_lsn()` (skips everything X committed after
the snapshot).

### Observed details (code-checked)

- If src has no `spock.progress` entry for X, the INNER JOIN drops X from
  `read_peer_progress`. n4 still has an entry for X (created with zero LSNs by
  `spock_group_ensure_entry` when the disabled sub was created,
  `src/spock_functions.c:710`). Phase 7 then reads `0/0`, not NULL, so it hits
  "already at or beyond" and does **not** advance; the X->n4 slot stays at its
  Phase 3 position and n4 re-receives X's commits that were already in the
  COPY. Plain rows converge (insert_exists -> applied as update, copied rows
  carry `epoch` ts); delta columns double-count. So that path gives duplicates,
  not loss.
- The `pg_current_wal_lsn()` fallback (loss) needs n4 to have no entry for X
  at all, e.g. Phase 3 `create_sub` for X failed and src also lacked X.
  That same case leaves n4 with no X->n4 subscription, see
  `add-node-success-has-sub-from-every-peer`.
- Nothing is atomic across phases; dblink calls use raw DSNs without timeouts
  (a paused peer hangs add_node); budgets use `clock_timestamp()`.

### Assertion

Workload, after a successful add_node and a full barrier round:
`Always(set(n4 ledger) == union of acknowledged ledger rows on n1..n3, "add_node success: new node has every committed row")`.
Report missing and extra keys separately in details. Also capture add_node's
NOTICE stream; include whether the fallback text or any "✗ Creating initial
subscription" line appeared (useful for triage, not a separate assertion).

Suggested SUT-side markers (missing; no Antithesis assertions exist):
`Reachable` in `maybe_pause_for_slot_creation`'s timeout branch
(`src/spock_apply.c:~565-586`, "apply worker pause timed out") so Antithesis
steers toward the L4 window.

### Scope

- n1-n3 writes ledger rows throughout; n4 takes no client writes until
  add_node returns (ZODAN precondition).
- auto_ddl off, no DDL, identical config, lowercase names without `_<digit>`.
- Rows whose client got no COMMIT ack are excluded unless seen on their origin.
- After a failed add_node: run `spock.remove_node` on n4 (plus
  `zodan_cleanup.sql`) before retrying; do not assert on n4's content.

### Fault requirements

- Process pause (stall `CREATE_REPLICATION_SLOT` past `spock.pause_timeout`
  10 s): needed for L4.
- Long-running transaction on src during Phase 5.
- Network partitions/latency between n4 and peers, between src and X.
- Node termination of src or X during add_node (crash restart resets
  `spock.progress` from `resource.dat`).

### Original open-question notes (detail for the combined list above)
- Is add_node expected to report success when a Phase 3 subscription could
  not be created (only a NOTICE)? (sut-analysis Open Q 15)
- How often does the `pg_current_wal_lsn()` fallback fire in CI logs? If
  never, any hit under Antithesis is a strong signal.

## Source: `add-node-success-implies-complete-ledger-on-new-node` (F1 Data Integrity)

### What the property says

If ZODAN `CALL spock.add_node(...)` for n4 returns without error while n1, n2
and n3 keep committing ledger rows, then after the check-phase barriers n4
holds exactly the set of ledger rows committed anywhere in the mesh (every
committed row once, nothing extra), and n1-n3 are unaffected. An add_node that
raises an error is acceptable (cleanup is documented), but must not corrupt
n1-n3.

### Claimed guarantee

`docs/modify/zodan/zodan_tutorial.md`: "This ensures no data is missed or
duplicated" (`:375-376`), "guaranteeing no data loss" (`:413-415`), "no data
is lost" (`:442-444`), "This guarantees data consistency" (`:973-976`).
sut-analysis S13. Past data-loss fixes in this exact area: dcbba6bb,
986ad069, a9bc8652, f38da44a, b7fc7022, 7d21b807, 8de96369.

### How the copy and the streams are stitched (summary)

- n4's initial data comes from one source node S via `sub_create(S -> n4,
  synchronize_data)`: the apply worker pauses apply workers **on S**
  (`spock.pause_apply_workers()`, `src/spock_functions.c:4060-4126`), creates
  the slot and exports a snapshot, reads `spock.read_peer_progress()` (the
  last commit from each other peer X that S had applied at the snapshot),
  resumes, COPYs under the snapshot and force-sets n4's progress entries.
- For every other peer X, a slot X -> n4 was created earlier (Phase 3).
  Phase 7 (`samples/Z0DAN/zodan.sql:~2625-2680`) advances that slot on X and
  the local origin on n4 to `spock.progress.remote_commit_lsn` for X, or, if
  that entry is missing, to X's `pg_current_wal_lsn()` (logged only as
  `RAISE NOTICE '    WARNING: No spock.progress entry ...'`).
- So rows from X committed after the snapshot point must come through X ->
  n4; rows before it through the COPY. Any gap or overlap is a loss or
  duplicate on n4.

### Ways it could break (leads)

- **L4 pause window**: the pause loop treats a worker with no xid as paused
  (`!TransactionIdIsValid(w->proc->xid)`), skips workers with `proc == NULL`,
  and each worker self-resumes after `spock.pause_timeout` (10 s) and clears
  the shared flag. If S's apply worker commits a transaction from X after the
  progress read but outside the snapshot, n4 misses it (the COPY doesn't have
  it, and the X -> n4 slot starts after it). Another property
  (`add-node-pause-held-until-progress-read`) covers the pause itself; this
  one checks the end result.
- **`read_peer_progress` INNER JOIN on `spock.progress`**: a missing shmem
  entry for (S, X) after a restart of S silently drops X; Phase 7 then falls
  back to X's current WAL end, skipping every X transaction not yet on S's
  snapshot.
- **L17**: `reconcile_progress_with_origin` at apply start can reset the
  force-set entry before Phase 7 reads it.
- **L20**: Phase 3 `create_sub` errors are only NOTICE'd (`:2017-2036`), so
  add_node can "succeed" without an X -> n4 subscription.
- **L16**: concurrent `resource.dat` dumps during multi-peer add_node.
- Duplicates: a Phase 7 target below what the COPY already contains would
  re-send rows; insert-only ledger rows hide that, so use the audit trigger
  from `ledger-row-applied-exactly-once-per-peer` on n4 too (a duplicate
  shows up as a second apply after the COPY).

### Oracle design

- Writers keep committing ledger rows on n1-n3 during add_node; record commits.
- Driver: on n4 run `CALL spock.add_node(...)` from `samples/Z0DAN/zodan.sql`
  with source = one of n1-n3 (random). Capture all NOTICE text; record whether
  it contains "falling back to pg_current_wal_lsn()" or a Phase 3 failure.
- If add_node returned OK: stop writes, barriers for every ordered pair
  including n4, then:
  - `Always(n4's ledger equals the committed set)` (no missing rows, no
    extra rows).
  - `Always(every ledger row on n4 has exactly one apply_audit entry)`.
    Row triggers enabled ALWAYS also fire for `COPY FROM` in a session with
    `session_replication_role = replica` (stock PG), so a row that arrived by
    COPY and again by stream counts 2. Verify this once when building the
    workload; if structure sync recreates the trigger differently on n4, the
    audit trigger must be created on n4 before data sync starts.
- If add_node raised: `Always(n1-n3 still pass the other ledger properties)`;
  run `remove_node`/`zodan_cleanup.sql` before any retry.
- `Sometimes(add_node succeeded while writes were in flight on all three
  nodes)` so the run shows the interesting state happened.

`Always` for the result checks; one missing row after a successful add is a
bug by the docs' own words.

### Fault requirements

- Process pause or CPU throttling of S during slot creation (stretches
  `CREATE_REPLICATION_SLOT` past `pause_timeout`, L4).
- Long-running transactions on S's peers (CREATE_REPLICATION_SLOT waits for
  running xids).
- Restart of S shortly before add_node (empties `spock.progress` entries until
  apply workers attach; reaches the INNER JOIN and the fallback).
- Partitions between n4 and peers during Phases 3-7.
- Kill of the add_node session (orchestrator death) -> must not corrupt n1-n3.

### SUT-side instrumentation (missing)

- In `spock_pause_apply_workers` after the wait loop: `Always("no apply worker
  in this database committed between pause start and resume")` would need a
  commit counter per worker; simpler: `Unreachable("apply worker
  self-resumed while pause flag was set by a live caller")` at the worker's
  timeout path (`src/spock_apply.c:565-586`).
- In zodan Phase 7 (PL/pgSQL, so via a NOTICE marker the workload parses):
  treat "falling back to pg_current_wal_lsn()" followed by a successful
  add_node as `Unreachable` in the workload unless the team confirms the
  fallback is safe.

### Original open-question notes (detail for the combined list above)
- Is the `pg_current_wal_lsn()` fallback ever safe while X is taking writes?
  If the team says yes (for example "only when X had no writes"), the
  workload must stop writes on X for the property to stay fair; if no, the
  fallback branch is a bug and should be an error.
- Is add_node expected to "succeed" when a Phase 3 subscription failed?
  (sut-analysis Open Question 15.) If yes, the property must allow missing
  rows from that X and instead require a visible warning; if no, success with
  a missing sub is a violation.
- Should writes to n4 be allowed during add_node? Docs say the new node must
  not serve clients; the workload must not write to n4 until add_node returns.

### Investigation Log

#### Is the `pg_current_wal_lsn()` fallback ever safe while the peer is taking writes?

- Examined: `samples/Z0DAN/zodan.sql:1794-2040` (Phase 3), `:2625-2680`
  (Phase 7), `:2048-2210` (Phase 9), add_node body `:2882-2955`;
  `src/spock_functions.c:690-715` (`spock_create_subscription` calls
  `spock_group_ensure_entry`), `:908-912`; `src/spock_group.c:245-290`.
- Found: the fallback sets X's slot to X's WAL end at Phase 7 time, which is
  after src's COPY snapshot, so any replicated X commit in between is lost
  on n4. Safe only if X committed nothing replicated in that interval. But
  the branch needs n4 to have no `spock.progress` row for X, and that row
  is created by `ensure_entry` whenever the X->n4 sub exists; if the sub
  doesn't exist, Phase 9 `sub_enable` raises and add_node fails.
- Not found: any path where a successful add_node reaches the fallback.
- Conclusion: resolved. Not safe under writes, and not reachable on a
  successful add at HEAD; the workload check stays as a regression guard.

#### Is add_node expected to report success when a Phase 3 subscription could not be created?

- Examined: Phase 3 catch block (`zodan.sql:2017-2036`), Phase 9 loop
  (`:2144-2210`), `spock_alter_subscription_enable`
  (`src/spock_functions.c:908-912`), commit 3250807a (SPOC-388, turned most
  ZODAN NOTICE handlers into `RAISE EXCEPTION`).
- Found: the Phase 3 failure is only a NOTICE, but Phase 9 then calls
  `sub_enable` on the missing sub, which errors (`missing_ok = false`) and
  is re-raised; add_node does not catch it. The only way past is a
  `create_sub` that errored on the reply but did create the sub, in which
  case the sub exists and Phase 9 enables it.
- Not found: a way to finish add_node without the sub.
- Conclusion: resolved. add_node does not report success in that case
  (the failure is late, at Phase 9, not at Phase 3). Intent of the NOTICE is
  moot for this property.

#### How often does the `pg_current_wal_lsn()` fallback fire in CI logs today?

- Examined: local `tests/tap/logs/*` (005441-005443, 033_zodan_lolor_add_node);
  grep of `tests/` for the NOTICE text.
- Found: the only matches are the echoed `CREATE PROCEDURE` source in
  statement logs; NOTICEs go to the client, not the server log, so these
  logs can't show it. No test asserts on it. Remote CI artifacts were not
  read (reading only, offline).
- Conclusion: resolved by the code analysis above instead of logs: the
  fallback can only print in an add_node that fails later in Phase 9, so a
  hit together with success under Antithesis would be a real regression.
