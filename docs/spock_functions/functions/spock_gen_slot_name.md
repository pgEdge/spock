## NAME

`spock.spock_gen_slot_name()`

### SYNOPSIS

`spock.spock_gen_slot_name (dbname name, provider_node name, subscription name)`

### DESCRIPTION

Generates a replication slot name from the given database, provider node, and subscription names. This is used internally by Spock to create consistent slot names for replication connections.

### EXAMPLE

`SELECT spock.spock_gen_slot_name('mydb', 'n1', 'sub_n2n1');`

### ARGUMENTS
    dbname
        The name of the database.
    provider_node
        The name of the provider node.
    subscription
        The name of the subscription.
