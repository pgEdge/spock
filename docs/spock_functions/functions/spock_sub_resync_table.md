## NAME

`spock.sub_resync_table()`

### SYNOPSIS

`spock.sub_resync_table (subscription_name name, relation regclass)`
 
### DESCRIPTION

Resynchronize one existing table. 

### EXAMPLE

`spock.sub-resync-table ('sub_n2n1', 'mytable')`
 
### POSITIONAL ARGUMENTS
    subscription_name
        The name of the existing subscription.
    relation
        The name of existing table, optionally schema qualified.
