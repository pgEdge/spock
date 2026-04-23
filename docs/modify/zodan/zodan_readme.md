# Zodan: Zero-Downtime Node Addition for Spock

Zodan provides tools to add or remove a node with zero downtime. The
scripts are located in the 
[samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock)
repository.

Zodan's workflows and scripts streamline the process of adding a node to
or removing a node from a Spock cluster. Zodan features the following
scripts and workflows:

- The [zodan.py](#the-zodanpy-python-script) script is a Python CLI script
  that uses `psql` to perform automated node addition.
- The [zodan.sql](#using-the-zodansql-sql-workflow) workflow is a complete
  SQL-based workflow that uses `dblink` to perform the same add node
  operations from within Postgres.
- The [zodremove.py](#the-zodremovepy-python-script) script is a Python
  CLI script that uses `psql` to perform node removal.
- The [zodremove.sql](#the-zodremovesql-workflow) workflow is a complete
  SQL-based workflow that uses `dblink` to perform the same removal
  operations from within Postgres.

## Components

The following scripts and workflows are available via Zodan.

### The zodan.py Python Script

This Python script leverages `psql` and is intended for use in
environments where you have shell and Python access. The script is located
in the [samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock)
repository.

The script has three execution modes:

- `add_node`
- `health-check --check-type pre`
- `health-check --check-type post`

We recommend running the health check before adding a node. The health
check script checks connectivity, ensures that the Spock extension is
installed and configured, verifies that subscriptions on the existing
nodes are healthy, and confirms that there are no user-created tables on
the new target node.

After adding the new node, you can use health checks on your cluster to
ensure that the cluster is healthy and replicating.

#### Prerequisites

The `zodan.py` script requires the following components:

- Postgres 15 or later.
- Spock extension installed and configured.
- `dblink` extension enabled on all nodes.
- Python 3.
- Passwordless access or a properly configured `.pgpass` file for remote
  connections.

#### Running a Health Check

Invoke the script on the node you are validating. In the following example,
the `zodan.py` script performs a health check on the cluster:

```bash
./zodan.py \
  health-check
   --check-type [pre|post] \
  --src-node-name <source_node> \
  --src-dsn "<source_dsn>" \
  --new-node-name <new_node> \
  --new-node-dsn "<new_node_dsn>" \
  [options]
```

The following options are available:

- `--src-node-name` - Name of an existing node in the cluster.
- `--src-dsn` - DSN of the source node (e.g., `"host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=<PASSWORD>"`).
- `--new-node-name` - Name of the new node to add.
- `--new-node-dsn` - DSN of the new node.
- `--new-node-location` - Location of the new node (default: "NY").
- `--new-node-country` - Country of the new node (default: "USA").
- `--new-node-info` - A JSON string with additional metadata (default:
  "{}").
- `--verbose` - Provide verbose output for debugging.

#### Using Add Node

After performing a health check, you can use the following command to add
a node:

```bash
./zodan.py \
  add_node
  --src-node-name <source_node> \
  --src-dsn "<source_dsn>" \
  --new-node-name <new_node> \
  --new-node-dsn "<new_node_dsn>" \
  [options]
```

The command supports the following options:

- `--src-node-name` - Name of an existing node in the cluster.
- `--src-dsn` - DSN of the source node (e.g., `"host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=<PASSWORD>"`).
- `--new-node-name` - Name of the new node to add.
- `--new-node-dsn` - DSN of the new node.
- `--new-node-location` - Location of the new node (default: "NY").
- `--new-node-country` - Country of the new node (default: "USA").
- `--new-node-info` - A JSON string with additional metadata (default:
  "{}").
- `--verbose` - Provide verbose output for debugging.

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

### The zodremove.py Python Script

This Python script leverages `psql` and is intended for use in
environments where you have shell and Python access. The script can safely
remove fully or partially added nodes.

The script is located in the 
[samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock)
repository.

#### Prerequisites

The `zodremove.py` script requires the following components:

- Postgres 15 or later.
- Spock extension installed and configured.
- `dblink` extension enabled on all nodes.
- Python 3.
- Passwordless access or a properly configured `.pgpass` file for remote
  connections.

To remove a node, use the `zodremove.py` command. In the following example,
the `zodremove.py` script removes a node from the cluster:

```bash
./zodremove.py \
  remove_node \
  --target-node-name <target_node> \
  --target-dsn "<target_dsn>" \
  [options]
```

The command supports the following option:

- `--verbose` - Provide verbose output for debugging.

### The zodremove.sql Workflow

The SQL-based implementation utilizes the Postgres `dblink` extension to
handle node removal directly from within the database. This method is
ideal for environments where you may not have access to a shell or Python.

Within the workflow, SQL commands orchestrate the following operations:

- `remove_node` - Main procedure to orchestrate the full workflow.
- `sub_drop` - Manages removing subscriptions. Also removes the
  replication slot if there are no remaining subscriptions.
- `repset_drop` - Removes published repsets on the node being removed.
- `node_drop` - Removes the node from the cluster.

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
