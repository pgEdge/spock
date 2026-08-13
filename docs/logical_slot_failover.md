# Logical Slot Failover

Spock creates logical replication slots on each provider node. For high
availability with a physical standby, these slots must be synchronized to the
standby so that replication can resume without data loss after a failover.

## How It Works

When a primary server fails and a physical standby is promoted, any active
logical subscribers must be able to continue replicating from the new primary.
This requires the logical replication slots, which track each subscriber's
replication position, to be present and up to date on the standby before the
failover occurs.

Without slot synchronization, a failover would require manual slot recreation
and a full re-sync of all subscriber tables.

## Opt-in: `spock.use_native_failover_slots`

Starting with Spock 5, PostgreSQL's native slot-failover path (PG17+) is
**opt-in**, controlled by the boolean GUC `spock.use_native_failover_slots`
(**default `off`**). With the GUC off, Spock behaves exactly as before on
every PostgreSQL version: its own `spock_failover_slots` worker runs and no
slot carries the `FAILOVER` flag.

This GUC is `PGC_POSTMASTER`. It can only be set in `postgresql.conf` (or
`ALTER SYSTEM`) and requires a **server restart** to take effect; it cannot
be changed with `SET` or reloaded with `SIGHUP`.

The flag is read on the **subscriber**, the node that issues
`CREATE_REPLICATION_SLOT` against the provider to create its logical slot.
Set it there, not on the provider.

ZODAN's `add_node` path works differently: it checks the GUC via `dblink`
on the node that **hosts** the slot (the existing provider), not on the
node being added. Because this is a `PGC_POSTMASTER` GUC, set
`spock.use_native_failover_slots` **uniformly** on every node in the
cluster so both paths agree on the same behavior.

## PostgreSQL Version Behaviour

| PostgreSQL | `spock.use_native_failover_slots` | Slot sync mechanism | Spock worker |
|---|---|---|---|
| 15, 16 | off or on | Spock built-in `spock_failover_slots` worker | Always runs on standby |
| 17 | off (default) | Spock built-in worker only | Always runs the full sync loop; no `FAILOVER` flag |
| 17 | on | Slots created with `(FAILOVER)`; native `sync_replication_slots` (if enabled) | Worker still registered but **yields** its sync loop when `sync_replication_slots = on` |
| 18+ | off (default) | Spock built-in `spock_failover_slots` worker | Always runs; no `FAILOVER` flag |
| 18+ | on | Native `sync_replication_slots` (required) | **Not registered** |

On PG15/16 there is no native slotsync mechanism, so the GUC has no effect;
Spock's worker always handles synchronization regardless of the setting.

On **PostgreSQL 17+**, when the GUC is `on`, Spock marks every logical slot
with the `FAILOVER` flag at creation time. This enables PostgreSQL's built-in
slotsync worker to pick them up automatically.

On **PostgreSQL 18+**, when the GUC is `on`, Spock's own failover worker is
not registered at all. The native slotsync worker is the only mechanism. If
the GUC is left `off` (the default), Spock's worker is registered and runs
as it did before, and no slot carries the `FAILOVER` flag.

## Setup: PostgreSQL 17 and 18+ (Native, requires `spock.use_native_failover_slots = on`)

On PostgreSQL 17 the Spock worker only steps aside once `sync_replication_slots
= on` is also set (step 4); on PostgreSQL 18+ with the GUC on, the Spock worker
is not registered and the native mechanism is required. The steps are the same
for both.

### 1. Enable the GUC on the subscriber

On the **subscriber node** (the node that creates the logical replication
slot on the provider), set:

```ini
spock.use_native_failover_slots = on
```

This is `PGC_POSTMASTER`, so restart the subscriber's server after setting
it. Without this step, the slot is created without the `FAILOVER` flag and
none of the steps below take effect.

### 2. Create a physical replication slot on the primary

```sql
SELECT pg_create_physical_replication_slot('spock_standby_slot');
```

### 3. Configure the primary (`postgresql.conf`)

```ini
# Hold walsenders back until the standby has confirmed this LSN,
# preventing logical subscribers from getting ahead of the standby.
synchronized_standby_slots = 'spock_standby_slot'
```

### 4. Configure the standby (`postgresql.conf`)

```ini
sync_replication_slots = on
primary_conninfo = 'host=<primary_host> port=5432 dbname=<dbname> user=replicator'
primary_slot_name = 'spock_standby_slot'
hot_standby_feedback = on
```

### 5. Verify slot synchronization

On the standby, confirm that Spock's logical slots are synchronized:

```sql
SELECT slot_name, synced, failover, invalidation_reason
FROM pg_replication_slots
WHERE NOT temporary;
```

All Spock slots should show `synced = true` and `failover = true`.

### 6. After failover

After promoting the standby, subscribers only need to update their connection
string to point to the new primary. Replication resumes from the last
synchronized LSN with no data loss and no slot recreation required.

**Important:** if `synchronized_standby_slots` was configured (step 3 above),
you must adjust it on the promoted node before replication will resume. See
[Runbook: clear `synchronized_standby_slots` after promotion](#runbook-clear-synchronized_standby_slots-after-promotion)
below.

## Runbook: clear `synchronized_standby_slots` after promotion

When `synchronized_standby_slots` is configured (Setup step 3 above), the
provider's walsenders hold back logical decoding until every physical slot
named in that list has confirmed flush of the relevant LSN. This is what
keeps a physical standby from falling behind a logical subscriber, but it
has a sharp edge on failover.

When a standby is promoted, `synchronized_standby_slots` on the **promoted**
node still lists the physical slot(s) that fed replication to *that* node
before promotion. Those slots are now orphaned: nothing is consuming them
any more, so they never confirm, and the promoted node's walsenders sit
blocked waiting on them indefinitely. The practical symptom is that logical
replication to subscribers **freezes** immediately after a promotion that
otherwise looked successful.

The fix is a mandatory post-promotion step, not optional cleanup:

```sql
-- On the newly promoted node:
ALTER SYSTEM SET synchronized_standby_slots = '';
SELECT pg_reload_conf();

-- Then drop the orphaned physical slot(s) that fed the old topology:
SELECT pg_drop_replication_slot('spock_standby_slot');
```

If the new topology has its own physical standby(s), set
`synchronized_standby_slots` to the physical slot(s) for *that* standby
instead of clearing it to `''`. The point is to remove references to
orphaned slots, not to leave the setting pointing at slots nothing will ever
consume.

Add this step to your failover runbook alongside the subscriber DSN update
described above; skipping it is the most common cause of "failover
succeeded but replication stopped" reports when native failover slots are
in use.

## Running Under Patroni (PostgreSQL 17+)

Patroni manages the physical replication slots for its members itself. When
`postgresql.use_slots: true` (the default), Patroni creates a slot per member
and drops or recreates those slots as the topology changes, including on a
graceful switchover. That behaviour is fine for the physical stream, but it
is also what makes Spock's built-in `spock_failover_slots` worker unreliable
under Patroni: when Patroni recreates a slot on switchover it resets the
`catalog_xmin` that `hot_standby_feedback` had pinned, and a busy primary
running vacuum can then remove catalog rows the promoted node's copied slot
still needs. The slot comes back invalidated (`invalidation_reason =
rows_removed`) and the subscriber has to re-sync from scratch.

The fix is to stop copying logical slots by hand and let PostgreSQL do it.
On PG17+ use the native failover-slots path (`spock.use_native_failover_slots
= on` plus `sync_replication_slots = on`) so the slot carries the `FAILOVER`
flag and PostgreSQL's own slotsync worker keeps it current on every member.
This is the same mechanism described under
[Setup: PostgreSQL 17 and 18+](#setup-postgresql-17-and-18-native-requires-spockuse_native_failover_slots--on);
the rest of this section is only about where those settings go in a Patroni
configuration and the one sharp edge switchover introduces.

Use Patroni 4.x, the line these instructions are written and tested against.

### Required settings

| Setting | Value | Where | Restart? | Why |
|---|---|---|---|---|
| `spock.use_native_failover_slots` | `on` | dynamic config, **every member** | **Yes** (`PGC_POSTMASTER`) | Creates each logical slot with the `FAILOVER` flag |
| `sync_replication_slots` | `on` | dynamic config | No (reload) | PostgreSQL slotsync worker copies flagged slots to standbys |
| `hot_standby_feedback` | `on` | dynamic config | No (reload) | Pins `catalog_xmin` so vacuum can't remove rows a slot needs |
| `wal_level` | `logical` | dynamic config | Yes | Required for logical decoding |
| `output_plugin_libraries` | include `spock_output` | dynamic config, **every member** | No (reload) | Only on servers that have the parameter (see note below). A synchronized slot keeps `spock_output` as its plugin, so a member missing this setting fails to serve replication once promoted |
| `postgresql.use_slots` | `true` | Patroni config | n/a | Patroni manages the physical member slots (leave on) |
| `max_replication_slots` / `max_wal_senders` | sized to cluster | dynamic config | Yes | Enough slots/senders for members plus Spock logical slots |
| `synchronized_standby_slots` | standby member slot name(s) | dynamic config | No (reload) | Optional but recommended; holds the leader back until the standby confirms. See the [sharp edge](#the-switchover-sharp-edge-synchronized_standby_slots) below |

"Dynamic config" means Patroni's DCS-backed configuration:
`bootstrap.dcs.postgresql.parameters` when you first bootstrap the cluster,
and `patronictl edit-config` for a running one. The next subsection shows the
full bootstrap block.

### Where the settings go (bootstrap)

Cluster-wide PostgreSQL parameters belong in Patroni's dynamic configuration
(`bootstrap.dcs.postgresql.parameters` at bootstrap, `patronictl edit-config`
afterwards) so every member, current and future leader, agrees on them.
Set them there, not in a per-node `postgresql.conf`.

```yaml
bootstrap:
  dcs:
    postgresql:
      use_slots: true
      parameters:
        wal_level: logical
        hot_standby_feedback: "on"          # required; pins catalog_xmin
        spock.use_native_failover_slots: "on"   # PGC_POSTMASTER, see restart note
        sync_replication_slots: "on"        # PG slotsync worker copies FAILOVER slots
        max_replication_slots: 10
        max_wal_senders: 10
        # Only on servers that have this parameter -- see the note below
        output_plugin_libraries: "pgoutput, test_decoding, spock_output"
```

`output_plugin_libraries` arrived with PostgreSQL's 2026 security fix
(CVE-2026-6471, back-patched to every supported major): a library may not be
used as an output plugin unless it is listed there, and the default excludes
`spock_output`. A synchronized slot keeps `spock_output` as its plugin, so a
member without this setting looks healthy while it is a replica and then fails
to serve replication the moment it is promoted — the failure surfaces during a
switchover, which is the worst time to find it. It is `PGC_SUSET`, so Patroni
reloads it without a restart.

Do not set it on a release that predates the fix: an unrecognised parameter
stops the server from starting, and pushing one through the DCS stops *every*
member. Check first, on each member, with
`SELECT current_setting('output_plugin_libraries', true)` — a NULL result means
the parameter does not exist.

`spock.use_native_failover_slots` is `PGC_POSTMASTER`. Patroni cannot reload
it into a running server; after adding it, Patroni flags every member as
**pending restart**, and you must restart them (`patronictl restart <scope>`)
before any slot is created with the `FAILOVER` flag. Set it uniformly across
the whole cluster. A mixed setting means slots created on one leader behave
differently after a switchover to another.

Do **not** also declare the Spock logical slots as Patroni *permanent logical
slots* (the `slots:` block in dynamic config). Permanent logical slots are
copied by Patroni's own mechanism, which is exactly the hand-copying the
native path replaces; declaring them there reintroduces the invalidation
race. Let Patroni manage only the physical member slots and leave the logical
slots to PostgreSQL's slotsync worker.

### The switchover sharp edge: `synchronized_standby_slots`

`synchronized_standby_slots` (Setup step 3) must name the physical slot(s) of
the standby member(s) so the leader's walsenders hold back until the standby
has confirmed the LSN. Under Patroni the member slots are named after the
members, so on a two-member cluster with leader `n2` and standby `r1` the
leader needs:

```
synchronized_standby_slots = 'r1'
```

The edge is that this value is *role-specific* but Patroni's dynamic config is
*cluster-wide*. If you hardcode `'r1'` and then switch over so `r1` becomes
leader, the new leader is left pointing at a slot for itself that nothing
consumes, so its walsenders block forever and logical replication freezes. This
is the same failure the
[post-promotion runbook](#runbook-clear-synchronized_standby_slots-after-promotion)
describes, and under Patroni it will recur on every switchover unless you
handle it.

Two ways to handle it:

- **Automate it with an `on_role_change` callback.** Point
  `synchronized_standby_slots` at the current standby member(s) whenever a
  node's role changes. This keeps the guarantee intact across switchovers
  without manual steps and is the recommended approach for anything beyond a
  test cluster.

  ```yaml
  postgresql:
    callbacks:
      on_role_change: /etc/patroni/set_synchronized_standby_slots.sh
  ```

  The script receives `on_role_change <role> <scope>`; on becoming leader it
  should `ALTER SYSTEM SET synchronized_standby_slots` to the other members'
  slot names and reload, and on becoming a replica it should clear it. A
  ready-to-adapt reference implementation ships with Spock at
  [`samples/set_synchronized_standby_slots.sh`](../samples/set_synchronized_standby_slots.sh);
  review and tailor it to your environment before production use.

- **Leave it unset and accept the trade-off.** Without
  `synchronized_standby_slots`, nothing freezes on switchover, but the leader
  no longer waits for the standby to confirm before letting logical
  subscribers advance. A subscriber can then get slightly ahead of the
  physical standby, so immediately after a promotion the new leader may be
  marginally behind a subscriber. For many deployments that small window is
  acceptable; for zero-data-loss requirements, use the callback instead.

### Verify

After bootstrap and restart, confirm every member carries the flagged,
synchronized slots:

```sql
-- on each standby member
SELECT slot_name, synced, failover, invalidation_reason
FROM pg_replication_slots
WHERE plugin = 'spock_output' AND NOT temporary;
```

`synced` and `failover` should both be `true` and `invalidation_reason`
`NULL`. If `failover` is `false`, the slot was created before
`spock.use_native_failover_slots` took effect (check that the restart
actually happened). Drop and recreate the subscription so the slot is
recreated with the flag.

## Setup: PostgreSQL 15 and 16 (Spock Worker)

On PostgreSQL 15 and 16, the `spock_failover_slots` background worker runs
on the standby and periodically copies slot state from the primary.

### Requirements

- `hot_standby_feedback = on` on the standby (required for the worker to run)
- The standby must be able to connect to the primary

### Configuration GUCs

| GUC | Default | Description |
|---|---|---|
| `spock.synchronize_slot_names` | `name_like:%%` | Slot name patterns to sync (all by default) |
| `spock.drop_extra_slots` | `on` | Drop standby slots not matching the pattern |
| `spock.primary_dsn` | `''` | DSN to connect to primary (falls back to `primary_conninfo`) |
| `spock.pg_standby_slot_names` | `''` | Physical slots that must confirm LSN before logical replication advances |
| `spock.standby_slots_min_confirmed` | `-1` | How many slots from `pg_standby_slot_names` must confirm (`-1` = all) |
| `spock.failover_slots_naptime` | `1000` | Worker sleep between slot-sync passes, in ms (SIGHUP; range 1000–3600000) |
| `spock.failover_slots_feedback_naptime` | `10000` | Shorter retry, in ms, while waiting for standby WAL feedback (SIGHUP; range 1000–3600000) |

### Example (`postgresql.conf` on standby)

```ini
hot_standby_feedback = on
spock.synchronize_slot_names = 'name_like:%%'
spock.drop_extra_slots = on

# Optional: hold walsenders on primary until this standby confirms
# (set this on the PRIMARY, not the standby)
# spock.pg_standby_slot_names = 'physical_slot_name'
```

## Monitoring

### Check slot sync status (PG17+)

```sql
SELECT slot_name,
       failover,
       synced,
       active,
       invalidation_reason,
       confirmed_flush_lsn
FROM pg_replication_slots
WHERE NOT temporary
ORDER BY slot_name;
```

### Check if native slotsync worker is active (PG17+)

```sql
SELECT pid, wait_event_type, wait_event, state
FROM pg_stat_activity
WHERE backend_type = 'slot sync worker';
```

### Check spock worker is running (PG15/16)

```sql
SELECT pid, application_name, state
FROM pg_stat_activity
WHERE application_name = 'spock_failover_slots worker';
```

## FAQ

**Q: Do I need to do anything after a failover?**

On PG17+ with `spock.use_native_failover_slots = on`: update the
subscriber's `host=` in their DSN, and, if `synchronized_standby_slots` was
configured, clear/adjust it on the promoted node as described in the
[runbook above](#runbook-clear-synchronized_standby_slots-after-promotion).
No slot recreation is needed.

On PG15/16, or on PG17+ with the GUC left at its default `off`: Spock's
worker on the standby (now primary) stops running since it is no longer in
recovery. Subscribers reconnect automatically.

**Q: What if `sync_replication_slots` is not configured on PG18 with the GUC on?**

With `spock.use_native_failover_slots = on`, Spock's worker is not
registered on PG18+. If `sync_replication_slots = on` is not also set,
logical slots will **not** be synchronized to standbys, and a failover will
require manual slot recreation and table re-sync. (With the GUC left `off`,
this does not apply, since Spock's worker is registered and runs as usual.)

**Q: Can I use both mechanisms on PG17?**

No, both can't run their sync loops at once, and this only matters if
`spock.use_native_failover_slots` is on in the first place. If it is on and
`sync_replication_slots = on` is also set on PG17, Spock's worker detects
this and skips its sync loop, deferring to the native worker entirely. With
the GUC off (the default), native `sync_replication_slots` has no effect on
Spock's slots since they are never marked with `FAILOVER`.

**Q: Do I need to restart the server to enable this?**

Yes. `spock.use_native_failover_slots` is `PGC_POSTMASTER`; it can only be
set at server start (via `postgresql.conf` or `ALTER SYSTEM` followed by a
restart), not with `SET` or a `SIGHUP` reload.
