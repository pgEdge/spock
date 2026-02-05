## NAME

spock.sub_add_repset()

### SYNOPSIS

spock.sub_add_repset (subscription_name name, replication_set name)

### RETURNS

  - true if the replication set was successfully added.

  - false if the operation fails.

### DESCRIPTION

Adds a replication set to an existing subscription.

This function modifies a subscription to begin receiving changes from an
additional replication set on the provider node. The subscription will start
consuming events from the newly added replication set immediately.

This operation does not perform data synchronization. It only activates the
consumption of future events from the replication set. If you need to
synchronize existing data from the replication set, you must handle that
separately.

This function writes metadata into the Spock catalogs.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of an existing subscription.

replication_set

    The name of the replication set to add to the subscription.

### EXAMPLE

SELECT spock.sub_add_repset('sub_n2_n1', 'custom_repset');
