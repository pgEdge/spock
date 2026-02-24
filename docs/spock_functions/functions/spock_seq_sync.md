## NAME

`spock.sync_seq()`

### SYNOPSIS

`spock.sync_seq(relation regclass)`
 
### DESCRIPTION

Push the sequence state to all subscribers. Unlike the subscription and table synchronization functions, this function should be run only on the provider. It forces an update of the tracked sequence state that will be consumed by all subscribers (replication set filtering still applies) when they replicate the transaction in which this function has been executed. 

### EXAMPLE 

`spock.sync_seq ('public.my_sequence')`
 
### ARGUMENTS
    relation
        The name of an existing sequence, optionally qualified.
