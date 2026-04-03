# spock.sub_drop

The `spock.sub_drop()` function disconnects a subscription and removes the
subscription from the catalog.

## Synopsis

```sql
spock.sub_drop(subscription_name name, ifexists bool)
```

## Description

The `spock.sub_drop()` function disconnects the subscription and removes the
subscription from the catalog.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `ifexists` - If `true`, an error is not thrown when the subscription does not
  exist; the default is `false`.

## Example

In the following example, the `spock.sub_drop()` function drops a subscription
named `sub_n1_n2`:

```sql
SELECT spock.sub_drop('sub_n1_n2');
 sub_drop
----------
        1
(1 row)
```
