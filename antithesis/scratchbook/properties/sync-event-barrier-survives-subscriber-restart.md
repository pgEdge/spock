# sync-event-barrier-survives-subscriber-restart — A reached sync barrier is reached again after the subscriber restarts

## Synthesis note

Merged from three files on lead L18 (non-transactional sync_event markers and
empty transactions advance the origin with `replorigin_session_advance` only,
no WAL; after a subscriber crash the origin falls back below the marker, and
the provider never resends it). F4 also notes that L1 (redo advances the
node-id origin, not the subscription origin) gives the same symptom for normal
commits.

Type disagreement: F3 and F9 called it Liveness (a bounded re-check must
succeed); F4 called it Safety (remote_lsn must never go backwards). Resolution:
Liveness. The user-visible failure is a barrier re-check that hangs until
unrelated traffic arrives, and the primary check is a bounded `Always` that the
re-check returns true within T with P idle. F4's raw-value check ("subscription
origin remote_lsn never goes backwards across restart") is kept as a second,
separately named `Always` because it fails faster and names the mechanism.

## Investigation update (2026-10-13)

- **L1 holds on PG18 too (code-level).** `REL_18_STABLE` `xact.c` tags the
  commit record with `replorigin_session_origin` (:5909-5914, xloginsert.c
  :841-845) and redo calls `replorigin_advance(origin_id = XLogRecGetOrigin)`
  (:6211-6214, :6377). The pgEdge PG18 patches (`patches/18/*.diff`) touch
  `XactLogCommitRecord` only to install a commit-timestamp hook; redo and
  origin tagging are unchanged. Spock's custom rmgr (`src/spock_rmgr.c`)
  only logs at redo, and `reconcile_progress_with_origin` trusts the origin.
  So after a crash the slot origin falls back to its checkpoint value even
  for data commits. Not run on a live cluster.
- **The suggested fix call would not work as written.** The apply worker
  holds the slot origin through `replorigin_session_setup`
  (`acquired_by = MyProcPid`, PG18 `origin.c:1195`), and
  `replorigin_advance()` raises "replication origin with ID %d is already
  active for PID %d" when `acquired_by != 0` (`origin.c:~960`). WAL-logging
  the marker advance needs another route (for example writing the
  `XLOG_REPLORIGIN_SET` record directly). A commit-based route would not
  help until L1 is fixed, because the commit record names the node id.
- **The raw-value check is wrong for crashes.** "Subscription origin
  `remote_lsn` never goes backwards across restart" can fail with no bug:
  apply commits run with `synchronous_commit=off`, so after kill -9 the
  origin legitimately falls back over applied-but-unflushed commits (they
  are re-sent because feedback never confirmed them). Keep that check only
  for **clean** restarts (the shutdown checkpoint persists the in-memory
  value, so a decrease there is a bug). The barrier re-check stays the
  primary crash check: data commits below a reached marker are either
  confirmed-and-durable or re-sent together with the marker, so only the
  no-WAL advance (and L1) can leave it stuck.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability CW4 and property finding, wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: node kill between checkpoints

- Evaluation note (2026-10-13): random kills rarely line up with "P quiet for this pair", so this runs as a scripted sequence: stop P's writers, take a marker, wait for it on S, call the crash helper on S, then re-check. Failures after a crash restart are reported as "explained by L1/L18"; failures after a clean restart are the unexplained message.

## Open questions

- Is subscriber-side durability of marker progress part of the barrier contract, or must callers issue a fresh marker after any restart? `(needs human input)`
- Would WAL-logging the non-transactional advance be acceptable cost? `(needs human input)` `(partial: replorigin_advance() errors on the session-held origin, so a fix needs a direct XLOG_REPLORIGIN_SET write; a commit-based fix depends on fixing L1)`

## Source: `sync-event-barrier-survives-subscriber-restart` (F4 Protocol)

### Summary

A barrier that has returned `true` (`wait_for_sync_event(P, lsn)` on S) should
stay satisfied: the subscription origin's `remote_lsn` is the resume point and
the thing the barrier reads. If S restarts (crash or immediate stop) and the
origin comes back **below** an LSN that was already reported reached, then:

- a re-check of the same barrier returns `false` / waits;
- if P is idle, it waits until P commits something new, because P's slot
  `confirmed_flush` is already past the marker and P will not resend it;
- with `timeout = 0` (the default) the caller waits forever.

The workload's quiescence step and ZODAN both call `wait_for_sync_event` in
loops, so this turns into hangs in exactly the "check convergence" phase.

### Mechanisms that can move `remote_lsn` backwards across a restart

1. **Non-transactional markers and empty transactions advance the origin in
   shared memory only** (`handle_message` `src/spock_apply.c:2955-2964`,
   empty-transaction branch of `handle_commit` `:1112-1128`). No WAL record;
   durable only if a checkpoint happens before the crash. Lead L18.
2. **Normal applied commits are redone against the wrong origin id**
   (`handle_origin` sets `replorigin_session_origin = remote node id`
   `:1332`; the commit record carries that id; redo calls
   `replorigin_advance(XLogRecGetOrigin(record))`). After a crash between
   checkpoints the slot-named origin falls back to its checkpoint value. Lead L1
   (three focuses agree; code-checked in the synthesis).
3. Feedback already confirmed the marker: with `lsn_mapping` empty,
   `send_feedback` reports `flush = recvpos` (`:3260-3267`), and the marker's
   `'w'` header set `recvpos` to the marker LSN. So P's `confirmed_flush` is at
   or past the marker before S crashes.

`reconcile_progress_with_origin` (`src/spock_progress_recovery.c:153-275`)
treats the origin as truth and does not raise it to the provider's position;
nothing else re-advances the origin until the next real transaction from P.

### Invariant

Workload-side `Always` ("satisfied sync barrier stays satisfied after
subscriber restart"):

- Keep a per-(P,S) record of the highest marker LSN for which
  `wait_for_sync_event` returned `true`.
- Whenever the workload notices S has restarted (postmaster start time from
  `pg_postmaster_start_time()` changed), and before P's workload threads write
  again (a short pause of P's writers for that pair), call
  `wait_for_sync_event(P, recorded_lsn, timeout => T)` with
  `T >= restart_delay_default + connect_timeout + margin`.
- Assert the result is `true`.

Direct read alternative: compare `pg_replication_origin_status.remote_lsn` for
the slot-named origin before and after restart; assert it never decreases
(message: "subscription origin remote_lsn never goes backwards across
restart"). This is the same fact without the barrier procedure and also flags
L1 when no marker is involved.

Companion `Sometimes`: "subscriber restarted after a non-transactional marker
was applied and before the next provider transaction" — proves the window is
reached.

### Fault requirements

- Node termination of S (kill -9 or `pg_ctl -m immediate`) **between
  checkpoints**; a larger `checkpoint_timeout` widens the window.
- P idle for that pair long enough for the re-check (the workload controls
  this).

### False-positive scoping

- Exclude subscriptions dropped/recreated or resynced between the two
  readings (origin dropped and recreated legitimately starts lower).
- Exclude ZODAN-managed subscriptions on n4 while add_node is running (it drops
  and advances origins on purpose).
- `sub_alter_skiplsn` only moves forward; no exclusion needed.

### Original open-question notes (detail for the combined list above)
- Is `remote_lsn` meant to be crash-durable for markers? The C comment on
  `spock_create_sync_event` says "the marker is durable regardless of the
  calling transaction's outcome", which is about the provider side; nothing
  states the subscriber side. If the team says "the barrier is a one-shot
  observation", the property becomes a liveness note (the barrier must not hang
  after restart when P keeps writing) rather than a safety one.
  `(needs human input)`
- Does L1 reproduce on the patched PG18 build (sut-analysis Open Question 1)?
  If not, only mechanism 1 remains and the property only fires for
  marker-only progress.

## Source: `satisfied-barrier-stays-satisfied-after-restart` (F3 Failure Recovery)

### What the property says

If `CALL spock.wait_for_sync_event(result, P, M, timeout)` on subscriber S has
returned `true` for a marker M from provider P, then after S restarts (crash
or clean), the same call for the same M returns `true` again within a bound,
even if P commits nothing new in the meantime.

A barrier answer that flips from "reached" back to "not reached" and stays
there while the provider is idle is a recovery bug: callers (ZODAN,
operators, the harness itself) that re-check a barrier after a restart hang
until unrelated traffic arrives.

### Why (lead L18, sync_event durability)

- `spock.sync_event()` defaults to `transactional = false`
  (sut-analysis 2.11). The provider emits a non-transactional logical message.
- Subscriber `handle_message()` for `SPOCK_SYNC_EVENT_MSG` with
  `!transactional` calls `replorigin_session_advance(lsn, InvalidXLogRecPtr)`
  only (`src/spock_apply.c:2955-2964`). No WAL record, no checkpoint
  interaction.
- Empty transactions take the same shortcut in `handle_commit`
  (`src/spock_apply.c:1113-1131`).
- `wait_for_sync_event` polls `pg_replication_origin_status.remote_lsn` for
  the subscription's slot origin every 200 ms
  (`sql/spock--6.0.0.sql:685-780`, `remote_lsn` read around line 742).
- After a crash, the origin comes back at its last checkpointed value (plus
  nothing from redo, because redo advances the node-id origin instead, L1;
  see `crash-redo-leaves-no-node-id-origin-state`). After a **clean**
  restart the shutdown checkpoint persists the in-memory value, so the clean
  case should pass.
- The provider's slot `confirmed_flush` already passed M (feedback reports
  `flush = recvpos` when nothing is pending, `src/spock_apply.c:3265-3272`), so
  the provider starts streaming at or after M and never resends the marker.
  The origin stays below M until the next real transaction from P is applied.

So in a crash, `remote_lsn` drops below M and the barrier for M stays false
for as long as P is idle. With a busy mesh this heals within one transaction;
with an idle provider (quiet period, maintenance window, ZODAN while writes
are stopped as its docs require) it does not heal.

Data is not lost here; this is a barrier-answer stability and liveness
property. Data visibility after `true` is covered by
`sync-event-barrier-implies-visible`.

### Assertions

- **Workload-side:** in a quiet period with no writes on P: record M and a
  `true` answer on S, crash-restart S, then re-run the same wait with a
  timeout equal to the reconnect bound.
  `Always("re-check of an already reached sync_event marker returns true after
  subscriber restart")`. Always: every such re-check must succeed.
- **SUT-side (missing, no existing assertions):**
  `Sometimes("subscription origin restored below a previously reached
  non-transactional sync_event LSN")` is not computable inside one process
  without persisting the reached LSN. Instead, at apply start, after
  `replorigin_session_get_progress()`, report
  `Sometimes(origin_startpos < provider confirmed_flush)` using the LSN the
  provider actually starts from (the first `'w'` / keepalive position). That
  marks the state "origin behind what the provider will send".

### Fault requirements

- Node termination of the subscriber between checkpoints (required).
- Idle provider during the re-check: the workload must stop writes on P in
  that phase, otherwise the property cannot fail.

### Original open-question notes (detail for the combined list above)
- **Is the barrier meant to be stable across a subscriber crash?** The
  monitoring doc (`docs/monitoring/spock_sync_event.md`) says a `true` result
  means changes "have been received and applied", which reads as a durable
  fact. If the team says callers must issue a new marker after any restart,
  this property becomes "a fresh marker issued after the restart is reached
  within bound" and moves to the liveness set.
- **Should non-transactional markers be WAL-logged on the subscriber?** A
  `replorigin_advance(..., wal_log=true)` there would make the advance
  durable. The answer decides whether a failure here is a bug or a documented
  limit.

## Source: `sync-event-barrier-stable-across-crash` (F9 Idempotency)

### What the property says

Once `spock.wait_for_sync_event(origin, lsn)` has returned true on subscriber
S for a marker LSN L from provider P, then after S crashes and restarts and
the cluster is quiet again (faults healed, no new writes on P), the same call
for L returns true again within a bounded time.

### Why it matters

- `docs/monitoring/spock_sync_event.md` claims a true result means "all
  changes up to [LSN] on the provider have been received and applied". It is
  the documented barrier, ZODAN uses it (Phases 4 and 6), and every
  convergence oracle in this catalog uses it.
- If a reached barrier can become unreached and stay that way, any caller that
  re-checks an older marker after a restart (an operator script, a retry of
  add_node Phase 6, a monitoring probe) hangs until its timeout, or until some
  unrelated write on P happens to move the origin.

### Mechanism (code-checked)

- `wait_for_sync_event` polls `pg_replication_origin_status.remote_lsn` of the
  subscription origin (`sql/spock--6.0.0.sql:685-780`).
- A non-transactional sync_event marker advances that origin with
  `replorigin_session_advance(lsn)` only (`handle_message`,
  `src/spock_apply.c:2955-2964`). An empty transaction (all changes filtered,
  or the marker sent transactionally with no data) does the same in
  `handle_commit` (`:1113-1131`). Neither writes WAL.
- Feedback: with no outstanding local commits, `send_feedback` reports
  `flush = recvpos` (`:3260-3268`), so the provider's slot `confirmed_flush`
  moves to or past L soon after L is received.
- After kill -9 of S, the origin goes back to its last checkpointed value
  (and, per L1, even data commits since the checkpoint do not restore it at
  redo). The provider restarts at max(origin, `confirmed_flush`) >= L, so the
  marker is **not** re-sent. `remote_lsn` stays below L until P commits a new
  transaction that S applies.
- Data transactions are different: their commits may be lost with
  `synchronous_commit=off`, but then `confirmed_flush` was not advanced past
  them (feedback waits for local flush), so they are re-sent and the origin
  catches up. The stuck case is the no-WAL advance.

### Workload design

- During the run, keep a list of (P, S, L) markers the workload saw reach
  true.
- After any crash of S, once faults are healed and P is quiet (no workload
  writes on P for the check window), call `wait_for_sync_event(NULL, P_id, L,
  timeout)` on S for the newest such L.
- `Always(true within timeout)`, with timeout >= `apply_idle_timeout` +
  restart delays (sut-analysis V1 bounds).
- To keep P quiet for the check without stopping the whole run, use a
  dedicated check phase at the end, after `spock.sync_event()` markers on
  every pair have been reached and S has been killed once more.

### Assertion choice

Liveness, implemented as `Always` evaluated once at the end of a quiet
window: the barrier must be reached again within the bound. (If the team
decides the marker only needs to be stable while new writes keep arriving,
this property should become a monitoring note instead; see Open questions.)

### Fault requirements

- Node termination of the subscriber, after a marker has been reached and
  before a checkpoint.
- Quiet period on the provider afterwards (no new commits on P).

### SUT-side instrumentation (missing; no existing assertions)

- At apply worker start (`spock_apply_main`, after
  `replorigin_session_get_progress`, `:4750-4752`), once the first keepalive
  reply shows the provider's start position:
  `Sometimes("apply worker started with origin below provider confirmed position")`
  marks the stuck state for triage. (The walsender logs "has been already
  streamed, forwarding to" in that case; matching that log line in the
  workload is a no-instrumentation alternative.)

### Original open-question notes (detail for the combined list above)
- Is it intended that `remote_lsn` may stay below a previously reached marker
  after a crash until the next real transaction? The design doc relies on
  stock logical replication for resume, which is fine for data, but the
  barrier reads the origin directly. `(needs human input)`
- Would writing the non-transactional advance with WAL
  (`replorigin_advance(..., wal_log=true)`) be acceptable cost? The answer
  decides whether a failure is a bug or a documented limit.

### Investigation Log

#### Does L1 (redo advances the node-id origin) reproduce on the patched PG18 build?

- Examined: `~/dev/pg/postgresql` branch `origin/REL_18_STABLE`:
  `xact.c` `RecordTransactionCommit` (:1409-1470), `XactLogCommitRecord`
  (:5909-5914), `xact_redo_commit` (:6211-6214), `xact_redo` (:6377);
  `xloginsert.c:841-845`; `origin.c` `replorigin_advance` (:910-1010).
  `patches/18/*.diff`; `src/spock_apply.c:1331-1332, 4745-4751`;
  `src/spock_rmgr.c` redo; `src/spock_progress_recovery.c:153-275`.
- Found: same code as PG17. Commit record carries the Spock node id;
  redo advances that id; no Spock code moves the slot origin at or after
  redo. TAP 022's header (lines 17-18) assumes the opposite, and the tests
  issue CHECKPOINT before SIGKILL, so they never exercise redo of apply
  commits.
- Not found: a patched PG18 build tree with local changes (patch files
  read instead); no live run.
- Conclusion: resolved at code level — mechanism 2 applies on PG18.

#### Would WAL-logging the non-transactional advance be acceptable?

- Examined: PG18 `origin.c` `replorigin_session_setup` (:1120-1195),
  `replorigin_advance` acquired_by check.
- Found: the proposed `replorigin_advance(..., wal_log=true)` errors when
  called from the worker that holds the origin.
- Not found: any team statement on cost.
- Conclusion: `(needs human input)`, with the API constraint noted.

#### Is the raw "remote_lsn never goes backwards" check valid?

- Examined: `src/spock_apply.c:4699-4702` (`synchronous_commit` off unless
  `spock.synchronous_commit`), `get_flush_position`/`send_feedback`
  (:3082-3118, :3260-3267).
- Found: after a crash the origin can legitimately drop over unflushed
  apply commits.
- Conclusion: restrict that check to clean restarts; the barrier re-check
  remains valid for crashes.
