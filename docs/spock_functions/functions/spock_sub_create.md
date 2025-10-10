## NAME

`spock.sub_create()`

### SYNOPSIS

`spock.sub_create (subscription_name name, provider_dsn text, replication_sets text[], synchronize_structure boolean, synchronize_data boolean, forward_origins text[], apply_delay interval, force_text_transfer boolean, enabled boolean, skip_schema text[])`

### DESCRIPTION

Creates a subscription from current node to the provider node. The command does not wait for completion before returning to the caller. Needs preliminary call of the `spock.node_create`.

The `subscription_name` is used as `application_name` by the replication connection. This means that it's visible in the `pg_stat_replication` monitoring view. It can also be used in `synchronous_standby_names` when Spock is used as part of a synchronous replication scenario.

Use `spock.sub_wait_for_sync(subscription_name)` to wait for the subscription to asynchronously start replicating and complete any needed schema and/or data sync.

### EXAMPLE

`spock.sub_create ('sub_n2n1', 'host=10.1.2.5 port=5432 user=rocky dbname=demo')`

### ARGUMENTS
    subscription_name
        The name of the subscription. Each subscription in a cluster must have a unique name.  The name is used as application_name by the replication connection. This means that the name is visible in the pg_stat_replication monitoring view.
    provider_dsn
        The connection string to a provider.
    replication_sets
        An array of existing replication sets to subscribe to; the default is {default,default_insert_only,ddl_sql}.
    synchronize_structure
        Specifies if Spock should synchronize the structure from provider to the subscriber; the default is false.
    synchronize_data
        Specifies if Spock should synchronize data from provider to the subscriber, the default is true.
    forward_origins
        An array of origin names to forward; currently the only supported values are an empty array (don't forward any changes that didn't originate on provider node, useful for two-way replication between the nodes), or {all} which means replicate all changes no matter what is their origin. The default is {all}.
    apply_delay
        How much to delay replication; the default is 0 seconds.
    force_text_transfer
        Force the provider to replicate all columns using a text representation (which is slower, but may be used to change the type of a replicated column on the subscriber). The default is false.
	enabled
		If true, it signals replication machinery to activate synchronisation of schema/data from the publisher. If false, the node synchronisation status is set to ready, no synchronization will be made (TODO: refer to a correct use case). The default is true.
	skip_schema
		Array of schema names that will be skipped during the structure synchronisation. Data from any table, included in these schemas will be filtered at initial data synchronisation. The default is NULL.
