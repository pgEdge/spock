## Finding Cluster Information

The following table describes the informational tables in the `spock` schema; query the tables with the psql
client to return information about your replication cluster. 

| Name | Description |
---------------------|----------------------------|
| `node` | This table contains one row per replication node. This table is replicated, and contains the `node_id`, `node_name`, and optionally the `location`, `country`, and `info`. |
| `node_interface` | This table contains one row per node interface. This table is replicated, and contains the `if_id`, `if_name`, `if_nodeid`, and `if_dsn` which represent the connection information for that node. |
| `local_node` | This table contains one row with information for the local node. It contains the `node_id` and `node_local_interface` and can be joined with the previous two tables to show all local node information only. |
| `replication_set` | This table contains one row per replication set. It contains the `set_id`, `set_nodeid`, `set_name` and four boolean columns: `replicate_insert`, `replicate_update`, `replicate_delete`, and `replicate_truncate`. This table contains three rows by default for the `default`, `default_insert_only`, and `ddl_sql` replication sets. |
| `replication_set_seq` | This table contains one row per replication set sequence. It contains `set_id` and `set_seqoid`. |
| `replication_set_table` | This table contains one row per table that is in any replication set. It contains the `set_id`, `set_reloid` (the table name), `set_att_list`,  and `set_row_filter`. The last two columns contain the row and column filters on that table for replication. |
| `tables` | This table contains one row per table in the database. It contains the `relid`, `nspname` (the schema), `relname` (the tablename), and `set_name` (null if that table is not added to any replication set). |
| `pii` | This is an optional table in which you can define columns that contain personally identifiable information (pii). You can add information such as the schema, table, and column names and then use this table to createcolumn filters when adding tables to replication sets. |
| `subscription` | This table contains one row per subscription. It contains the `sub_id`, `sub_name`, `sub_origin`, `sub_target`, `sub_origin_if`, `sub_target_if`, `sub_enabled`, `sub_slot_name`, `sub_replication_sets` (an array of replication sets that have been added to the subscription), `sub_forward_origins`, `sub_apply_delay`, and `sub_force_text_transfer`. |
| `resolutions` | This table contains one row per resolution made on this node. It contains the `id`, `node_name`, `log_time`, `relname`, `idxname`, `conflict_type` (`update_update`), `conflict_resolution` (`keep_local`), `local_origin`, `local_tuple`, `local_xid, local_timestamp`, `remote_origin`, `remote_tuple`, `remote_xid`, `remote_timestamp`, `remote_lsn`. |

### Examples

**Example:** Validating Spock Configuration for a Two Node Cluster

You can use the Spock extension to confirm that nodes are created and replication is happening. If a 
command returns a result set with no records, it implies that a command to create the node has not yet been run;
a single row in this table implies that a command to create a subscription on the node has not been executed. 

You can connect to the database server and query the `spock.node` table to return information about configured nodes:

```json
select * from spock.node;
-[ RECORD 1 ]--------
node_id   | 673694252
node_name | n1
location  |
country   |
info  	|
-[ RECORD 2 ]--------
node_id   | 560818415
node_name | n2
location  |
country   |
info  	|
```

**Example:** Confirming that a Functioning Subscription Exists

You can connect to the database server and query the `spock.subscription` table to return information 
about a subscription:

```sql
select * from spock.subscription;
-[ RECORD 1 ]-----------+--------------------------------------------------
sub_id              	| 3293941396
sub_name            	| sub_n1n2
sub_origin          	| 560818415
sub_target          	| 673694252
sub_origin_if       	| 4043145508
sub_target_if       	| 1437190346
sub_enabled         	| t
sub_slot_name       	| spk_demo_n2_sub_n1n2
sub_replication_sets	| {default,default_insert_only,ddl_sql,demo_repset}
sub_forward_origins 	|
sub_apply_delay     	| 00:00:00
sub_force_text_transfer | f
```
Note that the value of `sub_enabled` is `t` if the subscription is currently replicating.

**Example:** Listing Tables that are Part of a Replication Scenario

You can connect to the database server and query the `spock.subscription_set_table` table to return 
similar information:

```sql
select * from spock.replication_set_table ;                            	
-[ RECORD 1 ]--+-----------------
set_id     	| 2403235102
set_reloid 	| pgbench_accounts
set_att_list   |
set_row_filter |
-[ RECORD 2 ]--+-----------------
set_id     	| 2403235102
set_reloid 	| pgbench_branches
set_att_list   |
set_row_filter |
-[ RECORD 3 ]--+-----------------
set_id     	| 2403235102
set_reloid 	| pgbench_tellers
set_att_list   |
set_row_filter |
```

### Listing Tables that are not Part of a Replication Cluster

You can query the `spock.tables` table to identify tables that are not yet part of a replication set; if 
the set name is `null`, the table is not part of a replication set.

```sql
select * from spock.tables where set_name is null;
-[ RECORD 1 ]-------------
relid	| 24846
nspname  | public
relname  | pgbench_history
set_name |
```
