## NAME

`spock.sub_show_status()`

### SYNOPSIS

`spock.sub_show_status (subscription_name name)`

### DESCRIPTION

Show the status and basic information of a subscription.

### EXAMPLE

`spock.sub_show_status ('sub_n2n1')`

### ARGUMENTS
    subscription_name
        The optional name of the existing subscription.  If no name is provided, the function will show status for all subscriptions on the local node.

### RETURN

Returns one record per subscription with the following columns:

* `subscription_name text`,
* `status text`,
* `provider_node text`,
* `provider_dsn text`,
* `slot_name text`,
* `replication_sets text[]`,
* `forward_origins text[]`

Column `status` may have one of the following values: `unknown`, `replicating`, `initializing`, `disabled`, or `down`.