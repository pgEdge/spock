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

## PostgreSQL Version Behaviour

| PostgreSQL | Slot sync mechanism | Spock worker |
|---|---|---|
| 15, 16 | Spock built-in `spock_failover_slots` worker | Always runs on standby |
| 17 | Spock worker **or** native `sync_replication_slots` | Yields to native if enabled |
| 18+ | Native `sync_replication_slots` (required) | Not registered |

On **PostgreSQL 17+**, Spock marks every logical slot with the `FAILOVER` flag
at creation time. This enables PostgreSQL's built-in slotsync worker to pick
them up automatically.

On **PostgreSQL 18+**, Spock's own failover worker is not registered at all.
The native slotsync worker is the only mechanism.

## Setup: PostgreSQL 18+ (Native)

### 1. Create a physical replication slot on the primary

```sql
SELECT pg_create_physical_replication_slot('spock_standby_slot');
```

### 2. Configure the primary (`postgresql.conf`)

```ini
# Hold walsenders back until the standby has confirmed this LSN,
# preventing logical subscribers from getting ahead of the standby.
synchronized_standby_slots = 'spock_standby_slot'
```

### 3. Configure the standby (`postgresql.conf`)

```ini
sync_replication_slots = on
primary_conninfo = 'host=<primary_host> port=5432 dbname=<dbname> user=replicator'
primary_slot_name = 'spock_standby_slot'
hot_standby_feedback = on
```

### 4. Verify slot synchronization

On the standby, confirm that Spock's logical slots are synchronized:

```sql
SELECT slot_name, synced, failover, invalidation_reason
FROM pg_replication_slots
WHERE NOT temporary;
```

All Spock slots should show `synced = true` and `failover = true`.

### 5. After failover

After promoting the standby, subscribers only need to update their connection
string to point to the new primary. Replication resumes from the last
synchronized LSN with no data loss and no slot recreation required.

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

On PG17+: Just update the subscriber's `host=` in their DSN. No slot
recreation needed.

On PG15/16: Spock's worker on the standby (now primary) stops running
since it is no longer in recovery. Subscribers reconnect automatically.

**Q: What if `sync_replication_slots` is not configured on PG18?**

Spock's worker is not registered on PG18. If `sync_replication_slots = on`
is not set, logical slots will **not** be synchronized to standbys, and a
failover will require manual slot recreation and table re-sync.

**Q: Can I use both mechanisms on PG17?**

No. If `sync_replication_slots = on` is set on PG17, Spock's worker detects
this and skips its sync loop, deferring to the native worker entirely.
