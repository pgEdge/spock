## NAME

`spock.sub_drop ()`

### SYNOPSIS

`spock.sub_drop (subscription_name name, ifexists bool)`
 
### DESCRIPTION

Disconnects the subscription and removes it from the catalog. 

### EXAMPLE

`spock.sub_drop ('sub_n2n1')`
 
### POSITIONAL ARGUMENTS
    subscription_name
        The name of the existing subscription.
    ifexists
        If true, an error is not thrown when subscription does not exist; the default is false.
