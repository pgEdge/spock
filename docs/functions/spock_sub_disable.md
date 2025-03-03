## NAME 

`spock.sub_disable ()`

### SYNOPSIS

`spock.sub_disable (subscription_name name, immediate boolean)`
 
### DESCRIPTION
    Disable a subscription by putting it on hold and disconnect from provider. 

### EXAMPLE

`spock sub_disable 'sub_n2n1'`
 
### ARGUMENTS
    subscription_name
        The name of the existing subscription.
    immediate
        If true, the subscription is stopped immediately, otherwise it will be only stopped at the end of current transaction; the default is false.
 
