## NAME

`spock.sub_show_status()`

### SYNOPSIS

```sql
spock.sub_show_status(subscription_name name DEFAULT NULL)
```

### RETURNS

A set of rows describing the current state of one or more
subscriptions. Each row contains:

- the name of the subscription.
- the current replication status.
- the name of the provider node.
- the connection string used to reach the provider.
- the name of the logical replication slot used by the subscription.
- the replication sets associated with the subscription.
- the origins that are forwarded by this subscription.

### STATUS VALUES

The following table describes each possible value for the `status`
column:

| Status | Description |
|---|---|
| `replicating` | The apply worker is running and initial synchronization is complete; changes from the provider are being applied normally. |
| `initializing` | The apply worker is running but initial synchronization has not yet completed; table data is still being copied from the provider. |
| `disabled` | The subscription was explicitly disabled with `spock.sub_disable()`; the apply worker is not running. |
| `down` | The subscription is enabled but the apply worker is not running; the worker may not have started yet or may have exited unexpectedly. |
| `unknown` | The apply worker is running but no synchronization status record was found; this is a transient state that typically resolves quickly. |

### DESCRIPTION

`spock.sub_show_status()` displays detailed runtime information about
Spock subscriptions on the current node.

If a specific subscription name is provided, only that subscription is
shown. If `NULL` (the default), the function returns status for all
subscriptions on the node.

This function is useful for monitoring replication health, validating
configuration, and verifying which replication sets and origins are in
use. The information is derived from Spock catalog metadata and the
current state of logical replication workers.

This function does not modify any configuration.

### ARGUMENTS

subscription_name

    Optional. The name of a specific Spock subscription. If NULL
    (the default), the function returns status for all subscriptions.

### EXAMPLE

To display the status of all subscriptions, run:

```sql
SELECT * FROM spock.sub_show_status();
```

To display the status of a specific subscription, run:

```sql
SELECT * FROM spock.sub_show_status('sub_n1_to_n2');
```
