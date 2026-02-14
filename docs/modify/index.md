# Adding a Node to a Replicating Cluster

There are several tools and scripts you can use to add a node to a cluster; the way that you choose should depend on the use and state of your cluster:

* **Use Z0DAN to Add or Remove a Node with Zero Downtime**

[Z0DAN](../modify/zodan/index.md) is a spock utility that provides scripts that you can use to seamlessly add or remove a node from your cluster with zero downtime.

* **Use pgBackRest to Add a Node to a Replicating Cluster with Minimal Downtime**

[pgBackRest](add_node_pgbackrest.md) is an open-source tool that you can use add a node to a replicating cluster with minimal interruption.

* **Use Spockctrl to manage aspects of your Spock replication setup.**

The [Spockctrl utility](spockctrl/index.md) is appropriate for use in production clusters that can't be taken out of production.

* **Recover from a catastrophic node failure**

If a node fails unexpectedly and another node is left behind (for example, due to network delay), you can use [ACE to recover the lagging node](../recovery/catastrophic_node_failure.md) and bring it back in sync with the rest of the cluster.

