# spock.sub_alter_sync

The `spock.sub_alter_sync()` function synchronizes all unsynchronized tables
in all sets in a single operation.

## Synopsis

```sql
spock.sub_alter_sync(subscription_name name, truncate boolean DEFAULT false)
RETURNS boolean
```

## Description

The `spock.sub_alter_sync()` function synchronizes all unsynchronized tables
in all sets in a single operation. The function copies and synchronizes
tables one by one. The function does not wait for completion before returning
to the caller; use `spock.sub_wait_for_sync()` to wait for completion.

## Arguments

The function accepts the following arguments:

- The `subscription_name` argument specifies the name of an existing
  subscription.
- The `truncate` argument accepts a boolean value; when set to `true`,
  the function truncates tables before copying, and the default value
  is `false`.

## Example

In the following example, the `spock.sub_alter_sync()` function synchronizes
all unsynchronized tables for a subscription named `sub_n1_n2`:

```sql
SELECT spock.sub_alter_sync('sub_n1_n2', true);
```
