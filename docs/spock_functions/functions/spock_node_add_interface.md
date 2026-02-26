
## NAME

`spock.node_add_interface()`

### SYNOPSIS

spock.node_add_interface (node_name name, interface_name name, dsn text)

### RETURNS

The OID of the newly created interface. Returns NULL if any argument is NULL.

### DESCRIPTION

Adds a new network interface definition to an existing Spock node.

Interfaces allow a single node to be reachable through multiple connection
endpoints. This is commonly used in environments where nodes are accessible
through different hostnames, IP addresses, private networks, public networks,
or load balancers.

The interface definition consists of a name and a PostgreSQL DSN string that
describes how other nodes should connect to this node.

This function writes metadata into the Spock catalogs but does not modify
PostgreSQL server configuration or networking settings.

This command must be executed by a superuser.

### ARGUMENTS

node_name

    The name of an existing Spock node.

interface_name

    A unique name for this interface on the node.

dsn

    A PostgreSQL connection string that other nodes will use to connect to
    this node. The user in this string should equal the OS user. This
    connection string should be reachable from outside and match the one used
    later in the sub-create command. Example: host=10.1.2.5 port=5432
    user=rocky

### EXAMPLE

The following example adds an interface named private_net that uses the
connection string defined in the last argument of the function call
('host=10.0.0.10 port=5432 dbname=postgres'):

    postgres=# SELECT spock.node_add_interface('n1', 'private_net',
        'host=10.0.0.10 port=5432 dbname=postgres');

    node_add_interface
        --------------------
                 1239112588
        (1 row)
