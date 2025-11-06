# Adding a Node to a Replicating Cluster

There are several tools and scripts you can use to add a node to a cluster; the way that you choose should depend on the use and state of your cluster:

* **Z0DAN allows you to add a Node with Zero Downtime**

[Z0DAN](../modify/zodan/index.md) is a spock utility that provides scripts that you can use to seamlessly add or remove a node from your cluster with zero downtime.

* **pgBackRest adds a Node to a Replicating Cluster with Minimal Downtime**

[pgBackRest](add_node_pgbackrest.md) is an open-source tool that you can use add a node to a replicating cluster with minimal interruption.

* **spockctrl adds a node to a cluster with Zero Downtime**

The [Spockctrl utility](https://docs.pgedge.com/spock_ext/modify/spockctrl) is appropriate for use in production clusters that can't be taken out of production, but that need to replace nodes or expand their cluster to include new nodes.

