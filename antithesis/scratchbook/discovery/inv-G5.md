# Investigation summary: group G5

Shared findings:
- Antithesis clock skips are global (shared virtual time), forward or backward
  (`/docs/product/writing_tests/controlling_faults/fault_types/`). A global
  backward skip is enough to reach L2 ties, L3 (with a restart) and the
  `handle_commit` progress Assert. No per-node clock fault is needed.
- Branch `origin/task/SPOC-688/apply-clock-skew-fix` (4e0988de, not in main at
  69d9228f) removes the `handle_commit` Assert. Clock-fault runs on cassert
  need it, or every backward skip crash-loops all nodes.
- 64ea462d changed the equal-ts tiebreak from writer-vs-writer (converges) to
  applying-node-vs-sender. Both reasons the commit gives are already handled by
  the same-origin shortcut and node-id collision check added in the same commit.
- Patch 025 rewrites `xactStopTimestamp` and the WAL `xact_time` before
  `TransactionTreeSetCommitTsData`. So the origin's `pg_commit_ts` value is
  the same one that is sent and stored on peers.

## contested-rows-converge-after-quiesce
- resolved: strict form kept (no exception_log "explanation"); Antithesis can reach L2/L3 with global backward skips
- remaining:
  - Is the applying-node tiebreak (64ea462d), which lets 3 nodes diverge on equal commit ts, intended? `(needs human input)`
  - Is divergence from the restart-unsafe commit clock (L3) an accepted limit? `(needs human input)`
- property changed?: yes. Fault plan only: global backward clock skips are enough. Cassert clock runs need the SPOC-688 fix.
- invalidated?: no

## luw-final-version-has-max-commit-ts
- resolved: origin `pg_xact_commit_timestamp(xid)` equals the timestamp sent to peers (oracle valid); L3 reachable with backward skip + restart
- remaining:
  - Is the restart-unsafe commit clock (patch 025 TODO, unchanged through PG19, no fix on any branch) an accepted limit? `(needs human input)`
  - Which tie rule is intended: lower tiebreaker of the two writers (docs, pre-64ea462d code) or applying node vs sender (current code)? `(needs human input)`
- property changed?: no (the oracle is confirmed)
- invalidated?: no

## local-overwrite-gets-later-commit-ts
- resolved: no clock restore exists or is in progress on any branch (Spock never calls XLogSetLastTransactionStopTimestamp); per-container clocks not needed (global backward skip + restart reaches L3)
- remaining:
  - Is the restart gap in the commit clock an accepted limit, and is a maximum clock skew documented? `(needs human input)`
- property changed?: yes. Fault requirements: a backward skip (global is fine) plus a restart of X. Skew between nodes is not needed.
- invalidated?: no

## luw-tiebreak-against-third-origin-row-reached
- resolved: per-container skew not needed; global backward skip makes cross-node ties likely (no test-only knob needed)
- remaining:
  - Which pair is the tiebreaker meant to compare: the two writers (pre-64ea462d rule, docs wording) or the applying node vs the sender (current code)? `(needs human input)`
- property changed?: yes. Fault plan: global backward skips. Cassert caveat (SPOC-688 fix).
- invalidated?: no

## clock-step-forward-makes-commit-ts-ties
- resolved: Antithesis steps all clocks at once; per-node fake not needed (libfaketime-style custom fault optional); the +1 us bump only promises per-node order, so ties across nodes are expected and go to the tiebreaker
- remaining:
  - Is the applying-node tiebreak intended (L2)? Decides how much these ties matter. `(needs human input)`
- property changed?: yes. The mechanism is also reached by a global backward skip, which opens the window on every node. Prose should say "clock step (global backward or per-node forward)". The invariant and Sometimes stay the same.
- invalidated?: no

## apply-survives-provider-clock-ahead
- resolved: per-container clocks not needed (any global backward skip trips it on every node); the team already treats the Assert as wrong (SPOC-688 branch removes it)
- remaining:
  - Will the SPOC-688 fix (branch task/SPOC-688/apply-clock-skew-fix, removes the Assert) be merged, and should the Antithesis image include it before clock faults are enabled? `(partial: team already treats the Assert as wrong; branch not yet in main at 69d9228f)`
- property changed?: yes. Its role is a gate. Suggest building the image from main + 4e0988de. After that it is a regression guard.
- invalidated?: no

## luw-unchanged-toast-no-mixed-rows
- resolved: REPLICA IDENTITY FULL / log_old_value do not change it; delta columns add no new mixing
- remaining:
  - Is the partial-row merge on remote-wins with an unchanged TOAST column known and accepted? (Inherited unchanged from pglogical; not documented in either.) `(needs human input)`
- property changed?: no. Side lead noted: an out-of-line unchanged numeric delta column would pass the 0xfbadbeef placeholder to delta_apply_numeric. Not verified.
- invalidated?: no

## replicated-values-mean-same-on-every-node
- resolved: force_text_transfer forces 't' for every column and avoids both cases; per-node DateStyle/TimeZone is a harness choice (recommended: set it)
- remaining:
  - Is the raw 'i' transfer of OID-alias types accepted, given no doc says binary transfer needs identical OIDs? `(needs human input)`
  - Is `money` supported across nodes with different `lc_monetary`? `(partial: default 'i' copies raw int64 so meaning follows each node's locale; text path uses unpinned lc_monetary on both sides)`
- property changed?: no (harness should set per-node session settings)
- invalidated?: no
