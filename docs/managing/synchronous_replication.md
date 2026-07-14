# Synchronous Spock Replication

Spock can use a **logical** standby — a normal Spock subscriber — as a
synchronous standby, in place of a synchronous *physical* replica. This is
useful when you want local HA/durability between two co-located
multi-master nodes while continuing normal **asynchronous** Spock
replication to the rest of the mesh.

Requires **PostgreSQL 17 or later** (stock PG16 lacks the required
`sync_standbys_status` field).

## Topology

The supported topology is a **synchronous multi-master pair**:

```
        synchronous (both directions)
   A  <============================>  S        (co-located, low latency)
   |                                   |
   |  async (normal Spock)             |  async (normal Spock)
   v                                   v
   B, C, ...  (rest of the mesh)       B, C, ...
```

- **A** and **S** are both writable, and each is the other's **synchronous**
  standby: a local write on A is not acknowledged to the client until S has
  the transaction durably (flushed), and vice versa.
- Both A and S continue to replicate **asynchronously** to the rest of the
  mesh (B, C, …), exactly as with any other Spock subscription.
- Async peers never receive a transaction before the synchronous standby
  has it, so a failover to S can never leave an async peer ahead of the
  surviving node.

A fully-synchronous N-way mesh (more than one synchronous peer with
cross-dependencies) is not a supported or tested configuration, and
neither is a node having both a physical synchronous standby and a Spock
synchronous replica at the same time — there is no code-level check that
rejects either.

## Enabling synchronous replication

Turning a Spock subscription into a synchronous standby requires setting
**two** separate things, on the node that should wait for the standby (the
"provider" side of the connection, i.e. A when S is A's sync standby):

1. **`spock.synchronous_mode = 'standby'`** — a Spock GUC (enum,
   `PGC_SIGHUP`, default `off`). This is the master switch that turns on
   Spock's synchronous-standby-aware logic (self-skip on the walsender
   feeding the sync standby itself, the forwarding gate that keeps async
   peers from outrunning the sync standby, and peer-aware apply feedback).
   Values are `off` (default; today's async behavior, unchanged) and
   `standby` (the mechanism described in this document). The value `group`
   is reserved for a possible future multi-site quorum/durability mode and
   is **not implemented**.

2. **The subscriber's slot name listed in `synchronous_standby_names`** —
   this is the standard core PostgreSQL GUC. It remains the single source
   of truth for *which* connections are synchronous; Spock does not
   maintain a separate list. For a Spock subscription, the connection's
   `application_name` is its replication **slot name**, of the form
   `spk_<db>_<provider>_<sub>` (each component hashed/shortened to 16
   characters when long, so it is verbatim only when short). You can
   compute the exact value with `spock.spock_gen_slot_name`:

   ```sql
   SELECT spock.spock_gen_slot_name('postgres', 'n1', 'sub_n2n1');
   --  spock_gen_slot_name
   -- --------------------------
   --  spk_postgres_n1_sub_n2n1
   ```

   Then, on the node that should treat that subscriber as synchronous:

   ```sql
   ALTER SYSTEM SET synchronous_standby_names = 'spk_postgres_n1_sub_n2n1';
   ALTER SYSTEM SET spock.synchronous_mode = 'standby';
   SELECT pg_reload_conf();
   ```

   For the MM pair in the diagram above, set both entries symmetrically:
   each of A and S lists the *other's* subscription slot name in its own
   `synchronous_standby_names`, and each sets its own
   `spock.synchronous_mode = 'standby'`.

### Why two lists, not one

It would be simpler if Spock accepted a single, Spock-specific list of
synchronous peers. It does not, by design: PostgreSQL's own synchronous
replication machinery (`SyncRepWaitForLSN`, invoked from
`RecordTransactionCommit`) only ever reads `synchronous_standby_names` —
there is no supported hook to make it consult a second, Spock-owned list,
and Spock does not carry a patch to core PostgreSQL. `synchronous_standby_names`
must therefore name the standby regardless. `spock.synchronous_mode` is the
*separate* switch that tells Spock's own machinery (the output plugin's
forwarding gate, and the apply worker's feedback hold) to behave correctly
when the synchronous standby is itself a Spock peer rather than a plain
physical replica. Forgetting either half leaves you with the wrong
behavior:

- `synchronous_standby_names` set, `spock.synchronous_mode = 'off'` — core
  PostgreSQL will still wait for the standby (client durability works), but
  Spock's legacy output-plugin wait logic is unaware of the standby and can
  misbehave for a logical (Spock) synchronous standby (see the design notes
  for the defects this avoids).
- `spock.synchronous_mode = 'standby'`, standby not listed in
  `synchronous_standby_names` — nothing is synchronous; the subscription
  behaves exactly like a normal asynchronous one.

## `synchronous_commit` levels

The durability level is controlled by the standard PostgreSQL
`synchronous_commit` setting on the **committing session** on A (and S),
exactly as for a physical standby. The default and recommended level is
**`on`** (remote flush): a commit is acknowledged to the client only after
the synchronous standby has flushed the transaction to durable storage.
Lower levels (`remote_write`, `local`, `off`) are accepted by core
PostgreSQL but weaken the guarantee accordingly and are not the intended
mode for this feature.

There is a second, related setting: **`spock.synchronous_commit`** (boolean,
`PGC_POSTMASTER`, default `false`), which controls the apply worker's own
`synchronous_commit` (`off` vs `local`). **In `standby` mode you do not need
to change it.** When `spock.synchronous_mode = standby`, the apply worker
performs an eager local WAL flush (`XLogFlush`) immediately after each applied
commit, so the flush that A is waiting on happens at once instead of lagging a
WAL-writer cycle.

This is what makes the *default* (`spock.synchronous_commit = off`) usable:
without the eager flush, synchronous throughput collapses to roughly **one
transaction per second** — the confirming feedback would wait for the apply
loop's ~1 s idle wakeup — whereas with it the pair runs in the thousands of
TPS (loopback-local benchmark), with **no restart required**. (Setting
`spock.synchronous_commit = true` is therefore no longer necessary for
throughput in standby mode; it remains a `PGC_POSTMASTER`/restart option that
affects the apply worker outside standby mode.)

**Cost:** while a node is in `standby` mode, **every** applied commit is flushed
to disk — for all subscriptions on that node, not only the synchronous one.
That is the intended durability cost of opting a node into synchronous-standby
behaviour (equivalent to `synchronous_commit = local` for replayed traffic).

The eager flush is a *local* WAL flush only — it never calls
`SyncRepWaitForLSN`. The apply worker still never commits with
`synchronous_commit = on`: that would make S, while applying A's transaction,
wait for S's *own* synchronous standby (A) and form a genuine distributed
deadlock. Flushing locally (not waiting on a standby) is exactly what keeps a
synchronous MM pair from deadlocking against itself.

## Monitoring: `spock.synchronous_replica_status`

Use the `spock.synchronous_replica_status` view to see, per active
replication connection, whether it is synchronous and how far behind it
is:

```sql
SELECT * FROM spock.synchronous_replica_status;
```

| Column | Description |
|---|---|
| `sub_name` | Best-effort subscription name (see caveat below). |
| `application_name` | The connection's `application_name` — for a Spock subscriber, its slot name. |
| `is_synchronous` | `true` if this connection is currently a synchronous standby (`pg_stat_replication.sync_state <> 'async'`). |
| `is_logical` | `true` if the underlying replication slot is a logical slot using a Spock plugin (`spock_output`/`spock`) — i.e. this is a Spock subscriber rather than a physical standby. |
| `connected` | Whether the connection currently has replication state (a live walsender). |
| `flush_lag_bytes` | Bytes of WAL sent but not yet flushed by this standby (`sent_lsn` − `flush_lsn`). |

Two things to keep in mind when reading this view:

- **`sub_name` is best-effort and is often `NULL`.** The view runs on the
  *provider* side of the connection (the node sending WAL), but the
  subscription name is only recorded in `spock.subscription` on the
  *subscribing* node. The view can only resolve `sub_name` when this same
  node also happens to hold a local subscription using the identical slot
  name (i.e. a mutual/bidirectional pair). Otherwise `sub_name` is `NULL`
  and `application_name` (which equals the slot name) is what identifies
  the connection.
- **`connected` only reflects currently-connected walsenders.** The view is
  built from `pg_stat_replication`, which only contains rows for walsenders
  that are actually connected right now. A standby that is named in
  `synchronous_standby_names` but is down, disconnected, or never
  connected **will not appear in this view at all** — there is no
  placeholder row for it. Absence from the view, combined with A's commits
  blocking, is itself the signal that the configured standby is
  unreachable.

## Failure, degraded operation, and recovery

This is the operating procedure for when a synchronous peer is lost, and
when it comes back.

### Degrade (resume writes after losing the peer)

When the synchronous standby becomes unavailable (down, disconnected,
subscription disabled, stuck on a conflict, or never connected), the
surviving node's commits **block** — this is native PostgreSQL semantics
and Spock does not auto-degrade. To resume accepting writes, drop the sync
requirement on the survivor:

```sql
ALTER SYSTEM RESET synchronous_standby_names;   -- or: SET TO ''
SELECT pg_reload_conf();
```

Commits immediately become asynchronous again; the survivor continues
operating as a normal async Spock node. (This is also the fix for the
shutdown-hang gotcha below — reset `synchronous_standby_names` before
stopping a node whose standby is gone.)

### Recover (re-enable when the peer returns)

1. Let the returned node's subscription resume and replay the backlog
   accumulated during the outage.
2. **Wait for it to catch up before re-enabling synchronous mode** — watch
   `flush_lag_bytes` for that standby in `spock.synchronous_replica_status`
   until it is at or near zero. Re-enabling while it is still far behind is
   not *unsafe*, but the survivor's commits will immediately block again
   until the standby catches up, reintroducing the stall you just
   recovered from.
3. Re-apply the synchronous configuration:

   ```sql
   ALTER SYSTEM SET synchronous_standby_names = '<slot_name>';
   SELECT pg_reload_conf();
   ```

### Three things to keep in mind

- **Degraded is not durable.** Writes accepted while degraded had no
  synchronous guarantee. If the outage was a network partition and *both*
  nodes took writes during it, reconnection reconciles the divergent rows
  through Spock's normal conflict resolution (e.g. `last_update_wins`).
  Synchronous mode never prevents divergence during a partition — it only
  gates when a commit is *acknowledged*, not what happens if both sides
  keep accepting writes without a synchronous link between them.
- **Promotion is safe by construction.** If the primary actually dies, the
  synchronous standby is a sound promotion target precisely because
  synchronous replication guaranteed it held every transaction the primary
  had acknowledged — there are no acked-but-lost writes to reconcile. This
  is the payoff of the feature.
- **Re-enable timing is an availability decision**, made by watching the
  status view as described in step 2 above — there is no automatic
  "caught up enough" signal.

## Operational gotchas

- **Availability is a strict block, with no auto-degrade.** If the
  synchronous standby is unavailable for any reason (down, disconnected,
  subscription disabled, stuck applying), the committing node's writes
  simply **hang** until the standby returns or an operator/orchestration
  layer removes it from `synchronous_standby_names` and reloads. Spock does
  not decide on your behalf to silently fall back to asynchronous — that
  decision needs a whole-cluster view that belongs to your orchestration
  layer, and a silent downgrade would turn a durability guarantee into a
  fiction. Plan your failure-detection and degrade automation accordingly.

- **`statement_timeout` does not interrupt a stuck synchronous commit.**
  The wait for the synchronous standby happens *after* the transaction has
  already committed locally (inside `RecordTransactionCommit`), so
  `statement_timeout` never fires against it. A backend stuck waiting on a
  gone synchronous standby can only be released by canceling the query
  (`pg_cancel_backend`), terminating the backend
  (`pg_terminate_backend`), or by fixing `synchronous_standby_names` and
  reloading. Set client/application timeout expectations accordingly — a
  statement-level timeout is not a safety net here.

- **Graceful/fast shutdown hangs if a synchronous standby is configured
  but unreachable.** If you tear down or stop the synchronous standby
  first, a subsequent graceful (`smart`) or fast `pg_ctl stop` on the
  surviving node can hang waiting on the same synchronous-standby
  condition described above. Either reset `synchronous_standby_names`
  (and reload) before stopping the node, or stop with
  `pg_ctl -m immediate` if a hang is encountered. Build this into your
  failover/HA and node-teardown runbooks.

## Per-subscription semantics and multi-subscription caveat

Synchronous replication is **per subscription** (per replication slot named
in `synchronous_standby_names`), not per node. `synchronous_standby_names`
matches against a connection's `application_name`, and a Spock
subscription's `application_name` is its own slot name — so if a node has
several subscriptions to the same provider (for example, covering disjoint
replication sets), each one is independently synchronous or asynchronous
depending on whether *its own* slot name is listed.

This has real consequences for a node with more than one subscription to
the same provider:

- If only some of a node's subscriptions to a given provider are made
  synchronous, a transaction that only touches a replication set carried
  by an asynchronous subscription is **not** guaranteed durable on that
  node when the provider's commit is acknowledged — even though the
  provider believes it has a synchronous standby.
- A single transaction whose changes span replication sets carried by
  different subscriptions is applied **non-atomically** on the subscriber,
  and is only fully durable at ack time if **all** of the covering
  subscriptions are synchronous.

Spock does **not** detect or warn about partial synchronous coverage
automatically — there is no validation that rejects an incomplete
configuration, and no built-in check for it. Ensuring full coverage is an
**operator responsibility**. The recommended practice is for a synchronous
replica to subscribe to its provider through a **single subscription**
that covers every replication set you need synchronous durability for; if
you must use multiple subscriptions to the same provider, make sure the
slot names of *all* of them appear in `synchronous_standby_names` together
when you want a transaction guaranteed durable regardless of which
replication set it touches.
