## NAME

`spock.repset_remove_table ()`

### SYNOPSIS

`spock.repset_remove_table (set_name name, relation regclass)`
 
### DESCRIPTION

Remove a table from a replication set. 

### EXAMPLE 

`spock.repset_remove_table ('demo_repset', 'public.mytable')`
 
### POSITIONAL ARGUMENTS
    set_name
        The name of the existing replication set.
    relation
        The name or OID of the table to be removed from the set.
