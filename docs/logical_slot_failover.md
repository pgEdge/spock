# Logical Slot Failover

Spock creates logical replication slots on each provider node. For high
availability with a physical standby, these slots must be synchronized to the
standby so that replication can resume without data loss after a failover.

## How It Works

When a primary server fails and a physical standby is promoted, any active
logical subscribers must be able to continue replicating from the new primary.
This requires the logical replication slots — which track each subscriber's
replication position — to be present and up to date on the standby before the
failover occurs.

Without slot synchronization, a failover would require manual slot recreation
and a full re-sync of all subscriber tables.

## Opt-in: `spock.use_native_failover_slots`

Starting with Spock 5, PostgreSQL's native slot-failover path (PG17+) is
**opt-in**, controlled by the boolean GUC `spock.use_native_failover_slots`
(**default `off`**). With the GUC off, Spock behaves exactly as before on
every PostgreSQL version: its own `spock_failover_slots` worker runs and no
slot carries the `FAILOVER` flag.

This GUC is `PGC_POSTMASTER` — it can only be set in `postgresql.conf` (or
`ALTER SYSTEM`) and requires a **server restart** to take effect; it cannot
be changed with `SET` or reloaded with `SIGHUP`.

The flag is read on the **subscriber** — the node that issues
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
you must adjust it on the promoted node before replication will resume — see
[Runbook: clear `synchronized_standby_slots` after promotion](#runbook-clear-synchronized_standby_slots-after-promotion)
below.

## Runbook: clear `synchronized_standby_slots` after promotion

When `synchronized_standby_slots` is configured (Setup step 3 above), the
provider's walsenders hold back logical decoding until every physical slot
named in that list has confirmed flush of the relevant LSN. This is what
keeps a physical standby from falling behind a logical subscriber — but it
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
instead of clearing it to `''` — the point is to remove references to
orphaned slots, not to leave the setting pointing at slots nothing will ever
consume.

Add this step to your failover runbook alongside the subscriber DSN update
described above; skipping it is the most common cause of "failover
succeeded but replication stopped" reports when native failover slots are
in use.

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
subscriber's `host=` in their DSN, and — if `synchronized_standby_slots` was
configured — clear/adjust it on the promoted node as described in the
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
this does not apply — Spock's worker is registered and runs as usual.)

**Q: Can I use both mechanisms on PG17?**

No, both can't run their sync loops at once, and this only matters if
`spock.use_native_failover_slots` is on in the first place. If it is on and
`sync_replication_slots = on` is also set on PG17, Spock's worker detects
this and skips its sync loop, deferring to the native worker entirely. With
the GUC off (the default), native `sync_replication_slots` has no effect on
Spock's slots since they are never marked with `FAILOVER`.

**Q: Do I need to restart the server to enable this?**

Yes. `spock.use_native_failover_slots` is `PGC_POSTMASTER` — it can only be
set at server start (via `postgresql.conf` or `ALTER SYSTEM` followed by a
restart), not with `SET` or a `SIGHUP` reload.
