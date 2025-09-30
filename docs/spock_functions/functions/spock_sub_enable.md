## NAME

`spock.sub_enable()`

### SYNOPSIS

`spock.sub_enable (subscription_name name, immediate boolean)`

### DESCRIPTION

Enable a subscription. 

### Example

`spock sub_enable ('sub_n2n1')`
 
### ARGUMENTS
    subscription_name
        The name of the existing subscription.
    immediate
        If true, the subscription is started immediately, otherwise it will be only started at the end of current transaction; the default is false.
