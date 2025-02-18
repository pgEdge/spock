## Spock Functions

The following functions are included in the `spock` extension:

| Command  | Description |
|----------|-------------| 
| **Node Management Functions** | Nodes can be added and removed dynamically using the SQL interfaces.|
| [node_create](functions/spock_node_create.md) | Define a node for spock.
| [node_drop](functions/spock_node_drop.md) | Remove a spock node.
| [node_add_interface](functions/spock_node_add_interface.md) | Add a new node interface.
| [node_drop_interface](functions/spock_node_drop_interface.md) | Delete a node interface.
| **Replication Set Management Functions** | Replication sets provide a mechanism to control which tables in the database will be replicated and which actions on those tables will be replicated.  Each replicated set can specify individually if `INSERTs`, `UPDATEs`, `DELETEs` and `TRUNCATEs` on the set are replicated. Each table can be in multiple replication sets, and each subscriber can subscribe to multiple replication sets. The resulting set of tables and actions replicated is the union of the sets the table is in. There are three preexisting replication sets named "default", "default_insert_only" and "ddl_sql". The "default" replication set is defined to replicate all changes to tables in it. The "default_insert_only" only replicates INSERTs and is meant for tables that don't have primary key. The "ddl_sql" replication set is defined to replicate schema changes specified by `spock.replicate_ddl`.|
| [repset_create](functions/spock_repset_create.md) | Define a replication set.
| [repset_alter](functions/spock_repset_alter.md) | Modify a replication set.
| [repset_drop](functions/spock_repset_drop.md) | Remove a replication set.
| [repset_add_partition](functions/spock_repset_add_partition.md) | Add a partition to a replication set.
| [repset_remove_partition](functions/spock_repset_remove_partition.md) | Remove a partition from the replication set that the parent table is a part of.
| [repset_add_table](functions/spock_repset_add_table.md) | Add table(s) to replication set.
| [repset_add_all_tables](functions/spock_repset_add_all_tables.md) | Add all existing table(s) to the replication set.
| [repset_remove_table](functions/spock_repset_remove_table.md) | Remove table from replication set.
| [repset_add_seq](functions/spock_repset_add_seq.md) | Adds a sequence to a replication set.
| [repset_add_all_seqs](functions/spock_repset_add_all_seqs.md) | Adds all sequences from the specified schemas to a replication set.
| [repset_remove_seq](functions/spock_repset_remove_seq.md) | Remove a sequence from a replication set.
| **Subscription Management Functions** | |
| [sub_create](functions/spock_sub_create.md) | Create a subscription.
| [sub_drop](functions/spock_sub_drop.md) | Delete a subscription.
| [sub_disable](functions/spock_sub_disable.md) | Put a subscription on hold and disconnect from provider.
| [sub_enable](functions/spock_sub_enable.md) | Make a subscription live.
| [sub_add_repset](functions/spock_sub_add_repset.md) | Add a replication set to a subscription.
| [sub_remove_repset](functions/spock_sub_remove_repset.md) | Drop a replication set from a subscription.
| [sub_show_status](functions/spock_sub_show_status.md) | Display the status of the subcription.
| [sub_show_table](functions/spock_sub_show_table.md) | Show subscription tables.
| [sub_alter_interface](functions/spock_sub_alter_interface.md) | Modify an interface to a subscription.
| [sub_wait_for_sync](functions/spock_sub_wait_for_sync.md) | Pause until the subscription is synchronized.
| **Miscellaneous Management Functions** | |
| [table_wait_for_sync](functions/spock_table_wait_for_sync.md) | Pause until a table finishes synchronizing.
| [sub_resync_table](functions/spock_sub_resync_table.md) | Resynchronize a table.
| [replicate_ddl](functions/spock_replicate_ddl.md) | Enable DDL replication.
| [set_readonly](functions/spock_set_readonly.md) | Turn PostgreSQL read_only mode 'on' or 'off'.
