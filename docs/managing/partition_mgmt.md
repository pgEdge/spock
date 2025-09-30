# Replicating Partitioned Tables

By default, when you add a partitioned table to a Spock replication set, Spock will include all the current partitions of a partitioned table. If you partition a table, or add partitions to a partitioned table at a later date, you will need to use the [`spock.repset_add_partition`](../spock_functions/functions/spock_repset_add_partition.md) function to add them to your replication sets. The DDL for the partitioned table and partitions must reside on the subscriber nodes (like a non-partitioned table).

When you remove a partitioned table from a replication set, by default, the partitions of the table will also be removed.  You should use [`spock.repset_remove_partition`](../spock_functions/functions/spock_repset_remove_partition.md) to update the cluster's meta-data.

Replication of partitioned tables is a bit different from normal tables. During an initial synchronization, we query the partitioned table (or parent) to get all the rows for synchronization purposes and don't synchronize the individual partitions. After the initial sync of data, the normal operations resume and the partitions start replicating like normal tables.

If you add individual partitions to a replication set, they will be replicated like regular tables (to the table of the same name as the partition on each subscriber). This has performance advantages if your partitioning definition is the same on both provider and subscriber, as the partitioning logic does not have to be executed with each sync.

!!! info

    During the initial cluster setup and sync, table partitions are not synced directly. Instead, the parent table is synced with the source with data from all partitions, and the partitions are populated properly on the destination preserving the table structure. This partitioning behavior is equivalent to setting `synchronize_data = false` for individual partitions during the initial sync.

    When setup completes (after the initial sync), both the parent table and partitions are monitored for modifications, and changes are replicated as they are made.

When partitions are replicated through a partitioned table, `TRUNCATE` commands alway replicate to the complete list of affected tables or partitions.

!!! info

    You can use a `row_filter` clause with a partitioned table, as well as with individual partitions.

