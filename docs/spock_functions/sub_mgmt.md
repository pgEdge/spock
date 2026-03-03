# Subscription Management Functions

Each node in a multi-master scenario contains one or more subscriptions that identify the publisher node; the subscriber acts as the replication target for the publisher.


| Command  | Description
|----------|-------------
| [spock.sub_create](functions/spock_sub_create.md) | Create a subscription.
| [spock.sub_drop](functions/spock_sub_drop.md) | Drop a subscription.
| [spock.sub_disable](functions/spock_sub_disable.md) | Disable a subscription and disconnect it from the provider.
| [spock.sub_enable](functions/spock_sub_enable.md) | Enables a disabled subscription.
| [spock.sub_alter_interface](functions/spock_sub_alter_interface.md) | Switch the subscription to use a different interface to connect to the provider node.
| [spock.sub_sync](functions/spock_sub_sync.md) | Synchronize all unsynchronized tables in a single operation.
| [spock.sub_resync_table](functions/spock_sub_resync_table.md) | Resynchronize a single table.
| [spock.sub_wait_for_sync](functions/spock_sub_wait_for_sync.md) | Wait for a subscription to finish synchronization after a `spock.sub_create` or `spock.sub_sync`.
| [spock.sub_wait_table_sync](functions/spock_table_wait_for_sync.md) | Same as `spock.sub_wait_for_sync`, but waits only for the subscription's initial sync.
| [spock.sub_show_status](functions/spock_sub_show_status.md) | Shows status and basic information about subscription.
| [spock.sub_show_table](functions/spock_sub_show_table.md) | Shows synchronization status of a table.
| [spock.sub_add_repset](functions/spock_sub_add_repset.md) | Adds a replication set to a subscriber.
| [spock.sub_remove_repset](functions/spock_sub_remove_repset.md) | Removes a replication set from a subscriber.

**Example:** Creating a Subscription

To create a subscription from the current node to a publisher node with Spock, connect to the server with psql and invoke the `spock.sub_create` command:

`SELECT spock.sub_create(subscription_name, provider_dsn, replication_sets, synchronize_structure, synchronize_data, forward_origins, apply_delay interval, force_text_transfer)`

Parameters:
  - `subscription_name` is the unique name of the subscription.
  - `provider_dsn` is the connection string to a provider.
  - `replication_sets` is an array of replication sets that you wish to subscribe to. The sets must already exist; the default is `{default,default_insert_only,ddl_sql}`.
  - `sync_structure` is a boolean value that specifies if Spock should synchronize the structure from provider to the subscriber; the default is `false`.
  - `sync_data` specifies if Spock should synchronize data from provider to the subscriber; the default is `true`.
  - `forward_origins` is an array of origin names to forward. Currently, the only supported values are an empty array meaning don't forward any changes that didn't originate on provider node (this is useful for two-way replication between the nodes), or "{all}" which means replicate all changes no matter what is their origin. The default is `{all}`.
  - `apply_delay` specifies how long to delay replication; the default is `0` seconds.
  - Set `force_text_transfer` to `true` to force the provider to replicate all columns using a text representation (which is slower, but may be used to change the type of a replicated column on the subscriber). The default is `false`.

For example, the following command:

`SELECT spock.sub_create(accts, host=178.12.15.12 user=carol dbname=accounting, payables)`

Creates a subscription named `accts` that connects to the `accounting` database on `178.12.15.12`, authenticating with the credentials of a user named `carol`. The `payables` replication set is subscribed to the new subscription.

**Example:** Dropping a Subscription

To drop a subscription with Spock, connect to the server with psql and invoke the `spock.sub_drop` command:

- `spock.sub_drop(subscription_name name, ifexists bool)`

Parameters:
  - `subscription_name` is the name of the existing subscription.
  - If `ifexists` is `true`, an error is not thrown if the specified subscription does not exist. The default is `false`.

For example, the following command:

`SELECT spock.sub_drop(accts, true)`

Drops a subscription named `accts`; if the subscription does not exist, an error message will be suppressed by the `true` trailing parameter (`ifexists = true`).


## Subscription Management Functions

You can use the following settings to control and manage your subscriptions.

### spock.sub_create

**`spock.sub_create(subscription_name name, provider_dsn text, repsets text[], sync_structure boolean, sync_data boolean, forward_origins text[], apply_delay interval)`**

Creates a subscription from current node to the provider node. The command does not wait for completion before returning to the caller.

Parameters:

- `subscription_name` is the unique name of the subscription.
- `provider_dsn` is the connection string to a provider.
- `repsets` is an array of existing replication sets to which you are subscribing. The default is `{default,default_insert_only,ddl_sql}`.
- `sync_structure` tells Spock if it should synchronize the structure from the provider to the subscriber; the default is `false`.
- `sync_data` tells Spock to synchronize data from provider to the subscriber; the default is `true`.
- `forward_origins` is an array of origin names to forward. Currently, the only supported values are an empty array meaning don't forward any changes that didn't originate on the provider node (this is useful for two-way replication between the nodes), or `{all}` which means replicate all changes regardless of their origin. The default is `{all}`.
- `apply_delay` is the number of seconds to delay replication; the default is `0` seconds
- `force_text_transfer` forces the provider to replicate all columns using a text representation (which is slower, but may be used to change the type of a replicated column on the subscriber) when set to `yes`. The default is `false`.

The `subscription_name` is used as `application_name` by the replication connection. This means that it's visible in the `pg_stat_replication` monitoring view. It can also be used in `synchronous_standby_names` when Spock is used as part of a synchronous replication setup.

Use `spock.sub_wait_for_sync(subscription_name)` to wait for the subscription to asynchronously start replicating and complete any needed schema and/or data sync.

### spock.sub_drop

**`spock.sub_drop(subscription_name name, ifexists bool)`**

Disconnects the subscription and removes it from the catalog.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `ifexists` tells the Spock extension how to handle the error if the subscription does not exist. If `true`, an error is not thrown if the subscription does not exist; the default is `false`.

### spock.sub_disable

**`spock.sub_disable(subscription_name name, immediate bool)`**

Disables a subscription and disconnects it from the provider.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `immediate` tells Spock when to stop the subscription. If set to `true`, the subscription is stopped immediately; if set to `false` (the default), it will be only stopped at the end of current transaction.

### spock.sub_enable

**`spock.sub_enable(subscription_name name, immediate bool)`**

Enables a disabled subscription.

Parameters:
- `subscription_name` is the name of the existing subscription.
- `immediate` tells Spock when to start the subscription. If set to `true`, the subscription is started immediately; if set to `false` (the default), it will only be started at the end of the current transaction.

### spock.sub_alter_interface

**`spock.sub_alter_interface(subscription_name name, interface_name name)`**

Modify the subscription to use a different interface to connect to provider node.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `interface_name` is the name of an existing interface of the current provider node.

### spock.sub_sync

**`spock.sub_sync(subscription_name name, truncate bool)`**

Call this function to synchronize all unsynchronized tables in all sets in a single operation. Tables are copied and synchronized one by one. The command does not wait for completion before returning to the caller. Use `spock.wait_for_sub_sync` to wait for completion.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `truncate` tells Spock if it should truncate tables before copying. If `true`, tables will be truncated before copy; the default is `false`.

### spock.sub_resync_table

**`spock.sub_resync_table(subscription_name name, relation regclass)`**

Resynchronize an existing table. The table may not be the target of any foreign key constraints.

**WARNING:** This function will truncate the table immediately, and only then begin synchronising it, so it will be empty while being synced. The command does not wait for completion before returning to the caller; use `spock.wait_for_table_sync` to wait for completion.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `relation` is the name of an existing table, optionally qualified.

### spock.sub_wait_for_sync

**`spock.sub_wait_for_sync(subscription_name name)`**

Wait for a subscription to finish synchronization after a `spock.sub_create` or `spock.sub_sync`.

This function waits until the subscription's initial schema/data sync, if any, are done, and until any tables pending individual resynchronisation have also finished synchronising.

Parameters:

- `subscription_name` is the name of an existing subscription.

For best results, run `SELECT spock.wait_slot_confirm_lsn(NULL, NULL)` on the provider after any replication set changes that requested resyncs, and only then call `spock.sub_wait_for_sync` on the subscriber.

### spock.sub_wait_table_sync

**`spock.sub_wait_table_sync(subscription_name name, relation regclass)`**

Same as `spock.sub_wait_for_sync`, but waits only for the subscription's initial sync and the named table. Other tables pending resynchronisation are ignored.

### spock.wait_slot_confirm_lsn

**`SELECT spock.wait_slot_confirm_lsn(NULL, NULL)`**

Wait until all replication slots on the current node have replayed up to the xlog insert position at time of call on all providers. Returns when all slots' `confirmed_flush_lsn` passes the `pg_current_wal_insert_lsn()` at time of call.

- Optionally may wait for only one replication slot (first argument).
- Optionally may wait for an arbitrary log sequence number (LSN) passed instead of the insert LSN (second argument). Both are usually just left `NULL`.

This function is very useful to ensure all subscribers have received changes up to a certain point on the provider.

### spock.sub_show_status

**`spock.sub_show_status(subscription_name name)`**

Shows status and basic information about a subscription.

Parameters:

- `subscription_name` is the optional name of an existing subscription. If no name is provided, the function will show the status of all subscriptions on the local node.

### spock.sub_show_table

**`spock.sub_show_table(subscription_name name, relation regclass)`**

Shows the synchronization status of a table.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `relation` is the name of an existing table, optionally qualified.

### spock.sub_add_repset

**`spock.sub_add_repset(subscription_name name, replication_set name)`**

Adds one replication set into a subscriber. Does not synchronize, only activates consumption of events.

Parameters:

- `subscription_name` is the name of an existing subscription.
- `replication_set` is the name of a replication set to add to the specified subscription.

### spock.sub_remove_repset

**`spock.sub_remove_repset(subscription_name name, replication_set name)`**

Removes one replication set from a subscriber.

Parameters:

- `subscription_name` is the name of the existing subscription.
- `replication_set` is the name of replication set to remove.



