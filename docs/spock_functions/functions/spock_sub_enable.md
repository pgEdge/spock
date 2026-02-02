## NAME

spock.sub_enable()

### SYNOPSIS

spock.sub_enable (subscription_name name, immediate boolean)

### RETURNS

  - true if the subscription was successfully enabled.

  - false if the operation fails.

### DESCRIPTION

Enables a previously disabled subscription and reconnects to the provider
node.

This function activates a disabled subscription by re-establishing the
replication connection to the provider and resuming replication. The
subscription will continue receiving changes from where it left off when it
was disabled.

The immediate parameter controls when the subscription is started. If set to
true, the subscription is activated immediately. If false (default), the
subscription is activated at the end of the current transaction.

This function writes metadata into the Spock catalogs.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of the existing subscription to enable.

immediate

    If true, start the subscription immediately. If false, start at the
    end of the current transaction. Default is false.

### EXAMPLE

SELECT spock.sub_enable('sub_n2_n1');

SELECT spock.sub_enable('sub_n2_n1', true);
