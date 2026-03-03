## NAME

`spock.spock_version_num()`

### SYNOPSIS

`spock.spock_version_num ()`

### DESCRIPTION

Returns the Spock version as a single integer (for example, `50005` for version 5.0.5). This is useful for programmatic version comparisons.

### EXAMPLE

```sql
postgres=# SELECT spock.spock_version_num();
 spock_version_num
-------------------
             50005
(1 row)
```
