# Investigation summary: group G4 (HEAD 69d9228f)

PG core behaviour was checked against the local REL_17_STABLE tree at
~/dev/pg/postgresql (no PG18 tree found); the PG18 patches do not touch the
relevant paths.

## redelivered-ddl-not-turned-into-exception
- resolved: none fully. L1 mechanism confirmed by code: every txn carries an origin message (`forward_changeset_origins` always true), `handle_origin` sets the session origin to the node id, commit redo advances that id, not the slot origin. Also documented how each exception mode handles a redelivered DDL (TRANSDISCARD/SUB_DISABLE skip it and log `operation='SQL'` with `ddl_statement`; DISCARD reruns it in a subxact).
- remaining:
  - Is redelivery of a DDL transaction expected by the team, and should DDL apply be made idempotent or redelivery prevented? `(needs human input)`
  - Should 42P07-class errors on queued DDL be treated as "already applied" rather than as data faults? `(needs human input)`
- property changed?: yes — prose only: reachable (not just a guard) with a subscriber kill between checkpoints; the workload must use non-idempotent DDL (no IF NOT EXISTS / OR REPLACE).
- invalidated?: no

## readonly-local-keeps-inbound-ddl-flowing
- resolved: intent (docs, header, regression test all say `local` never blocks apply; no version ever exempted apply, and the pre-March-2026 hooks blocked queued DDL for every role); test coverage (none: the regression test's replicated DDL is superuser-issued and runs before the subscriber goes `local`).
- remaining: none
- property changed?: no (stays as written, not narrowed to superuser DDL)
- invalidated?: no

## worker-respawn-rate-bounded
- resolved: 1 ms intent (`fc4cf74e`: meant for restart-based row replay, which is now in-process); manager back-off; persistent errors after BEGIN in v1 (none known from infra faults).
- remaining: none
- property changed?: yes — prose and fault list. It is a regression guard. Corrections: when RegisterDynamicBackgroundWorker fails, the manager loop is paced at restart_delay_default (5 s) through the claimed apply slot's terminated_at; only a full Spock slot table loops with no delay. readonly=all is not a FATAL source (that FATAL is unreachable). 57014 goes to replay, not exit. SIGTERM is a clean exit.
- invalidated?: no

## readonly-toggle-resumes-without-loss
- resolved: FATAL marker (unreachable FATAL; the real exits, idle timeout / connection loss / SIGTERM, clear the marker); churn (an unplanned interaction between the readonly design and apply_idle_timeout; harmless to the outcome check).
- remaining:
  - Is a sync worker's COPY meant to be blocked by readonly=all? `(needs human input)`
- property changed?: yes — prose: the walsender timeout step does not happen (the stopped worker still sends feedback); the docs' "FATAL and exit" for `all` mode is stale. Side lead: libpq input buffer grows while stopped (PQconsumeInput without PQgetCopyData) until the idle-timeout reconnect.
- invalidated?: no

## readonly-all-never-commits-remote-txn
- resolved: the readonly FATAL in replication_handler cannot be reached at HEAD (every message passes the loop-top check after the last reload).
- remaining:
  - Is committing the one remote transaction already in flight when the worker observes `all` acceptable? `(needs human input)`
  - Is the sync worker's COPY (initial or table sync) meant to be blocked by readonly=all? `(needs human input)`
- property changed?: yes — instrumentation: drop the sync-worker COPY assertion until answered. A superuser DSN COPY is exempt by design since e1aa238f, and the resync "is blocked" comment is stale. The main AlwaysOrUnreachable check is unchanged.
- invalidated?: no

## apply-search-path-not-leaked-across-transactions
- resolved: not intended (comment says "Restore the GUC variables", origin side uses GUC_ACTION_SAVE, AtEOXact_GUC(true) keeps a plain SET); assertion location does not depend on the fix; the DML path does read search_path (unqualified delta_apply_function lookup via FuncnameGetCandidates, and user functions in constraints, defaults, index expressions and triggers).
- remaining: none
- property changed?: yes — prose only: more readers of the leaked value (CLUSTER sent with no prefix, the delta-function lookup, user code), which raises the impact. The assertion is unchanged.
- invalidated?: no

## apply-identity-restored-after-queued-sql
- resolved: every catch inside the identity switch aborts a (sub)transaction, and PG restores prevUser there; the catches that swallow errors cannot be reached from replicated DDL. `in_spock_queue_ddl_command`: leave it out of the Always (short stale window, minor effects).
- remaining: none
- property changed?: no (expected to hold; regression guard)
- invalidated?: no
