# spock.sub_show_status

The `spock.sub_show_status()` function displays the status and basic
information about a subscription.

## Synopsis

```sql
spock.sub_show_status(subscription_name name)
```

## Description

The `spock.sub_show_status()` function shows the status and basic information
about a subscription.

## Arguments

The function accepts the following argument:

- `subscription_name` - The optional name of an existing subscription. If no
  name is provided, the function shows the status for all subscriptions on the
  local node.

## Example

In the following example, the `spock.sub_show_status()` function displays the
status of a subscription named `sub_n1_n2`:

```sql
SELECT * FROM spock.sub_show_status('sub_n1_n2');
-[ RECORD 1 ]-----+--------------------------------------------------------------------
subscription_name | sub_n1_n2
status            | replicating
provider_node     | n2
provider_dsn      | host=192.168.105.11 dbname=postgres user=postgres password=<redacted>
slot_name         | spk_postgres_n2_sub_n1
replication_sets  | {default,default_insert_only,ddl_sql,audit_only}
forward_origins   |
```
