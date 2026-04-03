# Node Management

Use commands listed in this section to manage the nodes in your replication
cluster.

| Command  | Description
|----------|-------------
| [spock.node_add_interface](functions/spock_node_add_interface.md) | Add an additional interface to a node.
| [spock.node_create](functions/spock_node_create.md) | Create a `spock` node.
| [spock.node_drop](functions/spock_node_drop.md) | Drop a `spock` node.
| [spock.node_drop_interface](functions/spock_node_drop_interface.md) | Remove an existing interface from a node.
| [spock.node_info](functions/spock_node_info.md) | Returns information about the local Spock node.


## Creating a Node

To create a node with Spock, connect to the server with psql and use the
`spock.node_create` command:

```sql
SELECT spock.node_create(node_name, dsn, location, country, info)
```

Parameters include:

- a name for the node.
- the dsn of the server on which the node resides.
- connection information for your database.

!!! note
    The DSN is similar to a connection string to the node you’re creating.
    For example, the DSN to connect to the `acctg` database with an ip
    address of `10.1.1.1`, using credentials that belong to `carol` would
    be: `host=10.1.1.1 user=carol dbname=acctg`.

The `location`, `country`, and `info` are all optional inputs to label nodes
and have a default of `null`.

For example, the following command:

```sql
SELECT spock.node_create(n1, ‘host=178.12.15.12 user=carol dbname=accounting’)
```

Creates a node named `n1` that connects to the `accounting` database on
`178.12.15.12`, authenticating with the credentials of a user named `carol`.

## Dropping a Node

To drop a node with Spock, connect to the server with psql, and use the
`spock.node_drop` command:

```sql
SELECT spock.node_drop(node_name, ifexists)
```

Parameters include:

- the name of the node.
- `ifexists` is a boolean value that suppresses an error if the node does
  not exist when set to `true`.

For example, the following command:

```sql
SELECT spock.node_drop(n1, true)
```

Drops a node named `n1`. If the node does not exist, an error message will
be suppressed because `ifexists` is set to `true`.

## Node Management Functions

You can add and remove nodes dynamically with the following SQL functions.

### spock.node_create

Use `spock.node_create` to create a replication node.

`spock.node_create(node_name name, dsn text)`

Parameters:

- `node_name` is the name of the new node; only one node is allowed per
  database.
- `dsn` is the connection string to the node. For nodes that are supposed to
  be providers, this should be reachable from the subscription nodes.

### spock.node_drop

Use `spock.node_drop` to drop a replication node.

`spock.node_drop(node_name name, ifexists bool)`

Parameters:

- `node_name` is the name of an existing node.
- `ifexists` specifies the Spock extension behavior with regards to error
  messages. If `true`, an error is not thrown when the specified node does
  not exist. The default is `false`.

### spock.node_add_interface

Use `spock.node_add_interface` to add an additional interface to a node.

`spock.node_add_interface(node_name name, interface_name name, dsn text)`

When a node is created, the interface for it is also created using the `dsn`
specified in the `create_node` command, and with the same name as the node.
This interface allows adding alternative interfaces with different connection
strings to an existing node.

Parameters:

- `node_name` is the name of an existing node.
- `interface_name` is the name of a new interface to be added.
- `dsn` is the connection string to the node used for the new interface.

### spock.node_drop_interface

Use `spock.node_drop_interface` to remove an existing interface from a node.

`spock.node_drop_interface(node_name name, interface_name name)`

Parameters:

- `node_name` is the name of an existing node.
- `interface_name` is the name of an existing interface.

### spock.node_info

Use `spock.node_info` to return information about the local Spock node.

`spock.node_info()`

This function queries the Spock catalogs and returns metadata about the
current node, including its identifier, name, database information, and any
optional descriptive fields that were set during node creation.

This is a read-only query function that does not modify data.

