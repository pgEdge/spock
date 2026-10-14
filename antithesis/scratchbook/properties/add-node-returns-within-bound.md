# add-node-returns-within-bound — ZODAN add_node returns or raises within a bound after faults stop

## Origin

Evaluation gap (b) / coverage-balance F7. Claim V5 (sut-analysis §7): add_node
"completes or fails within a bound", the bound coming from
`spock.sync_timeout()`. Lead L20: ZODAN orchestration runs over dblink with no
per-call timeout, and its budgets use wall clock. No catalog property bounds
the orchestrator itself: `initial-sync-ends-ready-or-visibly-disabled` covers
only the src -> n4 sync worker, and the add_node safety properties only score
add_node calls that already returned.

## Code paths (HEAD 69d9228f)

- `spock.add_node` (`samples/Z0DAN/zodan.sql:2882-3020`) is one CALL on n4.
  It runs as one transaction until Phase 11's `COMMIT`
  (`present_final_cluster_state`, `:2757`).
- `spock.sync_timeout()` (`:46-52`): the `spock.sync_timeout` GUC
  (`src/spock.c:1368-1385`, seconds, USERSET, default 0) or 180 s when it is 0.
  The workload can `SET spock.sync_timeout` in the add_node session.
- Bounded waits, each with its own budget S = `sync_timeout()`, measured with
  `clock_timestamp()` (wall clock):
  - Phase 3 (`create_disable_subscriptions_and_slots`, `:1794-2037`): per peer
    X, wait for src to apply X's sync LSN, budget S (`:1917-1975`), then
    `pg_sleep(5)` (`:2031`).
  - Phase 4 (`:2361-2420`): per peer, remote `wait_for_sync_event` on src with
    timeout S, raises on false.
  - Phase 5 (`:2323-2358`): `create_sub` via dblink, then `pg_sleep(5)`.
  - Phase 6 (`:2687-2737`): remote `wait_for_sync_event` on n4 with timeout S,
    `wait_if_disabled = true`; raises on false. This is what bounds add_node
    when the src -> n4 initial sync hangs (pg_dump, see
    `initial-sync-ends-ready-or-visibly-disabled`): add_node raises after S.
  - Phase 7 (`:2453-2502`): READY wait, budget S, warning only.
  - Phase 9 (`:2048-2215`): remote `wait_for_sync_event` per node, timeout S.
  - Phase 10: `pg_sleep(5)` per peer (`:2262`, `:2316`).
  - Phase 11 (`:2740-2805`): wait for every subscription to be active, budget S.
  - Phase 12 (`monitor_lag_with_dblink`, `:981-1043`): fixed 60 s.
- `spock.wait_for_sync_event` (`sql/spock--6.0.0.sql:685-762`) honours its
  timeout (wall clock, 0.2 s polls).
- Unbounded steps: every `dblink(dsn, sql)` call. ZODAN passes the DSN as
  given: no `connect_timeout`, no keepalive settings. libpq turns keepalives on
  but with the OS idle time (Linux default 7200 s). In PG18, dblink waits with
  `libpqsrv_connect` / `libpqsrv_exec` (`contrib/dblink/dblink.c:231, 1462`),
  which are interruptible (cancel or terminate of the add_node backend works)
  and show as wait events `DblinkConnect`, `DblinkGetConnect`,
  `DblinkGetResult` in `pg_stat_activity`.
- Remote `pg_create_logical_replication_slot` on X (Phase 3) waits for every
  xid running on X. Bounded only by the workload's own transactions.
- **Phase 3's per-probe timeout does not work.** `:1942-1948` sets
  `statement_timeout = '5s'` with `set_config(..., true)` around the progress
  probe, with the comment "Bound each remote probe so dblink calls cannot hang
  forever". In PostgreSQL the statement timer is armed only in
  `start_xact_command()` at the start of a top-level statement
  (`src/backend/tcop/postgres.c:2814`, `enable_statement_timeout` at `:5208`);
  `statement_timeout` has no assign hook (`guc_tables.c:2739`), and plpgsql /
  SPI do not re-arm it. Inside the CALL the new value is never used, so the
  probe has no 5 s bound. (Code reading on the patched PG18 tree; not run.)

## Bound

With N existing nodes and P = N - 1 peers other than src, the sum of the
explicit budgets is about (2P + N + 5)·S + 5·(P + N + 1) + 60 s. For v1
(N = 3, P = 2): about 12·S + 90 s. Every wait measures its own budget from its
own start, so once faults stop no remaining wait can take longer than its
budget; the sum is an upper bound on time from quiet-period start to return,
provided every dblink round trip is short.

With S = 30 s (set in the session) the bound is about 8 minutes. That fits a
dedicated add_node test template (CW11 in the implementability evaluation).

## Failure scenarios

1. **Half-open dblink socket.** A dblink call is in flight from n4 to node Y
   (for example Phase 4's `wait_for_sync_event` on src, which lasts up to S,
   or Phase 9's `sub_enable` on a peer). Y is partitioned from n4 and then
   killed. Y's FIN/RST is dropped by the partition. After the partition heals,
   n4's backend is a passive reader with nothing outstanding, so TCP sends
   nothing and n4 waits for the OS keepalive (about 2 h 11 min with Linux
   defaults). add_node sits in `DblinkGetResult` long after faults stop.
   Whether this happens depends on whether the dead peer's kernel still has
   the socket and retransmits FIN after the heal (open question).
2. **Long partition with data in flight.** Y's reply is lost; Y retransmits
   with backoff (RTO up to 120 s) and gives up after `tcp_retries2`
   (about 15 min). If the partition outlasts that, Y's backend errors, its
   RST may also be lost, and n4 waits on keepalive as in 1.
3. **Connect to an unreachable host.** No `connect_timeout`: a SYN to a
   partitioned host waits for kernel SYN retries (about 127 s), then errors.
   Bounded, but adds up across calls; once faults stop it ends at the next
   SYN retry.
4. **Loopback lock wait.** add_node holds locks in its own transaction until
   Phase 11 and calls back into n4 over dblink (Phases 5, 8, 9). A dblink
   session that waits on a lock held by the add_node session is a deadlock the
   PostgreSQL detector cannot see. Phase 8's comment (`:2931-2940`) documents a
   past instance that was fixed by moving the work to dblink; no other instance
   found, but the class would show up here as a hang with no faults at all.
5. **Clock skips.** Budgets use `clock_timestamp()`. A backward skip extends
   the budget in progress by the skip size; a forward skip ends it early (a
   clean failure, acceptable).

## Fault requirements

- Partitions between n4 and src or a peer during Phases 3-11, combined with
  node termination of that peer (scenario 1).
- Process pause of a peer during a dblink call (the call resumes when the pause
  ends; should stay inside the bound).
- Node termination of n4 itself: the workload's own libpq session to n4 must
  set `keepalives_idle`/`tcp_user_timeout` (or the workload hangs instead of
  add_node); a lost session counts as "returned with error".

## Workload / oracle design

- Run add_node in its own driver with `SET spock.sync_timeout = <S>` and
  `statement_timeout = 0` in the session (a session `statement_timeout` would
  turn a hang into a cancel and hide it). Record start time and outcome in a
  workload-local file.
- In the quiet period (`eventually_` / `finally_` command): request fault stop,
  then wait up to B = 12·S + 90 s + margin (v1) for the add_node driver to
  finish. `Always(add_node returned or raised within B after faults stopped,
  "add_node returns within bound after faults stop")`.
- Second, sharper check while waiting: sample `pg_stat_activity` on n4 every
  few seconds; `Always(no add_node backend has been in wait event
  DblinkConnect/DblinkGetResult for longer than S + margin since faults
  stopped, "add_node dblink call does not outlive its budget after faults
  stop")`. Names the step that hung. Remote `wait_for_sync_event` calls
  legitimately last up to S; slot creation on X may wait on workload
  transactions, so the workload must not hold long transactions on any node
  during the quiet period.
- After a timeout, cancel the add_node backend (`pg_cancel_backend`) and run
  remove_node / `zodan_cleanup.sql` before the next attempt.
- Companion `Sometimes("a peer was partitioned or paused while add_node had a
  dblink call open to it")`, from fault timing vs. the driver's phase NOTICEs.
- Clock skips are not stopped by quiet periods: compare a monotonic clock with
  wall time across the window and re-run or skip the check after a jump.

## Instrumentation

All workload-side. No SUT change needed. Optional ZODAN change (in
`samples/Z0DAN/zodan.sql`, listed as a SUT change if made): give each dblink
DSN `connect_timeout` and `keepalives_idle/interval/count`, which would be the
fix for scenarios 1-3.

## Open questions

- What add_node bound does the team expect after faults stop: the sum of
  `sync_timeout` budgets, or something tighter? V5 says "bounded by
  sync_timeout" without a total. Changes B and whether a slow-but-finite
  add_node is a finding. `(needs human input)`
- Does an Antithesis node termination during a partition leave the other end's
  socket half-open after the heal (no FIN/RST ever delivered)? If yes,
  scenario 1 is expected to fire; if the dead peer's kernel still retransmits
  FIN after the heal, the hang ends within a few minutes and the property is a
  regression guard. Needs Antithesis-side knowledge of how container network
  state is torn down.
- Is the Phase 3 `statement_timeout = '5s'` meant to bound the probe? If yes,
  it is a bug (it never takes effect); `dblink` with a DSN `options=-c
  statement_timeout=5s` would bound the remote side instead.
  `(partial: code reading shows it never takes effect inside the CALL; intent unknown)`

### Investigation Log

#### Does Phase 3's `set_config('statement_timeout', '5s', true)` bound the dblink probe?

- Examined: `samples/Z0DAN/zodan.sql:1939-1975`; patched PG18
  `src/backend/tcop/postgres.c` (`start_xact_command`, `enable_statement_timeout`,
  `finish_xact_command`); `src/backend/utils/misc/guc_tables.c:2739`;
  `contrib/dblink/dblink.c`.
- Found: the statement timer is armed only at top-level statement start and
  never re-armed by a GUC change; no assign hook; the CALL is one top-level
  statement. The local setting has no effect on the probe, and it is not sent
  to the remote side.
- Conclusion: the probe is unbounded. Kept as an open question only for intent.

#### What total bound does add_node promise?

- Examined: `docs/modify/zodan/index.md`, `samples/Z0DAN/zodan.sql` wait
  loops and `spock.sync_timeout()` uses.
- Found: each wait has its own `sync_timeout`-based budget (about 12 of them
  plus fixed sleeps, roughly 12·S + 90 s in v1); the docs give no total.
- Not found: a documented end-to-end bound.
- Conclusion: `(needs human input)`; the harness uses the sum of budgets
  plus margin until the team names a bound.
