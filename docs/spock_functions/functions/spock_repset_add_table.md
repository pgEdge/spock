## NAME

`spock.repset_add_table()`

### SYNOPSIS

spock.repset_add_table (
    set_name name,
    relation regclass,
    synchronize_data boolean,
    columns text[],
    row_filter text,
    include_partitions boolean
)

### RETURNS

    - true if the table was successfully added to the replication set.
    - false if the table was already a member of the replication set.

### DESCRIPTION

Adds a specific table to an existing Spock replication set.

This function allows fine-grained control over what data is replicated by
optionally specifying:

    - A subset of columns to replicate.
    - A row filter to restrict which rows are replicated.
    - Whether partitions of a partitioned table should also be included.

If synchronize_data is set to true, existing table data is copied to all
subscribers that are subscribed to this replication set. Otherwise, only
future changes are replicated.

When used with partitioned tables, include_partitions controls whether
child partitions are automatically included in the replication set.

This function writes metadata into the Spock catalogs and does not modify
PostgreSQL configuration.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The name of an existing replication set.

relation

    The table to add, specified as a regclass (for example,
    'public.mytable').

synchronize_data

    If true, existing table data is synchronized to all
    subscribers. Default is false.

columns

    An optional list of column names to replicate. If NULL,
    all columns are replicated.

row_filter

    An optional SQL WHERE clause used to filter which rows
    are replicated.

include_partitions

    If true and the table is partitioned, all partitions are
    included automatically. Default is true.

### EXAMPLE

Add a table named public.accounts to the demo_repset replication set with
full replication:

SELECT spock.repset_add_table('demo_repset', 'public.accounts');

Add a table named public.accounts to the demo_repset replication set, and
synchronize existing data:

SELECT spock.repset_add_table('demo_repset',
    'public.accounts',
    synchronize_data := true);

Add only specific columns (id and balance) from the public.accounts table to
the demo_repset replication set, and filter the rows:

SELECT spock.repset_add_table('demo_repset',
    'public.accounts',
    columns := ARRAY['id','balance'],
    row_filter := 'balance > 0');

  **WARNING: Use caution when synchronizing data with a valid row filter.**
  Using `sync_data=true` with a valid `row_filter` is usually a one_time
  operation for a table. Executing it again with a modified `row_filter` 
  won't synchronize data to subscriber. You may need to call 
  `spock.alter_sub_resync_table()` to fix it.
