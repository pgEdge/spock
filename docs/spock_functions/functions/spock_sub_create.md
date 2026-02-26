## NAME

spock.sub_create()

### SYNOPSIS

spock.sub_create (subscription_name name, provider_dsn text,
replication_sets text[], synchronize_structure boolean,
synchronize_data boolean, forward_origins text[], apply_delay interval,
force_text_transfer boolean, enabled boolean, skip_schema text[])

### RETURNS

The OID of the newly created subscription.

### DESCRIPTION

Creates a subscription from the current node to a provider node.

This function establishes a replication subscription that allows the current
(subscriber) node to receive changes from the specified provider node. The
subscription defines which replication sets to subscribe to and how to
handle initial synchronization.

The command returns immediately without waiting for the subscription to
complete its initialization. Use spock.sub_wait_for_sync() to wait for the
subscription to finish synchronizing and begin replicating.

The subscription_name is used as the application_name for the replication
connection, making it visible in pg_stat_replication. This can be useful for
monitoring and for configuring synchronous_standby_names in synchronous
replication scenarios.

This function writes metadata into the Spock catalogs and initiates a
replication connection to the provider.

This command must be executed by a superuser.

### ARGUMENTS

subscription_name

    A unique name for the subscription. Must be unique across the cluster.
    This name appears in pg_stat_replication as application_name.

provider_dsn

    A PostgreSQL connection string specifying how to connect to the
    provider node.

replication_sets

    An array of replication set names to subscribe to. Accepted values
    are default, default_insert_only, ddl_sql.

synchronize_structure

    If true, synchronize table and schema structure from the provider
    before starting replication. Default is false.

synchronize_data

    If true, perform an initial data copy for all tables in the subscribed
    replication sets. Default is false.

forward_origins

    Controls which changes to replicate based on their origin. Use '{}' to
    only replicate changes originating on the provider (useful for
    bidirectional replication). Use {all} to replicate all changes
    regardless of origin. Default is '{}'.

apply_delay

    An interval specifying how long to delay applying changes from the
    provider. Useful for delayed standby scenarios. Default is '0'.

force_text_transfer

    If true, replicate all columns using text representation. This is
    slower but allows type conversions on the subscriber. Default is false.

enabled

    If true, the subscription is enabled immediately. If false, the
    subscription is created but not activated. Default is true.

skip_schema

    An array of schema names to exclude from structure and data
    synchronization. Default is '{}' (no schemas skipped).

### EXAMPLE

    SELECT spock.sub_create('sub_n2_n1',
        'host=127.0.0.1 port=5432 dbname=postgres');

    SELECT spock.sub_create('sub_n2_n1',
        'host=10.0.0.10 port=5432 dbname=postgres',
        replication_sets := '{default}',
        synchronize_structure := true,
        synchronize_data := true);
