# Adding a Node to a Replicating Cluster

There are several ways to add a node to a cluster; the way that you choose should depend on the use and state of your cluster:

* **Manually Adding a Node with Zero Downtime**

You can manually add a node to your cluster with zero downtime; follow the steps [outlined here](https://docs.pgedge.com/spock_ext/modify/zodan_tutorial) for details.

* **Adding a Node to a Replicating Cluster with Minimal Downtime**

You can safely add a node to a replicating cluster with minimal interruption to your cluster with pgBackRest; the technique is outlined [here](https://docs.pgedge.com/spock_ext/modify/add_node_pgbackrest).

* **Adding a Node to a Replicating Cluster with spockctrl**

You can use the [Spockctrl utility](https://docs.pgedge.com/spock_ext/modify/spockctrl) to add a node to a production cluster with zero-downtime.  This method is appropriate for production clusters that can't be taken out of production, but that need to replace nodes or expand their cluster to include new nodes.

