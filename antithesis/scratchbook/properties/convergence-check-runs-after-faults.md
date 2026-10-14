# convergence-check-runs-after-faults

## Why this property exists

Most Spock safety properties are checked at a quiescent point: stop writes,
wait for every ordered pair with `sync_event` + `wait_for_sync_event`, then
compare nodes. In a fault-heavy run that point may never come, or it may come
only before the first fault, or only with every subscription disabled, or with
almost no data. Then every convergence `Always` passes without checking
anything. Antithesis reports a passing `Always` that ran zero times, or ran only
in easy states, the same way as a real pass.

This is the "too obvious to assert" property the focus set does not own: it
checks the oracle, not the SUT. It also covers a Spock-specific trap: the
barrier itself can stall for 300 s (`spock.apply_idle_timeout`) after a silent
partition, and a disabled subscription (`sub_disable` mode, or
`wait_if_disabled=false`) makes `wait_for_sync_event` return early, which can
let a check run against a pair that is not replicating at all.

## Code facts the harness depends on

- `wait_for_sync_event(OUT result, origin, lsn, timeout, wait_if_disabled)`
  (`sql/spock--6.0.0.sql:685-780`): `timeout=0` waits forever; result `false`
  on timeout; returns when the subscription is disabled unless
  `wait_if_disabled`.
- `sub_show_status = 'replicating'` does not mean caught up (sut-analysis 5.4).
- `update_origin_differs` conflicts are never in `spock.resolutions`
  (`src/spock_conflict.c:393-419`), so an "explained by resolutions" oracle
  cannot explain update/update divergence; the checker must not rely on it for
  those.
- Liveness bound for a barrier after faults heal is about
  `restart_delay_default + connect_timeout + keepalives` or
  `apply_idle_timeout + 5 s` (sut-analysis V1).

## Property

Each of these must become true at least once per run (`Sometimes`), each with
its own message:

1. "convergence check completed after at least one node kill": a full
   cross-node comparison finished with every barrier returning `true`, after
   the run had injected at least one node termination.
2. "convergence check completed after a partition healed": same, after at
   least one network partition.
3. "convergence check covered rows from every origin": the compared data set
   held at least N ledger rows from each of n1, n2, n3 (N chosen so lost or
   doubled transactions are not drowned, for example 100).
4. "convergence check ran with all subscriptions enabled": no
   `sub_enabled = false` at the time of the check.
5. "convergence check ran on the joined node": n4 included after a successful
   add_node.

And one `Always`: "barrier returned true only for enabled subscriptions" — the
harness never treats a `wait_for_sync_event` result as a pass when the
subscription was disabled during the wait (check `sub_enabled` before and
after).

All workload-side. No SUT instrumentation needed.

## Fault requirements

None of its own. It needs the run to include node termination and partitions,
and quiet periods long enough for barriers (at least `apply_idle_timeout`; the
plan now sets it to 120 s with `wal_sender_timeout` 60 s; evaluation 2026-10-13).

## Confidence

High that the property is needed (standard anti-vacuity practice; Spock's
300 s detection backstop and early return on disabled subscriptions make
vacuous passes likely). The exact thresholds are harness choices.

## Findings from the investigation pass (2026-10-13)

- **Quiet periods are under workload control.** Antithesis docs ("Pausing
  faults"): any test command can call `"$ANTITHESIS_STOP_FAULTS" <seconds>`
  to stop faults for a chosen time (killed containers are restored,
  overlapping requests merge to the longest), and `eventually_`/`finally_`
  commands stop all faults at the end of a timeline and kill other
  commands. So checks 1 and 2 do not depend on tenant-chosen quiet periods:
  the convergence driver must request its own pause sized to the barrier
  bound (`mesh-barriers-complete-after-partition-heal`) plus compare time,
  and retry until restored containers accept connections. Docs warn that
  `eventually_`/`finally_` commands are not guaranteed to run on every
  timeline, which is one more reason for these `Sometimes` markers.
- **Clock skips continue during `ANTITHESIS_STOP_FAULTS` pauses.** A
  barrier that returns false because the clock jumped is not a convergence
  failure; re-run it once.
- **Timeouts: retry here, report elsewhere.** This property only tracks
  that a full check completed. A barrier that times out inside a quiet
  period is the liveness failure owned by
  `mesh-barriers-complete-after-partition-heal`; the convergence driver
  should not raise its own failure for it, only skip that check (so the
  `Sometimes` markers here stay honest).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard W1/W4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P0 (every data property depends on it) · Topology: v1 · Faults: all

- Evaluation note (2026-10-13): quiet periods must be sized for the new barrier bound (`wal_sender_timeout` 60 s + `apply_idle_timeout` 120 s + restart delay + connect timeout + margin, about 4-5 minutes). A strict no-exemption final round is a gap being filled separately.

## Gap-fill extensions (2026-10-13)

From the gap-fill step; see `discovery/gap-a-divergence.md` and `evaluation/synthesis.md`.

- Cross-reference: `strict-final-round-has-no-exemptions` runs every
  convergence check once in a fully healthy cluster with no state
  exemptions. Its `Sometimes("strict round completed with zero exemptions
  in a fully healthy cluster")` is stronger than this property's "ran with
  all subscriptions enabled". No change to the assertions here.

## Open questions

- None remaining from discovery.

### Investigation Log

#### How long are Antithesis quiet periods in this tenant?

- Examined: Antithesis docs `product/writing_tests/controlling_faults/pause_faults`
  and `test_templates/test_composer_reference` (via `snouty docs`).
- Found: the workload picks the length with `ANTITHESIS_STOP_FAULTS`;
  `eventually_`/`finally_` give an open-ended terminal pause. Clock skips
  are not paused by `ANTITHESIS_STOP_FAULTS`.
- Conclusion: resolved. Not a tenant setting; size the pause in the driver.

#### Should a check that times out be reported as a liveness failure or simply retried?

- Examined: this property's purpose (anti-vacuity), the sibling
  `mesh-barriers-complete-after-partition-heal` evidence file.
- Found: the liveness bound and its Always already live in the sibling
  property; reporting it twice would double-count one fault.
- Conclusion: resolved. Retry/skip here; the sibling property reports it.
  The bound itself is still an open human question there.
