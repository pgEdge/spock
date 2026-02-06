## NAME

spock.node_drop()

### SYNOPSIS

spock.node_drop (node_name name, ifexists boolean DEFAULT false)

### RETURNS

  - true if the node was dropped successfully.

  - false if the node did not exist and ifexists was set to true.

  - ERROR if the call has invalid parameters, if the invoker has insufficient
    privileges, or the node cannot be removed due to existing dependencies.

### DESCRIPTION

Removes an existing Spock node from the cluster metadata.

This function deletes the node definition and all associated metadata from the
Spock catalogs. It does not remove any PostgreSQL data directory or stop
the PostgreSQL server; it only removes Spock’s logical representation of the
node.

If ifexists is set to false (default), an error is raised when the specified
node does not exist. If ifexists is true, the function returns false
instead of raising an error.

This command must be executed by a superuser and modifies Spock catalog
tables.

### ARGUMENTS

node_name

    The name of the existing Spock node to remove.

ifexists

    If true, do not raise an error when the node does not exist; return
    false instead. Default is false.

### EXAMPLE

The following function call drops a node named 'n3':

    inventory=# SELECT spock.node_drop('n3');
     node_drop
    -----------
     t
    (1 row)
