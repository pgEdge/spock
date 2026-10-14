# remove-node-clean-report-no-leftovers

## What the property says

When ZODAN `spock.remove_node(n4, ...)` (run on n4,
`samples/Z0DAN/zodremove.sql:404-470`) finishes and its status table reports
no `ERROR` rows, then no surviving node still has (a) a subscription from n4
or (b) a replication slot that served one of n4's subscriptions. A removal
that reports itself clean must have cut every replication link to the removed
node on the survivors.

## Why it matters

A leftover slot on a survivor has no consumer and pins WAL there forever
(`restart_lsn` never moves), eventually filling the disk of a node that is
still serving traffic. A leftover subscription from n4 makes the survivor's
manager keep restarting an apply worker against a gone node. Neither shows up
in remove_node's result if it was swallowed. sut-analysis L28; section 12
already accepts that n4's last writes may exist on some survivors only, so
this property checks links, not data.

## Code (code-checked)

- `remove_node_subscriptions` (`zodremove.sql:147-250`):
  - For each survivor X: over dblink, look up X's subscription whose origin is
    n4 and run `spock.sub_drop(name, true)` on X (which drops the slot on n4).
    Errors are caught (`EXCEPTION WHEN OTHERS`), recorded in the session temp
    table `temp_removal_status` as `ERROR`, printed as NOTICE.
  - Then for each local subscription on n4 (X->n4): `spock.sub_drop` locally.
    `spock_drop_subscription` drops the remote slot on X inside
    `PG_TRY/PG_CATCH`; on failure it only logs
    `WARNING "could not drop slot ... you will probably have to drop it manually"`
    (`src/spock_functions.c:840-860`) and returns true. zodremove records
    `REMOVED`.
- So a partition between n4 and X during removal leaves X's slot for n4's
  subscription behind while the report says `REMOVED`. That is the case this
  property targets.
- `node_drop` on n4 drops n4's own `spk_*` slots (`src/spock_functions.c:343-360`);
  survivors are not touched by it.
- remove_node keeps going after any phase error; it does not raise.

## Assertion

Workload, before the call: on n4 read `SELECT sub_slot_name, n.node_name FROM
spock.subscription s JOIN spock.node n ON n.node_id = s.sub_origin` (the slots
that live on survivors). Call remove_node in the same session, then
`SELECT count(*) FROM temp_removal_status WHERE status = 'ERROR'`.

If that count is 0, on every survivor X:

- `SELECT 1 FROM pg_replication_slots WHERE slot_name = <recorded name for X>` returns nothing;
- `SELECT 1 FROM spock.subscription s JOIN spock.node n ON n.node_id = s.sub_origin WHERE n.node_name = 'n4'` returns nothing.

`Always(no leftover slot or subscription for n4 on any survivor, "remove_node clean report means survivors have no links to removed node")`.
Check again after faults stop, in case a survivor was briefly unreachable
for the check itself (the check, not remove_node, should be retried).

Optional companion (not a separate property): a survivor slot with
`active = false` whose `restart_lsn` has not moved for the whole quiet period
is the observable effect.

## Scope

- Only for runs where remove_node returned and reported no `ERROR` rows.
  Removal with ERROR rows is visible to the operator and acceptable
  (zodan_cleanup exists).
- Data on survivors that came from n4 is not checked (documented divergence).

## Fault requirements

- Network partition between n4 and one survivor during remove_node Phase 3.
- Node pause of a survivor (dblink has no timeout, so this can also hang
  remove_node; record the hang separately).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), wildcard W2, implementability CW7); see `evaluation/synthesis.md`.

Current catalog line: Priority: P3 · Topology: v1 · Faults: partition during remove_node

- Priority note: lowered from P2 in evaluation: a reporting gap with a known code cause that happens without a partition too; file it as a code-reading finding with a TAP repro and keep this as a cheap check.
- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): the WARNING in n4's server log is read through `logging_collector` and `pg_read_file`.

## Open questions

- Should zodremove record `spock.sub_drop`'s "could not drop slot ...
  drop it manually" WARNING in `temp_removal_status` (as `WARNING`/`ERROR`)
  instead of `REMOVED`? `(needs human input)`

## Findings (2026-10-13): the "slot is gone" form fires on intended behaviour

- **`sub_drop` succeeding when the remote slot drop fails is deliberate.**
  `spock_drop_subscription` (`src/spock_functions.c:838-860`): "Note, we
  can't fail here since we can't assume that the remote node is still
  reachable or even alive." zodremove's second loop runs
  `PERFORM spock.sub_drop(...)` and records `REMOVED` whenever it returns
  (`samples/Z0DAN/zodremove.sql:218-240`); the WARNING never reaches the
  status table.
- **It is not only a partition case.** `spock_drop_remote_slot` calls
  `pg_drop_replication_slot`, which errors at once if the slot is still
  active (`ReplicationSlotDrop(name, true)`, nowait, PG 17 `slotfuncs.c:230`).
  `sub_drop` on n4 stops n4's apply worker and then drops X's slot straight
  away; if X's walsender has not yet noticed the disconnect (normal under
  latency, up to `wal_sender_timeout` under a one-way or silent partition),
  the drop fails, a WARNING is logged, and the report says `REMOVED`.
- **A full n4-X partition usually does show up as `ERROR`**: the first loop
  dblinks from n4 to X for X's sub from n4, and that fails with an ERROR row.
  The hidden case is a link that fails (or a walsender that lingers) between
  the first loop and the second.
- **No "all nodes available" precondition for remove_node.** The docs state
  it for add_node only (`docs/modify/zodan/zodan_tutorial.md:23-24`) and
  present remove_node as the way to clean up after a failed add
  (`:131-136`); zodremove's only stated limit is "run this on the node you
  wish to remove" (`zodremove.sql:6`). So partitions during remove_node are
  in scope.

**Property change.** `Always(no leftover slot ...)` after a report with no
`ERROR` rows would fire on intended `sub_drop` behaviour. Restate as a
visibility property:
`Always(every survivor slot left for n4 after remove_node is reported, "remove_node reports every replication link it could not remove")`,
where "reported" means an `ERROR` (or new `WARNING`) row for that
subscription in `temp_removal_status`. At HEAD this is expected to fail
whenever the walsender race or a mid-call link failure happens, so it is a
known gap that depends on the open question; until the team answers, the
workload can also accept a matching "could not drop slot" WARNING in n4's
server log as "reported". Priority: medium/low (WAL growth on a survivor
over time, operator-visible only in logs).

### Investigation Log

#### Is it intended that `sub_drop` reports success when the remote slot could not be dropped, and that zodremove records `REMOVED`?

- Examined: `src/spock_functions.c:790-865` (`spock_drop_subscription`),
  `src/spock_rpc.c:243-295` (`spock_drop_remote_slot`), PG 17
  `src/backend/replication/slotfuncs.c:230`, `samples/Z0DAN/zodremove.sql:147-250`.
- Found: the `sub_drop` half is intended (code comment). zodremove never
  inspects the WARNING. The active-slot error is a second, fault-free way to
  hit it.
- Not found: any doc or comment on whether zodremove should surface it.
- Conclusion: `sub_drop` part resolved (intended); the zodremove reporting
  part needs human input. Property restated as above.

#### Should remove_node be run against a partitioned node at all?

- Examined: `docs/modify/zodan/zodan_tutorial.md`, `zodan_readme.md:75-120`,
  `index.md`, `zodremove.sql` header.
- Found: no availability precondition for remove_node; it is the documented
  cleanup tool after a failed add, which is often caused by an unavailable
  node.
- Conclusion: resolved. Partitions during remove_node are in scope.
