## NAME

`spock.spock_min_proto_version()`

### SYNOPSIS

`spock.spock_min_proto_version ()`

### DESCRIPTION

Returns the lowest Spock native protocol version for which the current binary is backward compatible. This is used during connection negotiation between provider and subscriber nodes.

### EXAMPLE

```sql
postgres=# SELECT spock.spock_min_proto_version();
 spock_min_proto_version
-------------------------
                       1
(1 row)
```
