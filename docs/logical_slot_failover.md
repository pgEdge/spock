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

## Which settings you need

There are two sync paths, and each needs a different set of settings. Both paths
also assume the base Spock settings are already in place.

### Base settings (all versions, every node)

These are the settings Spock needs to replicate at all. They are covered in
[Installing and Configuring Spock](install_spock.md).

```ini
wal_level = logical
shared_preload_libraries = 'spock'
track_commit_timestamp = on
max_worker_processes = 10
max_replication_slots = 10
max_wal_senders = 10
```

On PostgreSQL 18, also size `max_active_replication_origins` (default 10) to at
least the number of subscriptions plus some headroom.

### Native path (PostgreSQL 17 with `sync_replication_slots = on`, and PostgreSQL 18)

Core PostgreSQL copies the slots. Set these in addition to the base settings.

| Setting | Node | Value | Purpose |
|---|---|---|---|
| `sync_replication_slots` | standby | `on` | Turns on the core slot sync worker. Required on 18, optional on 17. |
| `hot_standby_feedback` | standby | `on` | Stops the primary from removing catalog rows the slots still need. |
| `primary_slot_name` | standby | physical slot name | The physical slot the standby streams through. |
| `primary_conninfo` | standby | connection string with `dbname` | How the standby reaches the primary. |
| `synchronized_standby_slots` | primary | physical slot name | Holds logical walsenders back until the standby has the changes. |
| slot `failover = true` | primary | per slot | Only slots with this flag are synced. Spock 6.0.0 sets it at creation; older slots are handled during upgrade. |

The physical slot must exist on the primary before the standby connects:

```sql
SELECT pg_create_physical_replication_slot('spock_standby_slot');
```

### Spock worker path (PostgreSQL 15, 16, and 17 when `sync_replication_slots` is off)

The Spock background worker on the standby copies the slots. Set these in
addition to the base settings.

| Setting | Node | Default | Purpose |
|---|---|---|---|
| `hot_standby_feedback` | standby | `on` (you set it) | Required for the worker to run, and stops the primary from removing needed catalog rows. |
| `primary_slot_name` | standby | physical slot name | The physical slot the standby streams through. |
| `primary_conninfo` | standby | connection string | How the standby reaches the primary. |
| `spock.synchronize_slot_names` | standby | `name_like:%%` | Which slots to sync. All by default. |
| `spock.drop_extra_slots` | standby | `on` | Drop standby slots that no longer exist on the primary. |
| `spock.primary_dsn` | standby | `''` | Connection to the primary. Falls back to `primary_conninfo` when empty. |
| `spock.pg_standby_slot_names` | primary | `''` | Physical slots that must confirm an LSN before logical replication advances. Optional. |
| `spock.standby_slots_min_confirmed` | primary | `-1` | How many of those slots must confirm. `-1` means all. |

`hot_standby_feedback = on` plus a physical slot named by `primary_slot_name` is
the important pair. Without both, the primary can remove catalog rows a slot
still needs, and the slot is invalidated with a message about conflicting with
recovery.

## Setup: PostgreSQL 17 and 18 (Native)

This is the native slot sync path. It is the only option on PostgreSQL 18. On
PostgreSQL 17 it is optional: the Spock worker runs by default, and setting
`sync_replication_slots = on` on the standby tells Spock to step aside and let
core PostgreSQL do the sync instead. Native sync only copies slots that have
`failover = true`. Spock 6.0.0 sets that flag when it creates a slot. If you
have slots from an older Spock release, see the upgrade section below.

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

## Upgrading Spock to 6.0.0

New slots created by Spock 6.0.0 already have `failover = true`. Slots created
by an older Spock release do not, and native slot sync on PostgreSQL 17 and 18
ignores slots that do not have the flag. The upgrade turns the flag on for those
existing slots.

This section covers only the failover part of the upgrade. For the full
procedure (disabling auto-DDL, installing the new binaries, and restarting each
node), follow [Upgrading the Spock Extension](upgrading_spock.md) first. The
steps below run after the 6.0.0 binaries are installed.

### 1. Run the extension update

```sql
ALTER EXTENSION spock UPDATE TO '6.0.0';
```

PostgreSQL walks the version chain (5.0.8 to 5.0.9 to 5.0.10 to 6.0.0) and runs
each step in order. The 5.0.10 to 6.0.0 step calls
`spock.slot_enable_failover()` for you.

`spock.slot_enable_failover()` behaves as follows:

- On PostgreSQL 16 and older it does nothing, because the flag does not exist.
- On a standby it does nothing, because the flag can only be set on a primary.
- It sets `failover = true` on each Spock logical slot that does not already
  have it.
- It skips any slot that is in use at that moment and prints a NOTICE naming
  the slot.
- It returns the number of slots it changed.

### 2. Handle any skipped slots

A slot that is actively streaming to a subscriber cannot be changed while it is
held, so the function leaves it alone and tells you which one. To set the flag
on those slots, pause the subscribers that hold them and run the function again
on the primary:

```sql
SELECT spock.slot_enable_failover();
```

### 3. Verify

On the primary, every Spock slot should now show `failover` as true:

```sql
SELECT slot_name, failover
FROM pg_replication_slots
WHERE plugin = 'spock_output';
```

The upgrade does not change any PostgreSQL settings. If you are switching to the
native path on PostgreSQL 17, or you are on PostgreSQL 18, set
`sync_replication_slots = on` on the standby yourself and confirm the primary
lists the physical slot in `synchronized_standby_slots`.

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
