## NAME

`spock.node_create()`

### SYNOPSIS

`spock.node_create (node_name name, dsn text, location text, country text, info jsonb)`
 
### DESCRIPTION

Create a spock node. 

### EXAMPLE 

`spock.node_create ('n1', 'host=10.1.2.5 user=rocky dbname=demo')`
 
### POSITIONAL ARGUMENTS
    node_name
        The name of the node. Only one node is allowed per database, and each node in a cluster must have a unique name. To use the Snowflake extension, use the convention n1,n2, etc. Example: n1
    dsn
        The connection string to the node. The user in this string should equal the OS user. This connection string should be reachable from outside and match the one used later in the sub-create command. Example: host=10.1.2.5 port= 5432 user=rocky dbname=demo
