## NAME

`spock.node_info()`

### SYNOPSIS

`spock.node_info ()`

### DESCRIPTION

Returns information about the local Spock node, including the node identifier, name, system identifier, database name, available replication sets, and any optional descriptive fields that were set during node creation.

### EXAMPLE

```sql
postgres=# SELECT * FROM spock.node_info();
-[ RECORD 1 ]----+--------------------------------------
node_id          | 49708
node_name        | n1
sysid            | 7600444661598442547
dbname           | postgres
replication_sets | "default",default_insert_only,ddl_sql
location         |
country          |
info             | 
```
