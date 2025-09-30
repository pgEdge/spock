## NAME

`spock.node_drop()`

### SYNOPSIS

`spock.node_drop (node_name name, ifexists bool)`
 
### DESCRIPTION
    Drop a spock node. 

### EXAMPLE 

`spock.node_drop ('n1')`
 
### POSITIONAL ARGUMENTS
    node_name
        The name of the node. Example: n1
    ifexists
        `ifexists` specifies the Spock extension behavior with regards to error messages. If `true`, an error is not thrown when the specified node does not exist. The default is `false`.
