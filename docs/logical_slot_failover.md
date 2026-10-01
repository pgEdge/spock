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
| 15, 16 | Spock built-in `spock_failover_slots` worker | Registered on every node; synchronizes only while in recovery |
| 17 | Spock worker **or** native `sync_replication_slots` | Yields to native if enabled |
| 18+ | Native `sync_replication_slots` (required) | Not registered |

The mechanism changes with the version, but the requirement does not: a slot
sync worker is running on every node of the cluster, primary and standby
alike. It is started before the server knows which role it will hold, so on a
primary it stays resident and idle, waking only to check whether the server
has entered recovery. Spock's own worker is registered from
`shared_preload_libraries` and occupies one `max_worker_processes` slot;
PostgreSQL's native worker is a dedicated postmaster process outside that
pool. Budget a worker for it on every node either way - see
[Sizing Postgres Resources for Spock](sizing.md).

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
max_worker_processes = 20
max_replication_slots = 10
max_wal_senders = 10
```

Size these for your cluster rather than copying the numbers - see
[Sizing Postgres Resources for Spock](sizing.md). Slots, walsenders, and
origins scale with the number of other nodes multiplied by the number of
replicated databases in the instance, and `max_replication_slots` and
`max_wal_senders` should be set to the same value. Note that a physical
standby adds a slot to that value on the primary, and that a slot sync worker
occupies one `max_worker_processes` slot on every node.

On PostgreSQL 18, also size `max_active_replication_origins` (default 10) to at
least the number of subscriptions this node applies - `(nodes - 1) x replicated
databases` in a full mesh - plus some headroom. Setting it equal to
`max_replication_slots` is the simplest safe choice.

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
| `hot_standby_feedback` | standby | `on` (you set it) | Required before the worker will synchronize anything, and stops the primary from removing needed catalog rows. |
| `primary_slot_name` | standby | physical slot name | The physical slot the standby streams through. |
| `primary_conninfo` | standby | connection string | How the standby reaches the primary. |
| `spock.synchronize_slot_names` | standby | `name_like:%%` | Which slots to sync. All by default. |
| `spock.drop_extra_slots` | standby | `on` | Drop standby slots that no longer exist on the primary. |
| `spock.primary_dsn` | standby | `''` | Connection to the primary. Falls back to `primary_conninfo` when empty. |
| `spock.pg_standby_slot_names` | primary | `''` | Physical slots that must confirm an LSN before logical replication advances. Optional. |
| `spock.standby_slots_min_confirmed` | primary | `-1` | How many of those slots must confirm. `-1` means all. |
| `spock.failover_slots_naptime` | standby | `1000` | Worker sleep between slot-sync passes, in ms (SIGHUP; range 1–3600000). |
| `spock.failover_slots_feedback_naptime` | standby | `10000` | Shorter retry, in ms, while waiting for standby WAL feedback (SIGHUP; range 1–3600000). |

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

**Important:** if the promoted node has `synchronized_standby_slots` set, you
must adjust it before replication will resume. See
[Runbook: clear `synchronized_standby_slots` after promotion](#runbook-clear-synchronized_standby_slots-after-promotion)
below.

## Runbook: clear `synchronized_standby_slots` after promotion

When `synchronized_standby_slots` is configured (Setup step 2 above), the
provider's walsenders hold back logical decoding until every physical slot
named in that list has confirmed flush of the relevant LSN. This is what
keeps a physical standby from falling behind a logical subscriber, but it
has a sharp edge on failover.

The setting is meant for the primary, but the standby often has it too:

- it was already in the primary's `postgresql.auto.conf` when the standby was
  built with `pg_basebackup`, which copies that file,
- the same `postgresql.conf` is deployed to every node, or
- a cluster manager such as Patroni applies one configuration to every member
  (see [Running Under Patroni](#running-under-patroni-postgresql-17)).

If the standby has it, then once it is promoted the setting still lists the
physical slot(s) that fed replication to *that* node before promotion. Those
slots are now orphaned: nothing is consuming them any more, so they never
confirm, and the promoted node's walsenders sit blocked waiting on them
indefinitely. The practical symptom is that logical replication to
subscribers **freezes** immediately after a promotion that otherwise looked
successful. Check on the promoted node with `SHOW synchronized_standby_slots;`.

When it is set, clearing it is a mandatory post-promotion step, not optional
cleanup:

```sql
-- On the newly promoted node:
ALTER SYSTEM SET synchronized_standby_slots = '';
SELECT pg_reload_conf();
```

The physical slot itself lives on the server that created it. In the setup
above that is the old primary, so drop `spock_standby_slot` there once that
node is rebuilt or retired:

```sql
-- On the old primary, once it is no longer needed:
SELECT pg_drop_replication_slot('spock_standby_slot');
```

Under Patroni the member slots are Patroni's: it removes a departed member's
slot after `member_slots_ttl`, so do not drop them by hand.

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

Patroni manages replication slots itself, and the way it does so decides
which of Spock's two mechanisms can work under it.

- **Member slots.** With `postgresql.use_slots: true` (the default) Patroni
  creates one physical slot per replica on that replica's upstream, named
  after the member (see [naming](#slot-names) below), and drops it once the
  member has been gone for `member_slots_ttl` (default `30min`). On a
  switchover the new leader creates fresh slots for the others.
- **Permanent slots.** Slots listed under `slots:` in the dynamic
  configuration survive switchover. Permanent *logical* slots are copied
  from the leader to each replica by stopping and restarting the replica,
  then advanced every `loop_wait` seconds. That is Patroni's own answer to
  logical slot failover, written before PostgreSQL had one.
- **Unknown slots.** On a replica, Patroni drops logical slots it does not
  manage. Since Patroni 4.1.0 it leaves slots created with `failover = true`
  alone, with one exception on PostgreSQL 17 and later: on a replica it
  removes failover slots whose `synced` is false, which is what a former
  leader's own slots look like after a switchover, so that PostgreSQL's
  slotsync worker can recreate them as synchronized copies of the new
  leader's. Patroni 4.1.4 fixed a crash in that path.

Spock's built-in `spock_failover_slots` worker is unreliable under Patroni.
It copies logical slots to the standby by hand and relies on the standby's
physical slot, through `hot_standby_feedback`, to pin `catalog_xmin` on the
primary. Patroni drops and recreates that physical slot as the topology
changes, which lets vacuum on a busy primary remove catalog rows a copied
slot still needs; the slot is then invalidated (`invalidation_reason =
rows_removed`) and the subscriber has to resynchronize from scratch.

The path that works is PostgreSQL's own: Spock creates its logical slots
with the `FAILOVER` flag, so with `sync_replication_slots = on` the slotsync
worker keeps them current on every member, and Patroni, from 4.1.0 on,
stays out of their way. On PostgreSQL 18 this is the only path, because
Spock's worker is not registered there. On PostgreSQL 17 Spock's worker
runs unless `sync_replication_slots = on` is set, so under Patroni set it.
The mechanism is the one described under
[Setup: PostgreSQL 17 and 18 (Native)](#setup-postgresql-17-and-18-native);
this section is about where those settings go in a Patroni configuration
and what a switchover does to them.

**Requirements:** Patroni 4.1.4 or later, on PostgreSQL 17 or later. On an
older Patroni release, protect the slots with an `ignore_slots` entry in the
dynamic configuration, so that Patroni neither drops nor copies them:

```yaml
ignore_slots:
  - plugin: spock_output
    type: logical
```

### Required settings

| Setting | Value | Where | Restart? | Why |
|---|---|---|---|---|
| `sync_replication_slots` | `on` | dynamic config | No (reload) | PostgreSQL's slotsync worker copies flagged slots to every replica |
| `hot_standby_feedback` | `on` | dynamic config | No (reload) | Required by slot synchronization; pins `catalog_xmin` so vacuum cannot remove rows a slot needs. Patroni turns it on by itself only when permanent logical slots are configured, so set it |
| `wal_level` | `logical` | dynamic config | Yes | Required for logical decoding and for slot synchronization |
| `output_plugin_libraries` | include `spock_output` | dynamic config, **every member** | No (reload) | Only on servers that have the parameter (see below). A synchronized slot keeps `spock_output` as its plugin, so a member missing this setting cannot serve replication once promoted |
| `postgresql.use_slots` | `true` | Patroni config | n/a | The default. Patroni creates the member slot each replica streams through and sets `primary_slot_name` to it, which slot synchronization requires |
| `max_replication_slots` / `max_wal_senders` | sized to cluster | dynamic config | Yes | Member slots plus Spock's logical slots on every node; see [Sizing](sizing.md) |
| `synchronized_standby_slots` | standby member slot name(s) | dynamic config or callback | No (reload) | Optional but recommended; holds the leader's walsenders back until the standby has the WAL. See the [sharp edge](#the-switchover-sharp-edge-synchronized_standby_slots) |

Two requirements of slot synchronization need no action under Patroni: the
`primary_conninfo` Patroni writes for a replica always carries `dbname`, and
`primary_slot_name` is the member slot.

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
        hot_standby_feedback: "on"          # required by slot synchronization
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

Do **not** declare the Spock logical slots as Patroni *permanent logical
slots* (the `slots:` block). That is the hand copying the native path
replaces: Patroni would restart replicas to copy the slots and advance them
itself, in competition with the slotsync worker. Leave the `slots:` block to
physical slots you need preserved, and the logical slots to PostgreSQL.

### Slot names

Patroni derives a member's slot name from the member name: lowercased, with
`-` and `.` turned into `_`, any other character outside `[a-z0-9_]` spelled
as `u` followed by its four-digit code point, and cut at 63 characters. A
member `pg-node.1` streams through slot `pg_node_1`. Whatever names the slots
in `synchronized_standby_slots` has to follow the same rule, which is why the
sample callback below asks Patroni for the name rather than computing it.

### The switchover sharp edge: `synchronized_standby_slots`

`synchronized_standby_slots` names the physical slot(s) the leader's
walsenders must wait for, so that no logical subscriber gets ahead of the
standby that may be promoted. Under Patroni those are the member slots, so
on a two-member cluster with leader `n2` and replica `r1` the leader needs:

```
synchronized_standby_slots = 'r1'
```

The edge is that this value is *role-specific* while Patroni's dynamic
configuration is *cluster-wide*. Hardcode `'r1'` and switch over so that `r1`
becomes leader, and the new leader waits for a slot named after itself, which
does not exist on it: its walsenders block and logical replication freezes.
This is the failure the
[post-promotion runbook](#runbook-clear-synchronized_standby_slots-after-promotion)
describes, and under Patroni it recurs on every switchover unless handled.

The same wait applies to any listed member that is down. Its slot stays on
the leader, inactive, until `member_slots_ttl` expires and Patroni drops it,
and a slot that is inactive or missing blocks alike. A standby that stops
therefore stops logical replication until it is back or removed from the
list.

Three ways to handle it:

- **Automate it with a callback and a periodic reconcile.** Patroni runs
  the `on_role_change` callback on promotion and demotion with the
  arguments `on_role_change <role> <scope>`; the role is `primary` or
  `replica` (`master` on releases before 4.0). On becoming leader the
  script sets `synchronized_standby_slots` to the slots of the other
  members that are up and reloads; on becoming a replica it clears it.

  ```yaml
  postgresql:
    callbacks:
      on_role_change: /etc/patroni/set_synchronized_standby_slots.sh
  ```

  That callback alone is not enough, because Patroni does not run it when
  a standby that was down comes back, nor when one goes away. A standby
  that rejoins after a promotion would stay off the list, and subscribers
  could advance ahead of it. So the same script is also run periodically on
  every member, from cron or a systemd timer, as
  `set_synchronized_standby_slots.sh reconcile <scope>`: it asks Patroni
  for the member's current role and brings the setting up to date,
  touching it only when it differs. A standby is protected from the first
  reconcile after it streams again; choose the interval accordingly.

  A reference implementation ships with Spock at
  [`samples/set_synchronized_standby_slots.sh`](https://github.com/pgEdge/spock/blob/main/samples/set_synchronized_standby_slots.sh).
  It reads the member name from `patroni.yml`, derives slot names with
  Patroni's own function, skips members that are not running or streaming,
  and leaves the setting untouched when the member list cannot be read. It
  supports Patroni's own member slots only, with `use_slots` on and no
  hand-made `primary_slot_name`. Review and adapt it before production use.

- **Let Patroni manage it.** Patroni's development branch has a
  `manage_synchronized_standby_slots` option that keeps
  `synchronized_standby_slots` equal to the synchronous standbys of
  `synchronous_standby_names`; it needs `synchronous_mode` and is not in a
  released version at the time of writing (4.1.5 is the latest). Once it
  ships, prefer it to the callback on clusters that run synchronous
  replication.

- **Leave it unset and accept the trade-off.** Nothing freezes on
  switchover, but the leader no longer waits for the standby before letting
  subscribers advance, so a subscriber can be slightly ahead of the standby
  at the moment of promotion and the new leader marginally behind it. For
  zero data loss, use one of the two options above.

### What a switchover does

1. `patronictl switchover` demotes the leader and promotes a replica.
2. On the new leader the synchronized Spock slots become usable; the
   subscribers only need their DSN pointed at it, as described under
   [After failover](#5-after-failover).
3. The old leader rejoins as a replica. Its own Spock slots carry
   `failover = true` and `synced = false`; Patroni 4.1.0 and later drops
   them there, and the slotsync worker recreates them as synchronized
   copies from the new leader.
4. Whatever manages `synchronized_standby_slots` has to run: the callback
   fires on both nodes, or you apply the runbook by hand.

### Verify

After bootstrap, and again after a switchover, confirm every replica carries
the flagged, synchronized slots:

```sql
-- on each replica
SELECT slot_name, synced, failover, invalidation_reason
FROM pg_replication_slots
WHERE plugin = 'spock_output' AND NOT temporary;
```

`synced` and `failover` should both be `true` and `invalidation_reason`
`NULL`. If `failover` is `false`, the slot was created by a Spock release
before 6.0.0 and the upgrade could not flag it. See
[Upgrading Spock to 6.0.0](#upgrading-spock-to-600) for how to handle it.
On the leader, `SHOW synchronized_standby_slots` should name the slots of
the replicas that are up, and `patronictl list` should show them streaming.

## Setup: PostgreSQL 15 and 16 (Spock Worker)

On PostgreSQL 15 and 16, the `spock_failover_slots` background worker
periodically copies slot state from the primary. The worker is registered on
every node, but it only does this work while the server is in recovery; on a
primary it idles.

### Requirements

- `hot_standby_feedback = on` on the standby (required before the worker will
  synchronize anything)
- The standby must be able to connect to the primary

### Configuration GUCs

| GUC | Default | Description |
|---|---|---|
| `spock.synchronize_slot_names` | `name_like:%%` | Slot name patterns to sync (all by default) |
| `spock.drop_extra_slots` | `on` | Drop standby slots not matching the pattern |
| `spock.primary_dsn` | `''` | DSN to connect to primary (falls back to `primary_conninfo`) |
| `spock.pg_standby_slot_names` | `''` | Physical slots that must confirm LSN before logical replication advances |
| `spock.standby_slots_min_confirmed` | `-1` | How many slots from `pg_standby_slot_names` must confirm (`-1` = all) |
| `spock.failover_slots_naptime` | `1000` | Worker sleep between slot-sync passes, in ms (SIGHUP; range 1–3600000) |
| `spock.failover_slots_feedback_naptime` | `10000` | Shorter retry, in ms, while waiting for standby WAL feedback (SIGHUP; range 1–3600000) |

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

PostgreSQL walks the version chain (5.0.8 to 5.0.9 to 5.0.10 to 5.0.11 to
6.0.0) and runs each step in order. The 5.0.11 to 6.0.0 step calls
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

This row is present on primaries too, where the worker is resident but idle,
so a hit here confirms only that the worker was registered - not that slots
are being synchronized. Confirm that on the standby by comparing
`confirmed_flush_lsn` against the primary, and look for the
`slot synchronization from primary now active` message in the standby log.

## FAQ

**Q: Do I need to do anything after a failover?**

On PG17+: update the subscriber's `host=` in their DSN, and, if the promoted
node has `synchronized_standby_slots` set, clear/adjust it as described in the
[runbook above](#runbook-clear-synchronized_standby_slots-after-promotion).
No slot recreation is needed.

On PG15/16: Spock's worker on the standby (now primary) stops
synchronizing slots, since the server is no longer in recovery. The worker
process itself remains, idle, and still holds its `max_worker_processes` slot.
Subscribers reconnect automatically.

**Q: What if `sync_replication_slots` is not configured on PG18?**

Spock's worker is not registered on PG18. If `sync_replication_slots = on`
is not set, logical slots will **not** be synchronized to standbys, and a
failover will require manual slot recreation and table re-sync.

**Q: Can I use both mechanisms on PG17?**

No. If `sync_replication_slots = on` is set on PG17, Spock's worker detects
this and skips its sync loop, deferring to the native worker entirely.
