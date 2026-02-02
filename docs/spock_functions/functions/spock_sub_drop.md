## NAME

spock.sub_drop()

### SYNOPSIS

spock.sub_drop (subscription_name name, ifexists boolean)

### RETURNS

The OID of the dropped subscription.

### DESCRIPTION

Disconnects and removes a subscription from the cluster.

This function terminates the replication connection for the specified
subscription and removes all associated metadata from the Spock catalogs. It
does not affect data that has already been replicated to the subscriber.

If ifexists is set to false (default), an error is raised when the specified
subscription does not exist. If ifexists is true, the function returns
successfully without error.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of the existing subscription to remove.

ifexists

    If true, do not raise an error when the subscription does not exist.
    Default is false.

### EXAMPLE

SELECT spock.sub_drop('sub_n2_n1');

SELECT spock.sub_drop('sub_n2_n1', true);
