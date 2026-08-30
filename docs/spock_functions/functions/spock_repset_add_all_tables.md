## NAME

spock.repset_add_all_tables()

### SYNOPSIS

spock.repset_add_all_tables (set_name name, schema_names text[],
synchronize_data boolean)

### RETURNS

  - true if every replicatable table was added to the replication set.

  - false if the call has invalid parameters, insufficient privileges, or
    the operation fails.

### DESCRIPTION

Adds all existing tables from the specified schemas to a replication set.

This function registers all table objects found in the given schemas with the
specified replication set. Only tables that exist at the time of execution
are added; tables created afterward must be added separately using
spock.repset_add_table().

A table that cannot be replicated is skipped and reported with a WARNING naming
its schema and table; the remaining tables are still added. A table is skipped
when the replication set replicates UPDATEs or DELETEs and the table has no
index-based replica identity, or when the table belongs to an extension listed
in spock.reserved_object. A schema listed in spock.reserved_object is reported
once and passed over as a whole.

A replication set that replicates UPDATEs or DELETEs has to locate the affected
row on the subscriber, so it can only take tables with an index-based replica
identity — a PRIMARY KEY, or a unique index on NOT NULL columns nominated with
ALTER TABLE ... REPLICA IDENTITY USING INDEX — or REPLICA IDENTITY FULL paired
with a PRIMARY KEY, in which case the PRIMARY KEY serves for the row lookup.
REPLICA IDENTITY NOTHING never qualifies, and neither does FULL without a
PRIMARY KEY. Tables that do not qualify can be added to a set that replicates
only INSERTs and TRUNCATEs.

Unlike spock.repset_add_table(), which raises an error when the table cannot be
replicated, this function never refuses the whole call on account of a single
relation. A schema that does not exist is still an error.

Views, materialized views, sequences, and UNLOGGED and TEMPORARY tables are not
considered at all.

Partitioned tables and their partitions are collected independently, each in its
own right, and each is checked separately. ALTER TABLE ... REPLICA IDENTITY does
not cascade to partitions in any supported PostgreSQL version, so a partitioned
table and its partitions can differ here: a partition may be skipped while its
parent is added, or the reverse. Spock resolves replication set membership per
relation, so a skipped partition means changes to the rows stored in that
partition are not replicated, even when the parent is a member.

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

