## NAME

`spock.sub_alter_skiplsn()`

### SYNOPSIS

`spock.sub_alter_skiplsn (subscription_name name, lsn pg_lsn)`

### DESCRIPTION

Advances the replication position of an existing subscription to the specified Log Sequence Number (LSN). This is typically used as a recovery operation when a subscription is unable to proceed due to a problematic change in the replication stream. Any changes between the old LSN and the specified LSN will be permanently skipped.

This command must be executed by a superuser.

### EXAMPLE

`SELECT spock.sub_alter_skiplsn('sub_n1_to_n2', '0/16B6A50');`

### ARGUMENTS
    subscription_name
        The name of an existing subscription.
    lsn
        The Log Sequence Number to which the subscription should advance.
