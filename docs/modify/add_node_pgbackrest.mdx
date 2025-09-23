## Adding a Node with pgBackRest

You can use a pgBackRest backup to populate a new cluster node, and then add that node to your cluster with the Spock extension.  In the following high-level walkthrough, we'll walk through the steps you can use to add a fourth node (`n4`) to a three-node cluster (`n1`, `n2`, and `n3`).

**1. Create a Stanza Using pgBackRest**

Create a [pgBackRest stanza](https://pgbackrest.org/user-guide.html#quickstart/create-stanza). This step is required as it defines the cluster configuration, which is essential for backup and restore operations.

**2. Take a Full Backup of Node 1 (`n1`)**

Perform a full backup of your primary node, `n1`.  The backup can be stored in a:
*  S3 bucket.
*  Network-shared folder.
*  Local directory (if all nodes are on the same machine).

**3. Restore the Backup to Node 4 (`n4`)**

[Restore the backup](https://pgbackrest.org/user-guide.html#restore) from `n1` to the data directory of `n4`; this prepares `n4` to become a replica of `n1`.

**4. Set Up Streaming Replication on Node 4 (`n4`)**

Configure streaming replication on `n4`, making the node a replica of `n1`.  This ensures that `n4` contains all transactions on `n1` since the backup was taken, ensuring `n4` is 100% synchronized with `n1`.

**5. Make Nodes 1, 2, and 3 (`n1`, `n2`, `n3`) Read-Only**

Use the `ALTER` command to set nodes `n1`, `n2`, and `n3` to read-only mode and reload the configuration on these nodes to apply the changes.  This step is crucial because `n4` has configurations copied from `n1` that are not valid for `n4`. By making the nodes read-only, you ensure no transactions occur while you modify the configurations.

**6. Terminate All Transactions on Nodes 1, 2, and 3**

Terminate all ongoing transactions on `n1`, `n2`, and `n3`.  This prevents any long-running queries from interfering during the configuration changes.

**7. Remove Spock from Shared Preload Libraries on `n4`**

Edit the `shared_preload_libraries` parameter on `n4`, removing `spock`;  this prevents Spock from using the old configuration from `n1` on `n4`.

**8. Start Node 4 (`n4`)**

Start `n4`, allowing it to become a replica of `n1`; this step ensures that `n4` contains all transactions from `n1`.

**9. Promote Node 4 (`n4`) to `Primary` or `Standalone`**

Promote `n4` to the role of primary node or configure it as a standalone node with Spock disabled.  This step finalizes `n4` as the new primary node in your replication setup.

**10. Remove All Replication Sets and Nodes**

Remove all replication sets and nodes from the configuration.  This clears any old replication configurations that are no longer needed.

**11. Add Spock to the Shared Preload Libraries parameter on `n4`**

Re-add `spock` to the `shared_preload_libraries` parameter on `n4`.
This prepares `n4` to handle replication in its new role.

**12. Restart Node 4 (`n4`)**

Restart `n4` to apply the changes made in the previous steps.

**13. Add Node 4 (`n4`) to Nodes 1, 2, and 3 (`n1`, `n2`, `n3`)**

Reintegrate `n4` into the replication cluster with `n1`, `n2`, and `n3`.

**14. Remove Read-Only Mode from Nodes 1, 2, and 3 (`n1`, `n2`, `n3`)**

Remove the read-only mode from `n1`, `n2`, and `n3`, allowing them to resume normal operations.

**15. Add Subscriptions Between Nodes**

Add the following subscriptions between the new node (`n4`) and Nodes 1, 2, and 3 (`n1`, `n2`, `n3`)

* `subn1n4` -  This syncs n1 with n4
* `subn2n4` - This syncs n2 with n4
* `subn3n4` - This syncs n3 with n4
* `subn4n1` - This syncs n4 with n1
* `subn4n2` - This syncs n4 with n2
* `subn4n3` - This syncs n4 with n3

**16. List All Nodes from `n1`, `n2`, `n3`, and `n4`**

Verify that all nodes (`n1`, `n2`, `n3`, and `n4`) are properly configured and synchronized within the cluster.  Ensure that replication is functioning as expected by checking the status of all nodes.

