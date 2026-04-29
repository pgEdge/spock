## NAME

spock.repset_add_all_tables()

### SYNOPSIS

spock.repset_add_all_tables (set_name name, schema_names text[],
synchronize_data boolean)

### RETURNS

  - true if all tables were successfully added to the replication set.

  - false if the call has invalid parameters, insufficient privileges, or
    the operation fails.

### DESCRIPTION

Adds all existing tables from the specified schemas to a replication set.

This function registers all table objects found in the given schemas with the
specified replication set. Only tables that exist at the time of execution
are added; tables created afterward must be added separately using
spock.repset_add_table().

The synchronize_data parameter controls whether existing table data is
immediately synchronized to subscribers. When set to true, a full table copy
is initiated for each table on all subscribers subscribed to the replication
set.

This function writes metadata into the Spock catalogs to track which tables
are part of the replication set.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The name of an existing replication set.

schema_names

    An array of schema names from which all tables will be added.

synchronize_data

    If true, synchronize existing table data to all subscribers
    immediately. Default is false.

### EXAMPLE

Specify the names of one or more schemas in an array to add all of the
tables in the schemas to the specified replication set; the following
command adds all of the tables in the public schema to the default
replication set:

    postgres=# SELECT spock.repset_add_all_tables('default', ARRAY['public']);
    -[ RECORD 1 ]---------+--
    repset_add_all_tables | t

