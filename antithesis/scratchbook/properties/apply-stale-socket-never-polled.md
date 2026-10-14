# apply-stale-socket-never-polled

## Summary

Regression target for `4dfe7496` ("refresh fd at stream_replay: to avoid stale
fd after connection death") and `d286f3df` (connection loss with an
origin-advance leak). Before the fix, `fd = PQsocket(applyconn)` was read once.
After libpq closed the socket on connection death, the apply worker passed the
closed fd number to `WaitLatchOrSocket` -> `epoll_ctl(EPOLL_CTL_ADD)` ->
`EINVAL` -> ERROR "epoll_ctl() failed: Invalid argument", which landed in the
`use_try_block` branch ("error during exception handling") and, combined with
the origin advance on abort, lost a transaction (TAP
`019_stale_fd_epoll_after_conn_death.pl`, and `101`/`102` which are not in any
schedule).

A closed fd number is reused by the next `open()`/`socket()` in that process.
In the apply worker, the replay spill file (`BufFileCreateTemp`) and relation
files open all the time, so a stale fd can also point at an **unrelated file**.
`epoll_ctl` on a regular file gives `EPERM`, and the worker could then wait on
the wrong object.

Current code (HEAD 69d9228f) reads `PQsocket` again at `stream_replay:` and
before each wait (`src/spock_apply.c:3443-3492`) and returns if
`CONNECTION_BAD` or `PGINVALID_SOCKET`. A grep of `src/` for
`WaitLatchOrSocket`, `PQsocket` and `WaitEventSetAdd` finds **only this one
wait site**. The sync worker's catch-up runs through the same `apply_work`;
`spock_sync_worker_cleanup` uses `WaitLatch` only; RPC helpers use blocking
`PQexec`, where libpq manages its own socket.

## Property

No Spock worker ever waits on a socket that libpq has already closed. In log
terms: no `epoll_ctl() failed` error from any Spock process.

## Assertions (all missing)

1. Workload-side log scan: `Unreachable("spock worker epoll_ctl failure")` on
   any server log line matching `epoll_ctl\(\) failed` from a process whose
   `application_name` / log prefix identifies a Spock apply or sync worker.
2. SUT-side `Always(fd == PQsocket(applyconn), "apply waits on live libpq socket")`
   immediately before the single `WaitLatchOrSocket` in `apply_work`
   (`:3492`), and `Always(PQstatus(applyconn) != CONNECTION_BAD, "apply waits
   on a connected libpq handle")` at the same place.
3. SUT-side `Reachable("apply detected dead connection at stream_replay")` at
   the early return near `:3450`, so the run proves that the fixed path was
   actually taken.

## Fault requirements

- Kill the provider walsender (`pg_terminate_backend` or SIGKILL on the
  provider) or RST the connection while the subscriber is **in replay mode**
  (a real data error in a transaction, then a connection drop). That is the
  exact combination the bug needed.
- Partitions during large (spilling) transactions, so the closed fd number is
  likely to be reused by a temp file.

## Open questions

- Does the failover-slots worker (PG<18, out of first scope) wait on a
  cached socket through PG's walreceiver API? Not checked; the mechanism
  itself is settled (see the Investigation Log).

### Investigation Log

#### Are there other waits on a cached libpq socket?

- Examined: `grep -n "WaitLatchOrSocket\|PQsocket\|WaitEventSetAdd" src/*.c`.
- Found: one wait site, `src/spock_apply.c:3492`, with the fd read again at
  `:3449` and `:3474`.
- Conclusion: resolved. One SUT-side assertion site is enough.
