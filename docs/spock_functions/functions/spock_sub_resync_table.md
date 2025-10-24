## NAME

`spock.sub_resync_table()`

### SYNOPSIS

`spock.sub_resync_table (subscription_name name, relation regclass, truncate boolean)`

### DESCRIPTION

Resynchronize one existing table.

### EXAMPLE

`spock.sub-resync-table ('sub_n2n1', 'mytable')`

### ARGUMENTS
    subscription_name
        The name of the existing subscription.
    relation
        The name of existing table, optionally schema qualified.
    truncate
        Truncate table before synchronisation (default value is true). If do not truncate, conflicts between existing rows and newly arriving may cause errors.
