# Keeping a Restarted Node Closed Until It Catches Up

While a node is down, the other nodes keep taking writes. When the node
starts again, PostgreSQL accepts connections right away, but the apply
workers still have to work through the changes made during the outage. Until
they are done, reads on the node return old data, and writes are made on old
rows and can conflict with the changes that are still on their way.

The startup gate closes this window. When it is on, a restarted node rejects
the statements of ordinary sessions until every enabled subscription is
close enough to its provider. The gate is off by default.

## Turning the Gate On

Set `spock.max_lag_for_availability_on_startup` to the lag you accept. The
node opens once every subscription is at most this far behind its provider:

```ini
spock.max_lag_for_availability_on_startup = '30s'
spock.startup_drain_timeout = '5min'
```

`spock.startup_drain_timeout` is the longest time the node waits. When the
time is up the node opens anyway and writes a warning to the log. The
default, `0`, waits without limit: a peer that is down keeps the node
closed until a superuser opens it with `spock.startup_gate_open()`. Set a
timeout if you prefer the node to come back on its own. Set `-1` to wait
without limit for the providers that can be reached and not for the others:
a subscription whose apply worker has failed to connect three times in a
row is set aside, and the gate opens once the rest have caught up.

The gate is set up at server start, so
`spock.max_lag_for_availability_on_startup` has to be set before the node is
started. Both settings can be changed with a reload while the gate is
closed. Setting `spock.max_lag_for_availability_on_startup` to `0` and
reloading opens the gate.

The gate is closed only at server start. An apply worker that restarts, or
a network problem between the nodes, does not close it again. A standby has
no gate.

## What Sessions See

While the gate is closed, a statement fails with SQLSTATE `57P03`:

```
ERROR:  spock node is catching up with its peers after a restart
HINT:  Retry later, or connect to another node.
```

This is the SQLSTATE PostgreSQL uses while it is starting up, so clients
and poolers that retry on it need no change. Reads and writes are both
rejected. The following are not held back:

- Superusers, roles with the `REPLICATION` attribute, and members of
  `pg_monitor`.
- `SET`, `RESET`, `SHOW`, `DISCARD` and transaction control statements.
- Databases without the Spock extension.

A connection to a closed node still succeeds. A health check that only
tests the connection, such as `pg_isready`, reports the node as up. Use a
check that runs a query, or read `spock.startup_status`.

## How the Node Decides It Has Caught Up

Each apply worker catches up in rounds:

1. The worker asks the provider for its current WAL position. This is the
   target of the round.
2. The worker applies changes as usual until it reaches the target.
3. The worker asks the provider for its position again. If the provider has
   not moved, the subscription has caught up. It has also caught up if this
   is at least the second round and the round took no longer than
   `spock.max_lag_for_availability_on_startup`. Otherwise the worker starts
   a new round.

When a round ends, the worker has applied everything the provider had when
the round started, so the node is behind by no more than the length of the
round. Both times are read from the local clock, so a clock difference
between the nodes does not matter.

For example, with a setting of `30s` and a node that was down for ten
minutes, the first round applies the whole backlog and may take 80 seconds.
That is too long, so a second round starts. It only has to apply what
arrived during the first round, and takes 12 seconds. The subscription has
caught up. The worker always does a second round when the provider moved
during the first, even if the first was short, so that the changes made
during the first round are applied too.

The gate waits only for subscriptions that were replicating before the
restart. A subscription that is disabled, or still in its initial
synchronization, is not waited for. If `spock.readonly` is `all`, nothing
is applied, so the gate is not closed.

## Watching the Drain

The `spock.startup_status` view has one row for each subscription the gate
waits for:

```sql
SELECT gate_state, gate_reason, subscription_name, drain_state,
       round, last_round_time, timeout_left
  FROM spock.startup_status;
```

| Column | Description |
|--------|-------------|
| `gate_state` | `draining` while the gate is closed, `open` afterwards. |
| `gate_reason` | Why the gate is open: `drained`, `timeout`, `manual`, `disabled` or `not applicable`. |
| `drain_started`, `gate_opened` | When the drain started and when the gate opened. |
| `timeout_left` | Time left before the gate opens on timeout. |
| `rejected_statements` | Number of statements turned away. |
| `subscription_name`, `provider_node` | The subscription and its provider. |
| `drain_state` | `pending`, `catching up`, `caught up`, `removed`, or `set aside` for an unreachable provider with a timeout of `-1`. |
| `round` | Number of the current round. |
| `target_lsn`, `received_lsn` | Provider position the round has to reach, and the position received so far. |
| `round_started`, `round_time` | Start of the current round and how long it has been running. |
| `last_round_time` | Length of the last finished round. |

The view is empty when the gate was not set up at server start. The server
log has a line for the start of the drain, for the end of each round and
for the opening of the gate. The `spock.events` view records the events
`startup_drain_started`, `startup_drain_completed` and
`startup_drain_timed_out`.

## Opening the Gate by Hand

A superuser can open the gate of the current database at any time:

```sql
SELECT spock.startup_gate_open();
```
