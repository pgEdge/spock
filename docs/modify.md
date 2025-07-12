
# Modifying a Cluster

There are several ways to add a node to a cluster; the way that you choose should depend on the use and state of your cluster:

* **Manually Adding a Node with Zero Downtime**

You can manually add a node to your cluster with zero downtime; follow the steps [outlined here](/docs/zodan.md).

* **Adding a Node to a Replicating Cluster with Minimal Downtime**

You can safely add a node to a replicating cluster with minimal interruption to your cluster with pgBackRest; the technique is outlined [here](/docs/add_node_pgbackrest.md).

* **Adding a Node to a Replicating Cluster with spockctrl**

You can use the [spockctrl utility](/docs/spockctrl.md) to add a node to a production cluster with zero-downtime.  This method is appropriate for production clusters that can't be taken out of production, but that need to replace nodes or expand their cluster to include new nodes.

* **Adding a Subscriber Node to an Empty Cluster**

You can use `pg_basebackup` to [add a node to an empty cluster](/docs/creating_subscriber_nodes.md) and start it as a Spock subscriber. This method is a good way to quickly increase the size and distribution of an empty cluster that is still in development; it is not recommended for production clusters. 
