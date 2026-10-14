# Focus 6: Security Boundaries — property candidates

Scope note: most of Spock's security boundaries are fixed checks: who may call
a function, which schemas are reserved, and grants. Fault injection and timing
do not change their outcome, and TAP or regression tests cover them better.
So this list is short. It keeps only the boundaries whose outcome depends on
timing, restarts or error paths: read-only modes, the apply worker's session
identity and environment, and an operator tool that cancels apply
transactions. Fixed findings that are not suited to Antithesis are listed
separately at the end.

## Read-only modes

### readonly-local-keeps-inbound-ddl-flowing — readonly=local does not block replicated DDL

| | |
|---|---|
| **Type** | Safety |
| **Property** | While a subscriber is in `spock.readonly=local`, every inbound replicated transaction commits on it, including queued DDL that a non-superuser role issued on the origin. |
| **Invariant** | Workload-side `Always`, checked after the quiet period that follows any phase where a node was in `local` mode: that node's `spock.exception_log` has no row with SQLSTATE 25006 / "read-only transaction", test-table columns match on all nodes, and ledger rows match. `Always` because the docs promise that inbound replication "continues normally" every time. |
| **Antithesis Angle** | Varies when the readonly reload lands relative to DDL arrival (the apply worker re-reads the GUC only at message boundaries or in `wait_for_previous_transaction`), plus worker restarts. Mostly a fixed-order bug: it fires whenever the DDL role is not a superuser. A TAP test would also catch it. |
| **Why It Matters** | The readonly hooks test `superuser()` on the *current* user. The apply worker switches to the queued role before parse analysis (`spock_apply.c:4342-4361`), so the DDL fails with 25006. That code is not on the transient list, so under the default TRANSDISCARD the DDL transaction is discarded for good, and the schema difference makes later DML fail too. |

**Open Questions:**

- Is the readonly hook meant to apply to the apply worker's role switch, or are the docs wrong?

Confidence: high (mechanism), medium (maintainers will call it a bug)
Evidence file: properties/readonly-local-keeps-inbound-ddl-flowing.md

### readonly-all-toggle-loses-and-duplicates-nothing — readonly=all on/off cycles are lossless

| | |
|---|---|
| **Type** | Safety |
| **Property** | After any number of `spock.readonly` changes `off -> all -> off/local` on any node, at random times relative to traffic and faults, every committed ledger row ends up on every node exactly once, with no subscription disabled and no `exception_log` row the workload did not cause. |
| **Invariant** | Workload-side `Always` with the shared ledger oracle after quiescence. Readonly=all must be held for less than slot WAL retention (§12). `Always` because the docs promise resume "from where it left off". Missing SUT-side helpers: `Reachable` for "FATAL on readonly=all inside an open remote transaction" and for "readonly=all observed while xact_had_exception". |
| **Antithesis Angle** | Toggles landing between rows, just before 'C', during in-process exception replay (the 1 s spin with the transaction open), during table-sync catch-up, and during add_node pauses. Combined with kills and partitions while the node is read-only. The FATAL path skips the PG_CATCH classifier. |
| **Why It Matters** | The documented maintenance procedure. If the FATAL exit or the replay spin advances the origin past an uncommitted transaction, or leaves an exception marker behind, rows are silently lost once readonly is cleared. |

**Open Questions:**

- Is a sync worker's COPY (libpq session, superuser DSN, exempt from hooks) meant to be blocked by readonly=all, as the comment at `spock_functions.c:1241-1247` claims?
- Does the FATAL exit leave an exception marker that misclassifies the transaction on restart (shared with L5)?

Confidence: medium
Evidence file: properties/readonly-all-toggle-loses-and-duplicates-nothing.md

### readonly-all-blocks-apply-commit — no apply commit while the worker's readonly=all is in effect

| | |
|---|---|
| **Type** | Safety |
| **Property** | Once an apply worker's own `spock_readonly` value is `all`, it does not commit a remote transaction. |
| **Invariant** | SUT-side `AlwaysOrUnreachable(spock_readonly != READONLY_ALL, ...)` in `handle_commit` just before `CommitTransactionCommand()` (missing). `AlwaysOrUnreachable` because the per-message FATAL should keep this point from being reached with the value set. It reports only if a path such as a reload inside `wait_for_previous_transaction` gets there. |
| **Antithesis Angle** | A reload landing while the worker waits in `wait_for_previous_transaction` (called from `handle_commit`, `handle_sql`, `handle_relation`, after the per-message check). That wait happens with slot groups or ordering waits. Thread pauses and CPU throttling widen it. Best reached in a slot-group configuration. |
| **Why It Matters** | It tests the docs' claim that `all` blocks apply workers from writing. An operator who sets `all` to freeze a node before a manual repair or ACE comparison can still get one more inbound commit, or a queued DDL. |

**Open Questions:**

- Is committing the one transaction already in flight after the worker observed `all` acceptable? If yes, narrow the property to transactions begun after observation. `(needs human input)`
- Should the sync worker's COPY count as an apply write?

Confidence: medium-low in default topology; medium with slot groups
Evidence file: properties/readonly-all-blocks-apply-commit.md

## Operator tools that cross the replication boundary

### terminate-active-transactions-never-discards-inbound — the readonly helper does not drop replicated data

| | |
|---|---|
| **Type** | Safety |
| **Property** | Calling `spock.terminate_active_transactions()` on a node never makes that node discard, skip or disable an inbound replicated transaction. |
| **Invariant** | Workload-side `Always` after quiescence following any call: no `exception_log` row with "conflict with recovery" / 40001, all ledger rows present everywhere, no disabled subscription. Missing SUT helper: `Sometimes(in_remote_transaction, "apply worker received recovery-conflict cancel mid-transaction")` in the apply PG_CATCH, to show the interleaving was reached. `Always` because the guarantee must hold for every call. |
| **Antithesis Angle** | The function cancels every backend with a valid vxid, including an apply worker that is mid-transaction. Whether the call lands inside an open remote transaction (or inside a DISCARD per-row subtransaction, which turns it into FATAL) depends on timing. Large transactions, provider pauses and CPU throttling widen the window. |
| **Why It Matters** | It is part of the read-only toolkit. The cancel raises ERROR 40001 (PG18 `ProcessRecoveryConflictInterrupt`, no recovery-in-progress check). 40001 is not on the classifier's transient list (admitted at `spock_apply.c:3951-3957`), so a routine operator action discards an inbound transaction under TRANSDISCARD, or disables the subscription under SUB_DISABLE. |

**Open Questions:**

- Is the function meant to skip Spock's own workers? If yes this is a bug; if no, the docs need a warning and the workload should only call it after readonly=all is in effect.

Confidence: high (mechanism checked in Spock and PG18 source), medium (intended use)
Evidence file: properties/terminate-active-transactions-never-discards-inbound.md

## Apply worker session identity and environment

### apply-search-path-not-leaked-across-transactions — queued SQL does not change the apply session's search_path

| | |
|---|---|
| **Type** | Safety |
| **Property** | At the start of every remote transaction, the apply worker's `search_path` equals its value at worker start, whatever queued SQL ran before. |
| **Invariant** | SUT-side `Always(strcmp(namespace_search_path, apply_boot_search_path)==0, "apply worker search_path unchanged at remote BEGIN")` in `handle_begin` (missing). Workload alternative with no SUT change: an `ENABLE ALWAYS` canary trigger that writes `current_setting('search_path')`, `current_user` and `session_replication_role` to a local audit table. `Always` because this must hold for every transaction. Expected to fail. |
| **Antithesis Angle** | The leaked value lasts until the apply worker restarts, so later behaviour depends on fault-driven restart history. Affected: queued commands sent without a `SET search_path` prefix (some AutoDDL statement types), REPLICA/ALWAYS triggers, and the apply worker's daily `spock.resolutions` cleanup SPI query, which uses unqualified `now()` and operators. Forward clock steps can trigger that query. |
| **Why It Matters** | The `SET search_path` prefix shipped with each `replicate_ddl` is a plain session SET, kept on commit by `AtEOXact_GUC(true, ...)` (`spock_apply.c:4345,4410`). The superuser apply worker then keeps a search_path chosen by the origin user. Results can differ by node and by restart history, and a path that puts a user schema before `pg_catalog` lets that schema capture names in superuser code. |

**Open Questions:**

- Is the leak intended? Probably not, since every call sends its own prefix.
- Is the right fix restoring the GUC after each queued command, or pinning `search_path` in the apply worker? The answer changes where the assertion goes.

Confidence: high (persistence), medium (impact in practice)
Evidence file: properties/apply-search-path-not-leaked-across-transactions.md

### apply-identity-restored-after-queued-sql — apply worker returns to its own identity after every queued-SQL error path

| | |
|---|---|
| **Type** | Safety |
| **Property** | Whenever the apply worker begins a remote transaction or applies a remote row, its effective user is its own superuser with no `SECURITY_LOCAL_USERID_CHANGE`, and `session_replication_role` is `replica`. |
| **Invariant** | SUT-side `Always` in `handle_begin` and at the start of `handle_insert/update/delete` comparing `GetUserIdAndSecContext()` with the boot values and checking `SessionReplicationRole` (missing). Workload cross-check through the canary trigger's `current_user` and `session_replication_role`. `Always` because it must hold for every remote change. Expected to hold; this is a regression guard. |
| **Antithesis Angle** | Make queued DDL fail in many ways: lock_timeout or deadlock against local sessions, a role missing on one node, `pg_cancel_backend` on the apply pid, `terminate_active_transactions()`, a kill mid-DDL. Do this in all three exception modes, then look at the next transaction. The DISCARD subtransaction path and in-process replay keep the worker alive after the error. |
| **Why It Matters** | `SetUserIdAndSecContext` to the queued role (`spock_apply.c:4342`) and to `BOOTSTRAP_SUPERUSERID` in `spock_object_access` (`spock_executor.c:300-322`) are undone only on success. Error paths rely on (sub)transaction abort. A missed path would run later replicated changes under the wrong identity, or leave a DDL session with superuser rights. |

**Open Questions:**

- Is there a PG_TRY in the apply path that swallows an error without a (sub)transaction abort while the identity is switched?
- Should the stale `in_spock_queue_ddl_command` flag (not cleared in PG_CATCH) be part of the invariant?

Confidence: medium
Evidence file: properties/apply-identity-restored-after-queued-sql.md

## Fixed security findings not suited to Antithesis (for a human or TAP follow-up)

All found by code reading. Not run.

- **`spock.replicate_ddl(..., role)` lets the caller pick any role.**
  `spock_replicate_ddl_command` (`src/spock_functions.c:2440-2511`) passes
  the caller-supplied `role` to `queue_message` and to
  `spock_execute_sql_command`, which calls `SetUserIdAndSecContext` with no
  `is_member_of_role` / `has_privs_of_role` check. The DDL runs locally and on
  every peer as that role, which can be a superuser.
  - The function has no `REVOKE ... FROM PUBLIC` (`sql/spock--6.0.0.sql`
    revokes only `slot_enable_failover`, `cleanup_resolutions`,
    `pause/resume_apply_workers`).
  - The only barrier is USAGE on schema `spock`, which is not granted by
    default. The regression test `init_fail.sql` does grant it.
- **`spock.terminate_active_transactions()` is not revoked from PUBLIC.** A
  role with USAGE on `spock` can cancel every transaction in every database,
  including superuser sessions and apply workers. Normal `pg_cancel_backend`
  rules need the same role or `pg_signal_backend`.
- **`spock.queue` is a trust boundary.** Every row is run on subscribers as
  the recorded role. Only the owner or superuser can insert by default (no
  grants), so this is acceptable, but any `GRANT INSERT ON spock.queue` hands
  over remote superuser execution. Worth a doc warning.
- **`output_plugin_libraries` (upstream 2a29b607dbb).** This is a setup
  requirement, not a property. On PG 18.6+ every node, including the spare n4
  that Z0DAN joins, must list `spock_output`. Otherwise slot creation fails
  during add_node. The harness probe in `tests/docker/entrypoint.sh` already
  handles it.
- **Reserved schema/object guards (TAP 027/034/038).** These are fixed checks
  in the utility hook on the issuing node (`spock_autoddl.c:366`,
  `spock_node.c:126-160`). Nothing about them depends on timing. Leave them to
  TAP.

## Areas examined

- `src/spock_readonly.c` (hooks, `terminate_active_transactions`),
  `src/spock_executor.c` (hook install, ProcessUtility deny_all_ddl,
  object-access identity switch).
- `src/spock_apply.c`:
  - readonly checks (`:2981`, `:3600-3630`);
  - `wait_for_previous_transaction` reload (`:295-337`);
  - TRANSDISCARD `transaction_read_only` (`:620-632`);
  - `handle_sql` / `handle_sql_or_exception` / `handle_queued_message` (`:2690-2885`);
  - `spock_execute_sql_command` (`:4285-4420`);
  - classifier PG_CATCH (`:3860-4110`);
  - session setup (`:4699-4716`);
  - resolutions cleanup call (`:3564-3580`).
- `src/spock_functions.c`: `replicate_ddl`, `append_set_search_path`,
  `spock_auto_replicate_ddl` search-path choices, `check_readonly_for_resync`.
- `src/spock_sync.c` COPY target session setup; `src/spock_conflict.c`
  resolutions cleanup SPI.
- `sql/spock--6.0.0.sql` grants and revokes, `spock.queue`, reserved_object
  seeds; `docs/managing/read_only.md`.
- TAP 015, 027, 034, 038 headers.
- PG 18.3 `postgres.c` recovery-conflict handling.

## Assumptions affecting multiple properties

- The workload connects as a superuser for setup but issues some DDL (via
  `spock.replicate_ddl`, AutoDDL off per ZODAN preconditions) as a
  **non-superuser** role that exists on every node. Without that,
  `readonly-local-keeps-inbound-ddl-flowing` cannot fire and
  `apply-identity-restored-after-queued-sql` exercises only superuser-to-superuser
  switches.
- The workload includes a readonly toggling action (ALTER SYSTEM + reload) on
  random nodes, kept shorter than slot WAL retention, and sometimes calls
  `spock.terminate_active_transactions()`.
- Cluster-wide `default_transaction_isolation` stays READ COMMITTED, so 40001
  rows in `exception_log` can be attributed to the cancel path.
- The canary `ENABLE ALWAYS` trigger and its local audit table are created in
  a quiet DDL phase and kept out of replication sets.
- `spock.resolutions_retention_days` is either left at its default and clock
  steps are bounded, or the convergence oracle does not depend on old
  `spock.resolutions` rows. The daily cleanup deletes them, and a forward
  clock step can trigger it early.
