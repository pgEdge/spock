## NAME

`spock.repset_remove_seq ()`

### SYNOPSIS

spock.repset_remove_seq (
    set_name name,
    relation regclass)

### RETURNS

    - true if the sequence was successfully removed from the replication set.
    - false if the sequence was not a member of the replication set.

### DESCRIPTION

Removes a sequence from an existing Spock replication set.

After removal, changes to the sequence value are no longer replicated to
subscribers of the replication set.

This function updates metadata stored in the Spock catalogs and does not
modify PostgreSQL configuration.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The name of an existing replication set.

relation

    The sequence to remove, specified as a regclass
    (for example, 'public.my_sequence').

### EXAMPLE

Remove a sequence (public.order_id_seq) from a replication set (demo_repset):

SELECT spock.repset_remove_seq('demo_repset', 'public.order_id_seq');
