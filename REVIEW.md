# Reviewing a change to Spock

Spock does multi-master logical replication: an output plugin on the provider,
apply and sync background workers on the subscriber, conflict resolution with
commit timestamps, AutoDDL, failover slots on standbys, and SQL-callable
management functions. A mistake here can lose data silently or take a cluster
through crash recovery, so the bar is high. Review a change assuming it has a
defect until you have checked the places one would hide.

## How to run a review

- On demand, in a Claude Code session: `/spock-commit-review`. It reads the
  staged change and reviews it against this file.
- As a pre-commit gate: the `spock-commit-review` skill installs a git hook
  (`.claude/skills/spock-commit-review/scripts/install-hook.sh`) that hands
  the reviewer the staged change and the committed copy of this file. It is
  opt-in and off by default; enable it with `git config --global
  spock.commitReview true`, or for one commit with `SPOCK_REVIEW=on`.
  `SPOCK_REVIEW=skip` bypasses one commit while it is on.
- By hand: work through the checklist below against the diff and the code
  around every hunk.

This file is the one place the checklist lives. The skill under
`.claude/skills/spock-commit-review` holds only the hook mechanics and the
output format the hook parses.

A diff alone is not enough. It rarely shows the lock held, the transaction
state, or the `#if PG_VERSION_NUM` branch that decides whether the change is
right, so open the functions around each hunk before judging it.

## What to check, in this order

1. **Correctness against PostgreSQL semantics**, across the supported range
   (15 to 19): locks acquired and released, snapshot visibility (catalog
   versus transaction snapshot), `CommitTransactionCommand()` inside a
   worker's transaction, `PreventInTransactionBlock()`, memory context
   lifetime, `ereport` levels, and anything that differs between majors. Right
   on 17 and wrong on 15 is wrong.
2. **Worker and transaction state.** Apply, sync, manager and failover-slot
   workers each have their own transaction and snapshot discipline. Flag any
   path that returns, errors, or loops without restoring it (PopActiveSnapshot,
   CommitTransactionCommand, ReplicationSlotRelease, lock release, GUC nest
   level), and any work on a possibly freed pointer after a commit.
3. **Races and ordering.** Signals set at commit, flags read without the lock,
   checks done before an acquire, pauses that time out, replay positions that
   move while something waits. Name the exact window and what loses data in it.
4. **Data loss and divergence.** Anything that can skip a transaction, apply
   one twice, advance a progress or origin position past work not yet applied,
   or let conflict resolution pick the wrong row. This category must never
   pass.
5. **Error handling and blast radius.** Does an error leave the subscription
   disabled, the worker crash-looping, or the postmaster restarting? Is a
   `FATAL` or `PANIC` justified? Is a provider-controlled value validated
   before it sizes an allocation or indexes an array?
6. **Version guards.** For every `#if PG_VERSION_NUM` branch: is the code
   reachable on that version, does the other branch still compile, and is a
   renamed core symbol handled on every major it changed in.
7. **Tests.** A fix without a test that fails before it and passes after it
   is incomplete unless the commit says why none is possible. Check that the
   test exercises the changed path, is in `tests/tap/schedule` or the regress
   list, takes a number no other test uses, does not depend on timing
   (sleeps, two separate queries that should be one), and skips loudly
   (`plan skip_all`) when a prerequisite such as `pageinspect` or injection
   points is missing rather than passing with fewer tests.
8. **Project conventions.** Comments short and factual, PostgreSQL style, no em
   dashes anywhere in code, comments, SQL, tests or messages. Commit subject:
   one capitalized line ending with a period, prefixed `Issue (#N): ` when an
   issue exists; body in plain paragraphs explaining the problem and the fix;
   no attribution trailers (no `Co-Authored-By`, no "Generated with").
   pgindent layout. Error message prefix `SPOCK ...:` where the file already
   does so.
9. **Scope.** Changes the message does not cover, or a fix that the other
   maintained branch (`main` versus `v5_STABLE`) also needs and the message
   does not mention.

## How to judge

Be concrete and adversarial. For each finding, show the line, the sequence of
events that triggers it (the input, the version), and the consequence. "Could
be a problem" is not a finding; "on PG 15 this reads `restart_lsn` after
`InvalidateObsoleteReplicationSlots()` cleared it, so the copy is never
recreated" is. If you reject, say exactly what change or evidence would make
you approve. If you approve, say what you checked and found sound, because an
approval with no evidence is the same as not reviewing.

Do not pad. Do not list style nits ahead of correctness. Do not soften a
rejection because the change is small, the author is senior, or the commit
message sounds confident. Do not approve to be agreeable.

## Verdict

Report a single `APPROVE` or `REJECT`, a one or two sentence summary, the
findings most severe first (file:line, what happens, consequence, fix), what
you checked and found sound, and whether the commit message is accurate.

Severity: critical = data loss, divergence, crash of the postmaster or a
cluster-wide effect; high = a worker crash, a stuck subscription, a wrong
result on some supported version or configuration; medium = correctness that
needs an unusual condition, or a test that proves nothing; low = convention.

Reject on any critical or high finding, on a fix with no test and no stated
reason, and on a commit message that misstates what the change does. Approve
only when you have opened the surrounding code for every hunk and found
nothing of medium severity or above.
