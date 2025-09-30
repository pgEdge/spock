## NAME

`spock.repset_remove_seq ()`

### SYNOPSIS

`spock.repset_remove_seq (set_name name, relation regclass)`
 
### DESCRIPTION

Remove a sequence from a replication set. 

### EXAMPLE 

`spock.repset_remove_sequence ('demo_repset', 'public.mysequence')`
 
### POSITIONAL ARGUMENTS
    set_name
        The name of the existing replication set.
    relation
        The name or OID of the sequence to be removed from the set.
