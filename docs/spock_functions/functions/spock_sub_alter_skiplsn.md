## NAME

NAME

spock.sub_alter_skiplsn()

### SYNOPSIS

spock.sub_alter_skiplsn (subscription_name name, lsn pg_lsn)

### RETURNS

    - true if the subscription LSN was successfully advanced.

    - false if the subscription does not exist.

### DESCRIPTION

Advances the replication position of an existing Spock subscription to the
specified Log Sequence Number (LSN).

This function is typically used as a recovery or repair operation when a
subscription is unable to proceed due to a problematic or corrupted change in
the replication stream. By skipping forward to a known good LSN, replication
can resume without replaying the offending transaction.

This operation does not replay or repair the skipped data. Any changes
between the old LSN and the specified LSN will be permanently ignored by the
subscriber. This should be used with caution and only when the administrator
understands the data implications.

This function writes metadata into the Spock catalogs but does not modify
PostgreSQL server configuration.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    The name of an existing Spock subscription.

lsn

    The Log Sequence Number to which the subscription should
    advance.

## EXAMPLE

    SELECT spock.sub_alter_skiplsn('sub_n1_to_n2', '0/16B6A50');