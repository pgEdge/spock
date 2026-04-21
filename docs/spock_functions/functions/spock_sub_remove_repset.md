# spock.sub_remove_repset

The `spock.sub_remove_repset()` function removes a replication set from a
subscription.

## Synopsis

```sql
spock.sub_remove_repset(subscription_name name, replication_set name)
```

## Description

The `spock.sub_remove_repset()` function removes a replication set from a
subscription.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `replication_set` - The name of the replication set to remove.

## Example

In the following example, the `spock.sub_remove_repset()` function removes a
replication set named `test` from a subscription named `sub_n2n1`:

```sql
select spock.sub_remove_repset('sub_n1_n2', 'test');
 sub_remove_repset 
-------------------
 t
(1 row)
```
