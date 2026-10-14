# enabled-subscription-always-has-provider-slot

## Why this property

`spock.sub_drop` is not atomic across the two nodes it touches
(`spock_drop_subscription`, `src/spock_functions.c:762-866`, code-checked):

1. delete sync-status rows and the `spock.subscription` row (uncommitted);
2. if no other sub uses the provider node, drop its node/interface rows;
3. SIGTERM the apply worker and wait (no timeout) for it to exit;
4. **open a new connection to the provider and drop the remote slot**
   (`spock_drop_remote_slot`, `:845-859`) — this takes effect on the provider
   immediately, it is not part of the local transaction;
5. drop the local origin; return; local COMMIT happens later.

If the subscriber backend or node dies (kill -9, OOM, `pg_terminate_backend`
of the caller, statement cancel) after step 4 and before the local COMMIT, the
local transaction rolls back: the subscription row is back and **enabled**,
but its slot no longer exists on the provider. The manager restarts the apply
worker, `START_REPLICATION SLOT ...` fails with "replication slot does not
exist", the worker exits with ERROR before its first BEGIN and is retried every
`restart_delay_default` forever. Nothing is written to `spock.exception_log`;
`sub_show_status` flips between `down` (worker not running) and
`replicating` (worker running, sync status READY) — corrected from an
earlier "initializing", see Investigation Log. Changes from that
provider are never received again, so the two nodes diverge permanently, and
recovery needs an operator. The same window exists for ZODAN `remove_node`,
which runs `sub_drop` on peers over dblink (`samples/Z0DAN/zodremove.sql`),
and for a dblink session that is cut mid-call.

The reverse case (local commit succeeds but the remote drop failed because the
provider was unreachable) is acknowledged by a WARNING ("you will probably have
to drop it manually", `:856`) and leaks a slot that pins WAL (L28). That is
documented behaviour, so it is not part of this property's Always; it is
recorded with a Sometimes for visibility.

Also checked: the manager cannot restart the killed worker during step 3-5
because `sub_drop` holds the local-node lock via `get_local_node(true, false)`
and the manager's `get_local_node(true, true)` blocks on it
(`src/spock_manager.c:59`, `src/spock_node.c:721`).

## Invariant and assertions

- Workload (Always, evaluated in a quiet period with all nodes up and
  reachable): for every row in `spock.subscription` on node X with
  `sub_enabled = true` and sync status READY, the provider has a logical slot
  named `sub_slot_name` (`pg_replication_slots`). Always because an enabled
  subscription with no slot is permanently broken.
  Scope: exclude subscriptions whose sync status is INIT (the slot is created by
  the initial sync) and the ZODAN Phase 3 disabled subs (not enabled).
- Workload (Sometimes): `Sometimes(orphan slot found for a dropped subscription)`
  — slot on a provider with no matching subscription on any node after a
  committed `sub_drop`/`remove_node`. Documents that the acknowledged leak path
  was reached; not a failure.
- SUT-side (missing, no existing assertions): `Reachable("sub_drop dropped remote slot before local commit")`
  right after `spock_drop_remote_slot` succeeds, so the window is known to be
  hit.

## Antithesis angle

Kill the subscriber node, or the session running `sub_drop` / `remove_node`,
at random points; partition subscriber from provider during `sub_drop`. The
window between remote drop and local commit is short (milliseconds) but
Antithesis can place a kill there; a pause of the subscriber process inside it
makes it wider.

## Fault requirements

Node termination (required) or killing the backend that runs `sub_drop`;
network partition for the orphan case. The workload must run `sub_drop` or
`remove_node` (the n4 add/remove loop does).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW3, implementability CW4/CW5); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: node kill during sub_drop / remove_node

- Evaluation note (2026-10-13): run on a throwaway subscription with its own replication set and table (dropping a mesh subscription breaks the shared oracles); start `sub_drop` and call the crash helper after a small random delay, since random kills rarely land between the remote slot drop and the local commit.

## Open questions

- Is dropping the remote slot before the local commit a deliberate trade-off
  (accepting "enabled sub without slot" on rollback to avoid an orphan slot)?
  The order is unchanged since the initial import from pglogical
  (`git log -L` on the block shows only the initial commit, a rename pass and
  a pgindent pass) and no comment explains it. If the team prefers an orphan
  slot, the fix is to drop the slot after commit (e.g. in an xact callback);
  the property stays the same. `(needs human input)`

### Investigation Log

#### Is the early remote slot drop a deliberate trade-off?

- Examined: `spock_drop_subscription` (`src/spock_functions.c:762-858`) and
  its history (`git log -L` on the remote-drop block: `527af0a6` initial
  commit, `20697827` rename, `1cef6e4b`, `e73c5b44` pgindent).
- Found: the only comment is "we can't fail here since we can't assume that
  the remote node is still reachable", which covers the orphan case, not the
  rollback case.
- Not found: any design note, doc or test covering a rollback after the
  remote drop.
- Conclusion: `(needs human input)`.

#### Does any monitoring report "slot missing" to the operator?

- Examined: `spock.sub_show_status` (`src/spock_functions.c:1430-1540`),
  `spock_apply_main` start-up path (`src/spock_apply.c:4733-4795`),
  `sql/spock--6.0.0.sql` uses of `pg_replication_slots`,
  `docs/troubleshooting.md`.
- Found: the `START_REPLICATION` failure is a plain ERROR outside
  `apply_work`'s PG_TRY, so nothing reaches `spock.exception_log`; the worker
  exits with error and is restarted every `restart_delay_default`.
  `sub_show_status` reports `replicating` while the new worker is alive
  (sync status is READY) and `down` between attempts. The only SQL that reads
  `pg_replication_slots` is the initial-sync helper and `node_drop`.
  Troubleshooting docs tell the operator to look at `pg_replication_slots` by
  hand.
- Not found: any check comparing a subscription with its provider slot.
- Conclusion: resolved. Only the server log ("replication slot ... does not
  exist") shows it; the status view can even say `replicating`. This makes the
  failure harder to see, which supports keeping it high priority. The
  property itself is unchanged.
