## NAME

spock.sub_show_table()

### SYNOPSIS

spock.sub_show_table (subscription_name name, relation regclass,
OUT nspname text, OUT relname text, OUT status text)

### RETURNS

A record containing synchronization status information for the table:

  - nspname is the schema name of the table.
  - relname is the table name.
  - status is the current synchronization status of the table.

### DESCRIPTION

Returns the synchronization status of a specific table within a
subscription.

This function queries the current state of table synchronization for a
given subscription. The status field indicates where the table is in the
synchronization process, with possible values:

    - 'i' - initial sync requested
    - 's' - structure synchronization in progress
    - 'd' - data synchronization in progress
    - 'c' - constraint synchronization in progress
    - 'w' - sync waiting for approval from main thread
    - 'u' - catching up with changes
    - 'y' - synchronization finished at LSN
    - 'r' - ready and actively replicating

This is useful for monitoring synchronization progress, diagnosing
replication issues, or verifying that a table has completed its initial
sync before performing dependent operations.

The function must be run on the subscriber node where the subscription
exists.

This is a read-only query function that does not modify any data.

### ARGUMENTS

subscription_name

    The name of the subscription to query.

relation

    The name of the table to check synchronization status for,
    optionally schema-qualified.

### EXAMPLE

    SELECT * FROM spock.sub_show_table('sub_n2_n1', 'public.mytable');
