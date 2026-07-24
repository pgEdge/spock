# Zodan: Zero-Downtime Node Addition for Spock

Zodan adds or removes a node from a Spock cluster with zero downtime for
the existing nodes. It is built into the Spock extension as two procedures,
`spock.add_node` and `spock.remove_node`. All of the orchestration runs
inside Spock and reaches the other nodes over libpq.

There is nothing to install beyond the extension itself. A single
`CREATE EXTENSION spock` makes both procedures available. The `dblink`
extension is not required, and there are no SQL scripts to load.

- `spock.add_node` must be run on the new node being added.
- `spock.remove_node` must be run on the node being removed.

## Adding a node

`spock.add_node` orchestrates the full join: it validates prerequisites,
creates the node, sets up replication slots and subscriptions in both
directions, coordinates synchronization events, advances replication slots
and origins to a consistent point, and enables replication. It supports
both a two node cluster and the general multi node case.

```sql
CALL spock.add_node(
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

In the following example, the command adds node `n4` to the cluster. Run
it while connected to `n4`:

```sql
CALL spock.add_node(
  'n1',
  'host=127.0.0.1 dbname=pgedge port=5431 user=pgedge password=<PASSWORD>',
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```

The `timeout_sec` argument bounds every internal wait loop, so a join that
cannot make progress fails quickly with a clear error rather than blocking
for a long fixed period.

## Removing a node

`spock.remove_node` removes a node in the correct order: it drops the
inbound subscriptions on each surviving node, drops the subscriptions local
to the node being removed, drops the node's replication sets, and finally
drops the node from the catalog. Replication slot and origin cleanup is
handled as part of dropping the subscriptions. A surviving node that cannot
be reached during teardown is skipped with a warning rather than aborting
the removal.

```sql
CALL spock.remove_node(
  target_node_name => 'target_node_name',
  target_node_dsn  => 'target_dsn',
  verbose_mode     => true             -- verbose progress output, optional
);
```

In the following example, the command removes node `n4` from the cluster.
Run it while connected to `n4`:

```sql
CALL spock.remove_node(
  'n4',
  'host=127.0.0.1 dbname=pgedge port=5434 user=pgedge password=<PASSWORD>'
);
```
