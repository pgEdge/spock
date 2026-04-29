# spock.sub_enable

The `spock.sub_enable()` function enables a subscription. Replication workers
then resume normal processing for that subscription.

## Synopsis

```sql
spock.sub_enable(subscription_name name, immediate boolean)
```

## Description

The `spock.sub_enable()` function enables a subscription.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `immediate` - If `true`, the subscription is started immediately; otherwise
  the subscription will be started only at the end of the current transaction.
  The default is `false`.

## Example

In the following example, the `spock.sub_enable()` function enables a
subscription named `sub_n1_n2`:

```sql
SELECT spock.sub_enable('sub_n1_n2');
 sub_enable
-------------
 t
(1 row)
```
