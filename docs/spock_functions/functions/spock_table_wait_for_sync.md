## NAME

`spock.table_wait_for_sync()`

### SYNOPSIS

`spock.table_wait_for_sync (subscription_name name, relation regclass)`
 
### DESCRIPTION
    
Pause until a table finishes synchronizing. 

For best results, run `SELECT spock.wait_slot_confirm_lsn(NULL, NULL)` on the provider after any replication set changes that requested resyncs, and only then call `spock.sub_wait_for_sync` on the subscriber.

### EXAMPLE

`spock.table_wait_for_sync ('sub_n2n1', 'mytable')`
 
### POSITIONAL ARGUMENTS
    subscription_name
        The name of the subscription. Example: sub_n2n1
    relation
        The name of a table. Example: mytable
    
