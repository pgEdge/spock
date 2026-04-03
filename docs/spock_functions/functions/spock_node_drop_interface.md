## NAME

spock.node_drop_interface()

### SYNOPSIS

spock.node_drop_interface (node_name name, interface_name name)

### RETURNS

  - true if the interface was dropped successfully.

  - false if the interface does not exist.

  - ERROR if the call has invalid parameters, insufficient privileges, or 
    the interface cannot be removed.

### DESCRIPTION

Removes an existing network interface definition from a Spock node.

This function deletes the interface definition from the Spock catalogs. It
does not modify PostgreSQL server configuration or networking settings; it
only removes Spock's logical representation of the interface.

Other nodes that were using this interface to connect will no longer be able
to use it. Ensure no active subscriptions are relying on this interface
before removing it.

This function writes metadata into the Spock catalogs but does not modify
PostgreSQL server configuration or networking settings.

This command must be executed by a superuser.

### ARGUMENTS

node_name

    The name of an existing Spock node.

interface_name

    The name of the interface to remove from the node.

### EXAMPLE

The following example drops an interface named 'private_net':

    inventory=# SELECT spock.node_drop_interface('n3', 'private_net');
     node_drop_interface
    ---------------------
     t
    (1 row)
