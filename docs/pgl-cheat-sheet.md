# pglogical to Spock function names

Spock's function names are shorter than pglogical's, so a cluster or a
script being ported from pglogical 2 needs almost every call renamed. This
page maps each pglogical function to its Spock equivalent.

Verified against pglogical 2.4.8 and Spock 6.0.0. Where a Spock function has
a reference page, its name links to it.

## Nodes

| pglogical 2.4 | Spock 6.0 |
| --- | --- |
| `pglogical.create_node()` | [`spock.node_create()`](spock_functions/functions/spock_node_create.md) |
| `pglogical.drop_node()` | [`spock.node_drop()`](spock_functions/functions/spock_node_drop.md) |
| `pglogical.alter_node_add_interface()` | [`spock.node_add_interface()`](spock_functions/functions/spock_node_add_interface.md) |
| `pglogical.alter_node_drop_interface()` | [`spock.node_drop_interface()`](spock_functions/functions/spock_node_drop_interface.md) |
| `pglogical.pglogical_node_info()` | [`spock.node_info()`](spock_functions/functions/spock_node_info.md) |

## Subscriptions

| pglogical 2.4 | Spock 6.0 |
| --- | --- |
| `pglogical.create_subscription()` | [`spock.sub_create()`](spock_functions/functions/spock_sub_create.md) |
| `pglogical.drop_subscription()` | [`spock.sub_drop()`](spock_functions/functions/spock_sub_drop.md) |
| `pglogical.alter_subscription_interface()` | [`spock.sub_alter_interface()`](spock_functions/functions/spock_sub_alter_interface.md) |
| `pglogical.alter_subscription_disable()` | [`spock.sub_disable()`](spock_functions/functions/spock_sub_disable.md) |
| `pglogical.alter_subscription_enable()` | [`spock.sub_enable()`](spock_functions/functions/spock_sub_enable.md) |
| `pglogical.alter_subscription_add_replication_set()` | [`spock.sub_add_repset()`](spock_functions/functions/spock_sub_add_repset.md) |
| `pglogical.alter_subscription_remove_replication_set()` | [`spock.sub_remove_repset()`](spock_functions/functions/spock_sub_remove_repset.md) |
| `pglogical.show_subscription_status()` | [`spock.sub_show_status()`](spock_functions/functions/spock_sub_show_status.md) |
| `pglogical.show_subscription_table()` | [`spock.sub_show_table()`](spock_functions/functions/spock_sub_show_table.md) |

## Replication sets

| pglogical 2.4 | Spock 6.0 |
| --- | --- |
| `pglogical.create_replication_set()` | [`spock.repset_create()`](spock_functions/functions/spock_repset_create.md) |
| `pglogical.alter_replication_set()` | [`spock.repset_alter()`](spock_functions/functions/spock_repset_alter.md) |
| `pglogical.drop_replication_set()` | [`spock.repset_drop()`](spock_functions/functions/spock_repset_drop.md) |
| `pglogical.replication_set_add_table()` | [`spock.repset_add_table()`](spock_functions/functions/spock_repset_add_table.md) |
| `pglogical.replication_set_add_all_tables()` | [`spock.repset_add_all_tables()`](spock_functions/functions/spock_repset_add_all_tables.md) |
| `pglogical.replication_set_remove_table()` | [`spock.repset_remove_table()`](spock_functions/functions/spock_repset_remove_table.md) |
| `pglogical.replication_set_add_sequence()` | [`spock.repset_add_seq()`](spock_functions/functions/spock_repset_add_seq.md) |
| `pglogical.replication_set_add_all_sequences()` | [`spock.repset_add_all_seqs()`](spock_functions/functions/spock_repset_add_all_seqs.md) |
| `pglogical.replication_set_remove_sequence()` | [`spock.repset_remove_seq()`](spock_functions/functions/spock_repset_remove_seq.md) |
| `pglogical.show_repset_table_info()` | [`spock.repset_show_table()`](spock_functions/functions/spock_repset_show_table.md) |

## Synchronisation

| pglogical 2.4 | Spock 6.0 |
| --- | --- |
| `pglogical.alter_subscription_synchronize()` | [`spock.sub_alter_sync()`](spock_functions/functions/spock_sub_alter_sync.md) |
| `pglogical.alter_subscription_resynchronize_table()` | [`spock.sub_resync_table()`](spock_functions/functions/spock_sub_resync_table.md) |
| `pglogical.synchronize_sequence()` | [`spock.sync_seq()`](spock_functions/functions/spock_sync_seq.md) |
| `pglogical.wait_for_subscription_sync_complete()` | [`spock.sub_wait_for_sync()`](spock_functions/functions/spock_sub_wait_for_sync.md) |
| `pglogical.wait_for_table_sync_complete()` | [`spock.table_wait_for_sync()`](spock_functions/functions/spock_table_wait_for_sync.md) |
| `pglogical.wait_slot_confirm_lsn()` | [`spock.wait_slot_confirm_lsn()`](spock_functions/functions/spock_wait_slot_confirm_lsn.md) |

## DDL, utilities and version information

| pglogical 2.4 | Spock 6.0 |
| --- | --- |
| `pglogical.replicate_ddl_command()` | [`spock.replicate_ddl()`](spock_functions/functions/spock_replicate_ddl.md) |
| `pglogical.table_data_filtered()` | `spock.table_data_filtered()` |
| `pglogical.xact_commit_timestamp_origin()` | [`spock.xact_commit_timestamp_origin()`](spock_functions/functions/spock_xact_commit_timestamp_origin.md) |
| `pglogical.pglogical_gen_slot_name()` | [`spock.spock_gen_slot_name()`](spock_functions/functions/spock_gen_slot_name.md) |
| `pglogical_version()` | [`spock.spock_version()`](spock_functions/functions/spock_version.md) |
| `pglogical_version_num()` | [`spock.spock_version_num()`](spock_functions/functions/spock_version_num.md) |
| `pglogical_max_proto_version()` | [`spock.spock_max_proto_version()`](spock_functions/functions/spock_max_proto_version.md) |
| `pglogical_min_proto_version()` | [`spock.spock_min_proto_version()`](spock_functions/functions/spock_min_proto_version.md) |

## Functions with no Spock equivalent

`pglogical.queue_truncate()` has no counterpart. Spock controls whether
`TRUNCATE` replicates with the replication set's `replicate_truncate`
option, set with [`spock.repset_create()`](spock_functions/functions/spock_repset_create.md)
or [`spock.repset_alter()`](spock_functions/functions/spock_repset_alter.md),
rather than with a function call.

## Spock functions with no pglogical ancestor

Spock adds functions that pglogical never had, so a port is not finished when
the last name in the table above has been changed. See the
[function list](spock_functions/index.md) for the full set; the additions
include `spock.sync_event()`, `spock.wait_for_sync_event()`,
`spock.repset_add_partition()`, `spock.sub_alter_options()` and
`spock.sub_alter_skiplsn()`.
