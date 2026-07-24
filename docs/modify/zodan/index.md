# Modifying a Cluster with Zodan

Zodan adds or removes a node with zero downtime. It is built into the Spock
extension as the `spock.add_node` and `spock.remove_node` procedures, so a
single `CREATE EXTENSION spock` is all that is required. The `dblink`
extension is not needed, and there are no SQL scripts to load.

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

    `spock.add_node` must be run on the new node being added, and
    `spock.remove_node` must be run on the node being removed.

## Key Differences Between using Zodan and the Manual Process

The following differences highlight how Zodan automates and simplifies
node addition:

- Zodan stores sync LSNs and uses them later to ensure subscriptions
  start from the correct point even if time passes between steps.

- Zodan verifies all nodes run a compatible Spock version before starting.

- Zodan waits for each new subscription to reach the replicating state
  before proceeding.

- When adding to a single-node cluster, Zodan handles the process
  differently, since no disabled subscriptions are needed.

- Every internal wait is bounded by the `timeout_sec` argument, so a join
  that cannot make progress fails quickly instead of blocking.


For more information, review the following resources:

- [Using Zodan](zodan_readme.md)
- [Zodan Tutorial](zodan_tutorial.md)
- [Spock Documentation](https://docs.pgedge.com/spock-v5/)

