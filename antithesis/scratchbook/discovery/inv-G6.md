# Investigation G6 — summary (2026-10-13, HEAD 69d9228f)

## add-node-success-new-node-has-every-row
- resolved: fallback safety (unsafe under writes, but unreachable on a successful add: n4 always has a (n4,X) row from `ensure_entry` at create_sub; a missing sub makes Phase 9 `sub_enable` raise); success with missing Phase 3 sub (impossible: Phase 9 fails add_node); CI frequency (moot by code; local TAP logs only echo procedure source, NOTICEs go to client)
- remaining: none
- property changed?: yes — prose refinement: fallback check becomes a pure regression guard; a peer dropped from `read_peer_progress` gives duplicates on n4 (keep the one-apply_audit-per-row check), not loss; L17 cannot reset n4's force-set row before Phase 7 (sub still disabled); live loss path is L4.
- invalidated?: no

## add-node-pause-held-until-progress-read
- resolved: self-resume is for a dead caller only (commit b8b1443b), so the contract holds; snapbuild does NOT cover the no-xid window (consistent at once when no xids run; later commits not in snapshot) — real, narrow; two concurrent captures = scope note, not v1
- remaining: none
- property changed?: yes — assertion: `resume_apply_workers` has a second caller (PG_CATCH, `src/spock_sync.c:1644`) where flag 0 is legitimate; primary SUT check becomes `Unreachable("apply worker self-resumed while the pausing backend is still alive")` in the worker timeout branch (needs owner PID in SpockCtx); flag `Always` only if limited to the success-path call.
- invalidated?: no

## add-node-success-has-sub-from-every-peer
- resolved: "success with missing Phase 3 sub" cannot happen — Phase 9 calls `sub_enable` (missing_ok=false) on every peer's sub and re-raises; Phase 10 re-raises too (3250807a)
- remaining: none
- property changed?: yes — priority suggestion: lower; now a regression guard, main lead (L20) closed at HEAD.
- invalidated?: no

## add-node-after-peer-restart-captures-every-peer
- resolved: fallback correctness (unreachable on success; guard only); LEFT JOIN (fix choice, outside property)
- remaining:
  - How wide is the gap between a source crash-restart and its X worker recreating the progress row, vs the Phase 5 `read_peer_progress` call (incl. n4 sync-worker retry)? `(partial: Phase 3/4 waits close the window before Phase 4 ends; the row is recreated at worker start before connecting to X, so a partition from X does not widen it; exact gap not measured)`
- property changed?: yes — outcome is duplicates (n4 row for X is the 0/0 `ensure_entry` row, Phase 7 skips advance, n4 re-receives X from the Phase 3 slot point), not loss; outcome check should be the duplicate side; SUT-side "read_peer_progress returned every peer" unchanged.
- invalidated?: no

## zodan-readd-node-progress-not-stale
- resolved: nothing clears SpockGroupHash rows (only new initdb); same-name re-add is supported/tested (Phase 3 drops stale origin "from a previous add_node cycle"; TAP 011/012/017/033); Phase 7 lacks the local node_id filter that Phase 3 uses (scenario B is a real query gap)
- remaining: none
- property changed?: no (prose refinement: scenario A confirmed; also triggers RECONCILE ANOMALY at Phase 9)
- invalidated?: no

## remove-node-clean-report-no-leftovers
- resolved: `sub_drop` succeeding when the remote slot drop fails is intended (code comment); no availability precondition for remove_node
- remaining:
  - Should zodremove record `sub_drop`'s "could not drop slot" WARNING in `temp_removal_status` instead of `REMOVED`? `(needs human input)`
- property changed?: yes — invariant: "no leftover slot after clean report" fires on intended behaviour (also without partition: `pg_drop_replication_slot` nowait errors while X's walsender still holds the slot); restate as `Always(every survivor slot left for n4 is reported)`; known gap at HEAD; priority medium/low.
- invalidated?: no

## progress-reconcile-anomaly-unreachable
- resolved: spock.progress role (monitoring for steady state, coordination input for ZODAN Phase 3/7; ANOMALY trusts origin so not loss); force-set keys = (db, n4, X), the live sub's key
- remaining:
  - Does the v1 workload run table resyncs (`sub_resync_table` / `repset_add_table` with sync)? If yes ANOMALY is reachable with no operator action and the Unreachable must exclude those timelines or be treated as a progress-accuracy finding. `(partial: path confirmed in code; workload choice not made yet)`
- property changed?: yes — prose refinement: no longer "pure regression guard"; live no-operator paths: re-add/retried add with peer omitted (stale row vs reset origin), and table resync writing provider progress into subscriber's live row followed by worker restart.
- invalidated?: no

## progress-commit-lsn-tracks-applied-commits
- resolved: role (freeze = monitoring error + add_node Phase 3 timeout, not data loss; Phase 7 uses ros.remote_lsn; Phase 12 uses insert-received); L3 trigger confirmed in patch 025 TODO (needs provider restart + clock behind prior logical max)
- remaining: none
- property changed?: yes — priority suggestion: medium/low (monitoring + add_node availability).
- invalidated?: no
