# operator-recovery-steps-restore-replication

Surfaced by: evaluation gap (a) item 2 (wildcard W4). Gap (a) proposed
absorbing the investigation candidate `table-resync-under-faults-ends-ready`
(G1) here; gap (b) folded it into `apply-never-waits-on-dead-sync-worker`.
Merge decision (2026-10-13): the resync retry assertion lives in
`apply-never-waits-on-dead-sync-worker` ("retried table resync reaches
READY after faults stop"); this property runs the resync as one operator
step and counts it in its `Sometimes`, but does not assert it a second
time.

## Why this property exists

Spock relies on operators for several recoveries: interrupted initial sync
leaves a disabled subscription; an interrupted table sync leaves a FAILED
table that apply skips (L12, L13); a failed ZODAN add_node needs
`remove_node` and a retry (`docs/modify/zodan/index.md` hint: "Zodan
simplifies removing partially added nodes created during failed node add
operations"); a `down` subscription is restarted with `sub_disable` +
`sub_enable` (`docs/troubleshooting.md:340-356`). The catalog stops at
"visible failure is acceptable" and never checks that the documented
recovery step works. If it does not, a visible failure is in practice a
permanent one.

## Recovery steps the workload runs (as the operator)

| Visible failure | How the workload sees it | Documented step |
|---|---|---|
| Subscription disabled (by the workload's own admin churn, by `sub_disable` mode, or by Spock) | `spock.subscription.sub_enabled = false` | `spock.sub_enable(name, immediate := true)` (`sql/spock--6.0.0.sql:255`). Under `sub_disable` mode with a known poison txn, `sub_alter_skiplsn` first, and the skipped txn is recorded as expected-missing |
| Subscription `down` but enabled | `sub_show_status` | `sub_disable` then `sub_enable` (`docs/troubleshooting.md`) |
| Initial sync interrupted in `s`/`d`/`c` (subscription disabled, status stays) | `local_sync_status` + `sub_enabled` | `sub_enable` alone re-disables (catalog, `initial-sync-ends-ready-or-visibly-disabled`); drop and re-create the subscription |
| Table FAILED (`f`) or stuck non-`r` | `spock.local_sync_status`, `spock.sub_show_table` (prints `unknown` for `f`, G8) | `spock.sub_resync_table(sub, table)` with default `truncate := true`, then `spock.table_wait_for_sync` |
| add_node raised or left partial state | add_node error, missing subs to/from n4 | `remove_node` (Z0DAN) from n4, then retry `add_node` |
| `spock.readonly` left on | `SHOW spock.readonly` | set `off` and reload |

Ordering rule for resync: `sub_resync_table` truncates the local table and
copies the provider's. Run it only after barriers on every other ordered
pair into the provider have passed, so the provider holds every row from
every origin; otherwise rows that reached the subscriber but not yet the
provider are lost from the subscriber's copy by design. The app table
(`every-divergence-explained-by-spock-records`) is never resynced: a resync
would erase the differences that oracle scores.

During fault phases the operator loop also runs these steps when it sees a
failure. Under faults a step may fail; that is not scored here (the data
properties catch any harm the step does). Scoring happens when faults are
off (in the strict round and in requested quiet periods).

## Assertions

Workload-side, scored only when faults are off:

- `Always(sub enabled, replicating and its barrier passes within bound, "operator recovery: re-enabled subscription replicates again within bound")`.
- Resynced table reaching READY: asserted by
  `apply-never-waits-on-dead-sync-worker` (`Always("retried table resync
  reaches READY after faults stop")`), not repeated here.
- `Always(new subscription reaches r and barrier passes within bound, "operator recovery: re-created subscription after interrupted initial sync replicates within bound")`.
- `Always(retry add_node succeeds within bound, "operator recovery: add_node retry after cleanup succeeds")`.
  Only scored when faults are off for the whole retry.
- `Sometimes(step ran and the next strict round passed, "operator recovery: <step> ran and the next strict round passed")`,
  one message per step above, so a green run shows each recovery path was
  actually used.

Bounds: as in `mesh-barriers-complete-after-partition-heal` for
re-enabled subscriptions; for resync add COPY time for the table size; for
add_node use `spock.sync_timeout()`-based budgets from Z0DAN.

## What a failure means

A documented recovery step that does not restore replication with faults
off. Known paths that could cause it: L12 (stale SYNC slot makes the apply
worker wait on a dead sync worker), the sync worker ignoring SIGTERM until
COPY ends (G7), ZODAN leftovers that make a retry fail (L20,
`remove-node-clean-report-no-leftovers`), stale progress rows on re-add
(`zodan-readd-node-progress-not-stale`).

## Instrumentation

None exists. All workload-side.

## Open questions

- Is drop-and-re-create the intended recovery for a subscription whose
  initial sync stopped in `s`/`d`/`c`, or should `sub_enable` work? The
  catalog notes `sub_enable` re-disables; the docs do not say which step to
  use.
- Should v1 run `sub_resync_table` during fault phases at all? The catalog
  has this as a catalog-wide open question (it makes
  `progress-reconcile-anomaly-unreachable` reachable with no fault). This
  property needs resyncs at least in the final round.
- What bounds does the team accept for each step? Same question as in
  `mesh-barriers-complete-after-partition-heal`.

### Investigation Log

#### What are the documented operator steps?

- Examined: `docs/troubleshooting.md` (Subscription Down Status),
  `docs/spock_functions/functions/spock_sub_resync_table.md`,
  `docs/modify/zodan/index.md`, `sql/spock--6.0.0.sql` signatures for
  `sub_enable`, `sub_resync_table`, `table_wait_for_sync`, `sync_event`;
  catalog entries `initial-sync-ends-ready-or-visibly-disabled` and
  `apply-never-waits-on-dead-sync-worker`.
- Found: the table above. `sub_resync_table` truncates by default and the
  doc warns that without truncate, conflicts may cause errors. No doc gives
  a step for a subscription disabled mid initial sync.
- Conclusion: steps listed; the initial-sync recovery step is an open
  question.
