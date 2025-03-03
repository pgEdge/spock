## NAME

`spock.repset_add_all_seqs()`

### SYNOPSIS

`spock.repset_add_all_seqs(set_name name, schema_names text[], sync_data boolean)`
 
### DESCRIPTION

Adds all sequences from the given schemas. This command only adds existing sequences; if you create additional sequences, add those sequences to your repset with the `spock.repset_add_seq` function.

### ARGUMENTS
    set_name
        The name of the existing replication set.
    schema_names
        An array of names name of existing schemas from which tables should be added.
    sync_data
        If true, the sequence value will be synchronized immediately; the default is false.

  *Warning:* If you're deploying a multi-master replication scenario, we recommend that you not add sequences to a replication set.  Instead, use the [Snowflake Sequences](https://github.com/pgEdge/snowflake-sequences) to manage sequences.
