# Spockctrl Tutorial

## Introduction

`spockctrl` is a command-line utility designed to simplify the management and administration of a Spock multi-master replication setup for PostgreSQL. It provides a convenient interface for common tasks such as:

*   **Node Management**: Creating, dropping, and listing nodes within your Spock cluster.
*   **Replication Set Management**: Defining and modifying replication sets, which control which data is replicated.
*   **Subscription Management**: Creating, dropping, and managing subscriptions between nodes to initiate and control replication.
*   **Executing SQL**: Running ad-hoc SQL commands against your database nodes.
*   **Workflow Automation**: Running predefined sets of operations (workflows) to perform complex tasks like adding a new node to the cluster.

This tutorial will guide you through the process of building, configuring, and using `spockctrl` to manage your Spock replication environment.

## Building and Installation

`spockctrl` is typically built from source using the `Makefile` provided in the `spockctrl` directory.

1.  **Navigate to the `spockctrl` directory:**
    ```bash
    cd spockctrl
    ```

2.  **Build `spockctrl`:**
    Run the `make` command. This will compile the source files and create the `spockctrl` executable in the current directory.
    ```bash
    make
    ```
    *(Note: If the build fails, check the output for any missing dependencies or errors. You may need to install development libraries for PostgreSQL or other system libraries.)*

3.  **Place `spockctrl` in your PATH (Optional but Recommended):**
    For ease of use, you can copy the compiled `spockctrl` executable to a directory included in your system's `PATH` environment variable (e.g., `/usr/local/bin/`).
    ```bash
    sudo cp spockctrl /usr/local/bin/
    ```

Alternatively, you can run `spockctrl` directly from the `spockctrl` directory by prefixing commands with `./spockctrl`.

## Configuration

`spockctrl` uses a JSON configuration file to store database connection details and other settings. By default, it looks for a file named `spockctrl.json` in the directory where you run the `spockctrl` command. You can also specify a different configuration file using the `-c` or `--config` command-line option.

The configuration file contains information necessary for `spockctrl` to connect to your PostgreSQL instances and manage the Spock extension.

**Key Configuration Elements:**

*   **Database Connection Parameters:** DSN (Data Source Name) strings or individual parameters (host, port, user, password, dbname) for each node involved in the replication.
*   **Logging Settings:** Configuration for log levels and output.
*   **(Other specific parameters as needed by `spockctrl` operations)**

**Example Configuration File:**

A template or example configuration file named `spockctrl.json` is typically located in the `spockctrl/` directory of the source code. You should copy and modify this file to match your environment.

Here's a conceptual example of what parts of a `spockctrl.json` might look like (refer to the actual `spockctrl/spockctrl.json` for the correct structure):

```json
{
  "global": {
    "param": "value"
  },
  "nodes": {
    "node1_name": {
      "dsn": "host=your_node1_host port=5432 dbname=your_db user=spock_user password=secret",
      "param": "value"
    },
    "node2_name": {
      "dsn": "host=your_node2_host port=5432 dbname=your_db user=spock_user password=secret",
      "param": "value"
    }
  }
  // ... other sections like repset, sub, etc.
}
```

**Important:**
*   Ensure the `spockctrl.json` file has the correct permissions to prevent unauthorized access to database credentials.
*   Always refer to the `spockctrl/spockctrl.json` file in the source distribution for the most up-to-date structure and available options. You can use this file as a starting point for your own configurations.

## Basic Commands

`spockctrl` provides several commands to manage different aspects of your Spock replication setup. Most commands follow a `spockctrl <command> <subcommand> [options]` structure.

You can always get help for a specific command by typing `spockctrl <command> --help` or `spockctrl <command> <subcommand> --help`.

### Node Management (`node`)

The `node` command is used to manage the Spock nodes (PostgreSQL instances) that participate in replication.

*   **`spockctrl node create <node_name> --dsn <connection_string>`**: Creates a new Spock node representation within the Spock metadata.
    *   `<node_name>`: A unique name for the node.
    *   `--dsn`: The connection string for the PostgreSQL instance.
    *   Example: `spockctrl node create provider1 --dsn "host=pg1 port=5432 dbname=testdb user=spock"`

*   **`spockctrl node drop <node_name>`**: Removes a Spock node.
    *   Example: `spockctrl node drop provider1`

*   **`spockctrl node list`**: Lists all configured Spock nodes.
    *   Example: `spockctrl node list`

*   **`spockctrl node add-interface <node_name> <interface_name> --dsn <connection_string>`**: Adds an alternative connection interface to a node.
    *   Example: `spockctrl node add-interface provider1 secondary_conn --dsn "host=pg1_alt_ip port=5432 dbname=testdb"`

*   **`spockctrl node drop-interface <node_name> <interface_name>`**: Drops an interface from a node.
    *   Example: `spockctrl node drop-interface provider1 secondary_conn`

### Replication Set Management (`repset`)

The `repset` command manages replication sets, which define groups of tables and sequences to be replicated.

*   **`spockctrl repset create <repset_name> [options]`**: Creates a new replication set.
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).
    *   Options can control DDL replication, DML replication, etc. (e.g., `--replicate_insert=true`, `--replicate_update=false`).
    *   Example: `spockctrl repset create my_tables_repset`

*   **`spockctrl repset drop <repset_name>`**: Drops a replication set.
    *   Example: `spockctrl repset drop my_tables_repset`

*   **`spockctrl repset add-table <repset_name> <table_name> [options]`**: Adds a specific table to a replication set.
    *   `<table_name>`: The schema-qualified table name (e.g., `public.my_table`).
    *   Options can include specifying columns to replicate or row filtering conditions.
    *   Example: `spockctrl repset add-table my_tables_repset public.orders --columns "order_id,product_id,quantity"`

*   **`spockctrl repset add-all-tables <repset_name> <schema_name>`**: Adds all tables from a given schema to a replication set.
    *   `<schema_name>`: The name of the schema (e.g., `public`).
    *   Example: `spockctrl repset add-all-tables default_repset public`

*   **`spockctrl repset add-seq <repset_name> <sequence_name>`**: Adds a sequence to a replication set.
    *   Example: `spockctrl repset add-seq default_repset public.my_sequence`

*   **`spockctrl repset add-all-sequences <repset_name> <schema_name>`**: Adds all sequences from a given schema.
    *   Example: `spockctrl repset add-all-sequences default_repset public`

*   **`spockctrl repset list`**: Lists available replication sets.

### Subscription Management (`sub`)

The `sub` command manages subscriptions, which connect a subscriber node to a provider node and initiate replication.

*   **`spockctrl sub create <subscription_name> <provider_dsn> [options]`**: Creates a new subscription.
    *   `<subscription_name>`: A unique name for the subscription.
    *   `<provider_dsn>`: The DSN of the provider node to subscribe to.
    *   Options include specifying replication sets, synchronization options, etc.
    *   Example: `spockctrl sub create sub_to_provider1 "host=pg1 port=5432 dbname=testdb user=spock" --repsets "default,my_tables_repset"`

*   **`spockctrl sub drop <subscription_name>`**: Drops a subscription.
    *   Example: `spockctrl sub drop sub_to_provider1`

*   **`spockctrl sub enable <subscription_name>`**: Enables a disabled subscription.
    *   Example: `spockctrl sub enable sub_to_provider1`

*   **`spockctrl sub disable <subscription_name>`**: Disables an active subscription, pausing replication.
    *   Example: `spockctrl sub disable sub_to_provider1`

*   **`spockctrl sub list`**: Lists all subscriptions.

*   **`spockctrl sub show-status <subscription_name>`**: Shows the status of a specific subscription.
    *   Example: `spockctrl sub show-status sub_to_provider1`

*   **`spockctrl sub wait-for-sync <subscription_name>`**: Waits for a subscription to complete its initial data synchronization.
    *   Example: `spockctrl sub wait-for-sync sub_to_provider1`

### SQL Execution (`sql`)

The `sql` command allows you to execute arbitrary SQL commands on a specified node. This can be useful for administrative tasks or querying Spock-specific metadata.

*   **`spockctrl sql <node_name> <SQL_command_string>`**: Executes an SQL command.
    *   `<node_name>`: The name of the node (from `spockctrl.json`) on which to execute the command.
    *   `<SQL_command_string>`: The SQL query or command to run.
    *   Example: `spockctrl sql provider1 "SELECT * FROM spock.node;"`
    *   Example: `spockctrl sql subscriber1 "CALL spock.sub_resync_table('my_subscription', 'public.my_table');"`

**Note:** The exact subcommands and their options might vary slightly based on the `spockctrl` version. Always use `spockctrl <command> --help` for the most accurate and detailed information.

## Workflows

`spockctrl` supports the execution of predefined workflows to automate more complex multi-step operations. A workflow is typically a JSON file that defines a sequence of `spockctrl` commands or other actions.

**Running a Workflow:**

You can execute a workflow using the `-w` (or `--workflow`) command-line option, followed by the path to the workflow JSON file.

```bash
spockctrl --config /path/to/your/spockctrl.json --workflow /path/to/your/workflow.json
```
or
```bash
spockctrl -c spockctrl.json -w my_workflow.json
```

**Workflow Structure:**

Workflow files are JSON documents that outline the steps to be performed. Each step might involve:
*   Executing `spockctrl` commands (node creation, subscription setup, etc.).
*   Running SQL scripts.
*   Conditional logic or waiting for certain states.

**Available Example Workflows:**

The `spockctrl/workflows/` directory in the source distribution contains several example workflows, such as:

*   `add_node.json`: A workflow to add a new node to an existing Spock replication setup. This might involve creating the node, setting up replication sets, and creating subscriptions.
*   `remove_node.json`: A workflow to cleanly remove a node from a replication setup.
*   `cross-wire.json`: Potentially a workflow to set up bi-directional replication between two nodes (cross-replication).
*   `uncross-wire.json`: Potentially a workflow to dismantle a bi-directional replication setup.

These example workflows can serve as templates or starting points for creating your own custom automation scripts. Examine their content to understand how they are structured and what operations they perform.

**When to Use Workflows:**

*   **Standardized Setups:** Ensuring consistent configuration when adding new nodes or setting up replication.
*   **Complex Operations:** Automating sequences of commands that are prone to manual error.
*   **Disaster Recovery/Failover:** Scripting procedures for failover or re-configuring replication after an outage (though this would require careful design).

## Command-Line Options

`spockctrl` supports several global command-line options that can be used with most commands:

*   **`-c <file>`, `--config <file>`**:
    Specifies the path to the `spockctrl.json` configuration file. If not provided, `spockctrl` looks for `spockctrl.json` in the current directory.
    *   Example: `spockctrl node list -c /etc/spock/spockctrl.conf`

*   **`-f <format>`, `--format <format>`**:
    Determines the output format for commands that display data.
    *   `table`: (Default) Outputs data in a human-readable tabular format.
    *   `json`: Outputs data in JSON format, which is useful for scripting or integration with other tools.
    *   Example: `spockctrl sub list --format json`

*   **`-v <level>`, `--verbose <level>`**:
    Enables verbose logging to provide more detailed output about what `spockctrl` is doing. The verbosity level can be an integer (e.g., 0, 1, 2, 3), with higher numbers typically meaning more detailed logs.
    *   Level 0: Errors only (or default behavior if not specified).
    *   Level 1: Warnings and errors.
    *   Level 2: Informational messages, warnings, and errors.
    *   Level 3: Debug level messages (most verbose).
    *   Example: `spockctrl --verbose 2 node create mynode ...`

*   **`-w <file>`, `--workflow <file>`**:
    Executes a predefined workflow from the specified JSON file. When using this option, you typically don't specify other commands like `node` or `sub` directly on the command line, as the workflow file dictates the operations.
    *   Example: `spockctrl --config myconfig.json --workflow workflows/add_node.json`

*   **`-h`, `--help`**:
    Displays a general help message listing all available commands, or help for a specific command or subcommand.
    *   Example (general help): `spockctrl --help`
    *   Example (help for `node` command): `spockctrl node --help`
    *   Example (help for `node create` subcommand): `spockctrl node create --help`

*   **`--version`**:
    Displays the version of the `spockctrl` utility.
    *   Example: `spockctrl --version`

These options provide flexibility in how you interact with `spockctrl` and how it integrates into your operational procedures.

## Example Scenario: Setting up Two-Node Replication

This section provides a simplified walkthrough of using `spockctrl` to set up a basic two-node (provider and subscriber) replication.

**Prerequisites:**

1.  Two PostgreSQL instances are running and accessible.
2.  The Spock PostgreSQL extension is installed and created (`CREATE EXTENSION spock;`) on both instances.
3.  `postgresql.conf` on both nodes is configured for logical replication (e.g., `wal_level = logical`, `shared_preload_libraries = 'spock'`, etc.).
4.  `pg_hba.conf` allows replication connections between the nodes and from where `spockctrl` is run.
5.  `spockctrl` is built and accessible.
6.  A `spockctrl.json` configuration file is prepared.

**Example `spockctrl.json`:**

Let's assume your `spockctrl.json` looks something like this:

```json
{
  "nodes": {
    "provider_node": {
      "dsn": "host=pgserver1 port=5432 dbname=salesdb user=spock_user password=securepass",
      "is_provider": true
    },
    "subscriber_node": {
      "dsn": "host=pgserver2 port=5432 dbname=salesdb_replica user=spock_user password=securepass",
      "is_subscriber": true
    }
  },
  "repsets": {
    "default": {
      "tables": ["public.orders", "public.customers"],
      "sequences": ["public.order_id_seq"]
    }
  },
  "subscriptions": {
    "sales_subscription": {
      "provider_node": "provider_node",
      "subscriber_node": "subscriber_node",
      "repsets": ["default"],
      "enabled": true
    }
  }
}
```
*(Note: The actual structure of `spockctrl.json` might differ; this is a conceptual example based on common needs. Refer to `spockctrl/spockctrl.json` for the correct format.)*

**Steps using `spockctrl`:**

(Assuming your `spockctrl.json` is in the current directory or specified with `-c`)

1.  **Create the Provider Node:**
    This command tells Spock about your provider database instance.
    ```bash
    spockctrl node create provider_node --dsn "host=pgserver1 port=5432 dbname=salesdb user=spock_user password=securepass"
    ```
    *(If your DSN is already fully defined in `spockctrl.json` for this node, you might not need to specify it again on the command line, depending on `spockctrl`'s design.)*

2.  **Create the Subscriber Node:**
    This command registers your subscriber database instance.
    ```bash
    spockctrl node create subscriber_node --dsn "host=pgserver2 port=5432 dbname=salesdb_replica user=spock_user password=securepass"
    ```

3.  **Create a Replication Set on the Provider:**
    Define what data to replicate. Let's create a default set.
    ```bash
    spockctrl repset create default_repset --node provider_node
    ```
    *(The `--node` might be implicit if your config ties repsets to nodes, or it might be needed to specify where the repset is being defined.)*

4.  **Add Tables and Sequences to the Replication Set:**
    Specify which tables and sequences belong to `default_repset`.
    ```bash
    spockctrl repset add-table default_repset public.orders --node provider_node
    spockctrl repset add-table default_repset public.customers --node provider_node
    spockctrl repset add-seq default_repset public.order_id_seq --node provider_node
    ```
    Alternatively, if you want to add all tables from the `public` schema:
    ```bash
    spockctrl repset add-all-tables default_repset public --node provider_node
    ```

5.  **Create the Subscription on the Subscriber:**
    This command initiates the replication process. It tells `subscriber_node` to connect to `provider_node` and subscribe to the specified replication sets.
    ```bash
    spockctrl sub create sales_subscription \
        --provider-dsn "host=pgserver1 port=5432 dbname=salesdb user=spock_user password=securepass" \
        --target-node subscriber_node \
        --repsets "default_repset" \
        --forward-origins "none" \
        --synchronize-data \
        --enable
    ```
    *(Command arguments might vary. For example, instead of `--provider-dsn`, it might use the node name defined in `spockctrl.json`. `--target-node` specifies where the subscription is created. `--synchronize-data` would handle initial data copy. `--enable` makes it active immediately.)*

6.  **Wait for Initial Synchronization (Optional but Recommended):**
    Ensure the initial data copy is complete before considering the setup fully operational.
    ```bash
    spockctrl sub wait-for-sync sales_subscription --node subscriber_node
    ```

7.  **Check Subscription Status:**
    Verify that the subscription is active and replicating.
    ```bash
    spockctrl sub show-status sales_subscription --node subscriber_node
    ```
    Look for a status like 'replicating' or 'synchronized'.

**Further Actions:**

*   You can now make changes to `public.orders` or `public.customers` on `provider_node`, and they should replicate to `subscriber_node`.
*   Use `spockctrl sub disable sales_subscription` and `spockctrl sub enable sales_subscription` to pause and resume replication.
*   If you need to add more tables, modify the replication set on the provider and then, if necessary, resynchronize the relevant tables or the subscription.

This example is illustrative. The exact commands, options, and workflow will depend on the specific version of `spockctrl` and the structure of its configuration file. Always refer to `spockctrl --help` and the official documentation for precise usage.

This tutorial provides a starting point for using `spockctrl`. For more advanced topics and troubleshooting, consult the output of `spockctrl --help` for specific commands and refer to any further documentation provided with the Spock replication system.
