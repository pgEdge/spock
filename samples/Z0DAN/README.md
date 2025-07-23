# Zodan: Zero-Downtime Node Addition for Spock

Zodan provides tools to add a new node to a PostgreSQL logical replication cluster **without any downtime**.

It includes two components:

- **[zodan.py](zodan.py)**: A Python CLI script that uses `psql` to perform automated node addition.
- **[zodan.sql](zodan.sql)**: A complete SQL-based workflow using `dblink` to perform the same operations from within PostgreSQL.

---

## Overview

Zodan is designed to streamline the process of adding a new node to an existing Spock cluster. It handles creation of the new node, subscription management (both to and from the new node), replication slot creation, data synchronization, replication slot advancement, and final activation of subscriptions.

---

## Components

### 1. zodan.py

This Python script leverages `psql` and is intended for use in environments where you have shell and Python access.

#### Requirements

- PostgreSQL 15 or later
- Spock extension installed and configured
- dblink extension enabled on all nodes
- Python 3
- Passwordless access or a properly configured `.pgpass` file for remote connections

#### Usage

```bash
./zodan.py \
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

---

### 2. zodan.sql

The SQL-based implementation utilizes PostgreSQL’s `dblink` extension to handle node addition directly from within the database. This method is ideal for environments where you may not have access to shell or Python.

#### How to Use

Execute the following command in your PostgreSQL session:

```sql
CALL add_node(
  'source_node_name',
  'source_node_dsn',
  'new_node_name',
  'new_node_dsn',
  'new_node_location',  -- optional
  'new_node_country',   -- optional
  '{}'::jsonb           -- optional info
);
```

#### Example

```sql
CALL add_node(
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

## When to Use

| Use Case                           | Use zodan.py | Use zodan.sql |
| ---------------------------------- | :----------: | :-----------: |
| CLI automation / scripting         | ✅          |               |
| SQL-only environments              |             | ✅            |
| No Python or shell access          |             | ✅            |
| PostgreSQL extension workflows     | ✅          | ✅            |

---
