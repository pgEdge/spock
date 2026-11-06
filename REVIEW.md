# Reviewing a change to Spock

Spock does multi-master logical replication: an output plugin on the provider,
apply and sync background workers on the subscriber, conflict resolution with
commit timestamps, AutoDDL, failover slots on standbys, and SQL-callable
management functions. A mistake here can lose data silently or take a cluster
through crash recovery, so the bar is high. Review a change assuming it has a
defect until you have checked the places one would hide.

## How to run a review

- On demand, in a Claude Code session: `/spock-commit-review`. It reads the
  staged change and prints a verdict.
- As a pre-commit gate: the `spock-commit-review` skill installs a git hook
  (`.claude/skills/spock-commit-review/scripts/install-hook.sh`). It is opt-in
  and off by default; enable it with `git config --global spock.commitReview
  true`, or for one commit with `SPOCK_REVIEW=on`. `SPOCK_REVIEW=skip`
  bypasses one commit while it is on.
- By hand: work through the checklist below against the diff and the code
  around every hunk.

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
7. **Tests.** A fix wants a test that fails before it and passes after, unless
   the change says why none is possible. The test should exercise the changed
   path, be listed in `tests/tap/schedule` or the regress list, take a unique
   number, avoid timing dependence, and skip loudly (`plan skip_all`) when a
   prerequisite is missing rather than passing with fewer tests.
8. **Project conventions.** Comments short and factual, PostgreSQL style, no em
   dashes anywhere in code, comments, SQL, tests or messages. Commit subject:
   one capitalized line ending with a period, prefixed `Issue (#N): ` when an
   issue exists; body in plain paragraphs explaining the problem and the fix;
   no attribution trailers. pgindent layout. Error message prefix `SPOCK ...:`
   where the file already does so.
9. **Scope.** Changes the message does not cover, or a fix that the other
   maintained branch (`main` versus `v5_STABLE`) also needs and the message
   does not mention.

## How to judge

Be concrete. For each finding, show the line, the sequence of events that
triggers it (the input, the version), and the consequence. "Could be a
problem" is not a finding; "on PG 15 this reads `restart_lsn` after
`InvalidateObsoleteReplicationSlots()` cleared it, so the copy is never
recreated" is. If you reject, say exactly what would change your mind. If you
approve, say what you checked and found sound.

## Verdict

Report a single `APPROVE` or `REJECT`, a one or two sentence summary, the
findings most severe first (file:line, what happens, consequence, fix), what
you checked and found sound, and whether the commit message is accurate.
Reject on any finding that loses data, diverges, crashes the postmaster, hangs
a worker, or is wrong on some supported version, and on a fix with no test and
no stated reason.
