- [Using Spockctrl to Manage a Cluster](spockctrl.md#using-spockctrl-to-manage-a-cluster)
- [The spockctrl.json file](spockctrl.md#thespockctrljson-file)
- [Spockctrl Functions](spockctrl.md#spockctrl-functions)
- [Writing a spockctrl Workflow File](spockctrl.md#writing-a-spockctrl-workflow-file)


# Using Spockctrl to Manage a Cluster

Spockctrl is a command-line utility designed to simplify the management of a Spock multi-master replication setup for PostgreSQL. It provides a convenient interface for common tasks such as:

*   **Node Management**: Creating, dropping, and listing nodes within your Spock cluster.
*   **Replication Set Management**: Defining and modifying the replication sets that control which data is replicated.
*   **Subscription Management**: Creating, dropping, and managing subscriptions between nodes to initiate and control replication.
*   **Executing SQL**: Running ad-hoc SQL commands against your database nodes.
*   **Workflow Automation**: Running predefined sets of operations (workflows) to perform complex tasks like adding a new node to the cluster.

This section will guide you through the process of building, configuring, and using `spockctrl` to manage your Spock replication environment.

## Installing and Configuring Spockctrl

Spockctrl is built from source when you build the Spock extension; all supporting `spockctrl` objects are created as well, and copied into place in their respective locations.  

To simplify use, you can add the binary directory to your path and ensure that `LD_LIBRARY_PATH` is in your `.bashrc` file:

 ```bash
echo 'export PATH="/usr/local/bin:$PATH"' >> ~/.bashrc && \
echo 'export LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"' >> ~/.bashrc
```

Alternatively, you can invoke `spockctrl` directly from the `spockctrl` directory by moving into the installation directory and prefixing commands with `./spockctrl`.

### Configuration - Updating the spockctrl.json File

Spockctrl uses a JSON configuration file to store database connection details and other settings. By default, `spockctrl` looks for a file named `spockctrl.json` in the directory where you run the `spockctrl` command. You can also specify a different configuration file using the `-c` or `--config=<path_to_spockctrl.json>` command-line option.

The configuration file contains the information necessary for `spockctrl` to connect to your PostgreSQL instances and manage the Spock extension.  Refer to the `spockctrl/spockctrl.json` file in the [source distribution](https://github.com/pgEdge/spock/blob/main/spockctrl/spockctrl.json) for the most up-to-date structure and available options. 

**Note:** You should ensure that the `spockctrl.json` file has the correct permissions to prevent unauthorized access to database credentials.


## Example: Manually Creating a Two-Node Cluster

Before using spockctrl to deploy and configure a two-node (provider and subscriber) replication scenario, you must:

1. Install and verify two PostgreSQL instances.
2. Install and create (using `CREATE EXTENSION spock;`) the Spock extension on both instances.
3. Configure the `postgresql.conf` file on both nodes for logical replication  
   (for example, set `wal_level = logical`, `shared_preload_libraries = 'spock'`, etc.).
4. Update the `pg_hba.conf` file on each instance to allow replication connections between the nodes and from the host running `spockctrl`.
5. Build `spock` in your environment, and optionally add the `spockctrl` executable to your path.
6. Update the `spockctrl.json` file.

### Using `spockctrl` to Create a Cluster

Assuming your `spockctrl.json` is in the current directory or is specified with `-c`:

1.  **Create the Provider Node:**
    The following command tells Spock about your provider database instance:
    
    ```bash
    spockctrl node create provider_node --dsn "host=pgserver1 port=5432 dbname=salesdb user=spock_user password=securepass"
    ```

2.  **Create the Subscriber Node:**
    The following command registers your subscriber database instance:
    ```bash
    spockctrl node create subscriber_node --dsn "host=pgserver2 port=5432 dbname=salesdb_replica user=spock_user password=securepass"
    ```

3.  **Create a Replication Set on the Provider:**
    The following command creates a replication data set named default_repset:
    ```bash
    spockctrl repset create default_repset --node provider_node
    ```
    *(The `--node` might be implicit if your config ties repsets to nodes, or it might be needed to specify where the repset is being defined.)*

4.  **Add Tables and Sequences to the Replication Set:**
    The following command adds our tables and sequences to the `default_repset` replication set:
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
    The following command initiates the replication process by telling the subscriber_node to connect to provider_node and subscribe to the specified replication sets:
    ```bash
    spockctrl sub create sales_subscription \
        --provider-dsn "host=pgserver1 port=5432 dbname=salesdb user=spock_user password=securepass" \
        --target-node subscriber_node \
        --repsets "default_repset" \
        --forward-origins "none" \
        --synchronize-data \
        --enable
    ```
Note that your command arguments will vary. In our example:
* `--provider-dsn` specifies a connection string, but you might instead use the node name defined in `spockctrl.json`. 
* `--target-node` specifies where the subscription is created. 
* `--synchronize-data` instructs spock to perform the initial data copy. 
* `--enable` makes the subscription active immediately.

6.  **Wait for Initial Synchronization (Optional but Recommended):**
    The following command confirms that the initial data copy is complete; when the copy is confirmed, replication should be operational:
    
    ```bash
    spockctrl sub wait-for-sync sales_subscription --node subscriber_node
    ```

7.  **Check Subscription Status:**
    You can use the following command to verify that the subscription is active and replicating:
    
    ```bash
    spockctrl sub show-status sales_subscription --node subscriber_node
    ```
    Look for a status `replicating` or `synchronized`.

**Further Actions:**

You can now:

*  Make changes to `public.orders` or `public.customers` on `provider_node` that will replicate to `subscriber_node`.
*  Use `spockctrl sub disable sales_subscription` and `spockctrl sub enable sales_subscription` to pause and resume replication.
*  Add more tables by modifying the replication set on the provider and then, if necessary, resynchronize the relevant tables or the subscription to the subscriber node.


## Using a Workflow to Add a Node to a Cluster

`spockctrl` supports the execution of predefined workflows to automate complex multi-step operations. A workflow is typically a JSON file that defines a sequence of `spockctrl` commands or other actions.

Sample workflow files are available in the [spockctrl GitHub repository](https://github.com/pgEdge/spock/tree/main/spockctrl/workflows).


## The spockctrl.json file

Before using Spockctrl to add a node to your cluster, your cluster information must be added to the `spockctrl.json` file.  The file template is available in the [spock repository](https://github.com/pgEdge/spock/blob/main/spockctrl/spockctrl.json).

You should ensure that the `spockctrl.json` file has the correct permissions to prevent unauthorized access to database credentials.

Within the template, provide information about your cluster and each node that is in your cluster.  If you are using Spockctrl to add a node to your cluster, you should also add the node details for the new node to this file before invoking `spockctrl`:

**spockctrl.json Properties**

Use properties within the `spockctrl.json` file describe your cluster before invoking `spockctrl`:

| Property | Description |
|----------|-------------|
| Global Properties | Use properties in the `global` section to describe your cluster. |
| spock -> cluster_name | The name of your cluster. |
| spock -> version | The pgEdge .json file version in use. |
| log -> log_level | Specify the message severity level to use for Spockctrl; valid options are: `0` (log errors only), `1` (log warnings and errors), `2` (log informational messages, warnings, and errors), and `3` (log debug level messages (most verbose)). |
| log -> log_destination | Specify the target destination for your log messages. |
| log -> log_file | Specify the log file name for your log files. |
| spock-nodes Properties | Provide a stanza about each node in your cluster in the `spock-nodes` section.  If you are adding a node to your cluster, update this file to add the connection information for the new node before invoking `spockctrl`. |
| spock-nodes -> node_name | The unique name of a cluster node. |
| spock-nodes -> postgres -> postgres_ip | The IP address used for connections to the Postgres server on this node. |
| spock-nodes -> postgres -> postgres_port | The Postgres listener port used for connections to the Postgres server. |
| spock-nodes -> postgres -> postgres_user | The Postgres user that will be used for server connections. |
| spock-nodes -> postgres -> postgres_password | The password associated with the specified Postgres user. |
| spock-nodes -> postgres -> postgres_db | The name of the Postgres database. |

### Example - spockctrl.json Content

The following is sample content from a `spockctrl.json` file; customize the `spockctrl.json` file to contain connection information about your cluster.

```json
{
    "global": {
        "spock": {
            "cluster_name": "pgedge",
            "version": "1.0.0"
        },
        "log": {
            "log_level": "INFO",
            "log_destination": "console",
            "log_file": "/var/log/spockctrl.log"
        }
    },
    "spock-nodes": [
        {
            "node_name": "n1",
            "postgres": {
                "postgres_ip": "127.0.0.1",
                "postgres_port": 5431,
                "postgres_user": "pgedge",
                "postgres_password": "pgedge",
                "postgres_db": "pgedge"
            }
        },
        {
            "node_name": "n2",
            "postgres": {
                "postgres_ip": "127.0.0.1",
                "postgres_port": 5432,
                "postgres_user": "pgedge",
                "postgres_password": "pgedge",
                "postgres_db": "pgedge"
            }
        },
        {
            "node_name": "n3",
            "postgres": {
                "postgres_ip": "127.0.0.1",
                "postgres_port": 5433,
                "postgres_user": "pgedge",
                "postgres_password": "pgedge",
                "postgres_db": "pgedge"
            }
        }
    ]
}
```


## Spockctrl Functions

Spockctrl provides functions to manage different aspects of your Spock replication setup. The functions are grouped by the type of object they manage:

* [Spockctrl node management](#spockctrl-node-management-functions) functions
* [Spockctrl replication management](#spockctrl-replication-set-management-functions) functions
* [Spockctrl subscription management](#spockctrl-subscription-management-functions) functions
* [Spockctrl SQL execution](#spockctrl-sql-execution-functions) functions

The exact subcommands and their options may vary slightly based on the `spockctrl` version. Use `spockctrl <command> --help` for the most accurate and detailed information.


### Spockctrl Node Management Functions

Use the `node` command to manage the nodes that participate in a replication cluster.  The functions are:

| Command | Description |
|---------|-------------|
| [spockctrl node create](#spockctrl-node-create) | Create a new node. |
| [spockctrl node drop](#spockctrl-node-drop) | Drop a node from a cluster. |
| [spockctrl node list](#spockctrl-node-list) | List the nodes in a cluster. | 
| [spockctrl node add-interface](#spockctrl-node-add-interface) | Add an alternative connection interface to a node. |
| [spockctrl node drop-interface](#spockctrl-node-drop-interface) | Drop a connection interface to a node. |
| `-h`, `--help` | Displays a general help message listing the command options. |
| `--version` | Displays the version of the `spockctrl` utility. |


#### spockctrl node create

Use `spockctrl node create` to create a new Spock node within the Spock metadata.  The syntax is:

`spockctrl node create <node_name> --dsn <connection_string>`

 *   `<node_name>`: A unique name for the node.
 *   `--dsn <connection_string>`: Specifies the connection string for the PostgreSQL instance.

**Optional Arguments**

* `-c <file>`, `--config=<path_to_spockctrl.json>` - Specifies the path to the `spockctrl.json` configuration file. If not provided, `spockctrl` looks for `spockctrl.json` in the current directory. For example: `spockctrl node list -c /etc/spock/spockctrl.conf`
*  `-f <format>`, `--format=<table or json>` - Determines the output format for commands that display data. Specify: `table` (the default) to outputs data in a human-readable tabular format or `json` to output data in JSON format, which is useful for scripting or integration with other tools.  For example: `spockctrl sub list --format=json`
*  `-v <level>`, `--verbose=<integer_value>` - Enables verbose logging to provide more detailed output about what `spockctrl` is doing. The verbosity level is an integer with higher numbers providing more detailed logs. `0` logs ERRORs only, `1` logs WARNINGs and ERRORs, `2` logs informational messages, WARNINGs, and ERRORs, and `3` logs debug level messages (most verbose).  For example: `spockctrl --verbose=2 node create mynode ...`
*  `-w <file>`, `--workflow=<path_to_workflow>` - Executes a predefined workflow from the specified JSON file. When using this option, you typically don't specify other commands like `node` or `sub` directly on the command line, as the workflow file directs the operations.   For example: `spockctrl --config=myconfig.json --workflow=workflows/add_node.json` 
*  `-h`, `--help` - Displays a general help message listing all available commands, or help for a specific command or subcommand. For example, to request help for the `node create` subcommand: `spockctrl node create --help` 

**Example** 

`spockctrl node create my_node --dsn "host=pg1 port=5432 dbname=testdb user=spock"`

#### spockctrl node drop

Use `spockctrl node drop` to remove a Spock node. The syntax is:

`spockctrl node drop <node_name>`
 *   `<node_name>`: A unique name for the node.

**Example** 

`spockctrl node drop my_node`

#### spockctrl node list

Use `spockctrl node list` to list all configured Spock nodes. The syntax is:

`spockctrl node list`

**Example** 

`spockctrl node list`

#### spockctrl node add-interface

Use `spockctrl node add-interface` to add an alternative connection interface to a node.  The syntax is:

`spockctrl node add-interface <node_name> <interface_name> --dsn <connection_string>`
 *   `<node_name>`: The name of the node accessed by the interface.
 *   `<interface_name>`: A unique name for the new interface.
 *   `--dsn <connection_string>`: Specifies the connection string of the new interface.

**Example** 

`spockctrl node add-interface my_node secondary_conn --dsn "host=pg1_alt_ip port=5432 dbname=testdb"`

#### spockctrl node drop-interface

Use `spockctrl node drop-interface` to drop an interface from a node. The syntax is:

`spockctrl node drop-interface <node_name> <interface_name>` drops an interface from a node.
 *   `<node_name>`: The name of the node accessed by the interface.
 *   `<interface_name>`: A unique name for the new interface.

**Example** 

`spockctrl node drop-interface my_node secondary_conn`


### Replication Set Management Functions

You can use the `spockctrl repset` command to manage the Spock replication sets that participate in a replication cluster. A replication set defines groups of tables and sequences to be replicated.

| Command | Description |
|---------|-------------|
| [spockctrl repset create](#spockctrl-repset-create) | Create a new replication set. |
| [spockctrl repset drop](#spockctrl-repset-drop) | Drop a replication set. | 
| [spockctrl repset add-table](#spockctrl-repset-add-table) | Add a specific table to a replication set. |
| [spockctrl repset add-all-tables](#spockctrl-repset-add-all-tables) | Add all tables from the specified schema to a replication set. |
| [spockctrl repset add-seq](#spockctrl-repset-add-seq) | Add a sequence to a replication set. |
| [spockctrl repset add-all-sequences](#spockctrl-repset-add-all-sequences) | Add all sequences from a given schema. |
| [spockctrl repset list](#spockctrl-repset-list) | List the available replication sets. |
| `-h`, `--help` | Displays a general help message listing all available commands, or help for a specific command or subcommand. For example, to request help for the `node create` subcommand: `spockctrl node create --help` |
| `--version` | Displays the version of the `spockctrl` utility.  For example: `spockctrl --version` |

#### spockctrl repset create

Use `spockctrl repset create` to create a new replication set.  The syntax is:

`spockctrl repset create <repset_name> [options]`
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).
    *   You can include `options` to control DDL replication, DML replication, etc. (for example, `--replicate_insert=true`, `--replicate_update=false`).

**Example** 

`spockctrl repset create my_repset`

#### spockctrl repset drop

Use `spockctrl repset drop` to drop a replication set; the syntax is:

`spockctrl repset drop <repset_name>`
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).

**Example** 

`spockctrl repset drop my_repset`

#### spockctrl repset add-table

Use `spockctrl repset add-table` to add a specific table to a replication set.  The syntax is:

`spockctrl repset add-table <repset_name> <table_name> [options]`
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).
    *   `<table_name>` is the schema-qualified table name (e.g., `public.my_table`).
    *   You can include `options` to specify which columns to replicate and filtering conditions.

**Example** 

`spockctrl repset add-table my_repset public.orders --columns "order_id,product_id,quantity"`

#### spockctrl repset add-all-tables

Use `spockctrl repset add-all-tables` to add all tables from the specified schema to a replication set. The syntax is:

`spockctrl repset add-all-tables <repset_name> <schema_name>`
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).
    *   `<schema_name>`: The name of the schema (e.g., `public`).

**Example** 

`spockctrl repset add-all-tables my_repset public`

#### spockctrl repset add-seq

Use `spockctrl repset add-seq` to add a sequence to a replication set.  The syntax is:

`spockctrl repset add-seq <repset_name> <sequence_name>`
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).
    *   `<sequence_name>`: The name of the sequence.

**Example** 

`spockctrl repset add-seq my_repset public.my_sequence`

#### spockctrl repset add-all-sequences

Use `spockctrl repset add-all-sequences` to adds all sequences from a given schema. The syntax is:

`spockctrl repset add-all-sequences <repset_name> <schema_name>`
    *   `<repset_name>`: Name for the replication set (e.g., `default`, `custom_set`).
    *   `<schema_name>`: The name of the schema (e.g., `public`).

**Example** 

`spockctrl repset add-all-sequences my_repset public`

#### spockctrl repset list

Use spockctrl repset list to list the available replication sets.  The syntax is:

`spockctrl repset list`


### Spockctrl Subscription Management Functions

The `sub` command manages subscriptions, which connect a subscriber node to a provider node and initiate replication.

| Command | Description |
|---------|-------------|
| [spockctrl sub create](#spockctrl-sub-create) | Create a new subscription. |
| [spockctrl sub drop](#spockctrl-sub-drop) | Drop the specified subscription. | 
| [spockctrl sub enable](#spockctrl-sub-enable) | Enable the specified subscription. |
| [spockctrl sub disable](#spockctrl-sub-disable) | Enable the specified subscription.  |
| [spockctrl sub list](#spockctrl-sub-list) | Generate a list of subscriptions.  |
| [spockctrl sub wait-for-sync](#spockctrl-sub-wait-for-sync) | Wait for a subscription sync event.  |
| [spockctrl sub show-status](#spockctrl-sub-show-status) | Display the status of the specified subscription.  |
| `-h`, `--help` | Displays a general help message listing all available commands, or help for a specific command or subcommand. For example, to request help for the `node create` subcommand: `spockctrl sub create --help` |
| `--version` | Displays the version of the `spockctrl` utility.  For example: `spockctrl --version` |


#### spockctrl sub create
Use `spockctrl sub create <subscription_name> <provider_dsn> [options]` to create a new subscription.
    *   `<subscription_name>`: A unique name for the subscription.
    *   `<provider_dsn>`: The DSN of the provider node to subscribe to.
    *   You can include `options` to specifying replication sets, synchronization options, etc.

**Example** 

`spockctrl sub create sub_n3_n1 "host=pg1 port=5432 dbname=testdb user=spock" --repsets "default,my_repset"`

#### spockctrl sub drop

Use `spockctrl sub drop` to drop a subscription.  The syntax is:

`spockctrl sub drop <subscription_name>`
    *   `<subscription_name>`: A unique name for the subscription.

**Example** 

`spockctrl sub drop sub_n3_n1`

#### spockctrl sub enable

Use `spockctrl sub enable` to enable a disabled subscription. The syntax is:

`spockctrl sub enable <subscription_name>`
    *   `<subscription_name>`: A unique name for the subscription.

**Example** 

`spockctrl sub enable sub_n3_n1`

#### spockctrl sub disable

Use `spockctrl sub disable` to disable an active subscription, pausing replication. The syntax is:

`spockctrl sub disable <subscription_name>`
    *   `<subscription_name>`: A unique name for the subscription.

**Example** 

`spockctrl sub disable sub_n3_n1`

#### spockctrl sub list

Use `spockctrl sub list` to list all subscriptions. The syntax is:

`spockctrl sub list`

#### spockctrl sub show-status

Use `spockctrl sub show-status` to show the status of a specific subscription. The syntax is:

`spockctrl sub show-status <subscription_name>`
    *   `<subscription_name>`: A unique name for the subscription.

**Example** 

`spockctrl sub show-status sub_n3_n1`

#### spockctrl sub wait-for-sync 

Use `spockctrl sub wait-for-sync` to wait for a subscription to complete its initial data synchronization.

`spockctrl sub wait-for-sync <subscription_name>`

**Example** 

`spockctrl sub wait-for-sync sub_n3_n1`


### Spockctrl SQL Execution Functions

The `sql` command allows you to execute arbitrary SQL commands on a specified node. This can be useful for performing administrative tasks or querying Spock-specific metadata.

| Command | Description |
|---------|-------------|
| [spockctrl sql](#spockctrl-sql) | Use the spockctrl sql command to execute a SQL command. |
| `-h`, `--help` | Displays a general help message listing all available commands, or help for a specific command or subcommand. For example, to request help for the `spockctrl sql` subcommand: `spockctrl sql --help` |
| `--version` | Display the version of the `spockctrl` utility.  For example: `spockctrl --version` |

#### spockctrl sql

Use the `spockctrl sql` command to execute a SQL command. The syntax is:

`spockctrl sql <node_name> <SQL_command_string>`
    *   `<node_name>` is the name of the node (from `spockctrl.json`) on which to execute the command.
    *   `<SQL_command_string>` is the SQL query or command to run.

**Examples** 

`spockctrl sql my_node "SELECT * FROM spock.node;"`
`spockctrl sql my_node "CALL spock.sub_resync_table('my_subscription', 'public.my_table');"`


## Writing a spockctrl Workflow File

To use `spockctrl` to make an automated change to your cluster, you need to describe the changes in a workflow file.  A workflow file describes the changes you'll be making to your cluster in a step-by-step, node-by-node manner, and needs to be customized for your cluster.

* The new node should not be accessible to users while adding a node with a workflow.

* Do not modify your cluster's DDL during node addition.

* All nodes in your cluster must be available for the duration of the addition.

* If the workflow fails, don't invoke the workflow again until you ensure that all artifacts created by previous run of the workflow have been removed!

Sample workflows are available in the Spock extension's Github repository for common activities; the samples can help you:

* `add_node.json` - Add a node to a cluster.
* `remove_node.json` - Remove a node from a cluster. 
* `cross-wire.json` - Configure subscriptions and replication artifacts between empty nodes.
* `uncross-wire.json` - Remove subscriptions and replication artifacts from empty nodes.

To execute a workflow, include the `-w` (or `--workflow=<path_to_workflow_file>`) command-line option when you invoke `spockctrl`, followed by the path to the workflow JSON file.

```bash
spockctrl --config=/path/to/my/spockctrl.json --workflow=/path/to/my/workflow.json
```
or
```bash
spockctrl -c path/to/my/spockctrl.json -w path/to/my/workflow.json
```

### Example - Creating a Workflow to Add a Node to a Two-Node Cluster

In this example, we'll walk through the stanzas that make up a workflow that adds a new node to a two-node cluster. Within the workflow file, the `COMMAND` property identifies the action performed by the stanza in which it is used.  Spock 5.0 supports the following `COMMANDs`:

| COMMAND | Description |
|---------|-------------|
| CREATE NODE | Add a node to a cluster. | 
| DROP NODE | Drop a node from a cluster. | 
| CREATE SUBSCRIPTION | Add a subscription to a cluster. | 
| DROP SUBSCRIPTION| Drop a subscription from a cluster. | 
| CREATE REPSET | Add a repset to a cluster. | 
| DROP REPSET | Drop a node to a cluster. | 
| CREATE SLOT | Add a replication slot. | 
| DROP SLOT | Drop a replication slot. | 
| ENABLE SUBSCRIPTION | Start replication on a node. | 
| DISABLE SUBSCRIPTION | Stop replication on a node. | 
| SQL | Invoke the specified Postgres SQL command. |


In this walkthrough, we're using a two-node cluster; if your cluster is larger than two nodes, any actions performed on the replica node (in our example, `n2`) should be performed on *every* replica node in your cluster.  A replica node is any existing node that is not used as a source node.

Our sample workflow adds a third node to a new node cluster. The first stanza provides connection information for the host of the new node.  Spockctrl can add only one node per workflow file; provide this information for each new node you add to your cluster.

This stanza associates the name of the new node with the connection properties of the new node:

* Provide the new node name in the `node` property and the `--node_name` property - the name must be identical.
* `--dsn` specifies the connection properties of the new node.

```json
{
  "workflow_name": "Add Node",
  "description": "Adding third node (n3) to two node (n1,n2) cluster.",
  "steps": [
    {
      "spock": {
        "node": "n3",
        "command": "CREATE NODE",
        "description": "Create a spock node n3",
        "args": [
          "--node_name=n3",
          "--dsn=host=127.0.0.1 port=5433 user=lcusr password=password",
          "--location=Los Angeles",
          "--country=USA",
          "--info={\"key\": \"value\"}"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```
The next stanza creates the subscription from the new node (`n3`) to the source node (`n1`). In this stanza: 

* the `node` property specifies the name of the node in our original cluster that is used as our source node. The content of this node will be copied to the new node that we are creating.
* `--sub_name` specifies the name of the new subscription.
* `--provider_dsn` specifies the connection properties of the provider (our new node).
* `--replication_sets` specifies the names of the replication sets created for the subscription.
* `--enabled`, `--synchronize_data` and `--synchronize_structure` must be `true`.

```json
    {
      "spock": {
        "node": "n1",
        "command": "CREATE SUBSCRIPTION",
        "description": "Create a subscription (sub_n3_n1) on (n1) for n3->n1",
        "sleep": 0,
        "args": [
          "--sub_name=sub_n3_n1",
          "--provider_dsn=host=127.0.0.1 port=5433 user=lcusr password=password",
          "--replication_sets=ARRAY['default', 'default_insert_only', 'ddl_sql']",
          "--synchronize_structure=true",
          "--synchronize_data=true",
          "--forward_origins='{}'::text[]",
          "--apply_delay='0'::interval",
          "--force_text_transfer=false",
          "--enabled=true"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

Our next stanza creates subscriptions between the new node and any existing replica nodes.  

* `node` specifies the name of the existing replica node.
* `--provider_dsn` specifies the connection properties of the new node; this is the provider node for the new subscription.
* `--replication_sets` specifies the names of the replication sets created for the subscription
* `--enabled`, `--synchronize_data` and `--synchronize_structure` must be `true`.

You will need to include this stanza once for each replica node in your cluster; if your existing cluster has three nodes (one source node and two replica nodes), you will add two copies of this stanza.  If your existing cluster has four nodes (one source node and three replica nodes), you will add three copies of this stanza.

```json
    {
      "spock": {
        "node": "n2",
        "command": "CREATE SUBSCRIPTION",
        "description": "Create a subscription (sub_n3_n2) on (n2) for n3->n2",
        "sleep": 0,
        "args": [
          "--sub_name=sub_n3_n2",
          "--provider_dsn=host=127.0.0.1 port=5433 user=lcusr password=password",
          "--replication_sets=ARRAY['default', 'default_insert_only', 'ddl_sql']",
          "--synchronize_structure=true",
          "--synchronize_data=true",
          "--forward_origins='{}'::text[]",
          "--apply_delay='0'::interval",
          "--force_text_transfer=false",
          "--enabled=true"
        ],
        "ignore_errors": false,
        "on_success": {},
        "on_failure": {}
      }
    },
```

In the next step, we wait for the apply worker to check state of the subscription.  This step is optional, but should be considered a *best practice*.  This step uses a SQL command to call the `spock.wait_for_apply_worker` function.

* `$n2.sub_create` is a variable (the subscription ID) populated by the previous `CREATE SUBSCRIPTION` stanza.  
* If needed, use the `sleep` property to accomodate processing time.

Note that if you have more than one replica node, and multiple `CREATE SUBSCRIPTION` stanzas, each stanza should be followed by a copy of this stanza, with the variable reset for each subsequent execution (`$n3.sub_create`, `$n4.sub_create`, etc).

```json
    {
      "sql": {
        "node": "n2",
        "command": "SQL",
        "description": "Wait for apply worker on n2 subscription",
        "sleep": 0,
        "args": [
          "--sql=SELECT spock.wait_for_apply_worker($n2.sub_create, 1000);"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

In our next stanza, we create a subscription between each replica node (`n2`) and our new node (`n3`).  

* `--provider_dsn` is the connection string of the replica node (in our example, the provider is the first node referenced in our subscription).
* `--enabled`, `--synchronize_data`, `--force_text_transfer` and `--synchronize_structure` must be `false`.

If you have multiple replica nodes, you will need one iteration of this stanza for each replica node in your cluster. 

```json
    {
      "spock": {
        "node": "n3",
        "command": "CREATE SUBSCRIPTION",
        "description": "Create a subscription (sub_n2_n3) on (n3) for n2->n3",
        "sleep": 5,
        "args": [
          "--sub_name=sub_n2_n3",
          "--provider_dsn=host=127.0.0.1 port=5432 user=pgedge password=spockpass",
          "--replication_sets=ARRAY['default', 'default_insert_only', 'ddl_sql']",
          "--synchronize_structure=false",
          "--synchronize_data=false",
          "--forward_origins='{}'::text[]",
          "--apply_delay='0'::interval",
          "--force_text_transfer=false",
          "--enabled=false"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

In the next stanza, we use a `CREATE SLOT` command to create a replication slot for the new subscription between our existing replica (`n2`) and our new node (`n3`).  Provide the slot name in the form `spk_database-name_node-name_subscription-name` where:

* `database-name` is the name of your database. 
* `node-name` name of the existing replica node.
* `subscription-name` is the subscription created in the previous step.

You must create one replication slot for each iteration of the CREATE SUBSCRIPTION stanza that allows a replica node to communicate with the new node; if you have three nodes in your cluster (one source node, and two replica nodes), you will need to provide one slot for each replica node (or two slots total). 

```json
    {
      "spock": {
        "node": "n2",
        "command": "CREATE SLOT",
        "description": "Create a logical replication slot spk_pgedge_n2_sub_n2_n3 on (n2)",
        "args": [
          "--slot=spk_pgedge_n2_sub_n2_n3",
          "--plugin=spock_output"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

Next, on each replica node, we invoke a SQL command that starts a sync event between the existing node(`n2`) and our source node (`n1`).  This ensures that our replica nodes stay in sync with the source node for the duration of the ADD NODE process.

The function (`spock.sync_event`) returns the log sequence number (LSN) of the sync event:

```json
    {
      "sql": {
        "node": "n2",
        "command": "SQL",
        "description": "Trigger a sync event on (n2)",
        "sleep": 10,
        "args": [
          "--sql=SELECT spock.sync_event();"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

The previous stanza returns the LSN of the sync event in the `$n2.sync_event` variable; in the next stanza, we watch for that variable so we know when the step is complete.

* `node` specifies the cluster source node (in our example, `n1`).
* `$n2.sync_event` is the LSN returned by the previous stanza.
* If needed, you can use `sleep` to provide extra processing time for the step.

Include this stanza once for each iteration of the previous stanza within your workflow file.

```json
    {
      "sql": {
        "node": "n1",
        "command": "SQL",
        "description": "Wait for a sync event on (n1) for n2-n1",
        "sleep": 0,
        "args": [
          "--sql=CALL spock.wait_for_sync_event(true, 'n2', '$n2.sync_event'::pg_lsn, 1200000);"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

In the next stanza, we create a subscription on our new target node (`n3`) from the source node (`n1`): 

* `arg->--sub_name` is `sub_n1_n3`.
* `arg->--provider_dsn` is the connection string for the source node (our provider, `n1`).
* `--enabled`, `--synchronize_data`,  and `--synchronize_structure` must be `true`.
* `--force_text_transfer` must be `false`. 

```json
    {
      "spock": {
        "node": "n3",
        "command": "CREATE SUBSCRIPTION",
        "description": "Create a subscription (sub_n1_n3) for n1 fpr n1->n3",
        "sleep": 0,
        "args": [
          "--sub_name=sub_n1_n3",
          "--provider_dsn=host=127.0.0.1 port=5431 user=pgedge password=spockpass",
          "--replication_sets=ARRAY['default', 'default_insert_only', 'ddl_sql']",
          "--synchronize_structure=true",
          "--synchronize_data=true",
          "--forward_origins='{}'::text[]",
          "--apply_delay='0'::interval",
          "--force_text_transfer=false",
          "--enabled=true"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

Then, we include a stanza that triggers a sync event on the source node (`n1`) between the source node and the new node (`n3`).  Use the `sleep` property to allocate time for the data to sync to the new node if needed.

```json
    {
      "sql": {
        "node": "n1",
        "command": "SQL",
        "description": "Trigger a sync event on (n1)",
        "sleep": 5,
        "args": [
          "--sql=SELECT spock.sync_event();"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

In the next stanza, we wait for the sync event started in the previous stanza to complete.  Use the `sleep` property to allocate time for the data to sync to the new node if needed.

```json
    {
      "sql": {
        "node": "n3",
        "command": "SQL",
        "description": "Wait for a sync event on (n1) for n1-n3",
        "sleep": 10,
        "args": [
          "--sql=CALL spock.wait_for_sync_event(true, 'n1', '$n1.sync_event'::pg_lsn, 1200000);"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

In the next stanza, we check for data lag between the new node (n3) and any replica nodes in our cluster (n2).  The timestamp returned is passed to the next stanza for use in evaluating the comparative state of the replica nodes and our new node.

```json
    {
      "sql": {
        "node": "n3",
        "command": "SQL",
        "description": "Check commit timestamp for n3 lag",
        "sleep": 1,
        "args": [
          "--sql=SELECT commit_timestamp FROM spock.lag_tracker WHERE origin_name = 'n2' AND receiver_name = 'n3'"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

In the next stanza, we use the timestamp from the previous stanza (`$n3.commit_timestamp`) to advance our replica slot to that location within our log files.  This effectively advances transactions to the time specified (preventing duplicate entries from being written to the replica node).

```json
    {
      "sql": {
        "node": "n2",
        "command": "SQL",
        "description": "Advance the replication slot for n2->n3 based on a specific commit timestamp",
        "sleep": 0,
        "args": [
          "--sql=WITH lsn_cte AS (SELECT spock.get_lsn_from_commit_ts('spk_pgedge_n2_sub_n2_n3', '$n3.commit_timestamp'::timestamp) AS lsn) SELECT pg_replication_slot_advance('spk_pgedge_n2_sub_n2_n3', lsn) FROM lsn_cte;"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

Then, we enable the subscription from each replica node to the new node.  At this point replication starts between any existing node and the new node (`n3`).

```json
    {
      "spock": {
        "node": "n3",
        "command": "ENABLE SUBSCRIPTION",
        "description": "Enable subscription (sub_n2_n3) on n3",
        "args": [
          "--sub_name=sub_n2_n3",
          "--immediate=true"
        ],
        "on_success": {},
        "on_failure": {}
      }
    },
```

After starting replication, we check the lag time between the new node and each node in the cluster.  This step invokes a SQL command that loops through each node in the cluster and compares the lag on each node until each returned value is comparable.  Use the `sleep` property to extend processing time if needed.

```json
    {
      "sql": {
        "node": "n3",
        "command": "SQL",
        "description": "Advance the replication slot for n2->n3 based on a specific commit timestamp",
        "sleep": 0,
        "args": [
          "--sql=DO $$\nDECLARE\n    lag_n1_n3 interval;\n    lag_n2_n3 interval;\nBEGIN\n    LOOP\n        SELECT now() - commit_timestamp INTO lag_n1_n3\n        FROM spock.lag_tracker\n        WHERE origin_name = 'n1' AND receiver_name = 'n3';\n\n        SELECT now() - commit_timestamp INTO lag_n2_n3\n        FROM spock.lag_tracker\n        WHERE origin_name = 'n2' AND receiver_name = 'n3';\n\n        RAISE NOTICE 'n1 → n3 lag: %, n2 → n3 lag: %',\n                     COALESCE(lag_n1_n3::text, 'NULL'),\n                     COALESCE(lag_n2_n3::text, 'NULL');\n\n        EXIT WHEN lag_n1_n3 IS NOT NULL AND lag_n2_n3 IS NOT NULL\n                  AND extract(epoch FROM lag_n1_n3) < 59\n                  AND extract(epoch FROM lag_n2_n3) < 59;\n\n        PERFORM pg_sleep(1);\n    END LOOP;\nEND\n$$;\n"
        ],
        "on_success": {},
        "on_failure": {}
      }
    }
```

The SQL command from the last step (in a more readable format) is:

```sql
  DO $$
    DECLARE
      lag_n1_n3 interval;
      lag_n2_n3 interval;
      BEGIN
        LOOP
          SELECT now() - commit_timestamp INTO lag_n1_n3
            FROM spock.lag_tracker
            WHERE origin_name = 'n1' AND receiver_name = 'n3';
                                        
          SELECT now() - commit_timestamp INTO lag_n2_n3
            FROM spock.lag_tracker
            WHERE origin_name = 'n2' AND receiver_name = 'n3';
                                                        
          RAISE NOTICE 'n1 -> n3 lag: %, n2 -> n3 lag: %',
            COALESCE(lag_n1_n3::text, 'NULL'),
            COALESCE(lag_n2_n3::text, 'NULL');
                                                                                                  
          EXIT WHEN lag_n1_n3 IS NOT NULL AND lag_n2_n3 IS NOT NULL
            AND extract(epoch FROM lag_n1_n3) < 59
            AND extract(epoch FROM lag_n2_n3) < 59;
                                                                                                                                      
          PERFORM pg_sleep(1);
          END LOOP;
        END
    $$;
```
