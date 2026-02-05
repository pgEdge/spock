## NAME

spock.repset_add_all_seqs()

### SYNOPSIS

spock.repset_add_all_seqs (set_name name, schema_names text[],
synchronize_data boolean DEFAULT false)

### RETURNS

  - true if all sequences were successfully added to the replication set.

  - ERROR if the call has invalid parameters, insufficient privileges, or
    the operation fails.

### DESCRIPTION

Adds all existing sequences from the specified schemas to a replication set.

This function registers all sequence objects found in the given schemas with
the specified replication set. Only sequences that exist at the time of
execution are added; sequences created afterward must be added separately
using spock.repset_add_seq().

The synchronize_data parameter controls whether sequence values are
immediately synchronized across nodes. When set to true, the current value of
each sequence is propagated to subscribers.

This function writes metadata into the Spock catalogs to track which
sequences are part of the replication set.

Returns NULL if any argument is NULL.

This command must be executed by a superuser.

**Warning:** If you're deploying a multi-master replication scenario, we
recommend that you not add sequences to a replication set. Instead, use
[Snowflake Sequences](https://github.com/pgEdge/snowflake) to manage
sequences in a distributed environment and avoid conflicts.

### ARGUMENTS

set_name

    The name of an existing replication set.

schema_names

    An array of schema names from which all sequences will be added.

synchronize_data

    If true, synchronize the current value of each sequence immediately.
    Default is false.

### EXAMPLE

SELECT spock.repset_add_all_seqs('default', ARRAY['public']);

SELECT spock.repset_add_all_seqs('default', ARRAY['public', 'app'],
    true);
