## NAME

`spock.repset_create()`

### SYNOPSIS

spock.repset_create (
    set_name name,
    replicate_insert boolean = true,
    replicate_update boolean = true,
    replicate_delete boolean = true,
    replicate_truncate boolean = true
)

### RETURNS

The OID of the newly created replication set.

### DESCRIPTION

Creates a new Spock replication set.

A replication set defines which types of table operations are replicated to
subscribers. Tables can later be added to this replication set with other
Spock functions.

By default, all data modification operations are replicated; INSERT, UPDATE,
DELETE, and TRUNCATE.

You can selectively disable specific operation types when creating the set.

This function writes metadata into the Spock catalogs but does not alter any
PostgreSQL server configuration.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The unique name for the replication set.

replicate_insert

    If true (the default), INSERT operations are replicated.

replicate_update

    If true (the default), UPDATE operations are replicated.

replicate_delete

    If true (the default), DELETE operations are replicated.

replicate_truncate

    If true (the default), TRUNCATE operations are replicated.

### EXAMPLE

    SELECT spock.repset_create('demo_repset');

    SELECT spock.repset_create('audit_only',
        replicate_delete := false,
        replicate_truncate := false);

