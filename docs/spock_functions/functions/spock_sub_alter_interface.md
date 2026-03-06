## NAME

spock.sub_alter_interface()

### SYNOPSIS

spock.sub_alter_interface (subscription_name name, interface_name name)

### RETURNS

  - true if the interface was successfully changed.

  - false if the operation fails.

### DESCRIPTION

Changes the network interface used by a subscription to connect to its
provider node.

This function modifies an existing subscription to use a different interface
when establishing the replication connection to the provider. The specified
interface must already exist on the provider node.

This is useful for switching between different network paths, such as moving
from a public network to a private network connection, or switching to a
different hostname or IP address for the same provider node.

The subscription connection will be restarted using the new interface.

This function writes metadata into the Spock catalogs.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of an existing subscription.

interface_name

    The name of an existing interface on the provider node.

### EXAMPLE

    SELECT spock.sub_alter_interface('sub_n2_n1', 'private_net');
