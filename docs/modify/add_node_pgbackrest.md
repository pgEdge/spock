# Adding a Node with pgBackRest

You can use a pgBackRest backup to populate a new cluster node, and then
add that node to your cluster with the Spock extension. In the following
high-level walkthrough, we walk through the steps you can use to add a
fourth node (`n4`) to a three-node cluster (`n1`, `n2`, and `n3`).

1. Create a 
   [pgBackRest stanza](https://pgbackrest.org/user-guide.html#quickstart/create-stanza).
   This step is required as the stanza defines the cluster configuration,
   which is essential for backup and restore operations.

2. Perform a full backup of your primary node, `n1`. The backup can be
   stored in an S3 bucket, a network-shared folder, or a local directory
   (if all nodes are on the same machine).

3. [Restore the backup](https://pgbackrest.org/user-guide.html#restore)
   from `n1` to the data directory of `n4`. This prepares `n4` to
   become a replica of `n1`.

4. Configure streaming replication on `n4`, making the node a replica of
   `n1`. This ensures that `n4` contains all transactions on `n1` since
   the backup was taken, ensuring `n4` is 100 percent synchronized with
   `n1`.

5. Use the `ALTER` command to set nodes `n1`, `n2`, and `n3` to
   read-only mode and reload the configuration on these nodes to apply
   the changes. This step is crucial because `n4` has configurations
   copied from `n1` that are not valid for `n4`. By making the nodes
   read-only, you ensure no transactions occur while you modify the
   configurations.

6. Terminate all ongoing transactions on `n1`, `n2`, and `n3`. This
   prevents any long-running queries from interfering during the
   configuration changes.

7. Edit the `shared_preload_libraries` parameter on `n4`, removing
   `spock`. This prevents Spock from using the old configuration from
   `n1` on `n4`.

8. Start `n4`, allowing the node to become a replica of `n1`. This step
   ensures that `n4` contains all transactions from `n1`.

9.  Promote `n4` to the role of primary node or configure the node as a
   standalone node with Spock disabled. This step finalizes `n4` as the
   new primary node in your replication setup.

10. Remove all replication sets and nodes from the configuration. This
    clears any old replication configurations that are no longer needed.

11. Re-add `spock` to the `shared_preload_libraries` parameter on `n4`.
    This prepares `n4` to handle replication in the new role.

12. Restart `n4` to apply the changes made in the previous steps.

13. Reintegrate `n4` into the replication cluster with `n1`, `n2`, and
    `n3`.

14. Remove the read-only mode from `n1`, `n2`, and `n3`, allowing them
    to resume normal operations.

15. Add the following subscriptions between the new node (`n4`) and
    Nodes 1, 2, and 3 (`n1`, `n2`, `n3`):

    - The `subn1n4` subscription syncs n1 with n4.
    - The `subn2n4` subscription syncs n2 with n4.
    - The `subn3n4` subscription syncs n3 with n4.
    - The `subn4n1` subscription syncs n4 with n1.
    - The `subn4n2` subscription syncs n4 with n2.
    - The `subn4n3` subscription syncs n4 with n3.

16. Verify that all nodes (`n1`, `n2`, `n3`, and `n4`) are properly
    configured and synchronized within the cluster. Ensure that
    replication is functioning as expected by checking the status of all
    nodes.

