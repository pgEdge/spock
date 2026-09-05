# spock.sub_resync_table

The `spock.sub_resync_table()` function resynchronizes one existing table.

## Synopsis

```sql
spock.sub_resync_table(subscription_name name, relation regclass,
                       truncate boolean DEFAULT true,
                       merge boolean DEFAULT false)
```

## Description

The `spock.sub_resync_table()` function copies one table again from the
provider of the given subscription. By default the local table is truncated
first and the copy replaces its contents.

With `merge := true` the copy is loaded into a temporary staging table and then
merged into the local table with `ON CONFLICT DO NOTHING`. Rows already
present locally are kept as they are, and only the rows missing locally are
added. Use this when the local table already holds data you want to keep, for
example after a plain copy failed on a duplicate key and the table's sync
status is `failed`.

A merge needs a way to recognise the rows that are already present, so the
table must have a primary key or another unique index. A merge does not
update rows that differ between the two nodes and does not delete rows that
exist only locally.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `relation` - The name of an existing table, optionally schema qualified.
- `truncate` - Truncate the table before synchronization; the default value is
  `true`. If you set this to `false` without also setting `merge`, a row that
  already exists locally makes the copy fail with a duplicate key error.
- `merge` - Keep the rows already present and add only the missing ones; the
  default value is `false`. Requires `truncate := false` and a unique index
  on the table.

## Examples

Replace the contents of `public.users` for the subscription `sub_n1_n2`:

```sql
SELECT spock.sub_resync_table('sub_n1_n2', 'public.users');
 sub_resync_table
------------------
 t
(1 row)
```

Add the rows missing from `public.users` and keep the ones already there:

```sql
SELECT spock.sub_resync_table('sub_n1_n2', 'public.users',
                              truncate := false, merge := true);
 sub_resync_table
------------------
 t
(1 row)
```
