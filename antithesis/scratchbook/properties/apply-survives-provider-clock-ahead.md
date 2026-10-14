# apply-survives-provider-clock-ahead — A subscriber behind its provider's clock does not crash

## Synthesis note

Merged from `apply-survives-provider-clock-ahead` (F7) and
`no-assert-crash-when-remote-commit-ts-ahead` (F3): the same Assert, the same
trigger.

**Confirmed by code reading (synthesis step, HEAD 69d9228f):**
`src/spock_apply.c:1169` sets `.last_updated_ts = GetCurrentTimestamp()` in the
progress struct built in `handle_commit`, and `:1173-1174` reads

```c
/* XXX: Don't care in production yet */
Assert(sap.last_updated_ts >= sap.remote_commit_ts);
```

`remote_commit_ts` is the provider's commit timestamp. Any provider clock ahead
of the subscriber's by more than the apply latency fails the Assert on a
cassert build, the postmaster crash-restarts the node, the provider resends
the transaction, and it fails again while the skew lasts.

Assertion type disagreement: F3 proposed `AlwaysOrUnreachable("applied remote
commit ts is not ahead of local wall clock")`; F7 proposed
`Unreachable("handle_commit progress assert: remote commit ts ahead of local
clock")`. The two are the same check written from opposite sides. Resolution:
the guarantee is "the subscriber never crashes here", and the state itself
(remote ts ahead of local clock) is normal under skew, so the catalog uses a
workload-side `Unreachable("spock apply process aborted by an Assert")` on the
log (TRAP line from a spock source file, or a postmaster restart with
"terminated by signal 6" outside injected kills), plus the SUT-side
`AlwaysOrUnreachable` placed just before the Assert as a precise locator. The
property is expected to fail as soon as clock faults run on a cassert build;
its main job is to gate clock-fault runs (fix or remove the Assert, or run
clock faults on a non-cassert build).

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (wildcard (odd things), implementability (property finding), coverage-balance F4); see `evaluation/synthesis.md`.

Current catalog line: Priority: P2 · Topology: v1 · Faults: clock skew

- Priority note: lowered from P0 in evaluation: the gate is now a build step (the clock-fault image is built from main plus 4e0988de, which merges onto HEAD without conflicts), so in that image this is a regression guard. On an image without the fix, keep clock faults off.
- Placement: build step — the clock-fault image includes 4e0988de; after that a regression guard. The workload `Unreachable` reads the TRAP line through `logging_collector` and `pg_read_file`.
- Merge check: `git merge-tree --write-tree HEAD 4e0988de` merges without conflicts; 4e0988de removes the Assert at `src/spock_apply.c:1173-1174`.

## Open questions

- Will the SPOC-688 fix (branch `task/SPOC-688/apply-clock-skew-fix`, removes the Assert) be merged, and should the Antithesis image include it before clock faults are enabled? `(partial: team already treats the Assert as wrong; branch not yet in main at 69d9228f; 4e0988de merges onto HEAD without conflicts, so the clock-fault image is built from main plus 4e0988de)`

Resolved (see log):

- **The team considers the Assert wrong.** Branch
  `origin/task/SPOC-688/apply-clock-skew-fix`, commit 4e0988de ("apply: handle
  clock skew in progress tracking"), deletes it with the comment "The origin
  commit time and local apply time come from independent clocks, so no
  ordering relationship is required between them", and reworks
  `progress_update_struct` so `remote_commit_lsn` advances independently of
  the timestamp. A TAP test (`047_progress_clock_skew.pl`, commit fde35e71)
  covers forwarded commits with older timestamps but does not change any
  clock. Not merged into main at HEAD 69d9228f.
- **Per-container clocks are not needed.** Antithesis clock skips are global,
  but a global backward skip trips the Assert on every node: commits in flight
  carry pre-skip timestamps, and patch 025 then stamps every local commit at
  `clock + 1 us`, above all nodes' wall clocks, until wall time catches up.
  So this fires on the first applied commit after any backward skip.

Property change: none to the invariant. Priority/role: this is a gate. With
the current HEAD and cassert, every backward clock skip crash-loops all nodes
and hides the clock-dependent LUW properties. Recommended plan: build the
Antithesis image from main plus 4e0988de (or after SPOC-688 merges); then this
property becomes a regression guard (any Assert-driven abort in the apply
process is a finding). Forward skips alone never trip it.

## Source: `apply-survives-provider-clock-ahead` (F7 Distributed)

### What the property says

A subscriber whose wall clock is behind its provider's keeps applying that
provider's transactions. It must not crash. In the planned cassert build, a
debug `Assert` in `handle_commit` fails as soon as an applied commit's
timestamp is later than the subscriber's current time, which aborts the apply
worker and makes the postmaster restart the whole node.

### Code (code-checked at HEAD 69d9228f)

`handle_commit`, `src/spock_apply.c:~1148-1177`:

```c
SpockApplyProgress sap = {
    ...
    .remote_commit_ts = commit_time,          /* provider's commit ts */
    ...
    /* XXX: Could we use commit_ts value instead? */
    .last_updated_ts = GetCurrentTimestamp(), /* subscriber wall clock */
    ...
};
/* XXX: Don't care in production yet */
Assert(sap.last_updated_ts >= sap.remote_commit_ts);
```

- `commit_time` is the provider's commit timestamp. With the commit-clock
  patch it can also be ahead of the provider's own wall clock (Lamport bump).
- Any skew where provider time minus subscriber time is larger than the
  replication delay makes the Assert fail.
- Under `--enable-cassert` (the planned image, `Dockerfile-step-1.el9`), the
  failure is `abort()` in a bgworker -> postmaster crash-restart -> the same
  transaction is re-sent after restart -> the Assert fails again while skew
  lasts. The node keeps crash-looping and its local clients get disconnected.
- In a production (non-cassert) build the line does nothing, and
  `spock.lag_tracker.replication_lag` (`last_updated_ts - remote_commit_ts`,
  `sql/spock--6.0.0.sql:823-845`) shows a negative lag.

Spock's conflict model (LUW plus the commit-clock patch) exists because node
clocks differ; this Assert assumes they do not. Introduced with the
resource-manager work (b8f1eea9, per `git log -L`).

### Why it matters

- For Antithesis it decides whether clock faults can be enabled with the
  cassert build at all: if the Assert fires, every clock-skew timeline turns
  into a crash loop that hides the LUW properties
  (`luw-final-version-has-max-commit-ts`, `local-overwrite-gets-later-commit-ts`).
- It is a real defect in debug builds that developers and CI use, and it
  marks an unchecked assumption about clocks in the progress code.

### Assertion

`Unreachable("handle_commit progress assert: remote commit ts ahead of local clock")`
placed just before the existing `Assert` (missing; no Antithesis assertions
exist), with both timestamps and the subscription name as details. Unreachable
is the right type: Spock claims to tolerate clock differences, so this state
being hit is the bug itself, independent of whether the build has cassert.
Workload-side backup: count postmaster restarts not caused by an injected
kill (server log line "terminated by signal 6: Aborted" for a
"spock apply" process).

### Fault requirements

- Clock skew/jitter where a provider is ahead of a subscriber. **Required.**
- Nothing else; any applied commit triggers it.

### Original open-question notes (detail for the combined list above)
- Should the harness build without cassert for clock-fault runs, or should the
  Assert be removed/relaxed first? Answer decides whether clock faults and
  cassert can share a run. (needs human input)
- Does Antithesis clock jitter apply per container (skew between nodes) or to
  the whole simulation? If whole-simulation only, provider-ahead skew may need
  a custom fault (e.g. `faketime`-style offset per node).

## Source: `no-assert-crash-when-remote-commit-ts-ahead` (F3 Failure Recovery)

### What the property says

A subscriber never crash-restarts because a provider's commit timestamp is
ahead of the subscriber's wall clock. In the Antithesis build (cassert on),
the progress-update Assert in `handle_commit` must never fail.

### The code

`handle_commit()` after `CommitTransactionCommand()` builds the progress
entry (`src/spock_apply.c:~1140-1170`):

```c
SpockApplyProgress sap = {
    ...
    .remote_commit_ts = commit_time,          /* provider commit ts */
    ...
    .last_updated_ts = GetCurrentTimestamp(), /* subscriber wall clock */
    ...
};
/* XXX: Don't care in production yet */
Assert(sap.last_updated_ts >= sap.remote_commit_ts);
```

`commit_time` is the provider's commit timestamp. The Assert fails whenever
the provider's commit ts is ahead of the subscriber's wall clock at apply
time, that is, whenever skew (provider ahead) is larger than replication
latency.

The commit clock patch makes it worse: a node that applied a remote
transaction raises its logical clock to that remote ts, and its own next
local commits get ts above it (`pgNN-025-logical_commit_clock.diff`). So one
node with a fast clock pushes the commit ts of every node that applies its
transactions ahead of their wall clocks, and the third node sees "future"
timestamps from both peers.

### Recovery effect (why this is in the failure-recovery set)

1. The Assert fires after the local commit, in a cassert build. The backend
   aborts (SIGABRT), the postmaster does a crash restart of the whole
   instance: all Spock shared memory is reset, every apply worker on the node
   dies.
2. The apply commit was async (`synchronous_commit=off`) and the origin
   advance was in memory only (L1), so after restart the provider resends
   the same transaction (or more).
3. Its commit ts is still ahead of the subscriber's wall clock until the
   clock catches up, so the same Assert fires again: a crash loop that lasts
   about as long as the skew, with a whole-instance restart per loop.
4. Each loop is another chance for duplicate apply (L1) and for every other
   crash-recovery path.

In a production (non-cassert) build the Assert is a no-op and
`spock.progress` just shows negative lag. Deployment-topology keeps cassert on
and asks that an Assert-caused postmaster restart be treated as a finding.
This property makes that rule concrete for the one Assert known to depend on
cross-node clocks.

Other Asserts in the same path with their own conditions:
`progress_update_struct` (`src/spock_group.c:345-361`) and
`spock_group_progress_update_ptr` (`:449-451`). Those compare LSNs and the
zero/non-zero pairing of timestamps; not clock dependent as far as read.

### Assertions

- **SUT-side (missing, no existing assertions):** just before the existing
  `Assert` at `src/spock_apply.c:~1165`,
  `AlwaysOrUnreachable("applied remote commit ts is not ahead of local wall
  clock", {remote_commit_ts, local_now, provider id})`. Antithesis then
  reports it as a property failure with details instead of an opaque
  SIGABRT. AlwaysOrUnreachable rather than Always: the line runs on every
  applied commit, but it is fine for a run with no applied commits to never
  reach it.
- **Workload/log-side:** `Unreachable("postgres log contains TRAP: failed
  Assert in spock source")` from a log tailer on each node. Covers every
  Spock Assert, not only this one; the message should include the file and
  line from the TRAP line so distinct Asserts are distinct findings.

### Fault requirements

- **Clock skew** with a provider ahead of a subscriber by more than apply
  latency (milliseconds is enough). Required.
- No other fault needed. With clock faults on, this will likely fire early
  and mask other findings; see open questions.

### Original open-question notes (detail for the combined list above)
- **Should the Antithesis build keep this Assert?** If the team agrees it is a
  development-only check that is wrong under skew, either remove it or build
  with it disabled, or the run will spend its time in crash loops. If the team
  wants it kept as a "clocks must be synced" guard, then clock faults must be
  bounded below the replication latency, which removes most of the value of
  clock faults for L2/L3.
- **Does Antithesis skew clocks per container?** If all containers share one
  clock, this never fires in Antithesis but still fires in real deployments
  with NTP drift on dev builds.

### Investigation Log

_Entries carried over from `apply-survives-provider-clock-ahead`:_

#### Should cassert runs with clock faults be expected to hit this Assert?

- Examined: `src/spock_apply.c` handle_commit progress block,
  `src/spock_group.c:309-362` (other progress Asserts, all LSN/zero checks),
  `git log -L` on the Assert line.
- Found: comment "XXX: Don't care in production yet" right above it; no guard
  for skew.
- Not found: any test that runs nodes with different clocks
  (`005_daylight_savings` is todo_skip per sut-analysis section 8).
- Conclusion: needs human input on intent; mechanism is direct.

#### Does the Assert fire whenever the provider clock is ahead of the subscriber's? (synthesis step, 2026-10-13)

- Examined: `src/spock_apply.c:1160-1178` at HEAD 69d9228f.
- Found: `.last_updated_ts = GetCurrentTimestamp()` (`:1169`) followed by
  `/* XXX: Don't care in production yet */` and
  `Assert(sap.last_updated_ts >= sap.remote_commit_ts)` (`:1173-1174`). No
  guard for skew between the two values.
- Conclusion: confirmed by code reading. A provider commit timestamp later than
  the subscriber's wall clock at apply time trips the Assert on cassert builds.
  Not yet run.

#### Should the Antithesis build keep this Assert? (2026-10-13)

- Examined: `git log --all -S"Don't care in production yet"`, `git log --all
  --grep=skew`, `git show 4e0988de`, `git show --stat fde35e71`,
  `git branch -a --contains 4e0988de`.
- Found: the Assert's comment string was last introduced by 76d53893 ("Change the Lag Tracker interface"; earlier `git log -L` pointed at b8f1eea9). Branch
  `origin/task/SPOC-688/apply-clock-skew-fix` removes it (4e0988de) and
  changes `progress_update_struct` (`src/spock_group.c`) to advance
  `remote_commit_lsn` separately and always refresh `prev_remote_ts` on commit
  records. Follow-up commits c32ace8a, fde35e71, 311f700d on the same branch.
  `git merge-base --is-ancestor` says none are in HEAD.
- Conclusion: partial. The team's direction is to remove the Assert; whether
  the Antithesis image should carry the fix before it merges is a planning
  call. `(partial: ...)` in the list above.

#### Does Antithesis skew clocks per container?

- Examined: `snouty docs show /docs/product/writing_tests/controlling_faults/fault_types/`.
- Found: "Clock skips affect every node simultaneously because Antithesis
  simulates a shared wall clock." Skips can be backward. With patch 025 a
  backward skip leaves every node's logical clock ahead of its wall clock, so
  every applied commit has `commit_time > GetCurrentTimestamp()` on the
  subscriber until wall time catches up.
- Conclusion: resolved. Built-in global backward skips reach the Assert; no
  custom per-node fault needed.
