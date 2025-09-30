
## NAME

`spock.node_add_interface()`

### SYNOPSIS

`spock.node_add_interface (node_name name, interface_name name, dsn text)` 

### DESCRIPTION

Add an additional interface to a spock node. 
    
When a node is created, the interface is also created using the dsn specified in the create_node command, and with the same name as the node. This interface allows you to add alternative interfaces with different connection strings to an existing node.

### EXAMPLE 

`spock.node_add_interface ('n1', 'n1_2', 'host=10.1.2.5 user=rocky')`

### POSITIONAL ARGUMENTS
    node_name
        The name of the node. Should reference the node already created in this database. Example: n1
    interface_name
        The interface name to add to the node. The interface created by default matches the node name, add a new interface with a unique name. Example: n1_2
    dsn
        The additional connection string to the node. The user in this string should equal the OS user. This connection string should be reachable from outside and match the one used later in the sub-create command. Example: host=10.1.2.5 port= 5432 user=rocky
