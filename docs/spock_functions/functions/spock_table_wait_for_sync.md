## NAME

spock.table_wait_for_sync()

### SYNOPSIS

spock.table_wait_for_sync (subscription_name name, relation regclass)

### RETURNS

void (returns nothing upon successful completion).

### DESCRIPTION

Waits until the specified table has completed synchronization for the given
subscription.

This function blocks the current session until the specified table finishes
its synchronization process. This is useful when you need to ensure a
specific table is fully synchronized before proceeding with operations that
depend on its data.

Unlike spock.sub_wait_for_sync() which waits for all tables in a
subscription to sync, this function targets a single table. This allows for
more granular control when monitoring synchronization progress or when only
specific tables are critical to downstream operations.

For optimal results, execute spock.wait_slot_confirm_lsn() on the provider
node after making replication set changes that trigger table resyncs. This
ensures the provider has flushed all necessary changes before checking sync
status on the subscriber. Only after the provider confirms the LSN should
you call spock.table_wait_for_sync() on the subscriber.

The function will continue waiting indefinitely until the table
synchronization completes, so callers should ensure the subscription is
actively processing and that there are no blocking issues preventing sync
completion.

Returns NULL if any argument is NULL.

### ARGUMENTS

subscription_name

    The name of the subscription to monitor.

relation

    The name of the table to wait for, specified as a regclass (can
    be schema-qualified).

### EXAMPLE

SELECT spock.table_wait_for_sync('sub_n2_n1', 'public.mytable');
