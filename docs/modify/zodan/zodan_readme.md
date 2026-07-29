# Using Zodan: Zero-Downtime Node Addition and Removal

Zodan adds or removes a node from a Spock cluster with zero downtime for the
existing nodes. Spock ships two implementations of the same workflow: the
in-core procedures `spock.attach_node` / `spock.detach_node`, and the SQL
scripts that provide `spock.add_node` / `spock.remove_node`. Both are covered
below.

## In-core procedures: attach_node and detach_node

The in-core implementation is built into the Spock extension. A single
`CREATE EXTENSION spock` makes both procedures available. There is nothing to
install beyond the extension itself: the `dblink` extension is not required,
and there are no SQL scripts to load. All local work runs over SPI and all
cross-node work runs over libpq.

- `spock.attach_node` must be run on the new node being added.
- `spock.detach_node` must be run on the node being removed.

### Adding a node

`spock.attach_node` orchestrates the full join: it validates prerequisites,
creates the node, sets up replication slots and subscriptions in both
directions, coordinates synchronization events, advances replication slots and
origins to a consistent point, and enables replication. It supports both a two
node cluster and the general multi node case.

```sql
CALL spock.attach_node(
  src_node_name     => 'source_node_name',
  src_dsn           => 'src_dsn',
  new_node_name     => 'new_node_name',
  new_node_dsn      => 'new_node_dsn',
  verb              => false,          -- verbose progress output, optional
  new_node_location => 'NY',           -- optional
  new_node_country  => 'USA',          -- optional
  new_node_info     => '{}'::jsonb,    -- optional metadata
  timeout_sec       => 180             -- bound on each wait, optional
);
```

In the following example, the command adds node `n4` to the cluster. Run it
while connected to `n4`:

```sql
CALL spock.attach_node(
  'n1',
  'host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=<PASSWORD>',
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```

The `timeout_sec` argument bounds every internal wait loop, so a join that
cannot make progress fails quickly with a clear error rather than blocking for
a long fixed period. It defaults to 180 seconds; pass a larger value if your
environment needs more headroom.

### Removing a node

`spock.detach_node` removes a node in the correct order: it drops the inbound
subscriptions on each surviving node, drops the subscriptions local to the
node being removed, drops the node's replication sets, and finally drops the
node from the catalog. Replication slot and origin cleanup is handled as part
of dropping the subscriptions. A surviving node that cannot be reached during
teardown is skipped with a warning rather than aborting the removal.

```sql
CALL spock.detach_node(
  target_node_name => 'target_node_name',
  target_node_dsn  => 'target_dsn',       -- accepted for symmetry, not used
  verbose_mode     => true             -- verbose progress output, optional
);
```

`detach_node` runs on the node being removed and does all of its work locally
and against the surviving nodes it already knows about, so `target_node_dsn`
is currently accepted for signature symmetry with `spock.remove_node` but is
not used. Pass any value (for example the node's own DSN).

In the following example, the command removes node `n4` from the cluster. Run
it while connected to `n4`:

```sql
CALL spock.detach_node(
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```

## SQL scripts: add_node and remove_node

The SQL-based implementation uses the Postgres `dblink` extension to run the
same node add and remove operations from within the database. The scripts are
located in the
[samples/Z0DAN](https://github.com/pgEdge/spock/tree/main/samples/Z0DAN)
directory of the [Spock GitHub](https://github.com/pgEdge/spock) repository.
This method is useful where you prefer to keep the orchestration in a script
you can read and modify. Load `zodan.sql` and `zodremove.sql` on the node you
run the procedures from, and make sure `dblink` is installed there.

### Adding a node with zodan.sql

The `zodan.sql` workflow orchestrates the following operations:

- `add_node` - the main procedure to orchestrate the full workflow.
- `create_node` - register the new node via `spock.node_create`.
- `get_spock_nodes` - fetch current node metadata from a remote node.
- `create_sub` and `enable_sub` - manage subscription creation and activation.
- `create_replication_slot` - create and configure logical replication slots.
- `sync_event` and `wait_for_sync_event` - coordinate data synchronization
  events.
- `get_commit_timestamp` and `advance_replication_slot` - align replication
  states.

To use the workflow, load `zodan.sql` and call `spock.add_node`. In the
following example, the command adds node `n4` to the cluster:

```sql
CALL spock.add_node(
  'n1',
  'host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=<PASSWORD>',
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```

### Removing a node with zodremove.sql

The `zodremove.sql` workflow orchestrates the following operations:

- `spock.remove_node` - the main procedure to orchestrate the full workflow.
- `spock.remove_node_subscriptions` - removes subscriptions, and the
  replication slot once no subscriptions remain.
- `spock.remove_node_replication_sets` - removes published repsets on the node
  being removed.
- `spock.remove_node_from_cluster_registry` - removes the node from the
  cluster.

To use the workflow, load `zodremove.sql` and call `spock.remove_node`. Note
that `spock.remove_node` is a Zodan utility procedure provided by
`zodremove.sql`; it is not a built-in function of the Spock extension. In the
following example, the command removes node `n4` from the cluster:

```sql
CALL spock.remove_node(
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```
