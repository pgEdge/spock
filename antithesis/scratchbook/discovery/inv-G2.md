# Investigation summary — group G2

PG source used: `~/dev/pg/postgresql` (`origin/REL_18_STABLE`, read with `git show`), plus `patches/18/*.diff`. Nothing built or run.

## sync-event-barrier-implies-visible
- resolved: "origin reached vs visible" for rows committed before `sync_event()`. Messages are applied in order and each commit finishes (ProcArrayEndTransaction included) before the next message, so those rows are visible before the origin can reach L. The race and the out-of-order marker LSN only affect DML inside the `sync_event(true)` caller's own transaction. That question is merged into the T-DML question.
- remaining:
  - Is DML in the transaction that calls `sync_event(true)` meant to be covered by the barrier? `(needs human input)` `(partial: code cannot guarantee it — a concurrent commit after the marker record can move the origin past L before T arrives, and T's own commit advances the origin before T is visible; rows committed before the call are covered)`
  - Should the barrier report true when the origin passed L only because a transaction was discarded? `(needs human input)` `(partial: handle_commit advances the origin on DISCARD/TRANSDISCARD on purpose and the docs describe discard as "skip the failed transaction and continue"; nothing says what a barrier should report)`
- property changed?: yes — prose refinement. The main Always (rows committed before the call) is a guard expected to hold. The separate T-own-rows message is where firings are expected. Side note: the C comment's "explicit WAL flush in both modes" is wrong for transactional markers on PG17+.
- invalidated?: no

## sync-event-barrier-survives-subscriber-restart
- resolved: L1 applies on PG18. Commit records carry the node id, redo advances that id, the patches don't touch it, and spock_rmgr/reconcile don't compensate.
- remaining:
  - Is subscriber-side durability of marker progress part of the barrier contract, or must callers issue a fresh marker after any restart? `(needs human input)`
  - Would WAL-logging the non-transactional advance be acceptable cost? `(needs human input)` `(partial: replorigin_advance() errors on the session-held origin, so a fix needs a direct XLOG_REPLORIGIN_SET write; a commit-based fix depends on fixing L1)`
- property changed?: yes — the secondary raw check "remote_lsn never goes backwards across restart" is invalid for crashes, because async apply commits can be lost legitimately. Restrict it to clean restarts. The barrier re-check stays the primary crash check.
- invalidated?: no

## sync-wait-functions-honor-contract
- resolved: the docs say both functions wait indefinitely and the caller must make sure the subscription keeps processing, so the disabled-subscription clause is dropped. Workload reachability: ZODAN never calls the C function (it uses its own SQL loop, which also accepts 'y'). The workload can call `sub_wait_for_sync` on the ZODAN-created subscription or use resync; no separate `sub_create` is needed.
- remaining:
  - Should the wait functions report a disabled subscription instead of waiting? `(needs human input)` `(partial: docs say they wait indefinitely and the caller must ensure the subscription is processing; assertion dropped from the property)`
- property changed?: yes — the second Always is narrowed to "sync wait reports FAILED table instead of waiting", and applies only once the subscription-level row is 'r' (the code checks FAILED only then). L12 hangs belong to the sync-worker properties.
- invalidated?: no

## feedback-never-confirms-undurable-apply
- resolved: the strict skip test (commit record start < start_decoding_at) and the late sentPtr update are unchanged in PG18 and the patches, so check (1) is a guard. Keepalive feedback during replay is safe because messages are read in stream order.
- remaining:
  - Is there any WAL flush between the old worker's last commit and the new worker's initial feedback report? `(partial: none in spock's exit/start path or in PG18 worker exit; only spock.synchronous_commit=on closes the window; not yet shown in a run)`
  - Is `flush = recvpos` with an empty mapping right after a worker restart accepted (it matches stock PG18 worker.c), limiting a fix to the explicit initial report? `(needs human input)`
  - Is unconditional keepalive feedback during `sub_disable` replay intended? `(needs human input)` `(partial: safe by stream order — keepalives are read only from the live socket, after earlier messages)`
- property changed?: yes — prose. Check (3) can only fail with `spock.synchronous_commit=off` (the default); the workload should keep the default or randomise it.
- invalidated?: no

## crash-redo-leaves-no-node-id-origin-state
- resolved: PG18 tags the commit record with replorigin_session_origin (the node id), and xact_redo_commit calls replorigin_advance(XLogRecGetOrigin) with no catalog check. The live path advances only the session (slot) origin, in memory. The patches change only the commit-timestamp hook. spock_rmgr redo only logs, reconcile trusts the regressed origin, and only forwarded origins get a WAL-logged advance. TAP 022 assumes the opposite, and TAP 008/022 run CHECKPOINT before SIGKILL, which hides the problem.
- remaining:
  - Is the node-id origin state an intended side effect? `(partial: TAP 022's header and the no-checkpoint-hook design doc both assume redo restores the slot-named origin, and no doc mentions node-id states; looks unintended)`
  - Should the workload rotate node names (or run many concurrent table resyncs) to push origin-state use toward `max_active_replication_origins`? `(partial: steady state is about 6-8 of the default 10 per node in the planned topology; exhaustion needs churn under new names)`
- property changed?: yes — prose. It moves from a regression guard to a likely finding: it should fire on the first subscriber crash with applied commits since the last checkpoint. The Unreachable assertion type is unchanged. Priority could rise.
- invalidated?: no

## apply-stream-framing-and-lsn-order
- resolved: all four questions.
  - No legitimate re-delivery below the origin: the strict skip test applies, ZODAN advances the slot and origin together to an end LSN, and the origin can't be advanced while it is held. Use `>=`.
  - Nothing relies on handle_begin leaving replorigin_session_origin alone. Assertion 3 must test remote_origin_id; replorigin_session_origin is never per-transaction Invalid.
  - The only Spock message on the wire is sync_event. Repair mode writes nothing.
  - No protocol-version GUC exists at HEAD.
- remaining: none
- property changed?: yes — prose. Assertion 6 uses `>=`. Assertion 3 is pinned to remote_origin_id. Assertion 2 is unaffected by replay (the error path resets the flag).
- invalidated?: no

## progress-insert-lsn-never-ahead-of-provider
- resolved: received_lsn comes from record LSNs in 'w' headers, keepalive sentPtr (or confirmed_flush at startup), or the origin seed, so it never legitimately passes P's WAL. Keep both columns. A promoted standby is out of scope for v1.
- remaining: none
- property changed?: no (one note: the startup keepalive echoes confirmed_flush, so a bogus subscriber flush report would show up here, which is acceptable)
- invalidated?: no
