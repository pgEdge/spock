# spock.startup_gate_open

The `spock.startup_gate_open()` function opens the startup gate of the
current database.

## Synopsis

```sql
spock.startup_gate_open()
```

## Returns

The function returns `true` if the gate was closed and is now open, and
`false` if the gate was already open or was not set up at server start.

## Description

When `spock.max_lag_for_availability_on_startup` is set, a restarted node
rejects the statements of ordinary sessions until its subscriptions have
caught up with their providers. This function ends the wait and lets the
node serve sessions at once. The subscriptions keep catching up in the
background.

Use it when a provider is down and you do not want to wait for
`spock.startup_drain_timeout`, or when the timeout is set to `0`.

Only a superuser can call this function. The gate stays open until the
next server start.

See [Keeping a Restarted Node Closed Until It Catches Up](../../managing/startup_gate.md)
for details.

## Arguments

This function takes no arguments.

## Example

```sql
SELECT spock.startup_gate_open();
 startup_gate_open
-------------------
 t
(1 row)
```
