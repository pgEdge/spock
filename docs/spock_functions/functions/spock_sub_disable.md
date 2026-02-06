## NAME

spock.sub_disable()

### SYNOPSIS

spock.sub_disable (subscription_name name, immediate boolean)

### RETURNS

  - true if the subscription was successfully disabled.

  - false if the operation fails.

### DESCRIPTION

Disables a subscription and disconnects from the provider node.

This function pauses an active subscription by disconnecting the replication
connection to the provider and marking the subscription as disabled. While
disabled, the subscription will not receive any changes from the provider.

The immediate parameter controls when the subscription is stopped. If set to
true, the subscription is terminated immediately. If false (default), the
subscription continues processing until the end of the current transaction
before stopping.

A disabled subscription can be re-enabled later using spock.sub_enable()
without losing its position in the replication stream.

This function writes metadata into the Spock catalogs.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of the existing subscription to disable.

immediate

    If true, stop the subscription immediately. If false, stop at the end
    of the current transaction. Default is false.

### EXAMPLE

    SELECT spock.sub_disable('sub_n2_n1');

    SELECT spock.sub_disable('sub_n2_n1', true);
