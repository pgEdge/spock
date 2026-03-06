## NAME

spock.sub_wait_for_sync()

### SYNOPSIS

spock.sub_wait_for_sync (subscription_name name)

### RETURNS

void (returns nothing upon successful completion).

### DESCRIPTION

Waits until the specified subscription has completed its initial schema and
data synchronization, and any pending table resynchronizations have
finished.

This function blocks the current session until the subscription is fully
synchronized. It monitors both the initial sync phase (if the subscription
is newly created) and any tables that are undergoing individual
resynchronization due to replication set changes or manual resync
operations.

For optimal results, execute spock.wait_slot_confirm_lsn() on the provider
node after making replication set changes that trigger resyncs. This
ensures the provider has flushed all necessary changes before checking sync
status on the subscriber. Only after the provider confirms the LSN should
you call spock.sub_wait_for_sync() on the subscriber.

The function will continue waiting indefinitely until synchronization
completes, so callers should ensure the subscription is actively processing
and that there are no blocking issues preventing sync completion.

### ARGUMENTS

subscription_name

    The name of the subscription to monitor for sync completion.

### EXAMPLE

    SELECT spock.sub_wait_for_sync('sub_n2_n1');
