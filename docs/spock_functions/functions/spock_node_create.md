## NAME

spock.node_create()

### SYNOPSIS

spock.node_create (node_name name, dsn text, location text,
country text, info jsonb)

### RETURNS

The OID of the newly created Spock node.

### DESCRIPTION

Creates a new Spock node definition.

A node represents a PostgreSQL instance that participates in Spock
replication. The node definition includes the connection information that
other nodes will use to communicate with this node.

Optional metadata fields such as location, country, and info can be provided
to describe the node for organizational or management purposes. These values
are stored in the Spock catalogs but are not required for replication to
function.

This function writes metadata into the Spock catalogs but does not modify
Postgres server configuration or networking settings.

This command must be executed by a superuser.

### ARGUMENTS

node_name

    A unique name for the Spock node.

dsn

    A PostgreSQL connection string that other nodes will use to
    connect to this node.

location

    Optional descriptive text indicating the physical or logical
    location of the node. The default is NULL.

country

    Optional country code or name associated with the node. The default is 
    NULL.

info

    Optional JSONB field for storing arbitrary metadata about
    the node.  The default is NULL.

    A `tiebreaker` key in this field overrides the node's default
    last-update-wins tiebreaker (otherwise the node's unique ID). Each
    node caches this value locally and only reads it once, when it
    first learns about the node. Use `spock.node_refresh_info` on every
    other node to pick up a later change -- see the Tiebreaker section
    in conflict_types.md for details.

### EXAMPLE

In the following example, Spock creates a node named n3, with a connection
to a database named 'inventory':

    inventory=# SELECT spock.node_create('n3','host=10.0.0.12 port=5432 dbname=inventory');
     node_create
    -------------
            9057
    (1 row)
