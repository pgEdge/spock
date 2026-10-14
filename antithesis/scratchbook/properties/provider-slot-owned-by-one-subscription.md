# provider-slot-owned-by-one-subscription

## Why this property exists

The provider-side slot name does not include the subscriber node. Two
subscriber nodes that give their subscriptions to the same provider the same
name get the **same** slot on the provider. Spock never checks whose slot it
is. The initial-sync code drops any inactive slot with that name, and the
error cleanup and `sub_drop` drop it too. So a naming choice that every
per-node check accepts can make two subscribers share or destroy each other's
slot, and the data loss is silent.

This sits between naming (input validation), lifecycle (initial sync, error
cleanup, drop) and network faults (the slot must be inactive at the wrong
moment). No single focus area owns it.

## Code path (HEAD 69d9228f)

- `gen_slot_name`, `src/spock_functions.c:3666-3687`: format
  `spk_<subscriber db>_<provider node>_<subscription name>`, each part through
  `shorten_hash(...,16)`, then every char outside `[a-z0-9_]` (including
  uppercase) becomes `_`. No subscriber node name or id.
- `shorten_hash`, `src/spock.c:213-228`: names longer than 16 chars become an
  8-char prefix plus hash. `snprintf(ret, maxlen, ...)` writes at most
  `maxlen-1` chars, so only 7 of the 8 hex digits survive (28 bits). Minor.
- Subscription name uniqueness is only checked in the local
  `spock.subscription` catalog.
- `spock_create_slot_and_read_progress`, `src/spock_sync.c:665-676`: runs
  `pg_drop_replication_slot(name) WHERE ... NOT active` on the provider, then
  `CREATE_REPLICATION_SLOT`. Comment: "Drop an existing inactive slot so we can
  re-create it cleanly". It assumes the slot is its own leftover.
- `spock_sync_worker_cleanup`, `src/spock_sync.c:1428-1465`
  (`PG_ENSURE_ERROR_CLEANUP` callback): waits in a loop until the remote slot
  is not active, then `spock_drop_remote_slot`. If the second subscriber's
  `CREATE_REPLICATION_SLOT` fails with "already exists" because the first
  subscriber is streaming, this cleanup waits for the first subscriber's next
  disconnect and then drops **its** slot.
- `spock_drop_subscription`, `src/spock_functions.c:~850`: drops the remote
  slot by name. Dropping the "wrong" subscription on n3 destroys n2's slot.
- `spock_drop_remote_slot`, `src/spock_rpc.c:243-...`: only checks the plugin
  is spock, not ownership.

## Failure scenarios

Names: n2 and n3 both create `sub_from_n1` (or `sub_n1`, or any names that
differ only in uppercase letters, for example `sub_A`/`sub_B` both map to
`sub__`) against provider n1, same database name.

1. n3's initial sync runs while n2's apply worker is disconnected (partition,
   restart, `restart_delay`): n3 drops n2's slot and creates a new one at the
   current LSN. n2 reconnects to a slot that starts later than n2's origin
   position -> n2 silently misses everything in between.
2. n2 is connected: n3's `CREATE_REPLICATION_SLOT` fails, ERROR cleanup waits
   for the slot to go idle, then drops it. Same loss for n2 at its next
   disconnect.
3. If both end up attached to one slot over time (each reconnects whenever the
   other is down), each subscriber confirms positions the other never received.
   Both silently lose interleaved stretches of the stream.

ZODAN names subscriptions `sub_<provider>_<subscriber>`
(`samples/Z0DAN/zodan.sql:67`), and the docs use `sub_n2_n1`
(`docs/two_node_cluster.md:55-57`), so the default paths do not collide. The
risk is for users who create subscriptions by hand with names that describe
only the provider.

## Property

At every check, each `spock_output` slot on a provider is the slot of exactly
one subscription in the cluster, and no subscription loses changes because
another node's subscription used its slot.

- Workload-side `Always` (periodic, cheap): join every node's
  `spock.subscription` (slot name, provider) across the cluster and assert no
  two subscriptions on different nodes map to the same provider slot that both
  are using. Message: "provider slot used by at most one subscription".
- Workload-side `Always` at quiescence: ledger completeness for the colliding
  subscribers (rows from n1 present on n2 and n3).
- SUT-side (missing, no existing assertions): `Unreachable` in
  `spock_create_slot_and_read_progress` and `spock_sync_worker_cleanup` when
  the slot about to be dropped has a `confirmed_flush_lsn` past the point this
  subscription's local origin knows about (a cheap sign that someone else used
  it). Also `Unreachable` in the walsender startup path if the requesting
  subscriber's node id differs from the node that created the slot (would need
  the owner recorded somewhere, which Spock does not do today).

## Workload requirements

A separate test configuration (not the main mesh) where the setup names the
n2<-n1 and n3<-n1 subscriptions the same. The main mesh must keep
`sub_<provider>_<subscriber>` names. Expected outcome under the current code:
the ledger check fails after a partition or restart of n2 during or after n3's
initial sync. If the team treats this as user error, the property becomes "the
collision is rejected with an error", which is a Reachable/Always on the
rejection.

## Fault requirements

- Network partition or node restart of one subscriber around the time the
  other runs initial sync (scenario 1), or any later disconnect (scenario 2).
- No special faults for detection; the catalog check fires as soon as the
  configuration exists.

## Confidence

High on the mechanism (all four code sites read). Medium on whether the team
considers it a defect or misconfiguration, which changes the assertion from
"no loss" to "rejected up front".

## Findings from open-question investigation (HEAD 69d9228f, code and docs read)

- **Cluster-wide uniqueness is documented but not enforced, and the
  documented rule is not enough.** `docs/spock_functions/functions/spock_sub_create.md`
  (ARGUMENTS, `subscription_name`, added in `d2107de6`) says "Must be unique
  across the cluster." Nothing checks it. More important, `gen_slot_name`
  (`src/spock_functions.c:3666-3687`) maps every character outside
  `[a-z0-9_]` to `_`, so names that **are** unique, as the docs require, still
  collide: `sub_A` / `sub_B`, `sub-1` / `sub.1`, any names differing only in
  upper-case letters, punctuation or non-ASCII. The same mapping applies to
  the provider node name and database name parts. The origin name is the same
  string (`sub->slot_name` is used for `replorigin_by_name`), so the
  subscriber-side origin collides too when two subs on one node map alike
  (that case is caught locally only if the generated name is checked; not
  traced).
- **Effect on the property.** Two cases now:
  1. Names that break the documented rule (same name on two nodes): user
     error; the right outcome is a rejection at `sub_create`. Lower priority,
     usability.
  2. Names that follow the documented rule but map to the same slot: silent
     data loss through a documented-valid configuration. This is the case the
     separate test configuration should use (e.g. n2 creates `sub_A`, n3
     creates `sub_B`, both against n1). Priority unchanged for this case.
  The invariant ("each provider slot belongs to exactly one subscription") is
  the same for both; only the test configuration and the expected fix
  differ.
- The note about slot groups is not a question about this property: the same
  character mapping can turn on slot groups (sut-analysis L10) when a mapped
  name ends in `_<digit>`. Test configurations for this property should avoid
  such names so the two problems are not mixed.

## Open questions

- Should slot names include the subscriber node (or be checked for an owner)?
  Changing the format affects existing slots and origins on upgrade and the
  ZODAN code that recomputes slot names with `spock.spock_gen_slot_name`
  (`samples/Z0DAN/zodan.sql:1770, 1867, 2516, 2617`). Design choice for the
  team; does not change the invariant. `(needs human input)`

### Investigation Log

#### Is cluster-wide unique subscription naming a documented requirement?

- Examined: `docs/spock_functions/functions/spock_sub_create.md`,
  `docs/spock_functions/sub_mgmt.md`, `spock_gen_slot_name.md`,
  `gen_slot_name`, `shorten_hash`.
- Found: documented ("Must be unique across the cluster"), not enforced; the
  character mapping makes distinct names collide.
- Conclusion: resolved. Property keeps its invariant; the test configuration
  should use names that obey the docs but collide after mapping.

#### Should slot names include the subscriber node?

- Examined: ZODAN callers of `spock_gen_slot_name`; origin naming (same string).
- Found: four ZODAN call sites and the origin name depend on the format.
- Conclusion: `(needs human input)`; design choice.

#### Slot-group interaction (L10)

- Not a question for this property; recorded as a test-configuration rule
  above.
