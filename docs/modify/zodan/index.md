# Modifying a Cluster with Zodan

Zodan provides tools to add or remove a node **with zero downtime**. The scripts are located in the [samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN) directory of the [Spock Github](https://github.com/pgEdge/spock) repository.

**During Node Addition** Zodan seamlessly manages creation of the new node, subscription management (both to and from the node), replication slot creation, data synchronization, replication slot advancement, and final activation of subscriptions.

**During Node Removal** Zodan also simplifies removing fully-functional or failed nodes from a cluster. When you remove a node from a cluster, the removal does not delete Postgres artifacts (the database, data directory, log files, etc.).

!!! hint

Zodan simplifies removing partially added nodes created during failed node add operations. Additional clean up steps may be required before attempting another node deployment on the target host.

!!! note

    Each script must be run from the target node being added or removed.

**Zodan Use Cases**

| Use Case                           | Use `zodan.py` & `zodremove.py` | Use `zodan.sql` & `zodremove.sql` |
| ---------------------------------- | :-----------------------------: | :-------------------------------: |
| CLI automation / scripting         | ✅                              |                                   |
| SQL-only environments              |                                 | ✅                                |
| No Python or shell access          |                                 | ✅                                |
| Postgres extension workflows       | ✅                              | ✅                                |

