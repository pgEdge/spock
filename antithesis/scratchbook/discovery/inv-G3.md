# Investigation summary: group G3

PG source used: PG 18.3 tree at `~/dev/pgedge/postgresql` (Spock PG18 patches applied; none touch abort, snapbuild, decode, walsender, condition variables or interrupt handling).

## apply-cancel-retried-not-discarded
- resolved: other interrupt-raised codes reachable from outside: 40001 (terminate_active_transactions on a primary), FATAL 25P04 (transaction_timeout, PG17+) bypasses PG_CATCH; statement/idle timeouts not armed in bgworkers; SIGTERM is graceful. One extra code does not close the gap.
- remaining:
  - Is 57014 (query cancel of an apply worker) meant to be a data fault or a transient retry? `(needs human input)`
- property changed?: no — prose refinement only (earlier "40001 only on standbys" note corrected; 25P04 noted as caught by the stale-marker Unreachable instead).
- invalidated?: no

## terminate-active-transactions-never-discards-inbound
- resolved: walsender hit by the call only cuts the stream (subscriber retries, commits only on 'C'); FATAL 40001 also reachable via delta-apply subtransactions in every mode, not only DISCARD.
- remaining:
  - Is terminate_active_transactions() meant to skip Spock's own workers? `(needs human input)`
- property changed?: yes — prose/oracle refinement: after a call in a conflict-free run, any exception_log row on that node is a violation (the FATAL path leaves rows without the "conflict with recovery" text). Invariant and Always unchanged.
- invalidated?: no

## lock-contention-retried-not-discarded
- resolved: goto retry always blocks on the competing writer (no spin; at worst lag); ALTER DATABASE lock_timeout reaches the apply worker (bgworker runs as bootstrap superuser, settings read at start, needs worker restart).
- remaining: none
- property changed?: no — prose refinement (ALTER ROLE must target the bootstrap superuser; restart workers after ALTER).
- invalidated?: no

## insert-race-resolved-not-discarded
- resolved: check_all_uc_indexes has the same find-then-insert gap (out of v1 scope).
- remaining:
  - Is the TRANSDISCARD-on-race outcome an accepted limit, or should the INSERT path retry as insert_exists? `(needs human input)`
  - How wide is the lookup-to-insert window in practice? `(partial: spans heap insert, BEFORE ROW triggers and constraint checks up to the unique check; apply workers of different upstreams run in parallel; not yet seen in a run)`
- property changed?: no
- invalidated?: no

## exception-replay-only-after-recorded-error
- resolved: other FATAL/proc_exit sites: transaction_timeout FATAL 25P04 and recovery-conflict FATAL 40001 (subtransaction) are new stale-marker sources; "incorrect spock message" FATAL is effectively unreachable (output plugin filters prefix); readonly FATAL confirmed unreachable; postmaster-death exits safe. Side finding: docs/managing/read_only.md says `all` mode FATALs the worker, but code just idles in the loop (possibly inside an open remote transaction).
- remaining:
  - Does a table-sync worker's last stamped commit_lsn ever equal the apply worker's first BEGIN after a restart? `(partial: normally the sync worker stops on the transaction the apply worker last committed; only when the sync stream starts past replay_stop_lsn does it stamp an unseen transaction; needs sub_resync_table in a run)`
- property changed?: no — fault suggestions widen (transaction_timeout variant, terminate_active_transactions calls).
- invalidated?: no

## exception-replay-never-reruns-committed-transaction
- resolved: ConditionVariableTimedSleep in PG18 calls CHECK_FOR_INTERRUPTS each wake-up, so a cancel during the add_node pause raises ERROR 57014 after commit and before the queue reset; replorigin_advance OBJECT_IN_USE confirmed.
- remaining:
  - Is a query cancel delivered to an apply worker a supported operator action? `(needs human input)`
- property changed?: no
- invalidated?: no

## interrupted-exception-replay-still-records-txn
- resolved: PG18 RecordTransactionAbort advances the session origin to commit_lsn; PG18 skip test still strict `<`, so restart at commit_lsn resends T; keepalive endpos cannot pass T's commit while T is unrecorded (sentPtr updated after the commit record, later keepalives follow T's 'C'); sub_disable resume-at-commit_lsn is the documented design (configuring.md). Also: the comment at src/spock_apply.c:3888 ("RecordTransactionAbort does not advance replorigin") holds only on the rethrow path.
- remaining:
  - Is a second set of exception_log rows for the same T (crash after replay commit, L1) acceptable? `(needs human input)`
- property changed?: yes — prose refinement: now a confirmed regression guard (no known bug) on both PG17 and PG18; Always unchanged.
- invalidated?: no

## proto5-replay-reparses-startup-message
- resolved: replay does start at the queued 'S' (only reset is in handle_commit); the second worker handles T via handle_begin exception mode without queue replay (marker and initial error survive the rethrow); L7 interaction gives no silent loss (origin at commit_lsn, strict skip resends); skip_lsn on the SUB_DISABLE path is T's commit_lsn (abort does not reset it).
- remaining: none (mechanism confirmed by code, not yet run; TAP repro still the cheap check)
- property changed?: yes — prose refinement: impact narrowed to one extra worker restart, wrong-cause SUB_DISABLE row, and corrupted remote_insert_lsn; the "silent drop" effect is ruled out.
- invalidated?: no
