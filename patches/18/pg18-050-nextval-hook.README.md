# pg18-050-nextval-hook.diff

## What this patch does

Adds a generic `nextval_hook` extension point inside
`nextval_internal()` (`src/backend/commands/sequence.c`) so that an
extension can replace the in-core sequence access method's value
generation on a per-call basis. Spock uses it to implement distributed
sequence methods (Snowflake, and later galloc / step-offset).

## Contract

```c
typedef bool (*nextval_hook_type) (Oid seqoid,
                                   Form_pg_sequence seqform,
                                   int64 *result);
extern PGDLLIMPORT nextval_hook_type nextval_hook;
```

When the hook is installed it is called after the sequence relation is
opened and the per-session `SeqTable` cache entry has been populated,
but *before* the in-core code reads the heap-stored `last_value`. The
hook is handed the `Form_pg_sequence` catalog row (so it sees
increment, min, max, start, cache, cycle) but not the heap-stored
`pg_sequence_data` -- by design, since hook-managed sequences are not
heap-state-driven.

If the hook returns true, the in-core code:

- updates `elm->last`, `elm->last_valid`, `elm->cached`, and
  `elm->increment` so that `currval()` / `lastval()` return the
  hook-produced value;
- records `elm` in `last_used_seq` (so `lastval()` after the call
  returns the same value as `currval()`);
- closes the relation and returns the value.

The heap-stored `last_value` and the WAL-logged `xl_seq_rec` are *not*
updated when the hook handles the call.

If the hook returns false, the in-core sequence AM runs unchanged --
this is the safe default for sequences that Spock has not been
configured to manage.

## Cross-version applicability

The same patch concept applies cleanly to PG 15 / 16 / 17 / 18. The
hook insertion point, the three `SeqTable` cache fields
(`last`, `last_valid`, `cached`), and the `last_used_seq` variable
have all been stable since well before PG 15. The exact line offsets
in this diff are written against the PG 18 tree shape; the patch is
expected to apply with `patch -F3` or with a small offset on PG 15-17.

Per-major patches will live alongside this one as the other Spock core
patches do:

```
patches/15/pg15-050-nextval-hook.diff
patches/16/pg16-050-nextval-hook.diff
patches/17/pg17-050-nextval-hook.diff
patches/18/pg18-050-nextval-hook.diff   <-- this file
```

## How tests are organized

The in-core regression suite has no way to install a C-language hook,
so the test for "hook unset behaves identically to stock PostgreSQL"
is implicit: every existing `nextval()` / `lastval()` / `currval()`
regression test in `src/test/regress/sql/sequence.sql` continues to
pass post-patch, which is enforced by the buildfarm.

The "hook set" path is tested by Spock's own SQL regression and TAP
suites. See:

- `tests/regress/sql/seqam_snowflake.sql` -- single-node functional
  tests including a `lastval()` regression test that fails if the
  hook forgets to update `last_used_seq`.
- `tests/tap/t/050_seqam_snowflake.pl` -- two-node concurrent-insert
  test verifying that no PK collisions occur across the cluster.

## Forward path

When Michael Paquier's SeqAM patch lands upstream (currently targeting
PG 19 or 20), this patch is dropped: Spock's methods become loadable
sequence AMs via the `SeqAmRoutine` API, the `nextval_hook` is removed
from `spock.c`, and existing `spock.sequence_kind` rows are migrated
to `pg_seqam` / `pg_class.relam` via `spock.migrate_to_seqam()`.

The hook is named `nextval_hook` (not `spock_seq_nextval_hook`)
deliberately, so that it is plausible as an upstream stopgap if anyone
were to propose it before SeqAM lands. Spock attaches its dispatcher
function (`spock_seqam_nextval`) to the hook in `_PG_init`.
