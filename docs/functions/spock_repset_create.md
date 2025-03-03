## NAME

`spock.repset_create()`

### SYNOPSIS

`spock.repset_create (set_name name, replicate_insert bool, replicate_update bool, replicate_delete bool, replicate_truncate bool)`
 
### DESCRIPTION

Create a replication set. 

### EXAMPLE

`spock.repset_create ('demo_repset')`
 
### ARGUMENTS
    set_name
        The name of the set, must be unique.
    replicate_insert
        Specifies if INSERT statements are replicated; the default is true.
    replicate_update
        Specifies if UPDATE statements are replicated; the default is true.
    replicate_delete
        Specifies if DELETE statements are replicated; the default is true.
    replicate_truncate
        Specifies if TRUNCATE statements are replicated; the default is true.
