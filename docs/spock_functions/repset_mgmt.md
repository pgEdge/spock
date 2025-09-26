# Replication Set Management

Replication sets provide a mechanism to control which tables in the database
will be replicated and which actions on those tables will be replicated. Use the following commands to create and manage replication sets.

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

**Example:** Creating a Replication Set

To create a replication set with Spock, connect to the server with psql and use the `spock.repset_create` command:

`SELECT spock.repset_create(replication_set_name, replicate_insert, replicate_update, replicate_delete, replicate_truncate)`

Provide:

* `replication_set_name` is the name of the replication set.

Use the four remaining parameters to specify the content type to replicate:

* When `replicate_insert` is `true`, `INSERT` statements are replicated. The default is `true`.
* When `replicate_update` is `true`, `UPDATE` statements are replicated. The default is `true`.
* When `replicate_delete` is `true`, `DELETE` statements are replicated. The default is `true`.
* When `replicate_truncate` is `true`, `TRUNCATE` statements are replicated. The default is `true`.

For example, the following command:

  `SELECT spock.repset_create(accts, true, true, true, false)`

Adds a replication set named `accts` that replicates all statements except `TRUNCATE statements`.

**Example:** Adding a Table to a Replication Set

To add a table to a replication set with Spock, connect to the server with psql and invoke the `spock.repset_create` command:

`SELECT spock.repset_create(replication_set_name, table_name, db_name, synchronize_data, columns, row_filter, include_partitions, pg_version)`

Provide:

* `replication_set_name` is the name of an existing replication set.
* `table_name` is the name or name pattern of the table(s) to be added to the set (e.g. '*' for all tables, 'public.*' for all tables in public schema).
* `db_name` is the name of the database in which the table resides.
* `synchronize_data` is a boolean value that instructs the server to synchronize table data on all related subscribers; the
default is `false`.
* `columns` specifies a list of columns to replicate.
* Use `row_filter` to provide an row filtering expression; this value defaults to `None`.
* `include_partitions` is a boolean value; specify `true` to include all partitions.  The default is `true`.
* `pg_version` is the PostgreSQL version; if you have only one version installed, this will default to the installed version.  If you have more than one version installed, you should include the version on which the replication set resides.

For example, the following command:

  `SELECT spock.repset_add_table(accts, payables, accounting)`

Adds a table named `payables` to a replication set named `accts` in the `accounting` database. Since no columns are specified, all columns will be replicated.

**Example:** Removing a Table from a Replication Set

To drop a replication set with Spock, connect to the server with psql and invoke the `spock.repset_remove_table` command:

- `spock.repset_remove_table(set_name, relation)`

  Parameters:
  - `set_name` is the name of the replication set in which the table resides.
  - `relation` is the name or OID of the table that will be removed.

For example, the following command:

  `SELECT spock.repset_add_table(accts, payables)`

Removes a table named `payables` from a replication set named `accts`.


## Replication Set Management Functions

The following functions are provided for managing replication sets:

### spock.repset_create

**`spock.repset_create(set_name name, replicate_insert bool, replicate_update bool, replicate_delete bool, replicate_truncate bool)`**

This function creates a new replication set.

Parameters:

- `set_name` is the unique name of the set.
- `replicate_insert` is `true` if `INSERT` statements are replicated; the default is `true`.
- `replicate_update` is `true` if `UPDATE` statements are replicated; the default is `true`.
- `replicate_delete` is `true` if `DELETE` statements are replicated; the default is `true`.
- `replicate_truncate` is `true` if `TRUNCATE` statements are replicated; the default is `true`.

### spock.repset_alter

**`spock.repset_alter(set_name name, replicate_inserts bool, replicate_updates bool, replicate_deletes bool, replicate_truncate bool)`**

This function changes the parameters of an existing replication set.

Parameters:

- `set_name` is the name of an existing replication set that will be modified by this function.
- `replicate_insert` is `true` if `INSERT` statements are replicated; the default is `true`.
- `replicate_update` is `true` if `UPDATE` statements are replicated; the default is `true`.
- `replicate_delete` is `true` if `DELETE` statements are replicated; the default is `true`.
- `replicate_truncate` is `true` if `TRUNCATE` statements are replicated; the default is `true`.

### spock.repset_drop

**`spock.repset_drop(set_name text)`**

Removes the specified replication set.

Parameters:

- `set_name` is the name of an existing replication set.

### spock.repset_add_table

**`spock.repset_add_table(set_name name, relation regclass, sync_data boolean, columns text[], row_filter text)`**

Adds a table to a replication set.

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the table to be added to the set.
- `sync_data` is `true` if the table data is to be synchronized on all subscribers which are subscribed to the specified replication set; the default is `false`.
- `columns` is the list of columns to replicate. Normally when all columns should be replicated, this will be set to `NULL` (the default).
- `row_filter` is a row filtering expression; the default is `NULL` (no filtering).

  **WARNING: Use caution when synchronizing data with a valid row filter.**

Using `sync_data=true` with a valid `row_filter` is usually a one-time operation for a table. Executing it again with a modified `row_filter` won't synchronize data to subscriber. You may need to call `spock.alter_sub_resync_table()` to fix it.

### spock.repset_add_all_tables

**`spock.repset_add_all_tables(set_name name, schema_names text[], sync_data boolean)`**

Adds all tables in the specified schemas to the replication set. Only existing tables are added, tables that will be created in the future will not be added automatically.

Parameters:

- `set_name` is the name of an existing replication set.
- `schema_names` is an array of names of existing schemas from which tables should be added.
- `sync_data` instructs Spock to synchronize the table data on all nodes which are subscribed to the given replication set when set to `true`. The default is `false`.

### spock.repset_remove_table

**`spock.repset_remove_table(set_name name, relation regclass)`**

Remove a table from a replication set.

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the table to be removed from the set.

### spock.repset_add_seq

**`spock.repset_add_seq(set_name name, relation regclass, sync_data boolean)`**

Adds a sequence to a replication set.

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the sequence to be added to the set.
- `sync_data` instructs Spock to synchronize the table data on all nodes which are subscribed to the given replication set when set to `true`. The default is `false`.

### spock.repset_add_all_seqs

**`spock.repset_add_all_seqs(set_name name, schema_names text[], sync_data boolean)`**

Adds all sequences from the given schemas. Only existing sequences are added, any sequences that will be created in the future will not be added automatically.

Parameters:

- `set_name` is the name of an existing replication set.
- `schema_names` is an array of names name of existing schemas from which tables should be added.
- `sync_data` specify `true` to synchronize the sequence value immediately; the default is `false`.

### spock.repset_remove_seq

**`spock.repset_remove_seq(set_name name, relation regclass)`**

Remove a sequence from a replication set.

Parameters:

- `set_name` is the name of an existing replication set.
- `relation` is the name or OID of the sequence to be removed from the set.

You can view information about which table(s) is in which replication set by querying the `spock.tables` view.

### spock.sub-add-repset

**`spock.sub_add_repset(subscription_name name, replication_set name)`**

Adds a replication set to a subscriber. Does not synchronize replication; only activates consumption of events.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `replication_set` is the name of replication set to add

### spock.sub-remove-repset

**`spock.sub_remove_repset(subscription_name name, replication_set name)`**

Removes a replication set from a subscriber.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `replication_set` is the name of replication set to remove.
