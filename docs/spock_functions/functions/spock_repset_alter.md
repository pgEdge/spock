## NAME

`spock.repset_alter()`

### SYNOPSIS

spock.repset_alter (
    set_name name,
    replicate_insert boolean,
    replicate_update boolean,
    replicate_delete boolean,
    replicate_truncate boolean
)

### RETURNS

The OID of the altered replication set.

### DESCRIPTION

Modifies the replication behavior of an existing Spock replication set.

Each replication set defines which types of table operations are replicated to
subscribers. This function allows you to change those behaviors after the set
has been created.

Any argument left as NULL will retain its current setting. Only the
specified operation types are modified.

This function updates metadata in the Spock catalogs and does not change
PostgreSQL server configuration.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The name of an existing replication set.

replicate_insert

    If true, INSERT operations are replicated; the default is NULL.

replicate_update

    If true, UPDATE operations are replicated; the default is NULL.

replicate_delete

    If true, DELETE operations are replicated; the default is NULL.

replicate_truncate

    If true, TRUNCATE operations are replicated; the default is NULL.

### EXAMPLE

Enable all operations in the demo_repset replication set:

SELECT spock.repset_alter('demo_repset',
    replicate_insert := true,
    replicate_update := true,
    replicate_delete := true,
    replicate_truncate := true);

Disable DELETE and TRUNCATE replication in the audit_only replication_set:

SELECT spock.repset_alter('audit_only',
    replicate_delete := false,
    replicate_truncate := false);

