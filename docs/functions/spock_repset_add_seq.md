## NAME

`spock.repset_add_seq()`

### SYNOPSIS

`spock.repset_add_seq(set_name name, relation regclass, sync_data boolean)`
 
### DESCRIPTION

Add a sequence to a replication set. 

### ARGUMENTS
    set_name
        The name of the existing replication set.
    relation
        The name or OID of the sequence to be added to the set.
    sync_data
        If true, the sequence value will be synchronized immediately; the default is false.

  *Warning:* If you're deploying a multi-master replication scenario, we recommend that you not add sequences to a replication set.  Instead, use the [Snowflake Sequences](https://github.com/pgEdge/snowflake-sequences) to manage sequences.
