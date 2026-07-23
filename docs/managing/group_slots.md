# Group Replication Slots

Group replication slots are internally managed replication slots that track the
oldest safe WAL position for an entire Spock replication group. Modeled after
BDR/PGD-style group slots, they let a node retain the WAL that any active or
relevant downstream member of the group might still need, and release it only
once every required member has confirmed durable progress for the current
membership generation.

Each Spock database maintains exactly **one** local, **inactive** logical
replication slot for its group. The slot is never streamed; it exists purely to
pin (retain) WAL at the group-safe horizon.

> **Operational rule:** group slots are managed by Spock. **Never** drop a group
> slot manually with `pg_drop_replication_slot()`. Doing so can discard WAL that
> other group members still require. Use [`spock.repair_group_slot()`](#spockrepair_group_slot)
> for recovery instead.

## Enabling the feature

Group slots are **disabled by default** and can be enabled without changing any
existing replication behaviour. Configure them with the following GUCs (all are
`PGC_SIGHUP`, so a configuration reload is enough — no restart required):

| GUC | Default | Description |
|-----|---------|-------------|
| `spock.group_slots_enabled` | `off` | Master switch. When `on`, each Spock database maintains a group slot. When `off`, no group slot is created and normal replication behaviour is unchanged. |
| `spock.group_slots_worker_interval` | `5s` | How often the per-database group-slot worker recomputes the group-safe horizon and, when safe, advances the group slot. |
| `spock.group_slots_progress_staleness_timeout` | `60s` | If a required member has not reported fresh progress within this interval, advancement is refused and the reason recorded. |
| `spock.group_slots_safety_mode` | `strict` | `strict` refuses any unsafe advancement or repair. `repair` additionally allows guarded recreation/relink of a damaged slot. `off` keeps metadata up to date but never advances the slot. |

Example:

```sql
ALTER SYSTEM SET spock.group_slots_enabled = 'on';
SELECT pg_reload_conf();
```

## How it works

* When a node is created (or on the worker's first tick after enabling the
  feature), Spock seeds durable metadata and the background worker creates the
  inactive group slot. The slot name is deterministic; see
  [`spock.local_group_slot_name()`](#spocklocal_group_slot_name). Group slots
  use the reserved `spkgrp_` prefix, which deliberately does **not** match the
  `spk_*` pattern used to clean up per-subscription slots, so ordinary
  subscription/node cleanup never removes a group slot.
* A per-database background worker periodically computes the **safe LSN** as the
  minimum confirmed flush/replay LSN across all active and relevant downstream
  members, and advances the group slot to that horizon — but only when it is
  safe to do so.
* All state (safe LSN, freeze LSN, membership generation, node state, blocked
  reasons, per-member progress) is stored in durable catalog tables
  (`spock.group_slot_state`, `spock.group_slot_membership`,
  `spock.group_slot_member_progress`), so decisions survive restarts without
  relying on shared memory.

### When advancement is refused

The worker never advances the group slot when any of the following holds. The
reason is recorded in `spock.group_slot_state.blocked_reason` and surfaced by
[`spock.group_slot_status()`](#spockgroup_slot_status):

| `blocked_reason` | Meaning |
|------------------|---------|
| `join_in_progress` | A node is joining; the horizon is held so the joining node has a stable base point. |
| `part_in_progress` | A node is parting; the slot is frozen at the part boundary. |
| `unknown_node_state` | A member is in an unknown lifecycle state. |
| `stale_progress` | A required member has not reported fresh progress within the staleness timeout. |
| `membership_generation_mismatch` | The cluster has not converged on a single membership generation. |
| `missing_slot_state` | The physical slot is missing; repair is required. |
| `safety_mode_off` | `spock.group_slots_safety_mode = off`; metadata is maintained but the slot is not advanced. |

## Zero-downtime node addition and removal

Group slots integrate with the ZODAN add/remove workflows while retaining the
existing temporary-slot behaviour as a fallback:

* **Adding a node** — `spock.add_node()` calls
  `spock.group_slot_begin_join()` on the source after the new node is
  registered, pausing group-slot advancement so the group-safe horizon is
  retained as a stable base point for the joining node. Once the new node is a
  full, bidirectionally replicating member, `spock.group_slot_complete_join()`
  resumes advancement.
* **Removing a node** — `spock.remove_node()` calls
  `spock.group_slot_begin_part()` before the departing node's slots are torn
  down, freezing the group slot at the pre-removal boundary so retained WAL
  covers the part. After the node is gone it calls
  `spock.group_slot_complete_part()` to advance to the next generation, clear
  the freeze, and resume advancement. Because each node maintains its own group
  slot, run the same call on every other remaining node:

  ```sql
  SELECT spock.group_slot_complete_part('<removed_node_name>');
  ```

## Functions

### spock.local_group_slot_name

```sql
spock.local_group_slot_name() -> name
```

Returns the deterministic group slot name for the current database and local
node (for example, `spkgrp_mydb_n1`), or `NULL` when the current database is not
configured as a Spock node.

### spock.group_slot_status

```sql
spock.group_slot_status()
```

Returns a single row describing the local group slot: `slot_name`,
`membership_generation`, `node_state`, `safe_lsn`, `freeze_lsn`,
`last_advanced_lsn`, `blocked_reason`, `repair_required`, `slot_present`,
`restart_lsn`, `confirmed_flush_lsn`, `updated_at`, `required_members`, and
`stale_members`. Use it to inspect the current horizon and any blocked reason.

### spock.advance_group_slot

```sql
spock.advance_group_slot(target_lsn pg_lsn DEFAULT NULL, force boolean DEFAULT false) -> pg_lsn
```

Performs a controlled manual advancement to `target_lsn` (or the computed
group-safe horizon when `NULL`). Even with `force`, hard blockers
(`join_in_progress`, `part_in_progress`, `unknown_node_state`,
`membership_generation_mismatch`, `missing_slot_state`) are never bypassed.
Soft blockers (`stale_progress`, `safety_mode_off`) and advancing past the
group-safe horizon require both `force = true` **and** a non-strict
`spock.group_slots_safety_mode`. Returns the LSN the slot was advanced to.

### spock.repair_group_slot

```sql
spock.repair_group_slot(mode text DEFAULT 'recreate') -> text
```

Safely repairs a damaged group slot.

* `relink` — re-synchronizes metadata to the deterministic slot name and adopts
  an existing slot. Always safe.
* `recreate` — recreates a **missing** slot. Because recreation starts
  protection at the current WAL position and therefore drops protection for
  older WAL, it is refused in `strict` safety mode and requires
  `spock.group_slots_safety_mode = repair`. A warning is logged when it runs.

Returns `relinked`, `recreated`, `already_present`, or `missing_slot`.

## Backward compatibility

When `spock.group_slots_enabled` is `off` (the default), no group slot is
created and replication behaves exactly as before. Existing deployments upgrade
transparently; the group-slot catalog objects are added by the extension
upgrade and remain dormant until the feature is enabled.
