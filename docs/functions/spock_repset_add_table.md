## NAME

`spock.repset_add_table()`

### SYNOPSIS

`spock.repset_add_table (set_name name, relation regclass, sync_data boolean, columns text[], row_filter text)`
 
### DESCRIPTION

Add a table or tables to a replication set. 

### EXAMPLE

`spock.repset_add_table ('demo_repset', 'public.my_table')`
 
### ARGUMENTS
    set_name
        The name of the existing replication set.
    relation
        The name or OID of the table to be added to the set.
    sync_data
        If true, the table data is synchronized on all subscribers which are subscribed to given replication set; the default is false.
    columns
        A list of columns to replicate. Normally when all columns should be replicated, this will be set to NULL (the default).
    row_filter
        A row filtering expression; the default is NULL (no filtering).
    
  **WARNING: Use caution when synchronizing data with a valid row filter.**
  Using `sync_data=true` with a valid `row_filter` is usually a one_time operation for a table. Executing it again with a modified `row_filter` won't synchronize data to subscriber. You may need to call `spock.alter_sub_resync_table()` to fix it.
