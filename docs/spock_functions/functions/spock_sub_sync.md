# spock.sub_sync

The `spock.sub_sync()` function synchronizes all unsynchronized tables in all
sets in a single operation.

## Synopsis

```sql
spock.sub_sync(subscription_name name, truncate bool)
```

## Description

The `spock.sub_sync()` function synchronizes all unsynchronized tables in all
sets in a single operation. Tables are copied and synchronized one by one. The
command does not wait for completion before returning to the caller. Use
`spock.sub_wait_for_sync()` to wait for completion.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `truncate` - If `true`, tables will be truncated before copying; the default
  is `false`.

## Example

In the following example, the `spock.sub_sync()` function synchronizes all
unsynchronized tables for a subscription named `sub_n1_n2`:

```sql
SELECT spock.sub_sync('sub_n1_n2', true);
```
