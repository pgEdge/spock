# proto5-replay-reparses-startup-message

## Summary

Under protocol version 5 (every 6.0 <-> 6.0 link, so the planned single-version
topology), the apply worker's exception replay re-reads the queued startup
message ('S') with v5 framing, although that message was sent and first read
with no v5 header. The replay then reads 8 bytes of the startup payload as a
`remote_insert_lsn`, writes that garbage into `spock.progress`, and raises
`unknown action of type o`. This is a code-reading finding; it has not been run.

This is a version-compatibility bug in the sense of the focus: the v5 framing
change (commit 72b7980a, "Add multi-protocol support for rolling upgrades")
added a per-message header that depends on a process-wide "current protocol
version" variable, and that variable changes value in the middle of the
connection. Any stored message parsed again later gets the new value.

## Mechanism (code-checked at HEAD 69d9228f)

1. Subscriber's parse version starts at 4 in every new process:
   `static uint32 spock_apply_proto_version = SPOCK_PROTO_MIN_VERSION_NUM;`
   (`src/spock_proto_native.c:45`). It is set only when the startup message is
   handled: `handle_startup_param` key `proto_version` ->
   `spock_apply_set_proto_version()` (`src/spock_apply.c:2429-2448`).
2. The publisher never puts the v5 header on the startup message:
   `write_startup_message` comment "Startup message never includes
   remote_insert_lsn" (`src/spock_proto_native.c:433-451`). It is sent as its
   own CopyData message (`send_startup_message`, `src/spock_output_plugin.c:1225-1248`),
   lazily, just before the first BEGIN (`:593-594`) or the first sync_event
   (`:807-808`).
3. In `apply_work()` every 'w' message, stream or replay, goes through the same
   code: parse 'w' header, then
   `if (spock_apply_get_proto_version() >= 5) last_inserted = pq_getmsgint64(msg);`,
   then `UpdateWorkerStats(last_received, last_inserted)`, then
   `replication_handler(msg)` (`src/spock_apply.c:3705-3751`).
   - First pass of 'S': version is still 4, so no header is read (correct);
     `handle_startup` sets version 5.
4. Every received 'w' message is appended to the replay queue before it is
   handled (`queue_append`, `:3693, 3724-3726`). The queue is reset only in
   `handle_commit` (`apply_replay_queue_reset`, `:1248`; that is the only
   call). So the 'S' entry stays at the head of the queue until the first
   COMMIT after connect.
5. If the first remote transaction after connect raises a data error (anything
   not in the connection/transient classes), `PG_CATCH` takes the "first
   occurrence" branch: `AbortOutOfAnyTransaction()`,
   `apply_replay_queue_start_replay()` (cursor = queue head),
   `need_replay = true`, then `use_try_block = true` and `goto stream_replay`
   (`:4065-4140`).
6. Replay reads the 'S' entry first. Version is now 5, so it reads 8 bytes as
   `last_inserted`: bytes `'S' 0x01 'm' 'a' 'x' '_' 'p' 'r'` (first key is
   `max_proto_version`, `src/spock_output_config.c:539`) -> LSN
   `53016D61/785F7072`. `UpdateWorkerStats` stores it as
   `remote_insert_lsn`; `spock_group_progress_update` keeps the max
   (`src/spock_group.c:~335-340`), so the value sticks.
7. `replication_handler` then reads the action byte `'o'` ->
   `elog(ERROR, "unknown action of type o")` (`src/spock_apply.c:3036-3038`).
8. `PG_CATCH` again, now with `use_try_block = true`,
   `xact_had_exception = false`:
   - `SUB_DISABLE`: the subscription is disabled (`:4014-4028`).
   - `TRANSDISCARD` / `DISCARD`: "error during exception handling", rethrow,
     worker exits (`:4040-4049`). The next worker reads 'S' fresh (version 4
     -> 5), sees BEGIN with the recorded `commit_lsn`, enters exception
     handling directly from `handle_begin` (`:830-845`), and does not need the
     queue replay. So the transaction is probably handled on the second try.

Under protocol 4 (any link touching a 5.0.x node) step 6 reads no header and
the 'S' replay just re-runs `handle_startup`, which is harmless apart from a
second `before_shmem_exit` registration. So the bug is v5-only.

## Effects (expected, not run)

- **Progress corruption.** `spock.progress.remote_insert_lsn` for that
  (subscriber, provider) pair becomes a huge value and stays there (max-kept),
  `spock.lag_tracker.replication_lag_bytes` reports a huge lag, and the value is
  written to `resource.dat` at clean shutdown. `read_peer_progress` copies
  `remote_insert_lsn` to a node being added, so add_node can carry it to the new
  node.
- **Spurious exit during replay.** One extra worker exit per occurrence. In the
  catch at step 5, `AbortOutOfAnyTransaction()` ran with
  `replorigin_session_origin_lsn = commit_lsn` set. Lead L7 (sut-analysis §9)
  says the abort record may advance the subscription origin to `commit_lsn`; if
  a restart at that position skips the transaction, the transaction is lost
  with no `exception_log` row. The misparse makes "graceful exit during replay"
  happen every time this path is hit, which turns L7 from a rare race into a
  likely outcome.
- **Wrong SUB_DISABLE cause.** Under `sub_disable` the disable is triggered by
  the misparse, not by the real error; the exception_log row is the generic
  "disabling subscription ... skip_lsn" row.
- In cassert builds no Assert in `spock_group_progress_update` catches this:
  a huge `remote_insert_lsn` satisfies `remote_insert_lsn >= remote_commit_lsn`.

## When it is reached

- Needs: a fresh connection (apply worker start, reconnect after a partition,
  apply_idle_timeout, provider restart, sync worker CATCHUP connection), and the
  first committed remote transaction on it hits a data error that has not
  already been recorded in the shmem exception marker.
- In the planned workload: update_missing after `read_retry_count` retries,
  unique violations from cross-upstream races (L6a), unknown column during DDL
  phases. After every partition heal or worker restart the backlog's first
  transaction is a candidate.
- Sync workers (CATCHUP via `apply_work`) have the same queue.
- Not reached when the error is already recorded (the second worker goes
  straight to exception mode without queue replay).

## Suggested instrumentation (all missing; no Antithesis assertions exist)

- SUT-side, `apply_work()` replay branch: record the parse version on each
  `ApplyReplayEntry` when it is appended, and
  `Always(entry->proto_version == spock_apply_get_proto_version(), "replayed message parsed with the protocol version it was received with")`.
- SUT-side, `replication_handler` default case:
  `Unreachable("apply received unknown protocol action")` with details
  (action byte, replay mode, proto version).
- SUT-side: `Sometimes(apply_replay_mode && first entry is 'S', "exception replay starts with the startup message at queue head")`
  so Antithesis knows the state was reached even if the bug is fixed.
- Workload-side oracle: see `progress-insert-lsn-never-ahead-of-provider`.

## Fault requirements

- Any fault that forces a reconnect (partition, node restart, worker
  SIGTERM/kill, `apply_idle_timeout`), followed by a data error as the first
  remote transaction. No clock faults needed. Node termination of the
  subscriber resets the process, which is enough to create the "fresh
  connection" state.

## A cheap confirmation outside Antithesis

A TAP test can show it in seconds: 2 nodes on 6.0, restart the subscriber's
apply worker (`pg_terminate_backend`), then commit on the provider a
transaction that fails on the subscriber (for example, an insert that hits a
subscriber-only unique index). Look for "unknown action of type o" and a huge
`remote_insert_lsn` in `spock.progress`.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit CW1, wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: reconnect (partition / worker restart) plus a workload data error

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.

## Open questions

None remaining from code reading. The mechanism is confirmed in code but has
not been run; the TAP test above is still the cheapest confirmation.

## Resolved

- **Replay starts at the 'S' entry.** The startup message goes out as its own
  CopyData message (`send_startup_message`, `src/spock_output_plugin.c:1225-1248`,
  sent from `pg_decode_begin_txn` at `:593-594` before BEGIN), arrives as a
  'w' message and is queued like any other (`src/spock_apply.c:3724-3726`).
  The queue is emptied only by `apply_replay_queue_reset()`, called only from
  `handle_commit` (`:1248`); each worker process starts with an empty queue.
  Non-transactional messages ('M' sync events) do not reset it. So 'S' is at
  the head until the first COMMIT after connect, and
  `apply_replay_queue_start_replay()` (`:5123-5145`) starts from the head.
  The first key is `max_proto_version` (`src/spock_output_config.c:539`), so
  after 8 bytes are misread the action byte is `'o'` and
  `replication_handler`'s default case raises `unknown action of type o`
  (`:3036-3038`).
- **The second worker handles the transaction.** Under TRANSDISCARD/DISCARD
  the misparse error takes the "error during exception handling" rethrow
  (`:4040-4049`), which clears nothing; `spock_apply_worker_shmem_exit`
  (`:2305-2325`) resets only the origin. The marker keeps T's `commit_lsn`
  and the real `initial_error_message`. The new worker's first BEGIN of T
  matches in `handle_begin` (`:830-845`), sets `use_try_block` and applies T
  in exception mode straight from the stream, so no queue replay and no second
  misparse. Only a postmaster crash (shmem wiped) costs one more round.
- **L7 interaction: no silent loss.** The first-pass
  `AbortOutOfAnyTransaction()` does move the origin to T's `commit_lsn` (PG18
  `xact.c:1813-1845`), but a restart at `commit_lsn` resends T because the
  decoding skip test is strict (`snapbuild.c:304-306`). Details in
  `interrupted-exception-replay-still-records-txn`. So the effects of this bug
  are one extra worker restart, a wrong-cause disable row under SUB_DISABLE,
  and the corrupted `remote_insert_lsn`; not a lost transaction. The S2
  (silent drop) concern in "Effects" is ruled out.
- **skip_lsn on the SUB_DISABLE path is correct.** PG abort does not reset
  `replorigin_session_origin_lsn` (only `origin.c` session functions do), so
  after `AbortOutOfAnyTransaction()` it still holds T's `commit_lsn`, set at
  BEGIN (`src/spock_apply.c:686`). `spock_disable_subscription` reports that
  value.

### Investigation Log

#### Does replay at step 6 really start at the 'S' entry?

- Examined: `src/spock_apply.c:3690-3751, 4935-4962, 5123-5145, 1248, 3036-3038`;
  `src/spock_output_plugin.c:521-600, 1225-1248`;
  `src/spock_proto_native.c:425-451`; `src/spock_output_config.c:535-545`;
  grep for every `apply_replay_queue_reset` / `apply_replay_head =` site.
- Found: one reset site (commit); 'S' is queued; replay starts at head.
- Not found: any reset or skip of 'S' between startup and first commit.
- Conclusion: resolved (code reading; not run).

#### Does the second worker always handle the transaction correctly?

- Examined: `src/spock_apply.c:4014-4049` (catch branches when
  `use_try_block`), `:2305-2325`, `:418-436`, `:826-880`.
- Found: the marker and initial error survive the rethrow exit; the next
  worker enters exception mode from `handle_begin` without queue replay.
- Conclusion: resolved, yes (one extra round only after a postmaster crash).

#### Does the abort advance the origin to commit_lsn, and does restart at commit_lsn resend?

- Examined: PG 18.3 `xact.c:1775-1845`, `snapbuild.c:304-306`,
  `decode.c:1296-1302`, `logical.c:556-576`.
- Found: advance yes, resend yes.
- Conclusion: resolved; no silent loss from this path.

#### What does spock_disable_subscription use as skip_lsn on this path?

- Examined: PG18 grep for `replorigin_session_origin_lsn =` in
  `src/backend` (set only in `origin.c` and native apply), Spock
  `src/spock_apply.c:686, 4014-4028`,
  `src/spock_exception_handler.c:230-275`.
- Found: still T's `commit_lsn`.
- Conclusion: resolved.
