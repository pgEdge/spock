## NAME

`spock.repset_add_all_tables()`

### SYNOPSIS

`spock.repset_add_table (set_name name, schema_names text[], sync_data boolean)`

### Returns

- true — The node was created successfully.
- false — The node already exists.
- ERROR — Invalid parameters or configuration issue.

### DESCRIPTION

Adds all tables in given schemas. Only existing tables are added; any table you create in future will not be added automatically. 

Returns NULL if any argument is NULL.

This command must be executed by a superuser, and writes metadata into Spock
catalogs.

### EXAMPLE

`spock.repset_add_table ('demo_repset', 'public')`
 
### ARGUMENTS
    set_name
        The name of the existing replication set.
    schema_names
        An array of names of existing schemas from which tables should be added.
    sync_data.
        If true, the table data is synchronized on all subscribers which are subscribed to given replication set; the default is false.

