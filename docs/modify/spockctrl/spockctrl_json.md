# Populating the spockctrl.json File

Before using Spockctrl to add a node to your cluster, your cluster information must be added to the `spockctrl.json` file.  The file template is available in the [spock repository](https://github.com/pgEdge/spock/blob/main/utils/spockctrl/spockctrl.json).

!!! warning

    You should ensure that the `spockctrl.json` file has the correct permissions to prevent unauthorized access to database credentials.

Within the template, provide information about your cluster and each node that is in your cluster.  If you are using Spockctrl to add a node to your cluster, you should also add the node details for the new node to this file before invoking `spockctrl`:

## spockctrl.json Properties

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
