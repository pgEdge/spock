## NAME

`spock.sync_event()`

### SYNOPSIS

`spock.sync_event ()`

### DESCRIPTION

Creates a synchronization event in the replication stream and returns its LSN. The returned LSN can be used with `spock.wait_slot_confirm_lsn()` to verify that subscribers have processed replication up to this point.

### EXAMPLE

`SELECT spock.sync_event();`
