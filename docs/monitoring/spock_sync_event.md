# Using spock.sync_event to Confirm Synchronization

`spock.sync_event` enables event tracking and synchronization between a
provider and a subscriber node in a Spock logical replication setup. You can
use `spock.sync_event` to ensure that all changes up to a specific point
(indicated by the PostgreSQL Log Sequence Number or LSN) on the provider have
been received and applied on the subscriber.

To mark the start of the sync event and return the LSN of the event on the
subscriber node, you call a function on the node you have selected to act as
a provider node:

`spock.sync_event()`

Then, you monitor a procedure on the node you have selected to act as the
subscriber node that detects the presence of the LSN, and confirms when it
has been received and applied:

`spock.wait_for_sync_event(...)` (see the [Synopsis](#synopsis) for the
required arguments)

## Synopsis

Invoked on the provider node, this function returns the current `pg_lsn`
value, representing a point-in-time value for your replication scenario. The
syntax of `spock.sync_event` is:

`spock.sync_event(transactional boolean DEFAULT false) RETURNS pg_lsn`

When `transactional` is `false` (the default), the sync event marker is
emitted into the WAL stream immediately, independent of the calling
transaction. When `transactional` is `true`, the marker is bound to the
calling transaction and is only visible to subscribers if the transaction
commits.

Invoked on a subscriber node, `spock.wait_for_sync_event` is available in two
flavors - the first uses the origin_id (an `oid`) as an identifier for the
node, while the second uses the node name as an identifier:

- `spock.wait_for_sync_event(OUT result boolean, origin_id oid, lsn pg_lsn,
  timeout int DEFAULT 0, wait_if_disabled bool DEFAULT false)`

- `spock.wait_for_sync_event(OUT result boolean, origin name, lsn pg_lsn,
  timeout int DEFAULT 0, wait_if_disabled bool DEFAULT false)`

This procedure waits on the subscriber node to alert you when the specified
LSN (from the provider) is received and applied to the node.

Parameters:

- `origin_id` or `origin`: Identifies the provider node (by OID or name).
- `lsn`: The target LSN to wait for.
- `timeout`: (Optional) Number of seconds to wait before timing out. The
  default is 0 (wait indefinitely).
- `wait_if_disabled`: (Optional) Controls how a missing or disabled
  subscription is handled. The default is `false`.

  When `wait_if_disabled` is `false` (the default), the procedure requires the
  subscription from the origin node to this node to already exist and be
  enabled. It raises an error if no such subscription is found, or if the
  subscription is disabled at any point while waiting:

  ```
  ERROR:  No subscription found for replication 16443 => 16444
  ERROR:  Subscription 16443 => 16444 has been disabled
  ```

  When `wait_if_disabled` is `true`, neither condition is an error. The
  procedure keeps polling until the subscription exists, becomes enabled, and
  reaches the target LSN, or until `timeout` expires. Use this when the
  subscription may not be ready yet - for example on a newly added node whose
  subscriptions are still being created, or while a subscription is
  temporarily disabled during a maintenance operation. Because a missing
  subscription is not reported, pass a non-zero `timeout` so a subscription
  that is never created does not wait forever.

  `wait_if_disabled` only affects the subscription checks. It does not
  suppress the argument validation both flavors perform first, so these are
  still raised immediately regardless of its value:

  ```
  ERROR:  Origin node 'provider_node' not found
  ERROR:  Invalid NULL origin_id
  ```

  In particular, the name-based flavor requires the origin node to already be
  registered in `spock.node`. If you are waiting on a node that is still
  joining the cluster, that row may not exist yet either - resolve the
  `origin_id` once the node is registered, or retry the call.

Returns:

- `result = true` - LSN has been received and applied.
- `result = false` - Timeout occurred before the LSN was reached. With
  `wait_if_disabled = true` this also covers the case where the subscription
  never existed or never became enabled within the timeout.

## Examples

On a provider node:

`SELECT spock.sync_event();`
`-- Returns: 0/16342B0 (example output)`

On a subscriber node:

```sql
CALL spock.wait_for_sync_event(NULL, 'provider_node', '0/16342B0', 10);
-- result: true  (if applied within 10s), false otherwise
```

The first parameter is the OUT `result` placeholder; pass `NULL` for it in
the `CALL` statement and read the OUT value from the procedure result.

To wait on a node whose subscription may not be created or enabled yet, pass
`wait_if_disabled = true` along with a timeout:

```sql
CALL spock.wait_for_sync_event(NULL, 'provider_node', '0/16342B0', 300, true);
-- result: true once the subscription is enabled and has applied the LSN,
-- false if 300s elapse first (including if the subscription never appeared)
```

