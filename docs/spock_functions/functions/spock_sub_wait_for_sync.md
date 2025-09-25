## NAME

`spock.sub_wait_for_sync(subscription_name name)`

### SYNOPSIS

`spock.sub_wait_for_sync()`
 
### DESCRIPTION

This function waits until the subscription's initial schema/data sync, if any, are done, and until any tables pending individual resynchronisation have also finished synchronising.

For best results, run `SELECT spock.wait_slot_confirm_lsn(NULL, NULL)` on the  provider after any replication set changes that requested resyncs, and only then call `spock.sub_wait_for_sync` on the subscriber. 

### EXAMPLE

`spock.sub_wait_for_sync ('sub_n2n1')`
 
### ARGUMENTS
    subscription_name
        The name of the subscription. Example: sub_n2n1
