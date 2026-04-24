# spock.sub_wait_for_sync

The `spock.sub_wait_for_sync()` function waits until a specified subscription
has completed its initial schema and data synchronization.

## Synopsis

```sql
spock.sub_wait_for_sync(subscription_name name)
```

## Description

The `spock.sub_wait_for_sync()` function waits until the specified subscription
has completed its initial schema and data synchronization, and any pending
table resynchronizations have finished.

This function blocks the current session until the subscription is fully
synchronized. The function monitors both the initial sync phase (if the
subscription is newly created) and any tables that are undergoing individual
resynchronization due to replication set changes or manual resync operations.

For optimal results, execute `spock.wait_slot_confirm_lsn()` on the provider
node after making replication set changes that trigger resyncs. This approach
ensures the provider has flushed all necessary changes before checking sync
status on the subscriber. Only after the provider confirms the LSN should you
call `spock.sub_wait_for_sync()` on the subscriber.

The function will continue waiting indefinitely until synchronization completes,
so callers should ensure the subscription is actively processing and that there
are no blocking issues preventing sync completion.

## Arguments

The function accepts the following argument:

- `subscription_name` - The name of the subscription to monitor for sync
  completion.

## Example

In the following example, the `spock.sub_wait_for_sync()` function waits for a
subscription named `sub_n2_n1` to complete synchronization:

```sql
SELECT spock.sub_wait_for_sync('sub_n2_n1');
-[ RECORD 1 ]-----+-
sub_wait_for_sync |
```

For more information about using subscription synchronization with Zero-Downtime
Add Node, see the [ZODAN Tutorial](../../modify/zodan/zodan_tutorial.md).
