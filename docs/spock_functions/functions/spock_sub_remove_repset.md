## NAME 

`spock.sub_remove_repset()`

### SYNOPSIS

`spock.sub_remove_repset (subscription_name name, replication_set name)`
 
### DESCRIPTION
    
Remove a replication set from a subscription. 

There is also a `postgresql.conf` parameter, `spock.extra_connection_options`, that you can use to assign connection options that apply to all connections made by spock. This can be a useful place to set up custom keepalive options, etc.

spock defaults to enabling TCP keepalives to ensure that it notices when the upstream server disappears unexpectedly. To disable them add `keepalives = 0` to `spock.extra_connection_options`.

### EXAMPLE 

`spock.sub_remove_repset ('sub_n2n1', 'demo_repset')`
 
### POSITIONAL ARGUMENTS
    subscription_name
        The name of the existing subscription.
    replication_set 
        The name of replication set to remove.
