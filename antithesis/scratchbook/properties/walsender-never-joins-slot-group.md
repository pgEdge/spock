# walsender-never-joins-slot-group

Surfaced by evaluation gap (c), item 7 (wildcard W11, lead L10). Code
checked at 69d9228f.

## What the property says

In every run that is not the deliberate slot-group config, no Spock
walsender joins a slot group. A walsender joins one whenever its slot name
ends in `_` followed by one digit (`spock_output_join_slot_group`,
`src/spock_output_plugin.c:1281-1360`, called from startup at `:232`).
Members of a group skip transactions another member already sent
(`:530-583`), so one provider stream is split across subscribers with no
error (L10). The guard makes sure a run never wanders into that state by
naming accident.

## How ordinary names reach it

- Slot names are `spk_<db>_<provider>_<subscription>`, each part passed
  through `shorten_hash(..., 16)` and every character outside `[a-z0-9_]`
  replaced with `_` (`gen_slot_name`, `src/spock_functions.c:3666-3687`).
- The last part is the subscription name. ZODAN names subscriptions
  `sub_<provider>_<subscriber>` (`samples/Z0DAN/zodan.sql:61-67`), and
  every ZODAN slot comes from `spock.spock_gen_slot_name`.
- So a subscriber node named `node-1`, `db_east_1`, `N1` (uppercase becomes
  `_`) or `x-2` gives a slot ending `_1`/`_2`. Lowercase `n1` gives `_n1`,
  which is safe.
- Names longer than 16 characters end in 8 hex digits from the hash, never
  `_<digit>` at the end. Table-sync slots add `_%08x` (`src/spock_sync.c:2013`)
  and are safe.
- The fix that rejects grouped names (f6887c7a) is not an ancestor of HEAD.

## Assertion

SUT-side `Unreachable("walsender joined a slot group")` placed right after
`is_slot_group` becomes true, before the LWLock is taken. Also a cheap
workload setup check: every `pg_replication_slots.slot_name` with plugin
`spock_output` does not match `_[0-9]$`.

In a deliberate slot-group variant (`v2/slot-groups`) this guard is
disabled; data loss there is caught by the ledger properties.

## Antithesis angle

None from faults; this is a guard so that a renamed node, a ZODAN rerun
with different names, or a workload variant that randomises naming does
not silently turn every ledger check into a slot-group finding. Priority
low because the trigger is configuration and is deterministic.

## Open questions

- Will f6887c7a (reject grouped slot names) merge to main? If yes, this
  becomes a regression guard for that check. `(needs human input)`

### Investigation Log

#### Is the slot-name guard (f6887c7a) on main?

- Examined: `git merge-base --is-ancestor f6887c7a HEAD`;
  `git branch -a --contains f6887c7a`.
- Found: f6887c7a ("Disable parallel apply: reject grouped slot names") is
  only on `origin/block-parallel-apply`, not in 69d9228f.
- Conclusion: `(needs human input)` on whether it will merge; until then the
  `Unreachable` is the only guard.
