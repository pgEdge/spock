## NAME

`spock.repset_remove_table ()`

### SYNOPSIS

spock.repset_remove_table (
    set_name name,
    relation regclass,
    include_partitions boolean)

### RETURNS

    - true if the table was successfully removed from the replication set.
    - false if the table was not a member of the replication set.

### DESCRIPTION

Removes a table from an existing Spock replication set.  After removal, 
changes to this table will no longer be replicated to subscribers that
are subscribed to the replication set.

If the table is partitioned, the include_partitions argument controls
whether all child partitions are also removed from the replication set.

This function updates metadata stored in the Spock catalogs and does not
modify the PostgreSQL configuration.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The name of an existing replication set.

relation

    The table to remove, specified as a regclass
    (for example, 'public.mytable').

include_partitions

    If true and the table is partitioned, all partitions are
    also removed from the replication set. Default is true.

### EXAMPLE

Remove a table (public.users) from the default replication set:

    postgres=# SELECT spock.repset_remove_table('default', 'public.users');
     repset_remove_table 
    ---------------------
     t
    (1 row)

Remove a partitioned table named public.sales_parent from the default
replication set without removing its partitions:

    postgres=# SELECT spock.repset_remove_table('default',
    'public.users',
    include_partitions := false);
    ---------------------
     t
    (1 row)
