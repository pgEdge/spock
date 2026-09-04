# A pluggable quorum layer for Spock

**Date:** 2026-09-01 (revised after implementing all three providers)
**Status:** Implemented — layer and providers; no consumer yet
**Branch:** `QURAM` (based on `main`)

> **Revised from the original proposal.** Three things the design got wrong,
> corrected below and worth stating up front because they were the load-bearing
> assumptions:
>
> 1. **Capability tiers were dropped.** The interface is uniform. Tiering was
>    solving a problem that disappeared once the interface stopped asking for
>    storage.
> 2. **pgBully turned out to be the *most* capable provider for liveness, and
>    pgraft the least** — the opposite of what was predicted. No upstream change
>    to pgBully was needed.
> 3. **A per-tick snapshot was added** after the first implementation showed the
>    layer could make decisions against a cluster state that never existed.

## Problem

Spock decides everything about WAL retention from local catalogs.
`group_slot_evaluate()` refuses to advance the group slot when any required
member has not reported progress recently, and `spock.progress` only records what
*this* node received *from* a member, never what that member has confirmed.

So a single unreachable node pins WAL on every survivor, indefinitely — during an
incident, exactly when disk headroom matters most. There is also no notion of a
majority, so a topology change needs every node reachable.

Closing that needs agreement between nodes. It does not need Spock to implement
consensus, or to marry itself to one implementation.

## Goals

- One interface, several backends, none privileged.
- With no provider configured, behaviour is exactly as today, bit for bit.
- Uncertainty never releases WAL. A broken quorum layer degrades to today's
  conservative behaviour, never past it.
- Attaching a system requires no new build dependency in Spock core.

## Non-goals

- Spock does not implement consensus and does not arbitrate elections.
- No Raft vocabulary in the interface. No terms, no log indexes — those are one
  implementation's concepts and would leak into an interface meant to outlast it.
- Not a general cluster manager. The scope is replication decisions.

## Why the interface is uniform

The original design tiered the interface, because the backends are not equally
capable and pgBully in particular has no replicated storage. That was the wrong
cut. The interface asks only for **judgements**, never for **storage**, and once
that is true there is nothing left to negotiate: Spock already keeps its durable
state in its own crash-safe catalogs, and what it lacks is not a place to write
things down but a second opinion about who is alive.

So every provider implements the same seven entry points, and a provider with
nothing to renew supplies a `refresh()` that returns true. That is the whole
contract, in `include/spock_quorum.h`.

Every answer is three-valued:

```c
typedef enum SpockQuorumAnswer
{
    SPOCK_QUORUM_NO = 0,
    SPOCK_QUORUM_YES,
    SPOCK_QUORUM_UNKNOWN
} SpockQuorumAnswer;
```

`UNKNOWN` is deliberately not folded into `NO`. Callers treat them identically —
that is the fail-safe rule — but keeping them apart is what lets the status view
distinguish *a cluster that lost quorum* from *a provider that stopped
answering*. During an incident those demand different responses, and a boolean
cannot tell them apart. This distinction earned its keep immediately: with pgraft
selected, "pgraft is not installed" and "pgraft reports no leader" are both
failures to proceed, and an operator needs to know which one they have.

## The fail-safe contract

A layer that can release WAL can destroy a node's ability to catch up. These
rules make that impossible by construction:

1. **Uncertainty means no.** Any error, timeout, or `UNKNOWN` produces today's
   conservative behaviour. No configuration inverts this.
2. **Off the hot path.** Providers are consulted only from the group-slot
   worker's timer. Never from an apply worker, a walsender, or anything a client
   waits on.
3. **Deadlines, not hope.** Every call is bounded by `spock.quorum_timeout`
   (default 2s). Overrunning is `UNKNOWN`.
4. **Providers may not throw.** A callback that `ereport(ERROR)`s would abort the
   very tick deciding whether releasing WAL is safe. Callbacks return a status
   and an `errdetail` string.
5. **One reading per tick.** Added after implementation, see below.
6. **Releasing a member is bounded and loud.** See *Group-slot integration*.

### Rule 5, and why it was added

The first implementation consulted the provider per question. Deciding about five
members cost ten round trips — and, far worse, nothing stopped quorum from
answering YES to the first question and NO to the fourth. Decisions inside one
tick could rest on a cluster state that never existed at any instant.

The layer now takes **one reading per tick** and decides against it. Efficiency
is the lesser benefit; self-consistency is the point. Leadership and membership
are not even asked for unless quorum is held, since a partitioned minority can
still believe it leads and still see some peers, and acting on either is the
failure this layer exists to prevent.

`spock.quorum_status()` explicitly invalidates first, because an operator running
it is asking about now, not about whatever the last tick saw.

## Where providers live

Spock core ships all three providers and depends on nothing new. etcd's HTTP
client is the only external dependency, and it is detected at build time via
`curl-config` rather than required: without it the provider still compiles and is
still selectable, and reports why it cannot be used. `NO_LIBCURL=1` forces it
off. Selecting a provider you did not build is a configuration mistake, not a
reason to fail to start.

Selection is one GUC: `spock.quorum_provider = none | etcd | pgraft | pgbully`.

## What the three providers actually turned out to be

The original table was a prediction. This one is measured, and it changed again
once pgraft reached 2.0 and pgBully grew a cluster-manager API.

| | etcd | pgraft 2.0 | pgBully |
|---|---|---|---|
| Transport | HTTP/JSON (daemon) | SPI (in-database) | SPI (in-database) |
| API shape | etcd v3 | `pgraft.*` cluster manager | `pgbully.*`, **the same one** |
| Quorum | native | `leader_id` set | `leader_id` set |
| Leadership | leased key | native | native |
| **Per-member liveness** | **yes** (lease TTL) | **no** | **yes** (`peers().reachable`) |
| Name mapping | own registration | replicated KV | replicated KV |

**pgraft and pgBully are now one provider.** They expose the identical
in-database interface — `get_cluster_status()`, `get_nodes()`, `is_leader()`,
`kv_put`/`kv_get` — differing only in the schema it lives under. Keeping two
near-identical files would have guaranteed drift, so `spock_quorum_cluster.c`
implements both, parameterised by schema name.

That collapse also retired a piece of scaffolding: pgBully previously had no
replicated storage, so node names had to be recovered by joining connection
strings between `pgbully.peers()` and `spock.node_interface`. With a KV
available it registers its id-to-name mapping the same way pgraft does, and the
conninfo join is gone.

**One real difference remains, and it is not cosmetic.** pgBully publishes
`peers().reachable`; pgraft still exposes no reachability at all. So the shared
implementation takes a per-backend liveness expression: pgBully joins its peer
table, pgraft reports every configured member live.

Reporting all-live is the safe reading rather than a pretence that nothing has
failed: under rule 1 a live member is never evicted, so nothing can be released
on the strength of a backend with no opinion. The practical consequence is that
pgraft users get quorum and leadership from this layer but not eviction, until a
last-contact column exists upstream. Raft already tracks it internally to drive
heartbeats; it is simply not published.

The lesson worth keeping: **consensus strength and observability are independent
axes.** The most sophisticated backend is the least useful here, because the
interface needs a fact it happens not to expose.

## A pgraft bug found on the way

`pgraft_shmem_startup_hook()` never called `prev_shmem_startup_hook`, though
`_PG_init` saves it and the matching *request* hook chains correctly. With
`shared_preload_libraries = 'spock,pgraft'`, pgraft's hook became head of the
chain and silently dropped spock's, so spock's shared memory was never
initialised and its supervisor segfaulted in a restart loop. This breaks any
extension loaded before pgraft. Fixed in `pgraft/src/pgraft.c`.

## Group-slot integration

Not yet built. This is where the correctness risk lives, so it is last and starts
disabled.

`group_slot_evaluate()`'s `stale_progress` branch becomes conditional:

| Provider | Quorum | Member | Behaviour |
|---|---|---|---|
| none | — | — | Exactly today: block. |
| any | no / unknown | — | Block. |
| any | yes | live | Block — it is up, just behind. A real backlog. |
| any | yes | not live | Eligible for release, subject to the rule below. |

The rule matters more than the table. **Advancing past what a down node still
needs means it can never resume by replication and will require a full resync.**
PGD accepts that trade under majority; so should we, but only explicitly:

- A member is released only after being continuously non-live for
  `spock.quorum_member_eviction_timeout` (generous by default — minutes, not
  seconds). A node rebooting must not lose its place.
- Release is logged at `LOG` naming the member and the horizon moved past, and
  recorded in `group_slot_state`. An operator must be able to answer "why does n3
  need a resync?" from the log.
- All of it sits behind `spock.quorum_advance`, **default off**.

Note that with pgraft this branch is unreachable, since it never reports a member
as non-live. That is correct, not a gap.

## Testing

Backend-specific tests only need to prove the mapping is right. Spock's own logic
should be proven against a driveable mock provider, which does not exist yet and
is the main gap in the current work — it is what would make the awkward states
(quorum lost mid-tick, leadership changing under a decision, a provider that
times out) deterministic in CI without an etcd daemon or a Raft cluster.

The `none` provider carries a standing regression obligation: with no provider
configured, behaviour must be byte-identical to today.

## Status and remaining work

Done: the layer, all three providers, `spock.quorum_status()`, GUCs, build
wiring. All three verified against live daemons; 40/40 pg_regress.

Remaining, in order:

1. **Mock provider and TAP coverage.** The correctness of everything above rests
   on states that are currently only reachable by hand.
2. **Group-slot integration** behind `spock.quorum_advance = off`.
3. Optional: the additive pgraft last-contact column, which would make its
   provider a peer of the other two.

## Open questions

- Should `members()` reconcile against `spock.node`, or report the provider's
  view raw and let the caller intersect? Currently the latter, since a quorum
  system may legitimately govern more nodes than Spock does.
- Does anything besides the group slot want this layer? Read-only mode and
  failover-slot promotion are plausible second consumers, and if either is
  likely, nothing here should be named after group slots.
