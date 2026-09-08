# Modifying a Cluster with Zodan

Zodan (Zero Downtime Add/Remove Node) adds or removes a node with zero
downtime for the existing nodes. During node addition it manages creation of
the new node, subscription management (both to and from the node), replication
slot creation, data synchronization, replication slot advancement, and final
activation of subscriptions. During node removal it drops the node's
subscriptions, replication sets, slots, and origins in the correct order,
without deleting any Postgres artifacts (the database, data directory, log
files, and so on).

Spock offers two ways to run this workflow. Both perform the same steps and
you can pick whichever fits your environment:

- **In-core procedures (recommended).** `spock.attach_node` and
  `spock.detach_node` are built into the Spock extension. A single
  `CREATE EXTENSION spock` makes them available: there is no script to load
  and no `dblink` dependency. All orchestration runs inside Spock and reaches
  the other nodes over libpq.

- **SQL scripts.** `spock.add_node` and `spock.remove_node` are loaded from
  the SQL scripts in the
  [samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
  directory and reach the other nodes through the `dblink` extension. This
  method is useful where you prefer to keep the orchestration in a script you
  can read and modify.

!!! note

    Whichever method you use, the add procedure (`attach_node` or `add_node`)
    must be run on the new node being added, and the remove procedure
    (`detach_node` or `remove_node`) must be run on the node being removed.

!!! hint

    Zodan simplifies removing partially added nodes created during failed node
    add operations. Additional cleanup steps may be required before attempting
    another node deployment on the target host.

## Key Differences Between using Zodan and the Manual Process

The following differences highlight how Zodan automates and simplifies node
addition:

- Zodan stores sync LSNs and uses them later to ensure subscriptions start
  from the correct point even if time passes between steps.

- Zodan verifies all nodes run a compatible Spock version before starting.

- Zodan waits for each new subscription to reach the replicating state before
  proceeding.

- When adding to a single-node cluster, Zodan handles the process
  differently, since no disabled subscriptions are needed.

- With the in-core procedures, every internal wait is bounded by the
  `timeout_sec` argument (default 180 seconds), so a join that cannot make
  progress fails quickly instead of blocking. Pass a larger `timeout_sec` if
  your environment needs more headroom.

For more information, review the following resources:

- [Using Zodan](zodan_readme.md)
- [Zodan Tutorial](zodan_tutorial.md)
- [Zodan Scripts and Workflows](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
- [Spock Documentation](https://docs.pgedge.com/spock-v5/)
