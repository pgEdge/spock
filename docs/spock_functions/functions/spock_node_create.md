## NAME

spock.node_create()

### SYNOPSIS

spock.node_create (node_name name, dsn text, location text DEFAULT NULL,
country text DEFAULT NULL, info jsonb DEFAULT NULL)

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
PostgreSQL server configuration or networking settings.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

node_name

    A unique name for the Spock node.

dsn

    A PostgreSQL connection string that other nodes will use to
    connect to this node.

location

    Optional descriptive text indicating the physical or logical
    location of the node.

country

    Optional country code or name associated with the node.

info

    Optional JSONB field for storing arbitrary metadata about
    the node.

### EXAMPLE

SELECT spock.node_create('n1',
    'host=10.0.0.10 port=5432 dbname=postgres');