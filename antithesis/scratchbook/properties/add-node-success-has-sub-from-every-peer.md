# add-node-success-has-sub-from-every-peer

## What the property says

When ZODAN `spock.add_node` returns without error, the new node n4 has an
**enabled** subscription from every node that was a member when add_node
started, and every such node has an enabled subscription from n4. In other
words, a successful add produces a full mesh, not a partial one.

## Why this can fail (code-checked)

`create_disable_subscriptions_and_slots` (`samples/Z0DAN/zodan.sql:1794`) loops
over the existing nodes. For each it creates the slot X->n4, triggers a sync
event, waits on src, then calls `spock.create_sub(... enabled=false ...)`
inside a `BEGIN ... EXCEPTION WHEN OTHERS THEN RAISE NOTICE ... END` block
(`:2017-2036`). An error there (connection loss to n4 or X, a timeout,
"slot is active", a name clash after a previous partial add) is printed as a
NOTICE line starting with "✗ Creating initial subscription" and the loop
continues. add_node then proceeds through Phases 4-14 and returns normally.

Consequences:

- Phase 9 has no disabled sub for X to enable, so X's changes after the COPY
  snapshot never reach n4. The new node silently misses part of the cluster.
- Phase 7 still finds the slot X->n4 (created earlier in Phase 3) and may
  advance it; with no progress entry it falls back to X's
  `pg_current_wal_lsn()` (NOTICE text "falling back to pg_current_wal_lsn()").
- The slot X->n4 has no consumer and pins WAL on X.

Other phases with warning-only handling: Phase 7's READY wait (warning on
timeout), Phase 12 `monitor_replication_lag` (NOTICE after 60 s). sut-analysis
L20.

## Assertion

Workload, right after `CALL spock.add_node` returns success (and again after
the post-fault barrier round, to rule out a transient state):

```sql
-- on n4
SELECT n.node_name, s.sub_enabled
  FROM spock.subscription s JOIN spock.node n ON n.node_id = s.sub_origin;
-- on each Xi
SELECT s.sub_enabled FROM spock.subscription s
  JOIN spock.node n ON n.node_id = s.sub_origin WHERE n.node_name = 'n4';
```

`Always(every member has an enabled sub to n4 and from n4, "add_node success implies full mesh around new node")`.
Always fits: this is a postcondition of a reported success, checked every time.

This is a cheaper and more direct check than the row-level
`add-node-success-new-node-has-every-row`, and it names the cause.

## Scope

- Only after add_node returned without error.
- A subscription disabled later by the exception handler (SUB_DISABLE mode)
  is a different failure; check `sub_enabled` immediately after add_node, when
  no replicated data error has had time to happen, and treat later disables
  under the exception properties.

## Fault requirements

- Network partition between n4 and one existing node X, or between n4 and
  itself over its own DSN (create_sub on n4 goes through dblink to
  `new_node_dsn`), during Phase 3.
- Node pause of X during Phase 3.

## Open questions

None remain open (see Investigation Log).

## Findings (2026-10-13): the main lead is closed at HEAD

The Phase 3 NOTICE does **not** let add_node return success without the
X->n4 subscription. Phase 9 (`enable_disabled_subscriptions`,
`samples/Z0DAN/zodan.sql:2144-2210`) loops over the same peers from
`temp_spock_nodes` and calls `spock.sub_enable('sub_<X>_<n4>')` on n4 for
each. `spock_alter_subscription_enable` looks the sub up with
`get_subscription_by_name(name, false)` (`src/spock_functions.c:912`), which
raises when it is missing. Phase 9 wraps the loop in an exception handler
that re-raises (`RAISE EXCEPTION`), and the add_node body (`:2882-2955`) has
no handler around Phase 9. Phase 9 also calls
`verify_subscription_replicating` for each sub, which raises after its
timeout. Phase 10 (`create_sub_on_new_node_to_src_node`, `:2232-2275`)
creates n4->X on every X and also re-raises errors (since commit 3250807a,
SPOC-388, "Change RAISE NOTICE to RAISE EXCEPTION ... instead of silently
continuing").

Consequences for the property:

- It stays valid (a true postcondition of a reported success) but is now a
  cheap regression guard, not a probe of a known gap. Suggest lowering its
  priority.
- The failure scenario above ("Phase 9 has no disabled sub for X to enable")
  and the Phase 7 fallback note describe a timeline that ends in an add_node
  **error** at Phase 9, not a success. What remains is the leftover state
  after that failure (slot X->n4 pinning WAL on X), which the cleanup
  procedure is documented to handle.
- The "check again after barriers" step is still useful: a sub disabled
  later by SUB_DISABLE is a separate failure (scope note above).

### Investigation Log

#### Is success with a missing Phase 3 subscription intended?

- Examined: `samples/Z0DAN/zodan.sql:1794-2040` (Phase 3), `:2882` add_node
  body, `docs/modify/zodan/zodan_tutorial.md` (claims of no data loss),
  `docs/modify/zodan/index.md:18-22` (partial adds may need cleanup).
- Found: the catch block is deliberate code (`EXCEPTION WHEN OTHERS THEN RAISE
  NOTICE`); other steps in the same procedure use `RAISE EXCEPTION` on
  failure (slot creation, sync event), so the inconsistency looks accidental.
- Not found: any doc saying add_node can succeed with a partial mesh.
- Conclusion: needs human input.

(2026-10-13, re-investigation) 

- Examined: Phase 9 `enable_disabled_subscriptions` (`zodan.sql:2048-2210`),
  `spock.enable_sub` (`:710-745`), `verify_subscription_replicating`
  (`:750-790`), Phase 10 (`:2232-2275`), add_node body (`:2882-2955`),
  `spock_alter_subscription_enable` (`src/spock_functions.c:908-921`),
  `git show 3250807a`.
- Found: a missing sub makes Phase 9 raise; add_node does not catch it.
  3250807a touched the Phase 3 `create_sub` block (moved `sub_name`) but left
  it as a NOTICE while converting nearly every other handler, so the NOTICE
  is probably an oversight, but Phase 9 catches the effect anyway.
- Not found: a timeline where add_node returns with a member missing a sub
  to or from n4.
- Conclusion: resolved (no longer needs human input). Success with a
  missing Phase 3 sub cannot happen at HEAD; the property stays as a
  regression guard. Whether the Phase 3 NOTICE should become an exception
  (fail earlier, with a clearer message) is a cleanup question for the
  team, not a correctness one.
