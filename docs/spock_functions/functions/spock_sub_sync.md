## NAME

`spock.sub_sync()`

### SYNOPSIS

`spock.sub_sync (subscription_name name, truncate bool)`
 
### DESCRIPTION
    
Call this function to synchronize all unsynchronized tables in all sets in a single operation. Tables are copied and synchronized one by one. The command does not wait for completion before returning to the caller. Use `spock.wait_for_sub_sync` to wait for completion.

### POSITIONAL ARGUMENTS
    subscription_name
        The name of the existing subscription.
    truncate
        If true, tables will be truncated before copy; the default is false.
