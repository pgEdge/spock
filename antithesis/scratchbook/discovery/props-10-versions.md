---
sut_path: /home/msharp/dev/pgedgea/spock
commit: 69d9228f5df363761dc3ae6eebf7e2fcfe49b8e5
updated: 2026-10-13
external_references: []
---

# Properties: Version Compatibility (focus 10)

Lens: protocol 4 vs 5 negotiation and framing, mixed 5.0.x / 6.0 clusters
(rolling upgrade, ZODAN joining a newer node), extension upgrade scripts, and
PostgreSQL-major differences.

The planned first topology is a single version (6.0 on PG18). Properties are
grouped by what they need:

- **Single-version (run in the first topology):** the 6.0 <-> 6.0 links all use
  protocol 5, so v5 framing bugs are reachable now.
- **Mixed-version (second configuration):** need a 5.0.11 build next to 6.0.
- **Mixed PG major:** need two PG builds; low priority.

## Protocol framing on 6.0 links (single-version topology)

These cover the per-message protocol-5 header and the rule that the subscriber
learns the version from the startup message. They are reachable with the
planned n1-n3 mesh.

### proto5-replay-reparses-startup-message — Exception replay re-reads the startup message with protocol-5 framing

| | |
|---|---|
| **Type** | Safety |
| **Property** | When the apply worker replays its queue after a data error, every queued message is parsed with the protocol framing it was received with; in particular the startup message ('S', never prefixed) is not re-read as a protocol-5 message. |
| **Invariant** | SUT-side (missing): store the parse version on each replay-queue entry when appended; at replay `Always(entry version == current parse version, "replayed message parsed with the protocol version it was received with")`. Plus `Unreachable("apply received unknown protocol action")` in the `replication_handler` default case. `Always`/`Unreachable` because a misparse is never legitimate. Workload-side consequence check is `progress-insert-lsn-never-ahead-of-provider`. Add `Sometimes(replay starts with 'S' at queue head)` as an exploration hint. |
| **Antithesis Angle** | Needs a fresh connection (reconnect after partition, worker or node restart, `apply_idle_timeout`) whose first committed remote transaction hits a data error not already recorded (update_missing after retries, cross-upstream unique violation). The 'S' entry stays at the queue head until the first COMMIT (`apply_replay_queue_reset` is only called from `handle_commit`). Code reading: the replay reads `'S' 0x01 "max_pr"` as LSN `53016D61/785F7072`, stores it in `spock.progress`, then fails with `unknown action of type o`; TRANSDISCARD/DISCARD exit the worker, SUB_DISABLE disables the subscription. |
| **Why It Matters** | Corrupts `spock.progress.remote_insert_lsn` and lag reporting permanently (max-kept, dumped to `resource.dat`, copied to new nodes by add_node), and forces a graceful exit during replay right after the abort record set the origin to `commit_lsn` — the exact trigger of lead L7 (possible silent skip with no `exception_log` row). Introduced with the v5 header (72b7980a); does not happen on protocol 4. |

**Open Questions:**

- Does replay really begin at the 'S' entry? `(partial: code shows no queue reset before the first COMMIT; not run — a short TAP repro settles it)`
- Does the second worker always handle the transaction correctly from the shmem marker?
- With L7: does the abort advance the origin to `commit_lsn`, and does restart at exactly that LSN resend or skip?
- Which skip_lsn does `spock_disable_subscription` record on this path under SUB_DISABLE?

Confidence: high (mechanism, code-read end to end); medium (downstream impact)
Evidence file: properties/proto5-replay-reparses-startup-message.md

### progress-insert-lsn-never-ahead-of-provider — Recorded provider LSNs never exceed the provider's WAL

| | |
|---|---|
| **Type** | Safety |
| **Property** | For every subscriber S and provider P, `spock.progress.remote_insert_lsn` and `received_lsn` for P on S never exceed the highest WAL insert LSN P has reached. |
| **Invariant** | Workload-side `Always(remote_insert_lsn <= maxP && received_lsn <= maxP)`, where the workload reads S's `spock.progress` first and then P's `pg_current_wal_insert_lsn()`, tracking `maxP` as the highest value ever observed on P. `Always` because S can never legitimately know of WAL that P never wrote; using the max observed value avoids a false positive when P loses unflushed WAL in a crash. |
| **Antithesis Angle** | Passive cross-node oracle checked at every check point, not only at quiesce. Fires on any header offset error in v5 (prefix on every message) or v4 (suffix on COMMIT) parsing, on stream or replay, including the 'S' replay misparse. |
| **Why It Matters** | `remote_insert_lsn` feeds lag monitoring, add_node progress seeding (`read_peer_progress`) and `resource.dat`. Wrong values are silent: no Assert in `spock_group_progress_update` catches a too-large value. |

**Open Questions:**

- Can a keepalive legitimately report `received_lsn` above P's insert LSN? If yes, check only `remote_insert_lsn`.

Confidence: medium-high
Evidence file: properties/progress-insert-lsn-never-ahead-of-provider.md

### startup-message-precedes-all-stream-data — The subscriber never parses data before it knows the protocol version

| | |
|---|---|
| **Type** | Safety |
| **Property** | On every replication connection the first non-keepalive message the subscriber handles is the startup message, and on 6.0 <-> 6.0 links the version it announces is 5. |
| **Invariant** | SUT-side (missing): per-connection `startup_seen` flag set in `handle_startup`; before `replication_handler` for any other action, `Always(startup_seen, "apply parses stream data only after the startup message")`. In `handle_startup_param` for `proto_version`: `Always(version == 5 when both sides are 6.0)`. `Reachable` at the `pg_decode_message` branch that sends 'S' before a sync_event (the fdd9587e path). |
| **Antithesis Angle** | The trigger is "first item decoded on a fresh walsender is a non-transactional message". Reconnects (partitions, restarts) followed by workload barriers (`sync_event`) or add_node's sync events right after slot creation produce it. The rule is kept by hand at two write sites in the output plugin. |
| **Why It Matters** | Regression guard for fdd9587e, where a sync_event before any BEGIN "caus[ed] a protocol version mismatch that crashes the apply worker". Any new pre-BEGIN writer reintroduces it, and only on v5 links. |

**Open Questions:**

- Does anything else write a Spock-prefixed non-transactional message (beyond sync_event and repair mode)?
- Will a GUC to cap the protocol version be added for upgrades? If so the second assertion must read it.

Confidence: medium
Evidence file: properties/startup-message-precedes-all-stream-data.md

## Mixed 5.0.x / 6.0 clusters (needs a mixed-version topology)

These need a 5.0.11 build next to 6.0 (two install trees as in
`099_zodan_mixed_version.pl`, and a node-level switch for which tree starts).
They run code that a 6.0-only cluster never executes: the v4 writer/reader
branches in 6.0, the pre-6.0 progress-table path in the sync worker, and the
5.x apply code itself.

### mixed-version-add-node-loses-nothing — A 6.0 node joins a 5.x or mixed cluster without missing or duplicating rows

| | |
|---|---|
| **Type** | Safety |
| **Property** | An add_node of a 6.0 node into a cluster with at least one 5.0.x node, under writes and faults, either fails visibly or leaves the new node with exactly the union of committed rows. |
| **Invariant** | Workload-side `Always` after a successful add and quiesce: ledger rows from every existing node present exactly once on the new node, with source and peer versions in the details. `Sometimes(add succeeded with a 5.x source)` and `Sometimes(add succeeded with a 5.x non-source peer)`. SUT-side (missing) `Unreachable`: sync worker on the pre-6.0 path read zero peer rows while the provider has enabled subscriptions from other nodes. |
| **Antithesis Angle** | Pause the 5.x provider during slot creation (exercises the 5.x pause code, not the 6.0 one), partition or kill a 5.x peer between Phase 3 and Phase 7, restart the source between its binary swap and its extension update (the "6.0 binary, 5.x catalog" window where the frozen progress table can drop a new peer and Phase 7 falls back to `pg_current_wal_lsn()`). |
| **Why It Matters** | New code (f8f78b2e, adfd708b, 40c7b39a: three fixes in two weeks, Sept 2026) on the highest-risk feature, and the path customers are told to use to start an upgrade. The only test (099, nightly) has no faults and no per-row check. |

**Open Questions:**

- Does the v5_STABLE pause implementation have the L4 self-resume / xid-less window issues?
- Is adding a node while some node is in the "6.0 binary, 5.x catalog" state supported?

Confidence: medium
Evidence file: properties/mixed-version-add-node-loses-nothing.md

### mixed-version-mesh-applies-exactly-once — Protocol-4 links in a mixed mesh keep exactly-once and convergence

| | |
|---|---|
| **Type** | Safety |
| **Property** | In a mesh where some nodes run 5.0.11 and some 6.0, every committed ledger row reaches every node exactly once and documented-resolvable conflicts converge, on v4 links as on v5 links. |
| **Invariant** | Reuse the single-version ledger and convergence `Always` checks, with each link's protocol version in the details so failures are attributable. `Sometimes(a protocol-4 link carried a transaction that hit a conflict)`. |
| **Antithesis Angle** | Same faults as the single-version mesh. New interleavings come from v4 framing (`remote_insert_lsn` only at COMMIT), the 5.x progress table lagging up to 1 s, and 5.x apply/crash code that lacks 6.0 fixes. |
| **Why It Matters** | Mixed clusters are a documented state during every 5.0 -> 6.0 upgrade ("zero-downtime rolling upgrades"); the 6.0 v4 code paths have no other way to run; `014_rolling_upgrade` is commented out of the schedule. |

**Open Questions:**

- Is 5.0.9 (old equal-timestamp tiebreak) a supported mixed partner, or is 5.0.10+ the real floor?
- Are 5.x-side failures (missing 6.0 fixes) in scope during an upgrade, or filtered?
- Does 5.0.x behaviour that depends on PG patch 035 change on a PG built from HEAD's patch set?

Confidence: medium
Evidence file: properties/mixed-version-mesh-applies-exactly-once.md

### rolling-upgrade-node-restart-loses-nothing — Swapping one node from 5.0.11 to 6.0 under load loses and duplicates nothing

| | |
|---|---|
| **Type** | Safety |
| **Property** | Restarting one node on the 6.0 binary while others keep writing loses and duplicates no transaction on any link, the node's catalog reaches 6.0.0, and every subscription resumes with the right protocol. |
| **Invariant** | Workload-side `Always` at quiesce: ledger exactly-once; every node's `extversion` equals its library `spock.spock_version()`; no subscription disabled and no `exception_log` rows in the upgrade phase. `Sometimes(extversion reached 6.0.0 on the upgraded node)` for the liveness side. |
| **Antithesis Angle** | Kill during the manager's automatic `ALTER EXTENSION UPDATE` (script also calls non-transactional `slot_enable_failover()`), partitions during catch-up through v4 walsenders, first 6.0 start with no `resource.dat` (progress rebuilt by reconcile). |
| **Why It Matters** | The documented upgrade procedure; release notes claim zero downtime; the upgrade script drops and recreates `spock.progress` and touches slots. |

**Open Questions:**

- Should walsenders and peer SQL be served in the "6.0 binary, 5.x catalog" window?
- Can the automatic `ALTER EXTENSION` be held up by peer lock holders under load, delaying apply start?
- Is a spock swap without a PG rebuild supported, given the differing PG18 patch sets?

Confidence: medium
Evidence file: properties/rolling-upgrade-node-restart-loses-nothing.md

## Mixed PostgreSQL majors (low priority)

### cross-pg-major-links-replicate-identically — Text-transfer links between PG majors replicate identically

| | |
|---|---|
| **Type** | Safety |
| **Property** | On a link between different PG majors (text datum transfer), every row arrives with the same value and exactly once, as on same-major (binary) links. |
| **Invariant** | Workload-side `Always` at quiesce: ordered per-row text dumps equal across nodes and ledger exactly-once. `Sometimes(a cross-major link applied a transaction)`. |
| **Antithesis Angle** | Little beyond the same-major mesh; the risk is mostly deterministic (type text round-trips). The same publisher text path can be reached in the single-version topology with one `force_text_transfer = true` subscription, which is the suggested cheaper route. |
| **Why It Matters** | v5.0 release notes claim PG major upgrades by adding a new-major node and removing old ones; binary transfer is only allowed for equal majors (`check_binary_compatibility`). |

**Open Questions:**

- Is a cross-major cluster supported beyond the add/remove transition?
- Does `force_text_transfer` exercise the same subscriber input path as a cross-major link?

Confidence: low
Evidence file: properties/cross-pg-major-links-replicate-identically.md

---

## Areas examined

- **Protocol negotiation** (`pg_decode_startup`, `src/spock_output_plugin.c:225-490`;
  `spock_start_replication`, `src/spock.c:686-770`; `include/spock_output_proto.h`):
  6.0 speaks 4-5, 5.0.x speaks 3-4 (`git show v5.0.9:include/spock_output_proto.h`).
  6.0 <-> 5.0.x negotiates 4 both ways; incompatible ranges ERROR in the
  walsender startup, and the subscriber FATALs at `START_REPLICATION` and
  restarts every `restart_delay_default` (expected, deterministic, not a
  property). Mismatched `spock_version` strings only log.
- **Framing** (`src/spock_proto_native.c`): v5 prefixes every message except
  'S' with `GetXLogWriteRecPtr()`; v4 appends it to COMMIT only. ORIGIN name
  only on v5. 5.0.x COMMIT layout matches the 6.0 v4 reader (checked against
  v5.0.9). Subscriber parse version: process static defaulting to 4, set only
  by 'S' — source of the replay finding.
- **Lazy startup message** (fdd9587e) and non-transactional sync_event: same
  semantics on 5.0.9+ (backported), so no cross-version barrier difference.
- **Conflict semantics across versions:** DELETE now resolved by timestamp in
  6.0 (only matters for races already excluded as no-tombstone divergence);
  equal-timestamp tiebreak changed in 5.0.10/6.0 (5.0.9 differs).
- **Upgrade scripts** (`sql/spock--5.0.0--5.0.1.sql` ... `spock--5.0.11--6.0.0.sql`)
  and the automatic `ALTER EXTENSION` in the manager. Schema equality after
  upgrade vs fresh install is deterministic (TAP `018_upgrade_schema_match`,
  commented out of the schedule) and not an Antithesis target. The 6.0 tree has
  no `spock--5.0.0.sql`, so a 5.x catalog can only come from a real 5.x install.
- **Mixed-version add_node** (zodan version rule, progress column switch,
  sync-worker catalog probe) and its fix history (f8f78b2e, adfd708b, 40c7b39a,
  3c7ed175 on a side branch).
- **PG-major differences on the PG18 target:** failover-slots worker absent
  on PG18 (native slotsync) — no property here, needs a standby topology;
  conflict stats (pgstat kind 29, PG18+) — reset after crash, not transactional
  with the apply transaction (reported before resolutions rows commit), so
  they are not a reliable oracle and no property is proposed; row-filter
  snapshot handling differs below PG18; `FAILOVER` slot flag only for PG17+
  providers; structure sync refuses newer-major upstreams.
- **Tests:** `014_rolling_upgrade` (commented out), `018_upgrade_schema_match`
  (commented out), `099_zodan_mixed_version` (nightly, no faults, count-level
  checks).

## Assumptions affecting multiple properties

- The old build for mixed configurations is 5.0.11 (v5_STABLE). 5.0.9 differs
  in tie-break semantics and would need extra workload exclusions.
- Both versions can run on PG installs built from their own patch sets; 099
  shows both load on copies of one PG install, but behavioural differences from
  patches only on v5_STABLE (035, 090) were not checked.
- The stock PG behaviour assumed by L7 (abort record advances the session
  origin; decoding resends a transaction whose commit starts exactly at the
  restart LSN) determines how bad the replay misparse is; see sut-analysis §16.1-2.
- Node termination in Antithesis may lose written-but-unflushed WAL; the
  insert-LSN oracle compares against the highest value ever observed to stay
  safe under that.
- **Is a mixed-version topology worth it?** Yes for one later configuration
  (n1 on 5.0.11, n2/n3 on 6.0, n4 joins on 6.0), mainly for
  `mixed-version-add-node-loses-nothing`; the mesh and swap properties ride on
  the same setup. Not for the first run: the single-version topology already
  reaches the v5 framing bugs, and the mixed state is transitional.
  Mixed PG majors: not worth it; use `force_text_transfer` instead.
