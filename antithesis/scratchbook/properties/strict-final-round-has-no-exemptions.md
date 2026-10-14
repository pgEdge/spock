# strict-final-round-has-no-exemptions

Surfaced by: evaluation gap (a) item 2 (wildcard W4).

## Why this property exists

Each data property in the catalog has exemptions that make sense on their
own:

- `remote-transaction-all-or-nothing-per-node` skips nodes where the table
  is not `r`.
- `committed-ledger-row-reaches-every-node` reports disabled subscriptions
  separately instead of as loss.
- Every data check skips its round when a barrier times out.
- `initial-sync-ends-ready-or-visibly-disabled`,
  `sync-wait-functions-honor-contract` and
  `apply-never-waits-on-dead-sync-worker` accept "visibly failed" (disabled
  subscription, FAILED table) as a pass.
- Checks on n4 run only after a successful add_node.

Together, in a run with all faults on, the state that the strict checks
actually see may be a small, easy slice: a pair or a table can stay
exempted for the whole run and the run still looks green.
`convergence-check-runs-after-faults` has
`Sometimes("ran with all subscriptions enabled")`, but nothing shows that a
check ever ran with every table `r`, n4 joined and no exemption used.

This property adds a final round where the workload first plays the
operator (see `operator-recovery-steps-restore-replication`) and then runs
every convergence check with state exemptions turned off.

## State exemptions vs history attributions

Two kinds of "exemption" exist in the catalog, and only one can be removed:

- **State exemptions** depend on the cluster's current state: disabled
  subscription, table not `r`, barrier timed out, n4 not joined, readonly
  still on. After faults stop and the operator steps run, none of these
  should remain. The strict round removes them.
- **History attributions** depend on what happened earlier in the run: a
  duplicate on a node that was killed while the row was in flight (L1), a
  divergent key last written right after a restart (L3), keys on n4 copied
  by the join. These cannot be undone by recovery. The strict round keeps
  them, but each stays under its own attributed message (as in
  `every-divergence-explained-by-spock-records`), never folded into a pass.

## Design

Runs as a `finally_` test command (faults off, drivers stopped; the
Antithesis docs say `finally_`/`eventually_` commands are not guaranteed on
every timeline, which is why the `Sometimes` below matters). Clock skips can
still happen; a barrier or bounded wait that spans a detected clock jump is
re-run, not scored.

1. Wait for every node to accept connections (bounded).
2. Run the operator recovery steps until no state exemption is left, or
   until their bound expires (that failure belongs to
   `operator-recovery-steps-restore-replication`; the strict round then
   records "not healthy" and stops without scoring).
3. Health gate, checked and recorded: every in-scope subscription
   `sub_enabled = true` and `sub_show_status = 'replicating'`; every
   replicated table `r` in `spock.local_sync_status` on every node;
   `spock.readonly = off` on every node; n4 either fully joined (sub from
   and to every peer) or cleanly removed; `sync_event` +
   `wait_for_sync_event(..., wait_if_disabled := true)` true for every
   ordered pair, run twice with a short delay (barrier contract question in
   the catalog).
4. Re-run every convergence oracle with state exemptions off, each under a
   distinct message prefixed `strict round:`. At minimum: ledger complete on
   every node (n1-n3, plus n4 if joined); exactly-once audit; delta counters
   exact; contested rows equal; all-or-nothing on every node; app table
   explained; no orphan slots; connection count matches subscriptions.

## Assertions

Workload-side:

- `Always(each check passes, "strict round: <check name> passed with no state exemptions")`,
  one message per check. These re-use the existing oracles; a failure here
  that does not also fire the normal check means the normal check's
  exemption hid it.
- `Sometimes(all gates in step 3 held and every check in step 4 ran, "strict round completed with zero exemptions in a fully healthy cluster")`.
- `Sometimes(at least one state exemption existed at step 2 and the round still completed healthy, "strict round reached full health after recovering from exemptions")`,
  to show the round did not only run on easy timelines.
- `Sometimes(n4 joined and included, "strict round included the joined node")`.

No SUT-side instrumentation.

## Fault requirements

None of its own. Value comes from runs that leave behind disabled
subscriptions, FAILED tables and failed add_node attempts.

## Second-pass refinements (2026-10-13)

From the second evaluation pass on the gap-fill properties; see `evaluation/synthesis.md` "Second pass (gap-fill)".

- Implementability: the round needs recovery, barriers and every check in
  one fault-free stretch (several minutes). Run it as a `finally_` command
  and also as an `eventually_` command, so it scores on more timelines than
  those that reach the end of every driver.
- Overlap: it aggregates the existing oracles rather than adding a new one;
  a failure here names the check that failed, and the owning property's
  message (for example `committed-ledger-row-reaches-every-node`) is the
  one to triage. Recovery that does not reach full health is scored by
  `operator-recovery-steps-restore-replication`, not here.

## Open questions

- How long a terminal quiet period does a `finally_` command get, and is it
  enough for recovery plus every barrier plus the checks? The sum of the
  bounds (resync COPY time, `apply_idle_timeout`, `sync_timeout`) may be
  several minutes.
- Should n4 be required to be joined in the strict round (retry add_node
  until it succeeds), or is a clean removal acceptable? Retrying is closer
  to what an operator does; removal is faster.
- Barrier contract: whether a barrier that was reached must stay reached
  across a restart is open in the catalog; the strict round runs barriers
  twice until that is settled.

### Investigation Log

#### Which existing exemptions can a final round remove?

- Examined: catalog entries for the properties listed above; wildcard W4;
  `convergence-check-runs-after-faults` evidence (quiet periods under
  `ANTITHESIS_STOP_FAULTS`, clock skips continue).
- Found: the exemptions split into state (removable after recovery) and
  history attributions (not removable).
- Conclusion: the strict round removes state exemptions only; history
  attributions keep their own messages.
