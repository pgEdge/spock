## NAME

`spock.sub_resync_table()`

### SYNOPSIS

`spock.sub_resync_table (subscription_name name, relation regclass, truncate boolean)`

### DESCRIPTION

Resynchronize one existing table.

### EXAMPLE

`spock.sub_resync_table ('sub_n2n1', 'mytable')`

### POSITIONAL ARGUMENTS
    subscription_name
        The name of the existing subscription.
    relation
        The name of existing table, optionally schema qualified.
	truncate
		Truncate table on the subscriber before re-synchronization. In the `false` state any rows, coming from the publisher will be applied other existing state, causing conflicts. The default value is true.
