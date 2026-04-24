# spock.sub_show_table

The `spock.sub_show_table()` function displays the synchronization status of a
table.

## Synopsis

```sql
spock.sub_show_table(subscription_name name, relation regclass,
                     OUT nspname text, OUT relname text, OUT status text)
```

## Description

The `spock.sub_show_table()` function shows the synchronization status of a
table.

## Arguments

The function accepts the following arguments:

- `subscription_name` - The name of an existing subscription.
- `relation` - The name of an existing table, optionally qualified.

## Example

In the following example, the `spock.sub_show_table()` function displays the
synchronization status of a table named `test` for a subscription named
`sub_n2`:

```sql
SELECT * FROM spock.sub_show_table('sub_n2', 'test');
-[ RECORD 1 ]----
nspname | public
relname | test
status  | unknown
```
