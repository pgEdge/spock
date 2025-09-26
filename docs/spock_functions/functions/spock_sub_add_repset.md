## NAME

`spock.sub_add_repset()`

### SYNOPSIS

`spock.sub_add_repset (subscription_name name, replication_set name)`
 
### DESCRIPTION

Adds one replication set into a subscriber. Does not synchronize, only activates consumption of events.

### EXAMPLE

`spock.sub_add_repset ('sub_n2n1', 'demo_repset')`
 
### POSITIONAL ARGUMENTS
    `subscription_name`
        The name of the existing subscription.
    `replication_set`
        The name of replication set to add.
