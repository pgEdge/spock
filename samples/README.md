## Spock Samples

The `samples` directory includes unmaintained helper tutorials, functions, and procedures for the Spock extension.  Sample programs in this directory should be considered illustrative only, and should be well tested before being used in a production environment.

The content of this directory is subject to change or removal at any time.  To contribute a sample to this directory, open a Pull Request and attach the content; a developer will review the content for inclusion.

### Contents

- `set_synchronized_standby_slots.sh` — Patroni `on_role_change` callback that keeps `synchronized_standby_slots` pointed at the current standby member(s) across switchovers. Reference only; see [`docs/logical_slot_failover.md`](../docs/logical_slot_failover.md) for the rationale.
- `Z0DAN/` — Zero Downtime Add/Remove Node sample scripts.
