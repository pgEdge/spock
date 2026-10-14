# no-orphan-slot-pins-wal-after-quiesce

## Summary

Each Spock subscription owns a logical slot on its provider
(`spk_<db>_<provider>_<sub>`, `gen_slot_name`, `src/spock_functions.c:3666-3687`),
and each table resync temporarily owns a second one
(`<sub slot>_<8 hex>`, `src/spock_sync.c:2012-2016`). A slot with no consumer
pins WAL (and catalog xmin) on the provider for ever unless
`max_slot_wal_keep_size` is set, which Spock does not set or document beyond a
mention in `docs/managing/read_only.md:80`. Over a long run, or in production,
that ends with the provider's disk filling up and the provider stopping.

Code reading found several ways a Spock slot loses its owner:

| Path | Code | Orphan |
|---|---|---|
| `sub_drop` with provider unreachable | `src/spock_functions.c:845-859`: `PG_TRY` around the drop; on failure `WARNING "could not drop slot ... you will probably have to drop it manually"` | subscription slot (known, warned) |
| `sub_drop` while a table resync runs | sub_drop kills only the apply worker (`:808-835`) and the manager only kills APPLY workers (`spock_manager.c:158-175`). The sync worker keeps going until its next `set_table_sync_status` fails with "status not found" (`spock_sync.c:2607`) outside any cleanup block, or it sits in CATCHUP holding the slot while no traffic arrives (L28). Contradicts `docs/spock_functions/functions/spock_sub_drop.md` ("removes all associated metadata") | table-sync slot, **no warning** |
| initial sync killed by SIGKILL in `s/d/c` | `PG_ENSURE_ERROR_CLEANUP` runs only on ERROR/FATAL (`src/spock_sync.c:1480-1810`, L13) | subscription slot until the subscription is dropped and re-created |
| table-sync worker killed in CATCHUP, table then FAILED | dropped by the next sync attempt's cleanup (`:1429-1468`) only if the apply worker starts one. If the subscription is disabled or dropped first, it stays | table-sync slot |
| `spock_sync_worker_cleanup` waiting on an active slot | loops `while (!got_SIGTERM)` until the slot is inactive (`:1438-1455`); a SIGTERM exits the loop and then tries the drop anyway, which fails while active | either |
| ZODAN add_node failure mid-way | Phase 3 creates slots on every peer before the subscriptions exist (`samples/Z0DAN/zodan.sql:1794+`); orchestrator death leaves them. `zodan_cleanup.sql` / `remove_node` are the documented cleanup (L20) | peer slots for the new node |

A slot that **has** an owner can also pin WAL if its walsender is stuck (for
example the apply worker is stuck in a hang described by another property). The
check below catches both, because it asks for `confirmed_flush_lsn` progress and
not only for ownership.

## Property

After faults stop, documented cleanup has run, and the cluster has quiesced,
every logical slot on every node that uses the `spock_output` plugin (a)
belongs to a live subscription (or a table sync in progress), and (b) has
`confirmed_flush_lsn` at or past a marker LSN taken on that node after
quiescence began. No slot keeps WAL pinned without a consumer.

## Assertions (all missing)

Workload-side, in the final (and any intermediate) quiescent check. Use three
separate messages:

1. `Always(orphan_spock_slots == 0, "no spock slot without owning subscription after quiesce")`:
   `SELECT slot_name FROM pg_replication_slots WHERE plugin='spock_output'` on
   provider P, minus the `sub_slot_name` of every subscription on every live
   node whose provider is P, minus `<sub_slot_name>_%` slots of tables whose
   `spock.local_sync_status` is not READY/FAILED.
2. `Always(lagging_owned_slots == 0, "every owned spock slot confirms past the quiesce marker")`:
   on each P take `m = pg_current_wal_lsn()` after a `spock.sync_event()`; after
   `wait_for_sync_event` succeeds on every subscriber, every owned slot must have
   `confirmed_flush_lsn >= m`. Allow at least `apply_idle_timeout` + 5 s.
3. `Sometimes(orphan_slot_dropped_with_warning, "sub_drop could not reach provider")`
   from the log, so the run shows the warned path happened. The workload then
   drops those slots itself (as the warning tells an operator to), and check 1
   runs after that.

`Always` at the quiescent check fits: once the system is quiet and cleanup has
run, a leftover slot is wrong whenever the check runs, not only eventually.

## Scope (avoid false positives; sut-analysis §12)

- Drop slots named in a "could not drop slot" WARNING before checking. That path
  is documented.
- After a failed add_node, run `zodan_cleanup.sql` / `remove_node` as the docs
  say before checking.
- Permanent node loss is out of scope. All nodes must be up at the check.
- Interrupted initial sync leaving a disabled subscription is expected. Its slot
  still counts as owned (the subscription row exists), so it is caught by check
  2 only. Leave out disabled subscriptions from check 2 and record them instead.

## Fault requirements

- Partition provider<->subscriber during `remove_node` / `sub_drop`.
- Kill or partition during `sub_resync_table` and initial sync.
- Kill the add_node orchestrator mid-way.

## Open questions

- None remaining. See the Investigation Log for the two questions resolved on
  2026-10-13.

### Investigation Log

#### Should `sub_drop` stop running sync workers and drop their slots?

- Examined: `spock_drop_subscription` (`src/spock_functions.c:762-870`);
  manager loop (`src/spock_manager.c:45-175`) and `spock_apply_find_all`
  (`src/spock_worker.c:539-554`); sync worker main and table sync
  (`src/spock_sync.c:1840-1913, 2002-2090`); `set_table_sync_status`
  (`:2570-2610`); `wait_for_sync_status_change` (`:2638-2690`);
  `docs/spock_functions/functions/spock_sub_drop.md`.
- Found: `sub_drop` deletes the sync-status rows, kills the apply worker and
  drops only `sub->slot_name` on the provider. The manager collects only
  APPLY workers, so it never kills the sync worker either. What the sync
  worker does next depends on its phase:
  - before COPY starts: `set_table_sync_status(DATA)` fails inside
    `PG_ENSURE_ERROR_CLEANUP`, so the remote table-sync slot **is** dropped
    (the local origin is not; see `replication-origin-states-do-not-leak`).
  - after COPY: `set_table_sync_status(SYNCWAIT)` fails outside the cleanup
    block, so the worker exits and the table-sync slot is left.
  - in SYNCWAIT: the wait loop sees the row gone and returns with `lsn`
    invalid; `Assert(lsn == status_lsn)` (`:2042`) fails in an assert build
    (node crash restart); otherwise it goes on to set SYNCDONE, fails, and
    leaves the slot.
  - in CATCHUP: it keeps its walsender and slot until it reaches
    `replay_stop_lsn`, then fails the same way.
  The user docs say `sub_drop` "removes all associated metadata from the Spock
  catalogs" and "terminates the replication connection".
- Conclusion: resolved. Leaving the table-sync slot behind contradicts the
  documented behaviour, so it counts as a defect. Check 1 must **not** list
  table-sync slots of dropped subscriptions as expected leftovers.

#### Is a `max_slot_wal_keep_size` recommendation intended?

- Examined: `grep -rn max_slot_wal_keep_size docs/ samples/ src/ tests/`;
  `docs/managing/read_only.md:72-82`; `tests/run-cluster-upgrade.sh:4659-4672,
  6118-6164` (commit `a1416cb5`).
- Found: no doc recommends a limit. `read_only.md` only says to plan for slot
  retention. The rolling-upgrade procedure makes `max_slot_wal_keep_size = -1`
  (unlimited) a hard requirement on every peer ("req 3 ... every peer retains
  WAL without bound") and sets it to -1 while a node is away.
- Conclusion: resolved. The project's stated stance is unlimited retention,
  so an orphan slot's harm is a growing disk on the provider, as the property
  says. The harness should keep the PG default (-1). A variant with a limit
  would turn the harm into `wal_status = 'lost'` and a broken subscription;
  that is optional and not what the docs describe.
