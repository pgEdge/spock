## NAME

spock.repset_drop()

### SYNOPSIS

spock.repset_drop (set_name name, ifexists boolean)

### RETURNS

  - true if the replication set was successfully dropped.

  - false if the replication set does not exist and ifexists is true.

  - ERROR if the replication set does not exist and ifexists is false.

### DESCRIPTION

Drops an existing replication set.

This function removes a replication set from the Spock configuration. When
a replication set is dropped, all table, sequence, and DDL memberships
associated with it are removed. However, the actual tables and sequences
themselves remain in the database - only their association with the
replication set is deleted.

Dropping a replication set does not affect existing subscriptions that
reference it, but those subscriptions will stop receiving changes for
objects that were in the dropped replication set. Subscriptions can be
modified to remove the dropped replication set using
spock.sub_remove_repset().

The ifexists parameter controls error handling behavior. When set to true,
the function returns false if the replication set does not exist instead of
raising an error. This is useful in scripts where the replication set may
or may not be present.

This function modifies the Spock catalogs but does not modify any user data
or PostgreSQL server configuration.

### ARGUMENTS

set_name

    The name of the replication set to drop.

ifexists

    If true, the function returns false instead of raising an error
    when the replication set does not exist. Defaults to false.

### EXAMPLE

SELECT spock.repset_drop('demo_repset', true);
