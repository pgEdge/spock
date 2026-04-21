# Modifying a Cluster with Zodan

Zodan provides tools to add or remove a node with zero downtime. The
scripts are located in the 
[samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock) repository.

During node addition, Zodan seamlessly manages creation of the new node,
subscription management (both to and from the node), replication slot
creation, data synchronization, replication slot advancement, and final
activation of subscriptions.

During node removal, Zodan simplifies removing fully-functional or failed
nodes from a cluster. When you remove a node from a cluster, the removal
does not delete Postgres artifacts (the database, data directory, log
files, etc.).

!!! hint

    Zodan simplifies removing partially added nodes created during failed
    node add operations. Additional cleanup steps may be required before
    attempting another node deployment on the target host.

!!! note

    Each script must be run from the target node being added or removed.

## Zodan Use Cases

The following table describes when to use the Python scripts versus the
SQL scripts:

| Use Case                           | Use `zodan.py` & `zodremove.py` | Use `zodan.sql` & `zodremove.sql` |
| ---------------------------------- | :-----------------------------: | :-------------------------------: |
| CLI automation or scripting        | Good                            |                                   |
| SQL-only environments              |                                 | Good                              |
| No Python or shell access          |                                 | Good                              |
| Postgres extension workflows       | Good                            | Good                              |


## Key Differences Between using Zodan and the Manual Process

The following differences highlight how Zodan automates and simplifies
node addition:

- Zodan stores sync LSNs and uses them later to ensure subscriptions
  start from the correct point even if hours pass between steps.

- Zodan automatically detects existing schemas on n4 and populates the
  `skip_schema` parameter, preventing conflicts during structure sync.

- Zodan verifies all nodes run the same Spock version before starting.

- Zodan includes the `verify_subscription_replicating()` function after
  enabling subscriptions to ensure they reach replicating status.

- Zodan handles 2-node scenarios differently. No disabled subscriptions
  are needed when adding to a single-node cluster.

- Zodan shows final status of all nodes and subscriptions across the
  entire cluster, not just the new node.


For more information, review the following resources:

- [Using Zodan](zodan_readme.md)
- [Zodan Tutorial](zodan_tutorial.md)
- [Zodan Scripts and Workflows](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
- [Spock Documentation](https://docs.pgedge.com/spock-v5/)

