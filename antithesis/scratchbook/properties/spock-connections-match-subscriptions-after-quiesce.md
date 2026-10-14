# spock-connections-match-subscriptions-after-quiesce

## Summary

Every Spock connection is opened through `spock_connect_base`
(`src/spock.c:366-475`), which sets `application_name` to
`<subscription name>_<purpose>` (the name part shortened with `shorten_hash`
so the whole string fits NAMEDATALEN). Full list of call sites, checked
2026-10-13 (all connect to the provider unless noted):

| Purpose suffix | Replication (walsender)? | Call site |
|---|---|---|
| `create` | no, yes, and one local | `spock_functions.c:573, 599, 603` (sub_create) |
| `cleanup` | no | `spock_functions.c:847` (sub_drop), `spock_sync.c:1434` |
| `sync` | no | `spock_functions.c:1173` (`spock_alter_subscription_synchronize`, i.e. `sub_alter_sync`) |
| `snap` | no and yes | `spock_sync.c:1563, 1598` (initial sync snapshot) |
| `copy` | no, plus yes at `:1878` | `spock_sync.c:1269, 1334, 1878`; `:1273, 1402` connect to the **local** node |
| `copy_slot` | no | `spock_sync.c:1881` |
| `catchup` | yes | `spock_sync.c:2070` (table-sync catch-up) |
| none: `application_name` = slot name `spk_...` | yes | `spock_apply.c:4756` (apply stream) |

Other libpq users: `spock_failover_slots.c:530` (standby only, out of scope)
and ZODAN's dblink sessions (their own names). Each open connection is a backend
(and for replication connections a walsender, counted against
`max_wal_senders`) on the provider. Leaked or stuck connections use up provider
`max_connections` / `max_wal_senders` and keep logical slots marked active, so
no new consumer can take them over.

Paths found by code reading:

- **SQL functions leak libpq connections on ERROR.** `spock_create_subscription`
  opens `conn = spock_connect(provider_dsn, ...)` and calls
  `spock_remote_node_info(conn, ...)` (`src/spock_functions.c:573-596`). If that
  raises, `conn` is never `PQfinish`ed. The case that leaves a **live**
  provider backend is an ERROR on a healthy connection, for example "the
  remote database is not configured as a spock node" (`spock_rpc.c:314`).
  Same in `sub_alter_sync` (`spock_alter_subscription_synchronize`, `:1173-1175`). Same in `sub_drop`: `spock_drop_remote_slot`
  errors inside the `PG_TRY` and `origin_conn` is not closed (`:845-859`); the
  likely trigger is "remote slot drop failed" because an old walsender still
  holds the slot after a partition (`spock_rpc.c:286-293`), which leaves an
  idle `<sub>_cleanup` backend on the provider **and** the orphan slot. The leak
  lasts until the calling session ends. With ZODAN the caller is often a dblink
  session that ends soon after, but a long-lived admin session (or a workload
  connection pool) keeps it.
- **Sync worker for a dropped subscription keeps running.** `sub_drop` stops
  only the apply worker (`:808-835`). A table-sync worker in CATCHUP keeps
  its walsender on the provider (L28).
- **Old walsender holding the slot after a partition.** A reconnecting
  subscriber's `START_REPLICATION` fails with "slot is active" until the old
  walsender notices (`wal_sender_timeout`, docs recommend 5 min). This is
  degraded but expected. It sets the minimum quiet time for this check.
- **`spock_sync_worker_cleanup`** holds a provider connection while it loops,
  with no time limit, waiting for the slot to become inactive
  (`src/spock_sync.c:1438-1455`).
- The stale-fd / `epoll_ctl(EINVAL)` cascade (`4dfe7496`, `d286f3df`) was the
  same family of problem on the subscriber side. See
  `apply-stale-socket-never-polled`.

## Property

After faults stop and the cluster quiesces for longer than `wal_sender_timeout`,
the Spock connections on each provider are exactly one walsender per enabled
subscription to that provider (plus one per table sync in progress). No
`_create`, `_cleanup`, `_copy`, `_sync` or other short-lived Spock sessions are
left over.

## Assertions (all missing)

Workload-side quiescent check, two separate messages:

1. `Always(extra_walsenders == 0, "spock walsenders match enabled subscriptions after quiesce")`:
   on provider P, `SELECT count(*) FROM pg_stat_replication r JOIN
   pg_replication_slots s ON s.active_pid = r.pid WHERE s.plugin =
   'spock_output'` grouped by slot, compared with the enabled subscriptions
   on all other nodes whose provider is P. Also no `pg_stat_replication` row
   whose `application_name` matches a subscription that no longer exists.
2. `Always(stray_sessions == 0, "no leftover spock helper sessions after quiesce")`:
   `pg_stat_activity` rows on P with `application_name` ending in one of the
   short-lived purpose suffixes (`_create`, `_cleanup`, `_sync`, `_snap`,
   `_copy`, `_copy_slot`, `_catchup`) and `backend_type` either `client backend`
   or `walsender`, minus `_copy` / `_catchup` sessions of a table sync still in
   progress. Match on the suffix only: long subscription names are hashed by
   `shorten_hash`. **Close every workload admin session before this check**
   (and before the quiet period), so a PGconn leaked inside a still-open admin
   session is not counted; what remains are sessions with no live owner, such
   as stuck sync workers or leaks from worker processes.

Both run only after quiet time > `wal_sender_timeout` + `apply_idle_timeout`, so
expected lingering walsenders have timed out.

## Fault requirements

- Partition / RST during `sub_create`, `sub_drop`, `remove_node`, add_node
  phases (for the connection leaks; needs a long-lived calling session, so the
  workload should make admin calls on a reused connection).
- Partition during table resync followed by `remove_node`.
- Provider pause (SIGSTOP) so old walsenders linger and reconnects overlap.

## Open questions

- Is a connection leaked by a failed `sub_create` / `sub_alter_sync` / `sub_drop` in
  the calling session considered a bug, given that it ends with the session?
  Check 2 no longer depends on the answer (admin sessions are closed before
  it runs). If owners call it a bug, add a separate check that keeps one admin
  session open across a failed call. `(needs human input)`

### Investigation Log

#### Exact `application_name` suffixes per call site

- Examined: `grep -rn "spock_connect(\|spock_connect_replica(" src/`;
  `spock_connect_base` (`src/spock.c:366-460`); `PQconnectdb*` users.
- Found: the table in the Summary. The apply stream uses the slot name with
  no suffix. `copy` connections at `spock_sync.c:1273, 1402` go to the local
  node, not the provider.
- Conclusion: resolved. Check 2 updated with the full suffix list.

#### Is a connection leaked by a failed `sub_create` in the calling session considered a bug?

- Examined: `spock_create_subscription` (`src/spock_functions.c:573-604`),
  `spock_alter_subscription_synchronize` (`:1173-1175`), `spock_drop_subscription` (`:845-859`),
  `spock_remote_node_info` (`src/spock_rpc.c:303-335`),
  `spock_drop_remote_slot` (`:243-295`). Looked for a doc statement about
  connection cleanup on failure; none found.
- Found: three leak sites confirmed. If the error comes from a dead
  connection, the provider backend is already gone and only client-side memory
  leaks. If the error comes from a healthy connection (wrong node, slot still
  active), the provider keeps an idle backend until the calling session ends.
  When the calling session ends, libpq's socket closes and the provider
  backend exits.
- Not found: any statement of intent.
- Conclusion: tagged `(needs human input)`. Changed check 2 so it does not
  depend on the answer: close workload admin sessions before the check.
