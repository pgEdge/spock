# Zodan: Zero-Downtime Node Addition for Spock

Zodan provides tools to add a new node to a PostgreSQL logical replication cluster **without any downtime**.

In addition, Zodan provides a tool to remove nodes from a cluster. A primary use case is to carefully undo the work of partially added nodes in case something went wrong during the add procedure, but it can also remove active nodes.

Included are the following components:

- **[zodan.py](zodan.py)**: A Python CLI script that uses `psql` to perform automated node addition.
- **[zodan.sql](zodan.sql)**: A complete SQL-based workflow using `dblink` to perform the same add node operations from within PostgreSQL.
- **[zodremove.py](zodremove.py)**: A Python CLI script that uses `psql` to perform node removal.
- **[zodremove.sql](zodremove.sql)**: A complete SQL-based workflow using `dblink` to perform the same removal operations from within PostgreSQL.

---

## Overview

Zodan is designed to streamline the process of adding a new node to an existing Spock cluster. It handles creation of the new node, subscription management (both to and from the new node), replication slot creation, data synchronization, replication slot advancement, and final activation of subscriptions.

NOTE: Each script must be run from the target node being added or removed.

---

## Components

### 1. zodan.py

This Python script leverages `psql` and is intended for use in environments where you have shell and Python access.

There are three modes of execution:

- `add_node`
- `health-check --check-type pre`
- `health-check --check-type post`

It is advisable to run the health check before adding a node. The script checks connectivity, ensures that the spock extension is installed and configured, that subscriptions on the existing nodes are healthy, and that there are no user-created tables on the new target node.

After adding the new node, you can run health checks on your cluster to ensure that the cluster is healthy and replicating.

#### Requirements

- PostgreSQL 15 or later
- Spock extension installed and configured
- dblink extension enabled on all nodes
- Python 3
- Passwordless access or a properly configured `.pgpass` file for remote connections

#### Health Check Usage

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

**Options:**

- `--src-node-name`: Name of an existing node in the cluster.
- `--src-dsn`: DSN of the source node (e.g., `"host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=pgedge"`).
- `--new-node-name`: Name of the new node to add.
- `--new-node-dsn`: DSN of the new node.
- `--new-node-location`: Location of the new node (default: "NY").
- `--new-node-country`: Country of the new node (default: "USA").
- `--new-node-info`: A JSON string with additional metadata (default: "{}").
- `--verbose`: Provide verbose output for debugging.

#### Add Node Usage

```bash
./zodan.py \
  add_node
  --src-node-name <source_node> \
  --src-dsn "<source_dsn>" \
  --new-node-name <new_node> \
  --new-node-dsn "<new_node_dsn>" \
  [options]
```

**Options:**

- `--src-node-name`: Name of an existing node in the cluster.
- `--src-dsn`: DSN of the source node (e.g., `"host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=pgedge"`).
- `--new-node-name`: Name of the new node to add.
- `--new-node-dsn`: DSN of the new node.
- `--new-node-location`: Location of the new node (default: "NY").
- `--new-node-country`: Country of the new node (default: "USA").
- `--new-node-info`: A JSON string with additional metadata (default: "{}").
- `--verbose`: Provide verbose output for debugging.

---

### 2. zodan.sql

The SQL-based implementation utilizes PostgreSQL’s `dblink` extension to handle node addition directly from within the database. This method is ideal for environments where you may not have access to a shell or Python.

#### How to Use

Execute the following command in your PostgreSQL session:

```sql
CALL spock.add_node(
  'source_node_name',
  'src_dsn',
  'new_node_name',
  'new_node_dsn',
  true|false,    	-- verbose? optional
  'new_node_location',  -- optional
  'new_node_country',   -- optional
  '{}'::jsonb           -- optional info
);
```

#### Example

```sql
CALL spock.add_node(
  'n1',
  'host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=pgedge',
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=pgedge'
);
```

#### Major SQL Components

- **add_node**: Main procedure to orchestrate the full workflow.
- **create_node**: Registers a new node via `spock.node_create`.
- **get_spock_nodes**: Fetches current node metadata from a remote node.
- **create_sub / enable_sub**: Manages subscription creation and activation.
- **create_replication_slot**: Sets up logical replication slots.
- **sync_event / wait_for_sync_event**: Coordinates data synchronization events.
- **get_commit_timestamp / advance_replication_slot**: Aligns replication states.

---

### 3. zodremove.py

This Python script leverages `psql` and is intended for use in environments where you have shell and Python access. The script can safely remove fully or partially added nodes.

#### Requirements

- PostgreSQL 15 or later
- Spock extension installed and configured
- dblink extension enabled on all nodes
- Python 3
- Passwordless access or a properly configured `.pgpass` file for remote connections

#### Usage

```bash
./zodremove.py \
  remove_node \
  --target-node-name <target_node> \
  --target-dsn "<target_dsn>" \
  [options]

```

**Options:**

- `--verbose`: Provide verbose output for debugging

---

### 4. zodremove.sql

The SQL-based implementation utilizes PostgreSQL’s `dblink` extension to handle node removal directly from within the database. This method is ideal for environments where you may not have access to a shell or Python.

#### How to Use

Execute the following command in your PostgreSQL session:

```sql
CALL spock.remove_node(
  'targete_node_name',
  'target_dsn',
  'verbose_mode'	    -- optional
);
```

#### Example

```sql
CALL spock.remove_node(
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=pgedge'
);
```

#### Major SQL Components

- **remove_node**: Main procedure to orchestrate the full workflow.
- **sub_drop**: Manages removing subscriptions. Also removes the replication slot if there are no remaining subscriptions.
- **repset_drop**: Removes published repsets on the node we are removing.
- **node_drop**: Removes node from cluster

## When to Use

| Use Case                           | Use zodan.py & zodremove.py | Use zodan.sql & zodremove.sql |
| ---------------------------------- | :-------------------------: | :---------------------------: |
| CLI automation / scripting         | ✅                          |                              |
| SQL-only environments              |                             | ✅                           |
| No Python or shell access          |                             | ✅                           |
| PostgreSQL extension workflows     | ✅                          |              ✅              |

---
