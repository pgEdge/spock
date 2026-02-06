## NAME

spock.sync_seq()

### SYNOPSIS

spock.sync_seq (relation regclass)

### RETURNS

- true if the sequence state was successfully synchronized.

### DESCRIPTION

Synchronizes the current state of a sequence to all subscribers.

This function captures the current value of a sequence on the provider node
and pushes it into the replication stream so that subscribers can update
their local copy of the sequence to match. This ensures sequence values
remain coordinated across nodes in a replication topology.

Unlike subscription and table synchronization functions which run on the
subscriber, this function must be executed on the provider node. The
sequence state update is embedded in the transaction where this function is
called, and subscribers will apply the sequence update when they replicate
that transaction.

Replication set filtering still applies - only subscribers whose
subscriptions include the replication set containing this sequence will
receive the update.

This is particularly useful after making direct changes to a sequence value
or when you need to ensure subscribers have the latest sequence state
before performing operations that depend on sequence coordination.

This function modifies the replication stream by inserting a sequence
synchronization event.

### ARGUMENTS

relation

    The name of the sequence to synchronize, optionally
    schema-qualified.

### EXAMPLE

The following command synchronizes a sequence named public.sales_order_no_seq:

    postgres=# SELECT spock.sync_seq('public.sales_order_no_seq');
    sync_seq 
    ----------
     t
    (1 row)
