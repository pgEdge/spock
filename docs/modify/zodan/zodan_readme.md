# Zodan: Zero-Downtime Node Addition for Spock

Zodan provides tools to add or remove a node with zero downtime. The
scripts are located in the 
[samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock)
repository.

Zodan's workflows and scripts streamline the process of adding a node to
or removing a node from a Spock cluster. Zodan features the following
scripts and workflows:

- The [zodan.sql](#using-the-zodansql-sql-workflow) workflow is a complete
  SQL-based workflow that uses `dblink` to perform the same add node
  operations from within Postgres.
- The [zodremove.sql](#the-zodremovesql-workflow) workflow is a complete
  SQL-based workflow that uses `dblink` to perform the same removal
  operations from within Postgres.

## Components

The following scripts and workflows are available via Zodan.

### Using the zodan.sql SQL Workflow

The SQL-based implementation utilizes the Postgres `dblink` extension to
handle node addition directly from within the database. This method is
ideal for environments where you may not have access to a shell or Python.

Within the workflow, SQL commands orchestrate the following operations:

- `add_node` - The main procedure to orchestrate the full workflow.
- `create_node` - Register the new node via `spock.node_create`.
- `get_spock_nodes` - Fetch current node metadata from a remote node.
- `create_sub` and `enable_sub` - Manage subscription creation and
  activation.
- `create_replication_slot` - Create and configure logical replication
  slots.
- `sync_event` and `wait_for_sync_event` - Coordinate data synchronization
  events.
- `get_commit_timestamp` and `advance_replication_slot` - Align
  replication states.

To use the workflow, execute the following command in your Postgres
session.  In the following example, the `spock.add_node` procedure adds a 
new node to the cluster:

```sql
CALL spock.add_node(
  'source_node_name',
  'src_dsn',
  'new_node_name',
  'new_node_dsn',
  true|false,               -- verbose? optional
  'new_node_location',      -- optional
  'new_node_country',       -- optional
  '{}'::jsonb               -- optional info
);
```

In the following example, the command adds node `n4` to the cluster:

```sql
CALL spock.add_node(
  'n1',
  'host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=<PASSWORD>',
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```

### The zodremove.sql Workflow

The SQL-based implementation utilizes the Postgres `dblink` extension to
handle node removal directly from within the database. This method is
ideal for environments where you may not have access to a shell or Python.

Within the workflow, SQL commands orchestrate the following operations:

- `spock.remove_node` - Main procedure to orchestrate the full workflow.
- `spock.remove_node_subscriptions` - Manages removing subscriptions. Also
  removes the replication slot if there are no remaining subscriptions.
- `spock.remove_node_replication_sets` - Removes published repsets on the
  node being removed.
- `spock.remove_node_from_cluster_registry` - Removes the node from the
  cluster.

The workflow is located in the 
[samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock)
repository.

To use the workflow, call a command from your Postgres session. In the
following example, the Z0DAN `spock.remove_node` procedure removes a node
from the cluster. Note that `spock.remove_node` is a Z0DAN utility
procedure provided by `zodremove.sql`; it is not a built-in function of
the Spock extension.

```sql
CALL spock.remove_node(
  'target_node_name',
  'target_dsn',
  true                      -- verbose_mode, optional boolean
);
```

In the following example, the command removes node `n4` from the cluster:

```sql
CALL spock.remove_node(
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```
