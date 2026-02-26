## NAME

`spock.sub_show_status()`

### SYNOPSIS

spock.sub_show_status (subscription_name name)

### RETURNS

A set of rows describing the status of one or more Spock subscriptions.

Each row contains:

    - The name of the subscription.

    — Current replication status.

    — The name of the provider node.

    — The connection string used to reach the provider.

    — The logical replication slot used by the subscription.

    — The replication sets associated with the subscription.

    — The origins that are forwarded by this subscription.

DESCRIPTION

Displays detailed runtime information about Spock subscriptions.

If a specific subscription name is provided, only that subscription is shown.
If NULL (the default), the status of all subscriptions on the node is
returned.

This function is useful for troubleshooting replication issues, validating
configuration, and verifying which replication sets and origins are in use.

The information returned is derived from Spock catalog metadata and the
current state of logical replication slots.

This function does not modify any configuration.

ARGUMENTS

subscription_name

    Optional. The name of a specific Spock subscription. The default is NULL;
    If NULL, all subscriptions are shown.

EXAMPLE

    SELECT * FROM spock.sub_show_status();

    SELECT * FROM spock.sub_show_status('sub_n1_to_n2');