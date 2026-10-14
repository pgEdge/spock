# add-node-pause-held-until-progress-read

## What led here

Lead L4 (seven focuses agree), concurrency note F4, sut-analysis S13. This
property isolates the concurrency part: the provider-side pause must still be
in force at the moment peer progress is read. The end-to-end "new node has
every row" check belongs to the add-node data properties
(e.g. `committed-ledger-row-reaches-every-node`); this one points at the
mechanism and fires even when the lost transaction happens to be invisible to
the ledger.

## Code path

Caller, run by the new node's apply worker against the provider P
(`spock_create_slot_and_read_progress`, `src/spock_sync.c:650-866`):

1. `SELECT spock.pause_apply_workers()` on P (`:702-707`).
2. `CREATE_REPLICATION_SLOT ... LOGICAL spock_output` on P (`:718-751`). This
   waits for P's running transactions (snapshot builder), so it can take
   arbitrarily long under a long-running or stalled transaction on P.
3. Import the slot snapshot (`:767-775`).
4. Read peer progress (`spock.read_peer_progress`, `sql/spock--6.0.0.sql:127-200`,
   or the older direct query `:785-800`). It returns
   `pg_replication_origin_status.remote_lsn` per peer subscription on P —
   live shared-memory values, not MVCC.
5. `SELECT spock.resume_apply_workers()` (`:852-857`).

The resume LSNs from step 4 become the new node's starting point for each peer X
(`spock_group_progress_force_set_list`, then ZODAN Phase 7 advances X's slot to
it). They are only right if no apply worker on P committed between the slot's
consistent point and step 4.

Pause implementation:

- `spock_pause_apply_workers` (`src/spock_functions.c:4060-4127`) sets the
  instance-wide `SpockCtx->pause_apply = 1`, then polls workers until each is
  `paused` or has no xid. On its own timeout it clears the flag and raises
  55P03.
- Workers check the flag only at `begin_replication_step` before
  `StartTransactionCommand` (`src/spock_apply.c:614`) and after commit
  (`:1186`), in `maybe_pause_for_slot_creation` (`:565-586`).
- **Each worker gives up after `spock.pause_timeout` (default 10 s) and writes
  `pause_apply = 0` for everyone** (`:576-580`), logging
  `apply worker pause timed out after %ds, resuming`. The caller is not told.
- `resume_apply_workers` (`src/spock_functions.c:4135-4145`) writes 0
  unconditionally. Pause is not counted per caller.
- The completeness scan reads `w->proc->xid`, `w->worker.apply.paused`,
  `worker_type`, `proc` without `SpockCtx->lock` (`:4078-4100`). A worker that
  read the flag as 0 just before it was set, started a transaction, and has no
  xid yet counts as paused.
- `spock.pause_timeout` is `PGC_USERSET`; each apply worker uses its own
  session value, so raising it in the add_node session (as the errhint says)
  does not extend the workers' self-resume timeout.

## Failure scenario

1. Steady writes on n1-n3. Workload starts `spock.add_node` for n4 with source
   P = n1.
2. P has a long transaction open (workload-held, or a stalled backend), or P is
   slow (CPU / I/O throttling, thread pause). `CREATE_REPLICATION_SLOT` on P
   waits for it for more than 10 s.
3. P's apply worker for peer X (n2) times out, clears the flag, applies X's
   transaction T and commits after the slot's consistent point.
4. Step 4 reads `remote_lsn(X on P)`, which now includes T. The COPY snapshot
   does not contain T. P will not forward T to n4 (default `forward_origins`).
   n4's subscription from X starts after T. **T never reaches n4.** No error, no
   exception_log row; at most the WARNING on P.

## Invariant

- Suggested SUT-side assertion (**missing**): in `spock_resume_apply_workers`,
  `Always(pg_atomic_read_u32(&SpockCtx->pause_apply) == 1,
  "add_node pause still in effect when progress capture resumes workers")`.
  **Corrected 2026-10-13:** `resume_apply_workers` has two in-tree callers,
  the success path right after step 4 (`src/spock_sync.c:857`) and a
  best-effort call in the sync worker's PG_CATCH (`:1644`), where a 0 flag
  is legitimate. The check must be limited to the success-path call. On that
  call a 0 flag means some worker or another caller ended the pause while
  the capture still depended on it. `Always` because the function's own
  contract says workers stay paused until this call
  (`src/spock_functions.c:4050-4058` comment), and b8b1443b says the
  self-resume is for a dead caller only. Preferred alternative that needs
  no caller split: store the pausing backend's PID in `SpockCtx` and assert
  `Unreachable("apply worker self-resumed while the pausing backend is still alive")`
  in the timeout branch of `maybe_pause_for_slot_creation`.
- Suggested SUT-side `Sometimes("add_node progress capture overlapped in-flight
  apply work on provider")`: in `spock_pause_apply_workers`, true when the
  first scan pass found at least one worker mid-transaction (`all_paused ==
  false` on iteration 0). Confirms the pause actually had something to hold
  back; otherwise the `Always` is easy to pass.
- Workload-side companion (shared with the add-node ledger property): after a
  **successful** add_node and quiescence, n4 holds every ledger row committed
  on n1-n3.

## Fault / timing requirements

- Process pause (SIGSTOP-like) on P or on a backend holding a transaction on P
  for more than `spock.pause_timeout` during add_node. A workload-driven long
  transaction on P during add_node is the cheapest trigger.
- CPU/thread modulation for the xid-less window.
- Writes from at least one peer other than P during add_node (so P's apply
  workers have something to commit).
- Optionally lower `spock.pause_timeout` (minimum 1 s, USERSET; must be set in
  the apply workers' config, e.g. `ALTER SYSTEM`) to make the window common.

## Synthesis note (2026-10-13)

Mechanism property for lead L4. Its outcome form is
`add-node-success-new-node-has-every-row` (n4 has every committed row). Kept
separate: this one fires on the pause being ended early even when no provider
apply commit landed in the gap, so it finds the cause in timelines where the
outcome check passes by luck, and it names the cause when the outcome check
fails.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (property finding), implementability (property finding), implementability CW9); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 · Topology: v1 (add-node template, `spock.pause_timeout = 1`) · Faults: source transaction held open past `pause_timeout` during slot creation, writes on peers

- Evaluation note (2026-10-13): the paused state is not visible to the workload (same wait event as an idle apply worker; `paused` not exposed), so the workload emits `Sometimes("source held an xid-assigned transaction open longer than pause_timeout across add_node slot creation")` from its own actions.
- `spock.pause_timeout = 1` and a workload-held xid-assigned transaction on the source across add_node Phase 5 are now required, not optional. Without them the `Unreachable` is reachable only by luck.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-b-addnode-ops.md` and `evaluation/synthesis.md`.

- Benign firing under partition: when n4 is partitioned from src, n4's sync
  worker errors out after keepalive detection, but the provider-side
  backend that ran the pause stays alive (idle in ClientRead) until server
  TCP keepalive notices, about 2 h with OS defaults, because the server sets
  no `tcp_keepalives_*`. The worker timeout then self-resumes "while the
  pausing backend is still alive" with no harm. Fire the `Unreachable` only
  when that same backend later reaches `spock_resume_apply_workers` (the
  caller really went on to read progress); alternatively the harness sets
  server `tcp_keepalives_idle` and `client_connection_check_interval` low
  and accepts the remaining gap.
- Worker timeouts do not broadcast, and an idle worker never clears the
  flag, so `pause_apply` can stay 1 long after any caller is gone. The
  `Always(pause_apply == 1)` at the success-path resume is unaffected. The
  bound on that stall is the new property
  `add-node-pause-released-after-caller-dies`, which shares the pausing
  backend PID instrumentation.

## Open questions

None remain open (see Investigation Log). Assertion change: the primary
SUT-side check becomes `Unreachable("apply worker self-resumed while the
pausing backend is still alive")` in the worker timeout branch (needs an
owner PID in `SpockCtx`); the flag `Always` in `spock_resume_apply_workers`
is kept only if it is limited to the success-path call.

## Findings (2026-10-13)

- **Self-resume is meant for a dead caller, not a live one.** Commit
  b8b1443b added `ConditionVariableTimedSleep` "so workers self-recover after
  spock.pause_timeout seconds if resume is never called (e.g., caller crashed
  or connection lost)". The function's own comment says workers stay paused
  until resume. Nothing tells a live, slow capture that the pause ended, so
  ending it under a live capture is outside the design intent; the
  flag-based `Always` matches the contract.
- **The no-xid window is real; PG's snapshot builder does not close it.**
  `snapbuild.c` (PG 17 tree, header comment lines 98-110): with no running
  xids at the slot's first `xl_running_xacts`, the slot is CONSISTENT at
  once; it only waits for xids that already existed when that record was
  logged. A worker that read `pause_apply == 0` just before the flag was
  set, was counted as paused because it had no xid yet, and then got its xid
  after that record and committed before `read_peer_progress` runs, is not
  in the exported snapshot but is in `ros.remote_lsn`. P does not forward it
  (origin filter), so n4 loses it. Narrow (needs a thread pause between the
  flag read and the first write), but thread pauses are what Antithesis does.
- **Correction: `resume_apply_workers` has two in-tree callers**, the success
  path (`src/spock_sync.c:857`) and the best-effort call in the PG_CATCH of
  the sync worker (`:1644`). On the error path the flag may already be 0
  (for example `pause_apply_workers` itself timed out and cleared it, or a
  worker self-resumed), and that is fine because the capture failed. So:
  - Either put the `Always(flag == 1)` only on the success path (for example
    a distinct SQL entry point or a parameter for the success call), or
  - Better: record the pausing backend's PID in `SpockCtx` in
    `spock_pause_apply_workers`, and in the worker timeout branch of
    `maybe_pause_for_slot_creation` assert
    `Unreachable("apply worker self-resumed while the pausing backend is still alive")`
    when `BackendPidGetProc(owner_pid) != NULL`. This hits the cause
    directly and does not fire for a crashed caller (the intended case).
- **Scope note (was listed as a question):** two captures against the same
  provider at once would also trip the check; confirmed by code (one
  instance-wide flag, unconditional clear in resume, also shared across
  databases because the flag is global even though the scan filters by
  `dboid`). Not reachable in v1 (one spare node, one add at a time).

### Investigation Log

#### Is the worker-side self-resume meant to override a still-running capture?

- Examined: `src/spock_apply.c:565-586`, `src/spock_functions.c:4044-4145`,
  `git show b8b1443b` and `dcbba6bb` commit messages.
- Found: b8b1443b's message gives the reason as caller crash or lost
  connection. dcbba6bb calls the pause a "deterministic pause barrier".
  No code checks whether the caller is still alive.
- Not found: any statement accepting loss for a slow but live caller.
- Conclusion: resolved. Not intended; the flag-based contract is the right
  one. Assertion placement needs the correction above.

#### Does the snapshot builder's wait cover the no-xid window?

- Examined: `~/dev/pg/postgresql/src/backend/replication/logical/snapbuild.c`
  (REL_17_STABLE; header state diagram and text), the pause scan in
  `spock_pause_apply_workers`, `begin_replication_step` order (flag read,
  then `StartTransactionCommand`, xid at first write).
- Found: the builder waits only for xids running when it logs/reads
  `xl_running_xacts`; with none running it is consistent at once. Commits
  after the consistent point are not in the exported snapshot.
- Not found: any spock-side re-check after slot creation.
- Conclusion: resolved. Not covered; the window is real but narrow.

#### Two captures against the same provider at once

- Examined: `spock_pause_apply_workers` / `spock_resume_apply_workers`.
- Found: single global flag, unconditional clear.
- Conclusion: resolved as a scope note (not reachable in v1), removed from
  the question list.

#### (new) How many callers does `resume_apply_workers` have?

- Examined: grep of `src/`, `samples/`, `tests/` for `resume_apply_workers`.
- Found: `src/spock_sync.c:857` (success) and `:1644` (PG_CATCH,
  best-effort). TAP logs show only those.
- Conclusion: the earlier "exactly one caller" note was wrong; see Findings.
