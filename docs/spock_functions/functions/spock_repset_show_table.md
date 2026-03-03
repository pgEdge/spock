## NAME

`spock.repset_show_table()`

### SYNOPSIS

`spock.repset_show_table (relation regclass, repsets text[])`

### DESCRIPTION

Returns detailed replication configuration information for a specific table within the specified replication sets, including which columns are replicated, whether row filtering is applied, and metadata about the table type and partition status.

### EXAMPLE

```sql
postgres=# SELECT * FROM spock.repset_show_table('public.invoices',
    ARRAY['default', 'ddl_sql']);
-[ RECORD 1 ]--+-----------------------------------------
relid          | 17241
nspname        | public
relname        | invoices
att_list       | {order_id,customer_id,order_date,amount}
has_row_filter | f
relkind        | r
relispartition | f
```

### ARGUMENTS
    relation
        The table to query information about.
    repsets
        An array of replication set names to check the table's configuration within.
