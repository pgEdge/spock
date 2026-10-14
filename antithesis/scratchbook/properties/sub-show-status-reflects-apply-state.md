# sub-show-status-reflects-apply-state

## Summary

`spock.sub_show_status()` documents (`docs/spock_functions/functions/spock_sub_show_status.md`):

| status | documented meaning |
|---|---|
| `replicating` | worker running, initial sync complete, "changes from the provider are being applied normally" |
| `initializing` | worker running, initial sync not complete |
| `disabled` | subscription disabled, worker not running |
| `down` | enabled but worker not running |
| `unknown` | worker running, no sync status row (transient) |

ZODAN Phase 7 and operators use this function as a health signal.

The code computes it from two facts only (`src/spock_functions.c:1437-1540`):
`spock_worker_running(apply)` (`worker && worker->proc`,
`src/spock_worker.c:651-654`) and the subscription-level sync row. It does not
check `sub_enabled` while a worker exists, the connection, progress, table-level
sync rows, or whether the worker is terminating.

## Mismatches found in code

1. **Disabled but still `replicating`.** After `sub_disable` (or an automatic
   disable), the row is `replicating` until the worker exits. The manager
   SIGTERMs it, but SIGTERM is not seen inside blocking libpq calls,
   heavyweight/LWLock waits or `pg_usleep` (sut-analysis 2.1), so this can last
   as long as the worker is blocked.
2. **Stuck but `replicating`.** Workers blocked in
   `wait_for_sync_status_change` (L12), in `wait_for_previous_transaction`
   (L30), in a pause (L4), or reading a silently dead connection until
   `apply_idle_timeout` (L26) all show `replicating`.
3. (Moved out of this property in the investigation pass; see findings.)
   `sub_show_table` has no case for `'p'` STARTED or `'f'` FAILED and prints
   `unknown` (`sync_status_to_string` `:1359-1382`).

## Invariant

Workload-side `Always` ("sub_show_status replicating is truthful within a
bound"), evaluated in quiet periods after faults have healed:

- The workload issues `sync_event()` on P and
  `wait_for_sync_event(P, lsn, timeout => B)` on S, while sampling
  `sub_show_status()` on S every few seconds.
- If the barrier times out **and** every sample during the wait said
  `replicating`, fail. B must exceed the documented detection bound:
  `apply_idle_timeout + restart_delay_default + connect_timeout + margin`
  (with the harness `apply_idle_timeout` of 120 s, about 120 + 5 +
  30 + margin seconds).
- Second message ("sub_show_status disabled matches catalog"): if
  `sub_enabled = false` in two samples at least
  `restart_delay_default + 5 s` apart, the later sample must say `disabled`.

## Why it matters

A health check that says `replicating` while nothing is being applied hides the
silent drift in L12 and makes ZODAN and operator scripts proceed on a false
signal. It is also how a stuck table resync stays invisible.

## Findings from the investigation pass (2026-10-13)

- **Code re-checked at HEAD.** `sub_show_status` (`src/spock_functions.c:1488-1516`)
  returns `replicating` when `spock_worker_running(apply)` and the
  subscription-level sync row is READY; `sub_enabled` is consulted only when
  no worker is running. Mismatches 1 and 2 stand.
- **Where the documented meaning came from.** The status table in
  `docs/spock_functions/functions/spock_sub_show_status.md` was added in
  docs commit 84edbd74, whose message says the values were "derived from
  the C source". The phrase "changes from the provider are being applied
  normally" is the writer's gloss on that code, not a separate design
  statement. This weakens the "docs promise data flow" reading but does not
  settle what maintainers intend.
- **FAILED is a table-level state by design.** Commit 6a063b22 added
  `SYNC_STATUS_STARTED`/`SYNC_STATUS_FAILED`, hard-codes `stop_on_error`
  for table syncs only (`src/spock_sync.c:2208-2218`), and surfaces FAILED
  by making `wait_for_table_sync_complete` raise an ERROR
  (`src/spock_functions.c:3503-3540`); extending it to subscription level is
  listed as a follow-up. So a FAILED table is not meant to change
  `sub_show_status`. Mismatch 3 is a separate display gap (that commit did
  not update `sync_status_to_string`, so `sub_show_table` prints `unknown`
  for `p` and `f`; FAILED is visible in `spock.local_sync_status`). It is
  dropped from this property's invariant; a workload check that a table
  stuck in `p`/`f` shows up as `unknown` (not `replicating`) can live with
  the table-sync properties.

## Open questions

- Is `replicating` meant to mean "worker exists and initial sync done"
  (code) or "changes are being applied" (docs)? If the code meaning is
  intended, the first assertion should be dropped and the docs fixed.
  `(needs human input)`

### Investigation Log

#### Is `replicating` meant to mean "worker exists and initial sync done" or "changes are being applied"?

- Examined: `src/spock_functions.c:1437-1540`, the doc page, `git show
  84edbd74` (doc table origin), git log of `spock_functions.c`, ZODAN use of
  `sub_show_status` (Phase 7).
- Found: docs table written from the code by a docs author; no design note
  or commit states that `replicating` should imply data flow.
- Not found: any maintainer statement of intent.
- Conclusion: `(needs human input)`. The disabled-catalog check (second
  message) does not depend on this answer and stays.

#### Should a FAILED table make the subscription-level status anything other than `replicating`?

- Examined: commit 6a063b22 message and diff, `src/spock_sync.c:1846-1875,
  2208-2218`, `src/spock_apply.c:4490-4515, 4605-4620`,
  `src/spock_functions.c:1300-1315, 1359-1382, 3495-3540`,
  `tests/regress/expected/sync_table.out:333-370`.
- Found: FAILED is intentionally table-scoped; sub-level reporting is a
  listed follow-up.
- Conclusion: resolved: no. Mismatch 3 moved out of this property.
