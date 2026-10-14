# apply-identity-restored-after-queued-sql

## What led here

The apply worker runs as the bootstrap superuser with
`session_replication_role=replica` (`src/spock_apply.c:4699-4716`). For queued
SQL it switches identity temporarily:
`SetUserIdAndSecContext(get_role_oid(role, false), save_sec_context | SECURITY_LOCAL_USERID_CHANGE)`
(`:4342-4344`). It switches back only on the success path (`:4412-4413`).
`spock_object_access` does a similar switch to `BOOTSTRAP_SUPERUSERID` around
dependency checks (`src/spock_executor.c:300-322`), also restored only on
success.

On error, the identity comes back through transaction abort:
`AbortOutOfAnyTransaction` in the apply PG_CATCH (`:4065`), or
`RollbackAndReleaseCurrentSubTransaction` in DISCARD mode (`:2805`). Both
restore `prevUser` / `prevSecContext`. If some path ever catches an error
without aborting the (sub)transaction, the worker would keep running as the
DDL's role (or with `SECURITY_LOCAL_USERID_CHANGE` set). Then:
- later row apply would run with that role's privileges (permission errors ->
  discard path);
- or, for the dependency-check switch, a non-superuser DDL session would keep
  superuser identity.

Also relevant: `in_spock_queue_ddl_command` is set at `:2875` and cleared only
on normal return (`:2880`). It is not cleared in the PG_CATCH. During
in-process replay the flag stays set until the same queued message is replayed.
Its effects are limited (DROP CASCADE behaviour, `add_ddl_to_repset`,
`isTopLevel`), but it is the same kind of "state cleared only on success".

## Property

Whenever the apply worker starts applying a remote transaction or a remote row
change, its effective identity is the worker's own superuser with no
local-userid-change flag, and `session_replication_role` is `replica`.
SUT-side **Always** (missing), in `handle_begin` and at the start of
`handle_insert` / `handle_update` / `handle_delete`:

```
GetUserIdAndSecContext(&uid, &ctx);
Always(uid == apply_boot_userid && (ctx & SECURITY_LOCAL_USERID_CHANGE) == 0
       && SessionReplicationRole == SESSION_REPLICATION_ROLE_REPLICA,
  "apply worker identity and replication role intact before applying remote change");
```

Workload-side cross-check: the canary `ENABLE ALWAYS` trigger described in
`apply-search-path-not-leaked-across-transactions` also records
`current_user` and `session_replication_role`. Always: `current_user` is the
superuser and the role is `replica`.

## Antithesis angle

Make queued DDL fail in many ways and at many points, then look at the next
transaction:
- lock_timeout or deadlock against a local session (transient-retry path);
- the role missing on one node (permanent error);
- `pg_cancel_backend` on the apply pid while the DDL runs (57014, L5 path);
- `terminate_active_transactions()` (40001; FATAL inside a DISCARD
  subtransaction);
- a node kill in the middle of the DDL;
- all three exception modes.

The interesting paths are in-process replay and the DISCARD subtransaction
path, where the worker keeps running after the error.

## Confidence

Medium. By code reading the abort paths restore identity, so this is expected
to hold. It is a cheap regression guard on a security-relevant invariant that
nothing tests today.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (implementability (audit trigger)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P3 · Topology: v1 · Faults: worker exit during DDL, lock contention

- Evaluation note (2026-10-13): the canary trigger is `ENABLE REPLICA` (see `apply-search-path-not-leaked-across-transactions`).

## Open questions

None remaining. Both earlier questions were answered by code reading (see the
Investigation Log). Summary of what changed:

- Every error catch on a path that can run inside the identity switch aborts a
  (sub)transaction, and PostgreSQL restores `prevUser` / `prevSecContext` on
  both `AbortTransaction` and `AbortSubTransaction`. The property is expected
  to hold; it stays as a cheap regression guard.
- `in_spock_queue_ddl_command` is left out of the `Always`. Its stale window
  is short and its effects are minor (details below).

### Investigation Log

#### Are there PG_TRY blocks in the apply path that swallow errors without a (sub)transaction abort?

- Examined: every `PG_TRY` / `PG_CATCH` / `FlushErrorState` in `src/`
  (`grep`), in particular `src/spock_apply.c` (`handle_sql_or_exception`
  `:2754-2860`, the per-row DISCARD blocks `:1658`, `:1832`, `:1965`,
  `:2189`, `apply_work` PG_CATCH `:3867-4135`),
  `src/spock_exception_handler.c:87-276`, `src/spock_conflict.c:980-1035`,
  `src/spock_executor.c:215-322`, `src/spock_functions.c:345-365, 840-860,
  2490-2510, 4185-4300`, `src/spock_sync.c:1606-1631`; PostgreSQL
  `src/backend/access/transam/xact.c` (local REL_17_STABLE tree;
  `SetUserIdAndSecContext(s->prevUser, s->prevSecContext)` at `:2844` in
  `AbortTransaction` and `:5241` in `AbortSubTransaction`).
- Found:
  - DISCARD queued SQL: `BeginInternalSubTransaction` ... `PG_CATCH` ->
    `RollbackAndReleaseCurrentSubTransaction` (`src/spock_apply.c:2792-2807`).
    The subtransaction was started as the apply superuser, so the abort puts
    that identity back.
  - TRANSDISCARD / SUB_DISABLE replay does not run the queued SQL at all
    (`:2775-2789` only extracts the text for logging), so no identity switch
    happens on the replay pass.
  - First-pass errors (no `use_try_block`) reach `apply_work`'s PG_CATCH,
    which calls `AbortOutOfAnyTransaction()` (`:4065`) before replay. The
    other PG_CATCH branches rethrow (worker exits) or disable the
    subscription and return (worker exits).
  - `spock_ProcessUtility`'s extension-drop `PG_FINALLY` rethrows.
  - `spock_object_access` (`src/spock_executor.c:300-322`) raises identity
    to `BOOTSTRAP_SUPERUSERID` and restores it only on success; an ERROR in
    `spock_checkDependency` is undone by the same (sub)transaction abort.
  - Swallowing catches exist only in `spock_drop_subscription` (remote slot
    drop, `src/spock_functions.c:845-858`), the failover-slot worker,
    `spock_cleanup_resolutions` (which does call `AbortCurrentTransaction`),
    and `spock_sync.c:1606` (no `FlushErrorState`). None of them is reached
    from inside `spock_execute_sql_command` through replicated DDL:
    `replicate_ddl` rejects non-DDL statements on the origin
    (`src/spock_apply.c:4351-4359` with `in_spock_replicate_ddl_command`).
- Not found: any catch inside the identity-switched region that keeps running
  without an abort.
- Conclusion: resolved. The property should hold. The only theoretical gap is
  a `spock.queue` row written by hand (not via `replicate_ddl` / AutoDDL)
  that calls a function such as `spock.sub_drop`; that is outside the
  workload.

#### Should `in_spock_queue_ddl_command` be part of the invariant?

- Examined: all readers (`src/spock_apply.c:4310, 4391`,
  `src/spock_executor.c:195`, `src/spock_autoddl.c:742`) and the writers
  (`src/spock_apply.c:2875, 2880`); `handle_insert` `:1715-1745` (queue rows
  call `handle_queued_message` on every pass, including replay).
- Found: after an error the flag stays `true` until the same queued message is
  handled again during in-process replay, which resets it. It can stay set
  longer only if replay never reaches that message (the transaction is being
  skipped through `skip_lsn`), and then only until the next queued SQL
  message. While it is set, its readers only matter for utility statements
  run in the apply worker: forced top-level for queued text, `DROP`
  defaulting to CASCADE, `add_ddl_to_repset`, and AutoDDL suppression. In the
  apply worker utility statements come only from queued SQL (which resets the
  flag itself) or from ENABLE ALWAYS / REPLICA triggers that run DDL.
- Conclusion: resolved. Leave the flag out of the `Always`. If wanted, add a
  separate, low-priority `Always(!in_spock_queue_ddl_command)` at
  `handle_begin` only when `!MyApplyWorker->use_try_block`, so the replay
  window is excluded.
