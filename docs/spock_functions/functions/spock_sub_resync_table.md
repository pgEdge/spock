# spock.sub_resync_table

The `spock.sub_resync_table()` function resynchronizes one existing table.

## Synopsis

```sql
spock.sub_resync_table(subscription_name name, relation regclass, truncate boolean DEFAULT true)
```

## Description

The `spock.sub_resync_table()` function resynchronizes one existing table.

After the resynchronization is scheduled, the function compares the cached
`spock.node` row of the subscription's provider with the provider's own row.
If they differ, it raises a `WARNING` that suggests
[`spock.node_refresh_info()`](spock_node_refresh_info.md). The check does not
change `spock.node`, and a provider that cannot be reached for the check
produces a `WARNING` without failing the resynchronization.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `relation` - The name of an existing table, optionally schema qualified.
- `truncate` - Truncate the table before synchronization; the default value is
  `true`. If you do not include the truncate argument, conflicts between
  existing rows and newly arriving rows may cause errors.

## Example

In the following example, the `spock.sub_resync_table()` function 
resynchronizes a table named `public.users` for a subscription named
`sub_n1_n2`:

```sql
SELECT spock.sub_resync_table('sub_n1_n2', 'public.users');
 sub_resync_table
------------------
 t
(1 row)
```
