## NAME

spock.sync_event()

### SYNOPSIS

spock.sync_event ()

### RETURNS

The Log Sequence Number (LSN) of the created synchronization event as
pg_lsn.

### DESCRIPTION

Creates a synchronization event in the replication stream and returns its
LSN.

This function inserts a special synchronization marker into the logical
replication stream at the current write position. The returned LSN
identifies this marker's location in the write-ahead log and can be used
with functions like spock.wait_slot_confirm_lsn() to verify that
subscribers have processed replication up to this point.

Synchronization events are useful for coordinating activities across
multiple nodes in a replication topology. By creating a sync event on a
provider and then waiting for subscribers to reach that LSN, you can ensure
all nodes have processed a consistent set of changes before proceeding with
operations that depend on synchronized state.

The sync event itself does not contain data or modify any tables - it
serves purely as a coordination marker in the replication stream.

This function modifies the replication stream by inserting a sync marker.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

    SELECT spock.sync_event();
