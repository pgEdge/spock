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

`spock.wait_for_sync_event()`

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
- `wait_if_disabled`: (Optional) If `true`, wait even if the subscription is
  disabled. The default is `false`.

Returns:

- `result = true` - LSN has been received and applied.
- `result = false` - Timeout occurred before the LSN was reached.

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

