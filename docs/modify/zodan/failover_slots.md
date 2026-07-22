# Failover Slots — Configuration per PostgreSQL Version, and Zodan Changes

A **failover slot** is a logical replication slot that has been copied
from a primary to its physical streaming standby, so that when the
standby is promoted to primary it already has the slot — meaning logical
subscribers can keep replicating without re-syncing.

PostgreSQL's mechanism for keeping slots in sync between a primary and a
standby changed in PG17, and changed again in PG18. This document
explains:

1. What configuration users must apply on **PG15/16**.
2. What configuration users must apply on **PG17/18**.
3. What changes **Zodan** required so that the slots it creates fit each
   mechanism correctly.

| PostgreSQL | Slot sync mechanism | Spock failover-slot worker |
|---|---|---|
| 15, 16 | Spock's `spock_failover_slots` background worker on the standby | Required; the only mechanism available |
| 17     | PG native slot sync worker **or** Spock's worker | Registered, but yields to native if `sync_replication_slots = on` |
| 18+    | PG native slot sync worker only | Not registered |

## PostgreSQL 15 and 16

PG15 and PG16 have no `failover` column on `pg_replication_slots` and no
built-in slot sync. Spock ships a background worker
(`spock_failover_slots`) that runs on the standby and periodically copies
slot state from its primary.

### Configuration on the primary

In `postgresql.conf`:

```ini
wal_level                = logical
shared_preload_libraries = 'spock'

# Optional but recommended: hold logical decoding back until the standby
# confirms it has the WAL. Without this, a logical subscriber could read
# past where the standby is, and after promotion would be ahead of the
# new primary.
spock.pg_standby_slot_names       = 'standby_slot'
spock.standby_slots_min_confirmed = -1   -- -1 = all named slots must confirm
```

Then create the physical slot the standby will stream from:

```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```

### Configuration on the standby

In `postgresql.conf`:

```ini
shared_preload_libraries     = 'spock'
hot_standby                  = on
hot_standby_feedback         = on
primary_slot_name            = 'standby_slot'
primary_conninfo             = 'host=<primary_host> port=5432 user=replicator dbname=<dbname>'

# spock_failover_slots worker GUCs (defaults shown):
spock.synchronize_slot_names = 'name_like:%%'  -- which slots to sync (all by default)
spock.drop_extra_slots       = on              -- drop standby slots that no longer exist upstream
# spock.primary_dsn          = ''              -- override; if blank, falls back to primary_conninfo
```

Restart the standby. Verify the worker is up:

```sql
SELECT pid
FROM   pg_stat_activity
WHERE  application_name = 'spock_failover_slots worker';
```

## PostgreSQL 17 and 18

Starting with PG17, PostgreSQL has a built-in slot sync worker on the
standby that copies any logical slot from its primary as long as the slot
is tagged `failover = true`. On PG18, this is the **only** mechanism —
Spock's own failover worker is not registered at all.

### Configuration on the primary

In `postgresql.conf`:

```ini
wal_level = logical

# Hold logical decoding back until the standby has confirmed it has the WAL.
synchronized_standby_slots = 'standby_slot'
```

Then create the physical slot the standby will stream from:

```sql
SELECT pg_create_physical_replication_slot('standby_slot');
```

### Configuration on the standby

In `postgresql.conf`:

```ini
hot_standby            = on
hot_standby_feedback   = on
primary_slot_name      = 'standby_slot'
sync_replication_slots = on
```

In `postgresql.auto.conf` (or `postgresql.conf`):

```ini
# IMPORTANT: dbname is required — without it, the slot sync worker
# cannot log into the primary to inspect logical slots, and slot sync
# silently does nothing. pg_basebackup -R does NOT include dbname.
primary_conninfo = 'host=<primary_host> port=5432 user=replicator dbname=<dbname>'
```

Restart the standby. Verify the native worker is up:

```sql
SELECT pid, backend_type
FROM   pg_stat_activity
WHERE  backend_type = 'slot sync worker';
```

## Zodan changes for failover slots

Every Zodan `add_node` operation creates one new logical replication slot
on each existing node in the cluster (the slot the new node's
subscription will consume). For those new slots to be eligible for the
PG17+ native slot sync worker, they must be created with `failover = true`.
On PG15/16 there is no such flag — the slot is plain logical, and
Spock's own worker on the standby will pick it up regardless.

### What changed in `zodan.sql`

The slot-creation procedure was updated to detect the target PostgreSQL
version and adapt accordingly. In
[`samples/Z0DAN/zodan.sql`](../../../samples/Z0DAN/zodan.sql), procedure
`spock.create_replication_slot`:

```sql
-- Detect remote PG version
SELECT v INTO remote_version
  FROM dblink(node_dsn, 'SHOW server_version_num') AS t(v int);

-- On PG17+ pass failover := true so the slot is picked up by the
-- native slot sync worker (sync_replication_slots = on) and is
-- synchronized to physical standbys, matching what Spock does
-- on its own CREATE_REPLICATION_SLOT path (see spock_sync.c).
IF remote_version >= 170000 THEN
    remotesql := format(
        'SELECT slot_name, lsn '
        'FROM pg_create_logical_replication_slot(%L, %L, false, false, true)',
        slot_name, plugin
    );
ELSE
    remotesql := format(
        'SELECT slot_name, lsn '
        'FROM pg_create_logical_replication_slot(%L, %L)',
        slot_name, plugin
    );
END IF;
```

The trailing `true` in the PG17+ branch is the `failover` positional
parameter to `pg_create_logical_replication_slot`. With it set, the
slot will appear with `failover = true` on the primary and PG's native
slot sync worker will copy it to the standby on its next cycle.

This change mirrors what Spock's own subscription path does in
[`src/spock_sync.c`](../../../src/spock_sync.c), where
`CREATE_REPLICATION_SLOT ... (FAILOVER)` is appended whenever the
provider is PG17 or newer:

```c
if (PQserverVersion(sql_conn) >= 170000)
    appendStringInfo(&query, " (FAILOVER)");
```

So after the Zodan change, slots created by `CALL spock.add_node(...)`
are indistinguishable from slots created by ordinary
`spock.sub_create(...)` calls with respect to failover behaviour.

### What did NOT need to change

- The Zodan workflow on PG15/16 — Zodan already created plain logical
  slots, and Spock's failover-slot worker on the standby copies them
  regardless of any flag. No code change was needed for those versions.
- The `add_node` API itself — users call it identically on every
  supported version. The version branch lives entirely inside
  `spock.create_replication_slot`.

## Verification after `add_node`

### PG17/18

On each existing node (the primary), confirm slots were created with
`failover = true`:

```sql
SELECT slot_name, failover
FROM   pg_replication_slots
WHERE  slot_type = 'logical' AND slot_name LIKE '%<new_node_name>%';
```

On each standby, confirm the slot appeared and is synced:

```sql
SELECT slot_name, synced, failover
FROM   pg_replication_slots
WHERE  slot_type = 'logical' AND slot_name LIKE '%<new_node_name>%';
```

Both `synced` and `failover` should be `t`.

### PG15/16

On each standby, confirm the new slot appears (give the Spock worker up
to ~2 minutes for its next cycle):

```sql
SELECT slot_name, slot_type, restart_lsn
FROM   pg_replication_slots
WHERE  slot_type = 'logical' AND slot_name LIKE '%<new_node_name>%';
```

You should see one row per new slot with a sensible `restart_lsn`. There
is no `synced` or `failover` column on PG15/16 — slot presence with a
live LSN is what success looks like.

## See also

- [Logical Slot Failover](../../logical_slot_failover.md) — the general
  user-facing guide to configuring physical standbys for slot sync,
  independent of Zodan
- [Zodan readme](zodan_readme.md) — full Zodan command reference
- [Zodan tutorial](zodan_tutorial.md) — step-by-step manual walkthrough
