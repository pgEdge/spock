## NAME

`spock.repset_add_seq()`

### SYNOPSIS

spock.repset_add_seq (
    set_name name,
    relation regclass,
    synchronize_data boolean)

### RETURNS

    - true if the sequence was successfully added to the replication set.
    — false if the sequence was already a member of the replication set.

### DESCRIPTION

Adds a sequence to an existing Spock replication set.

Once added, changes to the sequence value are replicated to subscribers
that are subscribed to the replication set. This ensures that nextval
operations remain consistent across nodes in a multi-master environment.

If synchronize_data is true, the current sequence value is immediately
synchronized to all subscribers.

This function updates metadata stored in the Spock catalogs and does not
modify PostgreSQL configuration.

This command must be executed by a superuser.

### ARGUMENTS

set_name

    The name of an existing replication set.

relation

    The sequence to add, specified as a regclass
    (for example, 'public.my_sequence').

synchronize_data

    If true, the current sequence value is synchronized to
    all subscribers. The default is false.

### EXAMPLE

Add a sequence (named public.sales_order_no_seq) to the 'default' replication
set:

    postgres=# SELECT spock.repset_add_seq('default', 'public.sales_order_no_seq');
     repset_add_seq
    ----------------
     t
    (1 row)

Add a sequence (named public.sales_invoice_no_seq) and synchronize its current value:

    postgres=# SELECT spock.repset_add_seq(
        'default',
        'public.sales_invoice_no_seq',
        synchronize_data := true
    );
     repset_add_seq
    ----------------
     t
    (1 row)
