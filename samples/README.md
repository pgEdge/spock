## Spock Samples

The `samples` directory includes unmaintained helper tutorials, functions, and procedures for the Spock extension.  Sample programs in this directory should be considered illustrative only, and should be well tested before being used in a production environment.

The content of this directory is subject to change or removal at any time.  To contribute a sample to this directory, open a Pull Request and attach the content; a developer will review the content for inclusion.

### Contents

- `failover/` — helpers for logical slot failover and HA standbys. See [`docs/logical_slot_failover.md`](../docs/logical_slot_failover.md) for the rationale behind both.
  - `enable_failover_slots.sh` — Marks Spock's existing logical replication slots as failover slots, so PostgreSQL's slotsync worker copies them to a standby. Slots are only flagged when created, so subscriptions predating `spock.use_native_failover_slots` keep unflagged slots until this is run. Each slot is flipped in place with `ALTER_REPLICATION_SLOT`, preserving `restart_lsn` and `confirmed_flush_lsn`, so no table data is re-copied. One run covers the whole cluster; supports `--dry-run`. Requires PostgreSQL 17+.
  - `set_synchronized_standby_slots.sh` — Patroni `on_role_change` callback that keeps `synchronized_standby_slots` pointed at the current standby member(s) across switchovers.
- `Z0DAN/` — Zero Downtime Add/Remove Node sample scripts.
