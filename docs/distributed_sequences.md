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
| `spock.default_sequence_kind`  | enum    | superuser      | `local`     | Method applied to sequences that have no explicit row in `spock.sequence_kind`. Valid values: `local`, `snowflake`. |

There is **no fixed cap** on the number of sequences that may be
managed. Per-sequence state lives in the sequence's own heap tuple
(no extension-private shared memory). The earlier
`spock.max_managed_sequences` and `spock.snowflake_node_id` GUCs have
been removed -- if you have them in `postgresql.conf` you will see
"unrecognized configuration parameter" at startup; remove the lines.

The Snowflake node id is derived from the local `spock.node` (the same
node identity Spock already uses for replication). `spock.node.id` is
a 16-bit hash of the node name (`hash_any(name) & 0xffff`); the
snowflake field takes the low 10 bits of that. **Two node names whose
hashes collide on the low 10 bits silently emit colliding snowflakes
cluster-wide.** Operators must pick node names whose derived ids are
distinct and non-zero across the cluster.

The derivation `spock.node.id & 1023` runs at `spock.node_create()`
time -- there is no preview helper, so the operator workflow is:
create the node, inspect `SELECT id & 1023 FROM spock.node;`, and if
the result is 0 or collides with a peer's value, drop the node and
recreate it with a different name. The first `nextval()` against a
snowflake sequence ERRORS when the local Spock node hasn't been
created yet or when its derived id is 0.

## SQL surface

### `spock.alter_sequence_set_kind(seqname regclass, kind text) → void`

Assigns a sequence to a kind. The caller must own the sequence (the
function rejects non-owners). Valid `kind` values: `'local'`,
`'snowflake'`.

```sql
SELECT spock.alter_sequence_set_kind('public.orders_id_seq', 'snowflake');
```

Effect is **node-local** in Spock 6.0. The call writes the
`spock.sequence_kind` row on the local node only and invalidates every
local backend's dispatcher cache via relcache; subsequent `nextval()`
calls on this node pick up the new kind. The row does **not** replicate
to peer nodes — `spock.sequence_kind` is intentionally not a
`user_catalog_table`, and Spock's autoddl machinery replicates only
LOGSTMT_DDL utility statements (CREATE/ALTER/DROP), not SQL function
invocations.

**Operators must run `spock.alter_sequence_set_kind()` (or
`spock.convert_all_sequences()`) on every node in the cluster.**
Running it on only some nodes is supported but inconsistent: the
unconverted nodes continue to emit stock sequence values while
converted nodes emit snowflakes, so cluster-wide uniqueness is no
longer guaranteed until every node has the same kind for a given
sequence.

Autoddl-driven propagation is a planned follow-up; see the technical
spec's "Known gaps and follow-up work" section.

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

### `spock.sequence_hook_available() → boolean`

Returns true when the patched PostgreSQL binary exports `nextval_hook`
and Spock has successfully attached to it. Intended for monitoring;
test code can use it to skip cleanly on unpatched servers.

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
                 (2023-01-01 00:00:00 UTC; matches the standalone `snowflake` extension)
 bits 21..12   : 10-bit node id  (0..1023)
 bits 11..0    : 12-bit counter  (0..4095)
```

### Guarantees

- **Cluster-wide uniqueness**: provided every node's Spock node name
  derives to a distinct non-zero 10-bit id (i.e. `spock.node.id & 1023`
  is distinct and non-zero on every peer), no two values produced
  anywhere in the cluster can collide.
- **Monotonicity per node**: every value emitted by a given node is
  strictly greater than the previous value emitted by that node on the
  same sequence, even across backend restarts and crashes. Per-sequence
  state is persisted in the sequence relation's heap tuple (the
  `last_value` column) and protected by a WAL pre-log reservation —
  not in extension-private shared memory. On backend restart or crash
  recovery the next `nextval()` reads `last_value` from the heap tuple
  and continues monotonic issuance from there (possibly skipping ahead
  by up to the reservation window).
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
  sequence. The same applies to `INCREMENT`, `MINVALUE`, `MAXVALUE`,
  `CYCLE`, and `CACHE`: all are ignored. To change any of these, revert
  to `local` first, run the `ALTER SEQUENCE`, then convert back to
  `snowflake` if desired.
- **`setval()`** does not propagate to the Snowflake state. The
  function silently succeeds but the next `nextval()` returns the
  Snowflake value, not the value set.
- **Sequence type and MAXVALUE**: `spock.alter_sequence_set_kind(seq,
  'snowflake')` refuses sequences whose declared type is not `bigint`
  and sequences whose `MAXVALUE` is below `1 << 22` (the lowest
  possible Snowflake value). Snowflake values are 64-bit; smaller
  column types cannot store them.
- **Epoch limit**: the 41-bit ms timestamp field exhausts in 2092.
- **Pre-epoch clock**: Snowflake sequences cannot produce values when
  the system clock indicates a time earlier than 2023-01-01 UTC.

### Interaction with built-in logical replication

Managed sequences **do not produce sequence-advance WAL records**. The
in-core code only writes `xl_seq_rec` records when it updates the
heap-stored `last_value`, and a hook-handled `nextval()` skips that
write entirely. As a consequence:

- Built-in logical replication (`pgoutput`) configured with
  `sequences = true`, and any third-party output plugin that consumes
  the `sequence_cb` callback, **will not receive sequence-advance
  events** for sequences assigned to `snowflake`. Replication of the
  rows that *use* those sequence values still works as normal; only
  the `last_value` state of the sequence object itself is skipped.
- This is intentional. Snowflake-managed sequences derive uniqueness
  from the embedded node id, not from cross-node replication of
  `last_value`; replicating the state would be pointless and
  occasionally wrong.
- If you have a non-Spock subscriber on the same publication that
  expects to receive sequence updates, revert the affected sequence
  to `local` before adding it to that publication.

### Security model

`spock.alter_sequence_set_kind` is `REVOKE`'d from `PUBLIC` and
performs a sequence-owner check on every call: only the owner of a
sequence (or a member of the owning role) may change its kind, even
after `EXECUTE` has been granted on the function. `spock.convert_all_sequences`
is superuser-only.

Each `alter_sequence_set_kind` call writes a row to `spock.sequence_kind`,
which is a `user_catalog_table` replicated to peer nodes via Spock's
existing machinery. **The apply worker on a peer node writes the
replicated row without re-checking the originating user's privileges**,
because peer Spock nodes are in the same trust domain by design. The
implication is:

- Any role you grant `EXECUTE` on `spock.alter_sequence_set_kind` is
  effectively a role that can change sequence behaviour on *every*
  node in the cluster.
- Grant `EXECUTE` only to roles you would also trust on every other
  node.

The read-only diagnostic function `spock.sequence_hook_available()` is
also `REVOKE`'d from `PUBLIC`; grant explicitly to monitoring or
support roles as needed.

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

1. Run `spock.node_create('newname', ...)` to create the local Spock
   node; that fixes the snowflake `node_id` for the lifetime of the
   node.
2. Verify that `SELECT id & 1023 FROM spock.node;` is non-zero and not
   already used by an existing peer. If it isn't, drop the node and
   retry with a different name -- the snowflake `node_id` is frozen
   at `node_create()` time.
3. Bring the node up; Spock replicates `spock.sequence_kind` rows
   automatically.
4. The new node generates Snowflake values immediately on first
   `nextval()` call.

No coordination across the cluster is needed for Snowflake (unlike the
planned `galloc` method, which uses chunk allocation).

### Removing a node

No action required. The removed node's id is never reused (Spock
tracks node ids in `spock.node`). Any Snowflake values it produced
remain valid; orphaned values are harmless.

### `pg_dump` and `pg_upgrade`

**`pg_upgrade`** preserves sequence OIDs and `spock.sequence_kind` rows
survive unchanged in both `--link` and `--copy` modes. No action
required.

**Logical `pg_dump | pg_restore`**: kind assignments survive the
round-trip. `spock.sequence_kind` is keyed on `(nspname, relname)`,
which are stable across restore (unlike sequence OIDs), and the table
is registered with `pg_extension_config_dump` so its rows are included
in the dump output. The restored sequences pick up their kind on the
destination automatically.

The `seqoid` cache column in `spock.sequence_kind` will hold stale
values from the source cluster immediately after restore — sequence
OIDs are reassigned on the destination. The dispatcher does not use
this column; it looks up rows by name. The column self-refreshes on
the next `spock.alter_sequence_set_kind()` or
`spock.convert_all_sequences()` call against the affected sequences.
The column is consulted only by the `ALTER SEQUENCE ... RENAME` hook;
a rename of a freshly-restored sequence before its seqoid has been
refreshed will not find the row, and the kind assignment will appear
to vanish until the operator runs `spock.convert_all_sequences()` to
re-establish (by name) and refresh the seqoid cache.

Migrating a Spock database to a server that does **not** have Spock
installed: use `pg_dump --no-extension=spock` (PostgreSQL 17+) or its
older equivalents. The dump then excludes the `CREATE EXTENSION spock`
and all `spock.*` content, and restores cleanly on a vanilla
PostgreSQL cluster.

### `ALTER SEQUENCE ... RENAME` and `... SET SCHEMA`

Both are handled transparently. An object-access hook on `OAT_POST_ALTER`
for `RELKIND_SEQUENCE` rewrites the matching `spock.sequence_kind` row
to the new `(nspname, relname)`. The kind assignment survives the
rename without operator intervention.

## Monitoring

```sql
-- Active managed sequences and their methods
SELECT * FROM spock.sequence_info;

-- Verify the hook is attached
SELECT spock.sequence_hook_available();
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
