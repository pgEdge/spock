# spock.sub_create

The `spock.sub_create()` function creates a subscription from the current node
to a provider node.

## Synopsis

```sql
spock.sub_create(
    subscription_name name,
    provider_dsn text,
    repsets text[],
    sync_structure boolean,
    sync_data boolean,
    forward_origins text[],
    apply_delay interval
)
```

## Description

The `spock.sub_create()` function creates a subscription from the current node
to the provider node. The command does not wait for completion before returning
to the caller.

The `subscription_name` is used as `application_name` by the replication
connection. This means that the name is visible in the `pg_stat_replication`
monitoring view. The name can also be used in `synchronous_standby_names` when
Spock is used as part of a synchronous replication scenario.

Use `spock.sub_wait_for_sync(subscription_name)` to wait for the subscription
to asynchronously start replicating and complete any needed schema and/or data
sync.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of the subscription. Each subscription in a
  cluster must have a unique name. The name is used as `application_name` by
  the replication connection. This means that the name is visible in the
  `pg_stat_replication` monitoring view.
- `provider_dsn` - The connection string to a provider.
- `repsets` - An array of existing replication sets to subscribe to; the
  default is `{default,default_insert_only,ddl_sql}`.
- `sync_structure` - Specifies if Spock should synchronize the structure from
  the provider to the subscriber; the default is `false`.
- `sync_data` - Specifies if Spock should synchronize data from the provider to
  the subscriber; the default is `true`.
- `forward_origins` - An array of origin names to forward; currently the only
  supported values are an empty array (don't forward any changes that didn't
  originate on the provider node, useful for two-way replication between the
  nodes), or `{all}` which means replicate all changes no matter what their
  origin is. The default is `{all}`.
- `apply_delay` - How much to delay replication; the default is 0 seconds.
- `force_text_transfer` - Force the provider to replicate all columns using a
  text representation (which is slower, but may be used to change the type of a
  replicated column on the subscriber). The default is `false`.

## Example

In the following example, the `spock.sub_create()` function creates a
subscription named `sub_n1_n2` to a provider node:

```sql
SELECT spock.sub_create(
    subscription_name := 'sub_n1_n2',
    provider_dsn := 'host=localhost port=5432 dbname=postgres user=asif'
);
 sub_create
------------
          2
(1 row)
```

