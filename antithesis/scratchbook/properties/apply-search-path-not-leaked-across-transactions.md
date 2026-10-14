# apply-search-path-not-leaked-across-transactions

## What led here

The apply worker runs as the bootstrap superuser
(`BackgroundWorkerInitializeConnectionByOid(dboid, InvalidOid)`,
`src/spock_worker.c:390`) and runs SQL text received from peers. The session
environment it runs that SQL in, and later triggers and its own SPI queries,
is a trust boundary.

## Mechanism (code-checked; GUC semantics checked against PG18 guc.c)

- `spock.replicate_ddl(command, repsets, search_path, role)` adds
  `SET search_path TO <quoted list>; ` in front of the command text before
  queueing (`src/spock_functions.c:2470-2489`, `append_set_search_path`
  `:2402-2430`). AutoDDL does the same for most statements
  (`spock_auto_replicate_ddl`, `:3084-3091`). For some statement types it does
  not: CLUSTER on a plain table (`:2990`), ALTER TABLESPACE options (`:2995`),
  and ALTER OWNER / RENAME on a tablespace (`:2873`, `:2881`).
- On the subscriber, `spock_execute_sql_command` (`src/spock_apply.c:4285-4420`)
  parses the text into separate statements. Each runs inside
  `NewGUCNestLevel()` ... `AtEOXact_GUC(true, save_nestlevel)`. A plain
  (non-LOCAL) `SET` is a `GUC_SET` stack entry. With `isCommit=true`,
  `AtEOXact_GUC` keeps its value and passes it to the outer level. At
  top-level commit it becomes the **session** value. So after the first
  replicated `replicate_ddl`, the apply worker's session `search_path` is
  whatever the origin user supplied. It stays that way for every later
  transaction until the worker restarts.
- The apply worker sets only `synchronous_commit`, `session_replication_role`
  and `check_function_bodies` at start (`:4699-4716`). It never sets or resets
  `search_path`.
- `session_replication_role` is set with `PGC_S_OVERRIDE`, so a queued
  `SET session_replication_role` from a lower-priority source is ignored.
  `search_path` has no such protection.

What reads the leaked value later:
1. Queued commands sent **without** a `SET search_path` prefix (the AutoDDL
   cases above). They resolve unqualified names against whatever the last
   DDL left behind, or against the default if the worker has restarted since.
   The result depends on restart history, which faults decide.
2. `ENABLE ALWAYS` / `ENABLE REPLICA` triggers whose functions do not pin
   `search_path`. They run as the superuser apply worker.
3. Spock's own SPI query in the apply worker:
   `DELETE FROM spock.resolutions WHERE log_time < now() - '%d days'::interval`
   (`src/spock_conflict.c:933-936`). It is run by `spock_cleanup_resolutions()`
   from the apply loop (`src/spock_apply.c:3571-3580`), at most once a day.
   `now()`, `<` and `-` are unqualified. If the leaked path lists a schema
   *before* `pg_catalog` (for example `'s, pg_catalog'`), a same-signature
   `s.now()` takes priority and runs as superuser.

Security note (not an Antithesis property): together with item 3, any role
that can call `replicate_ddl` can make every peer's apply worker run a
function of its choosing as superuser. That role needs USAGE on schema
`spock`, which is not granted by default; EXECUTE is PUBLIC by default. But
`replicate_ddl`'s `role` argument has no membership check either (see the
catalog notes), so that role can already run DDL as any role.

## Property

At the start of every remote transaction (`handle_begin`), the apply worker's
`search_path` equals the value it had at worker start. SUT-side **Always**
(missing):

```
Always(strcmp(namespace_search_path, apply_boot_search_path) == 0,
  "apply worker search_path unchanged at remote BEGIN")
```

Workload-side alternative, with no SUT change: put an `ENABLE REPLICA` trigger (evaluation 2026-10-13: was `ENABLE ALWAYS`, which also fires for local writes)
on a small canary table on every node. The trigger writes
`current_setting('search_path')`, `current_user` and
`current_setting('session_replication_role')` into a local, non-replicated
audit table. After any `replicate_ddl` with a distinctive `search_path`
(e.g. `'canary_sp, public'`), insert into the canary on another node, then
check (Always) that the audit rows on the receiving nodes show the default
search_path.

## Antithesis angle

The leaked value is reset only by an apply-worker restart. Antithesis decides
restarts (kills, partitions -> reconnect, error-driven restarts), so the
setting at any later point is fault-dependent. A queued command without a
prefix, or a REPLICA trigger, behaves differently depending on whether a fault
happened in between. Clock steps forward can also trigger the daily resolutions
cleanup (item 3) at times that cannot happen normally.

## Confidence

High that the setting persists (GUC stack semantics plus no reset anywhere in
`spock_apply.c`). Medium on how much the maintainers care in practice; the
security angle needs USAGE on schema `spock` to be granted.

## Additional readers of the leaked value (found during investigation)

- **CLUSTER without a prefix.** AutoDDL ships `CLUSTER t [USING i]` on a
  plain table with no `SET search_path` prefix (`src/spock_functions.c:2957-2991`,
  `add_search_path = false`). An unqualified `t` is then resolved on the
  subscriber against whatever path the last `replicate_ddl` left behind, or
  against the default if the worker restarted since. Whether CLUSTER finds
  the right table, a different table, or no table depends on restart history.
- **Delta-apply function lookup.** `spock_lookup_delta_function`
  (`src/spock_relcache.c:407-...`) resolves the `delta_apply_function`
  attribute option by name with `FuncnameGetCandidates`. The docs use the
  qualified `spock.delta_apply` (`docs/conflicts.md:40-48`), but an
  unqualified name is accepted and is resolved against the apply worker's
  current `search_path` whenever the relcache entry is rebuilt, which
  happens right after DDL.
- **User code run by row apply.** Functions called from CHECK constraints,
  defaults, generated columns, index expressions, domain checks and ENABLE
  ALWAYS / REPLICA triggers run in the apply worker; if their bodies do not
  pin `search_path`, they resolve names against the leaked value.
- Spock's own JSON helper query is qualified
  (`src/spock_jsonb_utils.c:73`, `pg_catalog.to_json`), and core row apply
  uses OIDs, so plain row apply without user functions is not affected.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), wildcard W2, implementability (audit trigger)); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 · Faults: worker restarts, clock step forward

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template.
- Evaluation note (2026-10-13): expected to fail on the first `replicate_ddl` that ships a `SET search_path` prefix; fault history only changes how long the leak lasts. TAP repro and fix, then a P3 regression guard. P1 is a severity rank.
- The workload canary trigger is `ENABLE REPLICA`, not `ENABLE ALWAYS`, so local writes do not add canary rows.

## Open questions

None remaining (see the Investigation Log). The leak is confirmed by code
reading and contradicts the code's own comment, and the assertion location
does not depend on how it is fixed.

### Investigation Log

#### Is the leak intended (so that later DDL from the same origin inherits the path)?

- Examined: `src/spock_apply.c:4285-4420` (`spock_execute_sql_command`),
  `src/spock_functions.c:2402-2512` (`append_set_search_path`,
  `spock_replicate_ddl_command`), `src/spock_functions.c:2855-3100`
  (AutoDDL prefix rules), PostgreSQL `AtEOXact_GUC`
  (`src/backend/utils/misc/guc.c:2264-2390`, local REL_17_STABLE tree; GUC
  stack code is the same in 18), `git log --grep=search_path`
  (`ee4b80a3`, `543150e5`).
- Found: on the subscriber, the queued text starts with a plain
  `SET search_path TO ...;`. It runs inside `NewGUCNestLevel()` and is closed
  with `AtEOXact_GUC(true, save_nestlevel)` under the comment "Restore the
  GUC variables we set above". With `isCommit = true` a `GUC_SET` entry keeps
  its value and is merged into the outer level (`guc.c:2314-2318`), so at top
  commit it becomes the session value. The origin side of the same feature
  uses `GUC_ACTION_SAVE` and does restore (`src/spock_functions.c:2470-2473,
  2511`). Nothing in `spock_apply.c` sets or resets `search_path` (only a
  comment at `:4711`).
- Not found: any commit message, doc or comment saying the subscriber should
  keep the path.
- Conclusion: resolved: not intended. The comment says "restore", the origin
  side restores, and the subscriber does not.

#### Should the fix be a SET LOCAL-style restore or pinning `search_path` in the apply worker? (affects where the assertion goes)

- Examined: the two candidate fixes against the proposed assertion at
  `handle_begin`.
- Found: both fixes make "`search_path` at remote BEGIN equals the value at
  worker start" true. A pin sets the start value explicitly; a restore keeps
  the default. The assertion compares against a value captured once at
  startup, so it fits either fix.
- Conclusion: resolved for this property: the assertion location does not
  depend on the fix. Which fix to choose is a maintainer decision and does not
  change the property.

#### Does the ExecSimpleRelation* DML apply path read `search_path` anywhere?

- Examined: `src/spock_apply_heap.c:511-580` (delta tuple build, calls by
  OID), `src/spock_relcache.c:140-175, 407-...` (delta function lookup),
  `src/spock_jsonb_utils.c:73-90`, `src/spock_conflict.c:925-1035`.
- Found: core row apply and the delta call itself use OIDs; the JSON helper
  query is qualified. But the delta function *lookup* resolves an
  unqualified option value through `search_path`, and user functions reached
  from constraints, defaults, index expressions and triggers read it too (see
  "Additional readers" above).
- Conclusion: resolved: yes, through the delta-function name lookup (when
  unqualified) and through user code. This raises the impact of the leak; the
  property and its assertion are unchanged. A workload can make the effect
  visible with an unqualified `delta_apply_function` or a CHECK constraint
  calling an unpinned function, plus a `replicate_ddl` that uses a different
  `search_path`.
