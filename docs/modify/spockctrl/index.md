# Using Spockctrl to Manage a Cluster

Spockctrl is a command-line utility designed to simplify the management of a multi-master replication setup for Postgres. It provides a convenient interface for common tasks such as:

*   **Node Management**: Creating, dropping, and listing nodes within your Spock cluster.
*   **Replication Set Management**: Defining and modifying the replication sets that control which data is replicated.
*   **Subscription Management**: Creating, dropping, and managing subscriptions between nodes to initiate and control replication.
*   **Executing SQL**: Running ad-hoc SQL commands against your database nodes.
*   **Workflow Automation**: Running predefined sets of operations (workflows) to perform complex tasks like adding a new node to the cluster.

This section will guide you through the process of building, configuring, and using `spockctrl` to manage your Spock replication environment.

Note that spockctrl is not a core component of the pgEdge Distributed or Enterprise Postgres product.

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

The configuration file contains the information necessary for `spockctrl` to connect to your Postgres instances and manage the Spock extension.  Refer to the `spockctrl/spockctrl.json` file in the [source distribution](https://github.com/pgEdge/spock/blob/main/utils/spockctrl/spockctrl.json) for the most up-to-date structure and available options.

!!! warning

    You should ensure that the `spockctrl.json` file has the correct permissions to prevent unauthorized access to database credentials.

### Example: Manually Creating a Two-Node Cluster

Before using spockctrl to deploy and configure a two-node (provider and subscriber) replication scenario, you must:

1. Install and verify two Postgres instances.
2. Install and create (using `CREATE EXTENSION spock;`) the Spock extension on both instances.
3. Configure the `postgresql.conf` file on both nodes for logical replication.
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

Sample workflow files are available in the [spockctrl GitHub repository](https://github.com/pgEdge/spock/tree/main/utils/spockctrl/workflows).

For detailed information about using a workflow, and to review a walkthrough of a Spockctrl workfile, visit [here](spockctrl_workflow.md).

