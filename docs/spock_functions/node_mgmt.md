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
| [spock.node_alter](functions/spock_node_alter.md) | Change this node's own location, country, and/or info (merging info), validating a tiebreaker if one is set.
| [spock.node_refresh_info](functions/spock_node_refresh_info.md) | Refresh this node's cached copy of a peer's (or every peer's) location, country, and info.


## Creating a Node

To create a node with Spock, connect to the server with psql and use the
`spock.node_create` command:

```sql
SELECT spock.node_create(node_name, dsn)
```

Parameters include:

- a name for the node.
- the dsn of the server on which the node resides.

!!! note
    The DSN is similar to a connection string to the node you’re creating.
    For example, the DSN to connect to the `acctg` database with an ip
    address of `10.1.1.1`, using credentials that belong to `carol` would
    be: `host=10.1.1.1 user=carol dbname=acctg`.

The `location`, `country`, and `info` are all optional inputs to label nodes
and have a default of `null`.

For example, the following command:

```sql
SELECT spock.node_create('n1', 'host=178.12.15.12 user=carol dbname=accounting');
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
SELECT spock.node_drop('n1', true);
```

Drops a node named `n1`. If the node does not exist, an error message will
be suppressed because `ifexists` is set to `true`.

## Automatic Node Metadata Propagation

A change to a node's own `location`, `country`, or `info` -- whether via
[`spock.node_alter`](functions/spock_node_alter.md) or a raw
`UPDATE spock.node SET ... WHERE node_id = (SELECT node_id FROM spock.node_info())`
-- propagates automatically to every node that subscribes to it *directly*.
No manual step is required for a direct subscriber to pick up the change.

The message is not forwarded through a cascade topology (Node A → Node B →
Node C): only Node B, as A's direct subscriber, receives A's change. Node C
normally has no `spock.node` row for A unless it subscribes to A, so there
is nothing for it to update.

A node that has a row for the changed node but did not apply the message
keeps the old values. This happens when the transaction carrying the message
is skipped (for example with `skip_lsn`) or discarded by the exception
handling. Run [`spock.node_refresh_info`](functions/spock_node_refresh_info.md)
on that node to catch up. A table resynchronization does not replay these
messages, but `spock.sub_resync_table()` warns when the provider's row
differs from the cached one.

An incoming change is applied only if the node named in the message has
the same `node_id` locally as the node that sent it. Otherwise it is
skipped and logged as a `WARNING`: either the name is unknown locally
(rows are never created from these messages), or the name and the
sender's `node_id` disagree with the local copy. This is a defensive
check against a corrupted or misconfigured peer, not something normal
operation triggers.

## Node Management Functions

You can add and remove nodes dynamically with the following SQL functions.

### spock.node_create

Use `spock.node_create` to create a replication node.

`spock.node_create(node_name name, dsn text, location text DEFAULT NULL, country text DEFAULT NULL, info jsonb DEFAULT NULL)`

Parameters:

- `node_name` is the name of the new node; only one node is allowed per
  database.
- `dsn` is the connection string to the node. For nodes that are supposed to
  be providers, this should be reachable from the subscription nodes.
- `location` (optional) is a text label for the node's physical location.
- `country` (optional) is a text label for the node's country.
- `info` (optional) is a JSON object for any additional node metadata. A
  `tiebreaker` key overrides the node's default conflict-resolution
  tiebreaker; see the Tiebreaker section in conflict_types.md for how each
  node caches this independently and what that means for changing it
  cluster-wide.

### spock.node_drop

Use `spock.node_drop` to drop a replication node.

`spock.node_drop(node_name name, ifexists bool)`

Parameters:

- `node_name` is the name of an existing node.
- `ifexists` specifies the Spock extension behavior with regards to error
  messages. If `true`, an error is not thrown when the specified node does
  not exist. The default is `false`.

### spock.node_add_interface

Use `spock.node_add_interface` to add an interface to a node.

`spock.node_add_interface(node_name name, interface_name name, dsn text)`

When a node is created, the interface for it is also created using the `dsn`
specified in the `spock.node_create` command, and with the same name as the node.
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

Returns one row with the following columns:

| Column | Type | Description |
|--------|------|-------------|
| `node_id` | `oid` | The object identifier of the local node. |
| `node_name` | `text` | The name of the local node. |
| `sysid` | `text` | The PostgreSQL system identifier for this instance. |
| `dbname` | `text` | The name of the current database. |
| `replication_sets` | `text` | Comma-separated list of replication sets associated with this node. |
| `location` | `text` | Optional location label; `NULL` if not set during node creation. |
| `country` | `text` | Optional country label; `NULL` if not set during node creation. |
| `info` | `jsonb` | Optional JSON metadata; `NULL` if not set during node creation. |

### spock.node_alter

Use `spock.node_alter` to change the local node's own `location`,
`country`, and/or `info`, merging `info` rather than replacing it, with a
`tiebreaker` key (if present in the patch) validated as a whole JSON
number that fits a 32-bit integer.

`spock.node_alter(p_location text DEFAULT NULL, p_country text DEFAULT NULL, p_info_patch jsonb DEFAULT NULL)`

Unlike `spock.node_refresh_info`, this only ever targets the local node --
there is no node-name argument. It ends in the same `UPDATE spock.node`
that a hand-written `UPDATE` would use, so it propagates the same way; see
[Automatic Node Metadata Propagation](#automatic-node-metadata-propagation)
above. See [spock_node_alter.md](functions/spock_node_alter.md) for full
details and examples.

Parameters:

- `p_location` (optional) replaces this node's `location`; left unchanged
  if omitted.
- `p_country` (optional) replaces this node's `country`; left unchanged if
  omitted.
- `p_info_patch` (optional) is merged into this node's existing `info`;
  left unchanged if omitted. A `tiebreaker` key inside it must be a JSON
  number representable as a 32-bit integer, or the call raises an error
  and changes nothing.

### spock.node_refresh_info

Use `spock.node_refresh_info` to refresh this node's cached copy of a
peer's `location`, `country`, and `info` (including any `tiebreaker` key
within `info`).

`spock.node_refresh_info(p_node_name name DEFAULT NULL)`

`spock.node` is a local catalog: each node populates its row for a peer
once, either when that node is created or when a subscription to it is
first created. A *direct* subscriber picks up a peer's later changes
automatically -- see
[Automatic Node Metadata Propagation](#automatic-node-metadata-propagation)
above -- but the message is not forwarded, and it is lost if the
transaction carrying it is skipped or discarded.
`spock.node_refresh_info` is the way to catch such a node up on demand, in
bulk for every known peer at once, or to recover a specific peer's info
without waiting on it to change again. See the Tiebreaker section in
[conflict_types.md](../conflict_types.md).

Parameters:

- `p_node_name` (optional) is the name of a single peer node to refresh. If
  omitted, every node other than the local one is refreshed, best-effort:
  a node that fails to refresh for any reason (an unreachable or
  misconfigured interface, a dsn that now answers as a different node, or
  any other error from the remote fetch) logs a warning rather than
  aborting the rest.
