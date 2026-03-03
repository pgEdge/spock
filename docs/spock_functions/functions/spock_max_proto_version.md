## NAME

`spock.spock_max_proto_version()`

### SYNOPSIS

`spock.spock_max_proto_version ()`

### DESCRIPTION

Returns the highest Spock native protocol version supported by the current binary. This is used during connection negotiation between provider and subscriber nodes to determine the protocol version to use.

### EXAMPLE

```sql
postgres=# SELECT spock.spock_max_proto_version();
 spock_max_proto_version
-------------------------
                       1
(1 row)
```
