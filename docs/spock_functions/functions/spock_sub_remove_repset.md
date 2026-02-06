## NAME

spock.sub_remove_repset()

### SYNOPSIS

spock.sub_remove_repset (subscription_name name, replication_set name)

### RETURNS

  - true if the replication set was successfully removed.

  - false if the operation fails.

### DESCRIPTION

Removes a replication set from an existing subscription.

This function modifies a subscription to stop receiving changes from the
specified replication set on the provider node. The subscription will
immediately stop consuming events from the removed replication set.

Only the replication set association is removed. This does not affect data
that has already been replicated, nor does it drop any tables or other
database objects.

This function writes metadata into the Spock catalogs.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of an existing subscription.

replication_set

    The name of the replication set to remove from the subscription.

### EXAMPLE

    SELECT spock.sub_remove_repset('sub_n2_n1', 'custom_repset');
