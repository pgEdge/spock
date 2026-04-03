## NAME

spock.repset_remove_partition()

### SYNOPSIS

spock.repset_remove_partition (parent regclass, partition regclass)

### RETURNS

The number of partitions removed from replication sets as an integer.

### DESCRIPTION

Removes a partition or all partitions of a partitioned table from the
replication sets that include the parent table.

This function removes partition tables from replication without affecting
the parent table's replication membership. When a specific partition is
provided, only that partition is removed. When the partition parameter is
NULL, all partitions of the parent table are removed from replication.

This is useful when you want to exclude specific partitions from
replication while keeping the parent table and other partitions replicated.
For example, you might want to replicate recent partitions but not
historical data stored in older partitions.

Removing a partition from replication does not drop the partition table
itself - it only removes the partition from the replication sets. The
partition remains in the database and can still be accessed locally.

The function returns the count of partitions that were actually removed
from replication sets. If no partitions were removed (because they were not
in any replication sets), it returns 0.

This function modifies the Spock catalogs but does not modify any user data
or PostgreSQL server configuration.

### ARGUMENTS

parent

    The parent partitioned table whose partition(s) should be removed
    from replication.

partition

    The specific partition to remove from replication. If NULL, all
    partitions of the parent table are removed. Defaults to NULL.

### EXAMPLE

    SELECT spock.repset_remove_partition('public.mytable',
    'public.mytable_202012');
