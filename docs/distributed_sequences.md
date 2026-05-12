# Distributed Sequences

PostgreSQL sequences are node-local. In a multi-master Spock cluster, two
nodes executing `INSERT INTO orders DEFAULT VALUES` concurrently will each
call `nextval('orders_id_seq')` and may produce the same value; the second
insert violates the primary key constraint on replication and is
discarded. The Spock distributed sequence framework intercepts
`nextval()` and produces cluster-unique values, removing the conflict
without changing the application's schema.

This release ships the **Snowflake** generation method.

## Concepts

A sequence may be assigned a *kind*: `local` (stock PostgreSQL behaviour,
the default) or `snowflake`. Assignments are stored in
`spock.sequence_kind` and replicated to all nodes via Spock's
`user_catalog_table` machinery, so every node converges on the same view
of which sequences are managed.

When a managed sequence is advanced (`nextval()`, a `serial`/`bigserial`
default, `GENERATED AS IDENTITY`, a trigger that calls `nextval()`,
etc.) Spock's `nextval_hook` dispatches to the configured method and
returns a generated value. The on-disk `last_value` of the sequence is
*not* advanced for managed sequences; `currval()` and `lastval()` are
updated and return the method-generated value, as they would for stock
sequences.

## Configuration

### Required core patch

The framework requires a patched PostgreSQL binary that exposes
`nextval_hook`. The patch lives in
`patches/<major>/pg<major>-050-nextval-hook.diff` and is applied as part
of the Spock build. On an unpatched server the Spock shared library
fails to load with an unresolved-symbol error.

### GUCs

| GUC                            | Type    | Scope          | Default     | Purpose |
|--------------------------------|---------|----------------|-------------|---------|
| `spock.max_managed_sequences`  | integer | postmaster     | 1024        | Maximum number of sequences that may be managed concurrently. Each slot consumes a small amount of shared memory (≈24 bytes). Changing this value requires a server restart. |
| `spock.default_sequence_kind`  | enum    | superuser      | `local`     | Method applied to sequences that have no explicit row in `spock.sequence_kind`. Valid values: `local`, `snowflake`. |
| `spock.snowflake_node_id`      | integer | postmaster     | 0           | Node identifier embedded in every Snowflake value generated on this node. Must be unique cluster-wide, in the range 1..1023. If 0, Spock derives the value from `spock.node` at first use; this is intended for single-node testing only. |

`spock.snowflake_node_id` **must be set to a value unique across every
node in the Spock cluster** before any Snowflake-managed sequence is
used in production. Two nodes with the same node id will produce
colliding values, defeating the purpose of distributed sequences.

## SQL surface

### `spock.alter_sequence_set_kind(seqname regclass, kind text) → void`

Assigns a sequence to a kind. The caller must own the sequence (the
function rejects non-owners). Valid `kind` values: `'local'`,
`'snowflake'`.

```sql
SELECT spock.alter_sequence_set_kind('public.orders_id_seq', 'snowflake');
```

Effect is cluster-wide on the next `nextval()` call in every backend
on every node: Spock's per-backend dispatcher cache is invalidated via
relcache on every commit that touches `spock.sequence_kind`, and the
row replicates to peers as part of the same transaction.

### `spock.convert_all_sequences(method text DEFAULT 'snowflake', force bool DEFAULT false) → integer`

Assigns *every* sequence in the current database to the given method.
Sequences that already have an entry are skipped unless `force` is
true. Returns the number of sequences whose row was inserted or
updated.

```sql
-- One-shot conversion at cluster setup
SELECT spock.convert_all_sequences('snowflake');
```

Restricted to superuser, because it touches sequences owned by other
roles. Holds a database-scoped advisory lock for the duration to
serialise concurrent invocations.

### `spock.seq_hook_available() → boolean`

Returns true when the patched PostgreSQL binary exports `nextval_hook`
and Spock has successfully attached to it. Intended for monitoring;
test code can use it to skip cleanly on unpatched servers.

### `spock.seq_snowflake_decode(val bigint) → table(timestamp_ms bigint, node_id int, counter int, ts_utc timestamptz)`

Decodes a Snowflake-generated value into its component fields. Useful
for support, monitoring, and root-cause analysis.

```sql
SELECT (spock.seq_snowflake_decode(id)).*
FROM orders ORDER BY id LIMIT 1;
```

### `spock.sequence_info` view

Per-sequence summary of managed sequences:

```sql
SELECT * FROM spock.sequence_info;
 sequence_name      |   kind    | hook_status
--------------------+-----------+-------------
 public.orders_id   | snowflake | active
 public.shipments_id| snowflake | active
```

## Snowflake method

### Bit layout

A Snowflake value is a non-negative `int8` (bigint) with the layout:

```
 bit 63        : reserved, always 0 (sign bit, keeps values non-negative)
 bits 62..22   : 41-bit timestamp in milliseconds since the Spock epoch
                 (2026-01-01 00:00:00 UTC)
 bits 21..12   : 10-bit node id  (0..1023)
 bits 11..0    : 12-bit counter  (0..4095)
```

### Guarantees

- **Cluster-wide uniqueness**: provided the operator assigns a distinct
  `spock.snowflake_node_id` to every node, no two values produced
  anywhere in the cluster can collide.
- **Monotonicity per node**: every value emitted by a given node is
  strictly greater than the previous value emitted by that node on the
  same sequence, even across backend restarts (the high-water-mark
  state lives in shared memory).
- **Throughput**: up to 4096 distinct values per millisecond per node
  (~4M / s). If the rate is exceeded the implementation advances the
  timestamp field one millisecond ahead of the wall clock and resets
  the counter; the wall clock catches up when the workload subsides.
- **Clock-skew tolerance**: if the wall clock regresses (NTP step, VM
  migration), the implementation continues from the last-observed
  timestamp rather than producing duplicates. A WARNING is logged
  (rate-limited to one per backend per minute).

### Caveats

- **`CACHE > 1` is ignored** for managed sequences. The in-core cache
  is bypassed; the per-call cost is one CAS plus a hash lookup.
- **`ALTER SEQUENCE ... RESTART`** has no effect on a Snowflake-managed
  sequence. Values are computed from timestamp and node id; the
  heap-stored `last_value` is unused.
- **`setval()`** does not propagate to the Snowflake state. The
  function silently succeeds but the next `nextval()` returns the
  Snowflake value, not the value set.
- **Epoch limit**: the 41-bit ms timestamp field exhausts in 2095.
- **Pre-epoch clock**: Snowflake sequences cannot produce values when
  the system clock indicates a time earlier than 2026-01-01 UTC.

## Operations

### Converting an existing cluster

On any one node (the change replicates to the rest):

```sql
-- After all nodes have been upgraded to the Spock release that ships
-- distributed sequences
SELECT spock.convert_all_sequences('snowflake');
```

Verify on each node:

```sql
SELECT count(*) FROM spock.sequence_info WHERE kind = 'snowflake';
```

### Reverting a sequence to local

```sql
SELECT spock.alter_sequence_set_kind('public.orders_id_seq', 'local');
```

After revert, `nextval()` reads the heap-stored `last_value`. Because
Snowflake never wrote it, the next value is whatever the sequence's
`START WITH` was (1 by default). **Pause writes on all but one node
during the transition** if downstream consumers cannot tolerate id
discontinuity.

### Adding a new node

When a new node joins the Spock cluster:

1. Set a unique `spock.snowflake_node_id` in the new node's
   `postgresql.conf` and restart.
2. Bring the node up; Spock replicates `spock.sequence_kind` rows
   automatically.
3. The new node generates Snowflake values immediately on first
   `nextval()` call.

No coordination across the cluster is needed for Snowflake (unlike the
planned `galloc` method, which uses chunk allocation).

### Removing a node

No action required. The removed node's id is never reused (Spock
tracks node ids in `spock.node`). Any Snowflake values it produced
remain valid; orphaned values are harmless.

### `pg_dump` and `pg_upgrade`

`spock.sequence_kind` is registered with `pg_extension_config_dump`
and is included in logical dumps. On a `pg_dump | pg_restore`
migration the per-sequence kind assignments are preserved.

On an in-place `pg_upgrade --link` the sequence OIDs are preserved
and the assignments transfer unchanged.

## Monitoring

```sql
-- Active managed sequences and their methods
SELECT * FROM spock.sequence_info;

-- Decode a recent value to check the timestamp and node id
SELECT (spock.seq_snowflake_decode(id)).*
FROM orders ORDER BY id DESC LIMIT 1;

-- Verify the hook is attached
SELECT spock.seq_hook_available();
```

Clock-skew events appear as `WARNING: wall clock regressed by N ms on
a Spock snowflake sequence` in the server log; the WARNING is
rate-limited to one per backend per minute.

## Forward compatibility

When PostgreSQL's upstream Sequence Access Method patch is committed
(targeting PG 19 or 20), the local `nextval_hook` patch is dropped and
Spock's methods become loadable sequence AMs registered via
`pg_seqam`. The SQL surface (`spock.sequence_kind`,
`spock.alter_sequence_set_kind`, `spock.convert_all_sequences`) maps
cleanly to `ALTER SEQUENCE ... USING <method>` and
`pg_class.relam`. A migration function `spock.migrate_to_seqam()`
will be provided.

## Limitations

- Only the `snowflake` method is implemented in this release. `galloc`
  (range-allocated by Raft-style consensus) and `step_offset`
  (disjoint arithmetic progressions) are planned for follow-up
  releases.
- Snowflake values are `bigint`. Sequences feeding `int2` or `int4`
  columns cannot use Snowflake; either widen the column or wait for
  the `galloc` method.
- `pg_dump` of a database with Snowflake-managed sequences preserves
  the per-sequence kind assignments, but the column type of each
  sequence is whatever was declared at `CREATE SEQUENCE` time --
  including the `data_type` setting. Snowflake assumes `bigint`.
