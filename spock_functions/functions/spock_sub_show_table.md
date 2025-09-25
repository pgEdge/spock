## NAME

`spock.sub_show_table()`

### SYNOPSIS
    
`spock.sub_show_table (subscription_name name, relation regclass)`
 
### DESCRIPTION
    
Shows synchronization status of a table. 

### EXAMPLE

`spock.sub_show_table ('sub_n2n1', 'mytable')`
 
### POSITIONAL ARGUMENTS
    subscription_name
        The name of the existing subscription.
    relation 
        The name of existing table, optionally qualified.
