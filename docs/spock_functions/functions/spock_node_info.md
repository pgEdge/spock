## NAME

spock.node_info()

### SYNOPSIS

spock.node_info (OUT node_id oid, OUT node_name text, OUT sysid text,
OUT dbname text, OUT replication_sets text, OUT location text,
OUT country text, OUT info jsonb)

### RETURNS

A record containing information about the local Spock node:

  - node_id is the OID of the node.
  - node_name is the name of the node.
  - sysid is the system identifier.
  - dbname is the database name.
  - replication_sets is the available replication sets.
  - location is the node location (if set).
  - country is the node country (if set).
  - info is additional metadata stored in JSONB format (if set).

### DESCRIPTION

Returns information about the local Spock node.

This function queries the Spock catalogs and returns metadata about the
current node, including its identifier, name, database information, and any
optional descriptive fields that were set during node creation.

This is a read-only query function that does not modify data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

    postgres=# SELECT * FROM spock.node_info();

    -[ RECORD 1 ]----+--------------------------------------
    node_id          | 49708
    node_name        | n1
    sysid            | 7600444661598442547
    dbname           | postgres
    replication_sets | "default",default_insert_only,ddl_sql
    location         |
    country          |
    info             | 