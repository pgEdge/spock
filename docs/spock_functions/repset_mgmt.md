# Replication Set Management

Replication sets provide a mechanism to control which tables in the database
will be replicated and which actions on those tables will be replicated. Use
the following commands to create and manage replication sets.

| Command  | Description
|----------|-------------
| [spock.repset_create](functions/spock_repset_create.md) | Create a new replication set.
| [spock.repset_alter](functions/spock_repset_alter.md) | Modify an existing replication set.
| [spock.repset_drop](functions/spock_repset_drop.md) | Remove a replication set.
| [spock.repset_add_table](functions/spock_repset_add_table.md) | Adds a table to replication set.
| [spock.repset_add_all_tables](functions/spock_repset_add_all_tables.md) | Adds all tables in a given schema(s).
| [spock.repset_remove_table](functions/spock_repset_remove_table.md) | Remove a table from replication set.
| [spock.repset_add_seq](functions/spock_repset_add_seq.md) | Adds a sequence to a replication set.
| [spock.repset_add_all_seqs](functions/spock_repset_add_all_seqs.md) | Adds all sequences from the given schemas.
| [spock.repset_remove_seq](functions/spock_repset_remove_seq.md) | Remove a sequence from a replication set.
| [spock.sub_add_repset](functions/spock_sub_add_repset.md) | Adds a replication set to a subscriber.
| [spock.sub_remove_repset](functions/spock_sub_remove_repset.md) | Removes a replication set from a subscriber.

## Creating a Replication Set

To create a replication set with Spock, connect to the server with psql and
use the `spock.repset_create` command:

```sql
SELECT spock.repset_create(replication_set_name, replicate_insert,
    replicate_update, replicate_delete, replicate_truncate)
```

Parameters include:

- `replication_set_name` is the name of the replication set.

Use the four remaining parameters to specify the content type to replicate:

- when `replicate_insert` is `true`, `INSERT` statements are replicated; the
  default is `true`.
- when `replicate_update` is `true`, `UPDATE` statements are replicated; the
  default is `true`.
- when `replicate_delete` is `true`, `DELETE` statements are replicated; the
  default is `true`.
- when `replicate_truncate` is `true`, `TRUNCATE` statements are replicated;
  the default is `true`.

For example, the following command:

```sql
SELECT spock.repset_create('accts', true, true, true, false);
```

Adds a replication set named `accts` that replicates all statements except
`TRUNCATE` statements.

## Adding a Table to a Replication Set

To add a table to a replication set with Spock, connect to the server with
psql and invoke the `spock.repset_add_table` command:

```sql
SELECT spock.repset_add_table(set_name name, relation regclass,
    synchronize_data boolean DEFAULT false, columns text[] DEFAULT NULL,
    row_filter text DEFAULT NULL, include_partitions boolean DEFAULT true)
```

Parameters include:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the table to add.
- `synchronize_data` is a boolean value that instructs the server to
  synchronize table data on all related subscribers; the default is `false`.
- `columns` specifies a list of columns to replicate; the default is `NULL`
  (all columns).
- `row_filter` is a row filtering expression; the default is `NULL` (no
  filtering).
- `include_partitions` is a boolean value; specify `true` to include all
  partitions; the default is `true`.

For example, the following command:

```sql
SELECT spock.repset_add_table('accts', 'payables');
```

Adds a table named `payables` to a replication set named `accts`. Since no
columns are specified, all columns will be replicated.

## Reserved Schemas and Extensions

Some schemas and extensions are reserved and are treated specially by Spock.
They are listed in the `spock.reserved_object` catalog, which is the single
source of truth for two behaviours:

- `exclude_from_dump`: the object is left out of the structure-sync dump used
  when a subscription synchronizes structure. Restoring these on a subscriber
  that already has them would fail.
- `block_in_repset`: a table in this schema, or belonging to this extension,
  may not be added to a replication set.
- `replicate_ddl`: applies to schemas only. When `false`, AutoDDL does not
  ship DDL that targets only this schema to other nodes -- the schema is
  node-local. It is not meaningful for extensions, so it is required for
  `schema` rows and is `NULL` for `extension` rows (a `CHECK` enforces this,
  and `reserved_object_add` sets it to `NULL` automatically for an extension).

Spock seeds the following built-in rows, and they cannot be removed or
modified:

| Object            | exclude_from_dump | block_in_repset | replicate_ddl |
|-------------------|-------------------|-----------------|---------------|
| `spock`           | yes               | yes             | yes           |
| `snowflake`       | yes               | yes             | yes           |
| `lolor`           | yes               | no              | yes           |
| `pgedge_ace` (schema only) | yes      | yes             | no            |

`spock`, `snowflake`, and `lolor` each have both a `schema` and an
`extension` row. The `replicate_ddl` column above is the value on the
`schema` row; the `extension` row carries `replicate_ddl = NULL` (not
applicable), while `exclude_from_dump`/`block_in_repset` apply to both.

`lolor` is excluded from the dump but is intentionally allowed in replication
sets: its tables must replicate so that large objects survive a
`DROP EXTENSION` on every node, not only where the drop was issued.

`pgedge_ace` is the schema used by the pgEdge ACE utility. It is node-local
configuration/state, not application data: its DDL is never shipped to other
nodes (`replicate_ddl=no`), and its tables can never be added to a
replication set, so `CREATE SCHEMA pgedge_ace` and DDL/tables underneath it
stay local to the node where they were issued.

To reserve an additional schema or extension of your own, use
`spock.reserved_object_add`:

```sql
-- keep a custom schema out of structure sync and out of replication sets
SELECT spock.reserved_object_add('ace', 'schema');

-- exclude an extension from the dump but still allow its tables in repsets
SELECT spock.reserved_object_add('myext', 'extension', p_block_in_repset := false);

-- keep a custom schema node-local: AutoDDL will not replicate its DDL
SELECT spock.reserved_object_add('myschema', 'schema', p_replicate_ddl := false);
```

Use `spock.reserved_object_remove('ace', 'schema')` to drop your own entry.
Reserved objects are node-local configuration: apply the same additions on
each node of the cluster. Operator-added rows are preserved across
`pg_dump`/`pg_restore`; the built-in rows are always re-seeded.

## Removing a Table from a Replication Set

To remove a table from a replication set with Spock, connect to the server
with psql and invoke the `spock.repset_remove_table` command:

```sql
SELECT spock.repset_remove_table(set_name name, relation regclass,
    include_partitions boolean DEFAULT true)
```

Parameters include:

- `set_name` is the name of the replication set in which the table resides.
- `relation` is the name or OID of the table that will be removed.
- `include_partitions` is a boolean value; specify `true` to also remove
  partitions of the partitioned table; the default is `true`.

For example, the following command:

```sql
SELECT spock.repset_remove_table('accts', 'payables');
```

Removes a table named `payables` from a replication set named `accts`.


## Replication Set Management Functions

The following functions are provided for managing replication sets:

### spock.repset_create

Use `spock.repset_create` to create a new replication set.

`spock.repset_create(set_name name, replicate_insert bool,
replicate_update bool, replicate_delete bool, replicate_truncate bool)`

Parameters:

- `set_name` is the unique name of the set.
- `replicate_insert` is `true` if `INSERT` statements are replicated; the default is `true`.
- `replicate_update` is `true` if `UPDATE` statements are replicated; the default is `true`.
- `replicate_delete` is `true` if `DELETE` statements are replicated; the default is `true`.
- `replicate_truncate` is `true` if `TRUNCATE` statements are replicated; the default is `true`.

### spock.repset_alter

Use `spock.repset_alter` to change the parameters of an existing replication
set.

`spock.repset_alter(set_name name, replicate_insert bool DEFAULT NULL,
replicate_update bool DEFAULT NULL, replicate_delete bool DEFAULT NULL,
replicate_truncate bool DEFAULT NULL)`

Parameters:

- `set_name` is the name of an existing replication set that will be modified by this function.
- `replicate_insert` is `true` if `INSERT` statements are replicated. Pass `NULL` (the default) to leave the current value unchanged.
- `replicate_update` is `true` if `UPDATE` statements are replicated. Pass `NULL` (the default) to leave the current value unchanged.
- `replicate_delete` is `true` if `DELETE` statements are replicated. Pass `NULL` (the default) to leave the current value unchanged.
- `replicate_truncate` is `true` if `TRUNCATE` statements are replicated. Pass `NULL` (the default) to leave the current value unchanged.

### spock.repset_drop

Use `spock.repset_drop` to remove the specified replication set.

`spock.repset_drop(set_name name, ifexists boolean DEFAULT false)`

Parameters:

- `set_name` is the name of an existing replication set.
- `ifexists` controls whether dropping a non-existent replication set
  raises an error. When `true`, no error is raised if the set is missing;
  the default is `false`.

### spock.repset_add_table

Use `spock.repset_add_table` to add a table to a replication set.

`spock.repset_add_table(set_name name, relation regclass,
synchronize_data boolean DEFAULT false, columns text[] DEFAULT NULL,
row_filter text DEFAULT NULL, include_partitions boolean DEFAULT true)`

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the table to be added to the set.
- `synchronize_data` is `true` if the table data is to be synchronized on all
  subscribers which are subscribed to the specified replication set; the
  default is `false`.
- `columns` is the list of columns to replicate. Normally when all columns
  should be replicated, this will be set to `NULL` (the default).
- `row_filter` is a row filtering expression; the default is `NULL` (no
  filtering).
- `include_partitions` is `true` to also add partitions of a partitioned
  table; the default is `true`.

!!! warning
    Use caution when synchronizing data with a valid row filter. Using
    `synchronize_data=true` with a valid `row_filter` is usually a one-time
    operation for a table. Executing it again with a modified `row_filter`
    won't synchronize data to subscriber. You may need to call
    `spock.sub_resync_table()` to fix it.

### spock.repset_add_all_tables

Use `spock.repset_add_all_tables` to add all tables in the specified schemas
to the replication set.

`spock.repset_add_all_tables(set_name name, schema_names text[],
synchronize_data boolean DEFAULT false)`

Only existing tables are added; tables that will be created in the future
will not be added automatically.

Parameters:

- `set_name` is the name of an existing replication set.
- `schema_names` is an array of names of existing schemas from which tables
  should be added.
- `synchronize_data` instructs Spock to synchronize the table data on all
  nodes which are subscribed to the given replication set when set to
  `true`; the default is `false`.

### spock.repset_remove_table

Use `spock.repset_remove_table` to remove a table from a replication set.

`spock.repset_remove_table(set_name name, relation regclass,
include_partitions boolean DEFAULT true)`

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the table to be removed from the set.
- `include_partitions` is `true` to also remove partitions of the
  partitioned table; the default is `true`.

### spock.repset_add_seq

Use `spock.repset_add_seq` to add a sequence to a replication set.

`spock.repset_add_seq(set_name name, relation regclass,
synchronize_data boolean DEFAULT false)`

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the sequence to be added to the set.
- `synchronize_data` instructs Spock to synchronize the sequence on all
  nodes which are subscribed to the given replication set when set to
  `true`; the default is `false`.

### spock.repset_add_all_seqs

Use `spock.repset_add_all_seqs` to add all sequences from the given schemas.

`spock.repset_add_all_seqs(set_name name, schema_names text[],
synchronize_data boolean DEFAULT false)`

Only existing sequences are added; any sequences that will be created in the
future will not be added automatically.

Parameters:

- `set_name` is the name of an existing replication set.
- `schema_names` is an array of names of existing schemas from which sequences
  should be added.
- `synchronize_data` specify `true` to synchronize the sequence value
  immediately; the default is `false`.

### spock.repset_remove_seq

Use `spock.repset_remove_seq` to remove a sequence from a replication set.

`spock.repset_remove_seq(set_name name, relation regclass)`

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the sequence to be removed from the set.

You can view information about which table(s) is in which replication set by
querying the `spock.tables` view.

### spock.sub_add_repset

Use `spock.sub_add_repset` to add a replication set to a subscriber.

`spock.sub_add_repset(subscription_name name, replication_set name)`

Does not synchronize replication; only activates consumption of events.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `replication_set` is the name of replication set to add.

### spock.sub_remove_repset

Use `spock.sub_remove_repset` to remove a replication set from a subscriber.

`spock.sub_remove_repset(subscription_name name, replication_set name)`

Parameters:

- `subscription_name` is the name of an existing subscription.
- `replication_set` is the name of replication set to remove.

### spock.reserved_object_add

Use `spock.reserved_object_add` to reserve a schema or extension (see
[Reserved Schemas and Extensions](#reserved-schemas-and-extensions)). If the
object is already reserved, its flags are updated. Built-in objects cannot be
changed.

`spock.reserved_object_add(p_name name, p_kind text, p_exclude_from_dump bool
DEFAULT true, p_block_in_repset bool DEFAULT true, p_replicate_ddl bool
DEFAULT NULL)`

Parameters:

- `p_name` is the schema or extension name.
- `p_kind` is `'schema'` or `'extension'`.
- `p_exclude_from_dump` keeps the object out of the structure-sync dump; the
  default is `true`.
- `p_block_in_repset` blocks the object from replication sets; the default is
  `true`.
- `p_replicate_ddl` applies to schemas only. For a schema, leaving it unset
  (`NULL`) defaults to `true`; pass `false` to keep the schema node-local so
  AutoDDL does not ship its DDL to other nodes (as `pgedge_ace` is). For
  `p_kind = 'extension'` the argument is ignored and the value is stored as
  `NULL`.

### spock.reserved_object_remove

Use `spock.reserved_object_remove` to remove one of your own reserved objects.
Built-in objects are protected and cannot be removed.

`spock.reserved_object_remove(p_name name, p_kind text)`

Parameters:

- `p_name` is the schema or extension name.
- `p_kind` is `'schema'` or `'extension'`.
