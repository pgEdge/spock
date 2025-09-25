## NAME

`spock.repset_alter()`

### SYNOPSIS

`spock.repset_alter (set_name name, replicate_inserts boolean, replicate_updates boolean, replicate_deletes boolean, replicate_truncate boolean)`
 
### DESCRIPTION

Alter a replication set. 

### EXAMPLE

`spock.repset_alter ('demo_repset', 'demo', 'replicate_truncate=False')`
 
###  ARGUMENTS
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
