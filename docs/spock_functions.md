## Spock Functions

The following user functions are available via the Spock extension:

| Command  | Description |
|----------|-------------| 
| **Node Management Functions** | You can add and remove nodes dynamically using Spock interfaces.|
| spock.node_info | Returns information about the node on which the function is invoked.
| [spock.node_create](functions/spock_node_create.md) | Define a node for spock.
| [spock.node_drop](functions/spock_node_drop.md) | Remove a spock node.
| [node_add_interface](functions/spock_node_add_interface.md) | Add a new node interface.
| [spock.node_drop_interface](functions/spock_node_drop_interface.md) | Delete a node interface.
| **Replication Set Management Functions** | Replication sets provide a mechanism to control which tables in the database will be replicated and which actions on those tables will be replicated.  Each replicated set can specify individually if `INSERTs`, `UPDATEs`, `DELETEs` and `TRUNCATEs` on the set are replicated. Each table can be in multiple replication sets, and each subscriber can subscribe to multiple replication sets. The resulting set of tables and actions replicated is the union of the sets the table is in. Spock installation creates three replication sets: `default`, `default_insert_only` and `ddl_sql`. The `default` replication set is defined to replicate all changes to tables in it. The `default_insert_only` replication set only replicates `INSERT` statements, and is meant for use by tables that don't have primary key. The `ddl_sql` replication set is defined to replicate schema changes specified by `spock.replicate_ddl`.|
| [spock.repset_create](functions/spock_repset_create.md) | Define a replication set.
| [spock.repset_alter](functions/spock_repset_alter.md) | Modify a replication set.
| [repset_drop](functions/spock_repset_drop.md) | Remove a replication set.
| [spock.repset_add_partition](functions/spock_repset_add_partition.md) | Add a partition to a replication set.
| [spock.repset_remove_partition](functions/spock_repset_remove_partition.md) | Remove a partition from the replication set that the parent table is a part of.
| [spock.repset_add_table](functions/spock_repset_add_table.md) | Add table(s) to replication set.
| [spock.repset_add_all_tables](functions/spock_repset_add_all_tables.md) | Add all existing table(s) to the replication set.
| [spock.repset_remove_table](functions/spock_repset_remove_table.md) | Remove table from replication set.
| [repset_add_seq](functions/spock_repset_add_seq.md) | Deprecated; Adds a sequence to a replication set.
| [repset_add_all_seqs](functions/spock_repset_add_all_seqs.md) | Deprecated; Adds all sequences from the specified schemas to a replication set.
| [repset_remove_seq](functions/spock_repset_remove_seq.md) | Deprecated; Remove a sequence from a replication set.
| [spock.sync_seq](functions/spock_seq_sync.md) | Synchronize the specified sequence.
| **Subscription Management Functions** | |
| [spock.sub_create](functions/spock_sub_create.md) | Create a subscription.
| [spock.sub_drop](functions/spock_sub_drop.md) | Delete a subscription.
| [spock.sub_disable](functions/spock_sub_disable.md) | Put a subscription on hold, and disconnect from the provider.
| [spock.sub_enable](functions/spock_sub_enable.md) | Make a subscription live.
| [spock.sub_add_repset](functions/spock_sub_add_repset.md) | Add a replication set to a subscription.
| [spock.sub_remove_repset](functions/spock_sub_remove_repset.md) | Drop a replication set from a subscription.
| [spock.sub_resync_table](functions/spock_sub_resync_table.md) | Resynchronize one existing table.
| [spock.sub_show_status](functions/spock_sub_show_status.md) | Display the status of the subcription.
| [spock.sub_show_table](functions/spock_sub_show_table.md) | Show subscription tables.
| [spock.sub_sync](functions/spock_sync.md) | Call this function to synchronize all unsynchronized tables in all sets in a single operation.
| [spock.sub_alter_interface](functions/spock_sub_alter_interface.md) | Modify an interface to a subscription.
| [spock.sub_wait_for_sync](functions/spock_sub_wait_for_sync.md) | Pause until the subscription is synchronized.
| spock.sub_alter_skiplsn | Skip transactions until the specified lsn. 
| spock.sub_alter_sync | Synchronize all missing tables.
| **Miscellaneous Management Functions** | |
| [spock.table_wait_for_sync](functions/spock_table_wait_for_sync.md) | Pause until a table finishes synchronizing.
| [spock.replicate_ddl](functions/spock_replicate_ddl.md) | Enable DDL replication.
| spock.set_readonly | Turn PostgreSQL read_only mode 'on' or 'off'.
| spock.spock_version | Returns the Spock version in a major/minor version form: `4.0.10`.
| spock.spock_version_num | Returns the Spock version in a single numeric form: `40010`.
| spock.convert_sequence_to_snowflake | Convert a Postgres native sequence to a Snowflake sequence.
| spock.get_channel_stats | Returns tuple traffic statistics.
| spock.get_country | Returns the country code if explicitly set; returns `??` if not set.
| spock.lag_tracker | Returns a list of slots, with commit_lsn and commit_timestamp for each.
| spock.repair_mode | Used to manage the state of replication - If set to `true`, stops replicating statements; when `false`, resumes replication.
| spock.replicate_ddl | Replicate a specific statement.
| spock.reset_channel_stats | Reset the channel statistics.
| spock.spock_max_proto_version | The highest Spock native protocol supported by the current binary/build.
| spock.spock_min_proto_version | The lowest build for which this Spock binary is backward compatible. 
| spock.table_data_filtered | Scans the specified table and returns rows that match the row filter from the specified replication set(s).  Row filters are added to a replication set when adding a table with `repset_add_table`.
| spock.terminate_active_transactions | Terminates all active transactions.
| spock.wait_slot_confirm_lsn | Wait for the `confirmed_flush_lsn` of the specified slot, or all logical slots if none given.
| spock.xact_commit_timestamp_origin | Returns the commit timestamp and origin of the specified transaction.


 
