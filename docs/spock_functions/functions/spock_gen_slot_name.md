## NAME

spock.spock_gen_slot_name()

### SYNOPSIS

spock.spock_gen_slot_name (dbname name, provider_node name,
subscription name)

### RETURNS

The generated replication slot name as a name type.

### DESCRIPTION

Generates a standardized replication slot name for a Spock subscription.

This function creates a consistent naming convention for replication slots
based on the database name, provider node name, and subscription name. The
generated name follows Spock's internal naming scheme to ensure uniqueness
and traceability.

This function that performs a calculation without accessing the
database or modifying any data. It can be used to predict what slot name
Spock will generate for a given subscription configuration.

### ARGUMENTS

dbname

    The name of the database.

provider_node

    The name of the provider node.

subscription

    The name of the subscription.

### EXAMPLE

The following example executes the function; the database name is postgres,
the node name is n1, and the subscription name is sub_n2n1:

postgres=# SELECT spock.spock_gen_slot_name('postgres', 'n1', 'sub_n2n1');
   spock_gen_slot_name    
--------------------------
 spk_postgres_n1_sub_n2n1
(1 row)
