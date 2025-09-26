## NAME

`spock.sub_alter_interface()`

### SYNOPSIS
    
`spock.sub_alter_interface (subscription_name name, interface_name name)`
 
### DESCRIPTION

Alter the subscription to use a different interface when connecting to the provider node.

### EXAMPLE

`spock.sub_alter_interface ('sub_n2n1', 'n1_2 demo')`
 
### POSITIONAL ARGUMENTS
    subscription_name
        The name of an existing subscription.
    interface_name
        The name of an existing interface of the current provider node.
