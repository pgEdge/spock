# Managing a Spock Installation

The Spock extension is a powerful addition to any PostgreSQL installation; management features of the Spock extension allow you to seamlessly:

* [replicate partitioned tables](partition_mgmt.md).
* use [batch inserts](batch_inserts.md) to improve performance.
* create logical [row-based data filters](filtering.md).
* set a cluster to [READ-ONLY mode](read_only.md); this restricts non-superusers to read-only operations, while superusers can still perform both read and write operations.
* use a [trigger](repset_trigger.md) to manage replication set membership.
* use [Snowflake sequences](snowflake.md) for sequence management in a distributed cluster.
* use [the Lolor extension](lolor.md) to replicate large objects.
* enable [automatic DDL replication](spock_autoddl.md).
