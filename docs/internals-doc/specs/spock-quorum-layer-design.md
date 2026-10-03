# A pluggable quorum layer for Spock

**Date:** 2026-10-02 (revised after the review of PR #604)
**Status:** Implemented: layer, three providers, status functions, tests. No consumer yet.
**Branch:** `QUORUM` (based on `main`), targeted at 6.1.0

## Problem

Spock decides everything about WAL retention from local catalogs.
`spock.progress` only records what *this* node received *from* a member, never
what that member has confirmed, and nothing in Spock knows whether a member
that went quiet is down or merely unreachable from here.

So a single unreachable node pins WAL on every survivor, indefinitely, during
an incident, exactly when disk headroom matters most. There is also no notion
of a majority, so a topology change needs every node reachable.

Closing that needs agreement between nodes. It does not need Spock to
implement consensus, or to marry itself to one implementation.

## Goals

- One interface, several backends, none privileged.
- With no provider configured, behaviour is exactly as today.
- Uncertainty never releases WAL. A broken quorum layer degrades to today's
  conservative behaviour, never past it.
- Attaching a system requires no new mandatory build dependency.

## Non-goals

- Spock does not implement consensus and does not arbitrate elections.
- No Raft vocabulary in the interface. No terms, no log indexes; those are one
  implementation's concepts and would leak into an interface meant to outlast
  it.
- Not a general cluster manager. The scope is replication decisions.

## The interface

A provider is four functions, in `include/spock_quorum.h`:

| Entry point | Called | Does |
|---|---|---|
| `startup` | once per process, retried after failure | resolve identity, check the backend is there |
| `shutdown` | when the provider is switched or the process ends | release what startup took |
| `refresh` | at the top of a consumer tick | renew a registration, campaign for leadership |
| `read` | once per reading | fill one `SpockQuorumReading` |

`read` is the only question. It returns, from one request, whether this node
is in a quorum, whether it leads, who leads, and the membership with each
member's liveness. The first design had four separate questions
(`have_quorum`, `is_leader`, `leader`, `members`), and the layer composed a
"snapshot" from them; review pointed out, correctly, that four calls can see
four cluster states, so the composite described a cluster that never existed.
The provider now takes the reading, in one etcd transaction or one SQL
statement, and the layer only caches it.

Every answer is three-valued:

```c
typedef enum SpockQuorumAnswer
{
    SPOCK_QUORUM_NO = 0,
    SPOCK_QUORUM_YES,
    SPOCK_QUORUM_UNKNOWN
} SpockQuorumAnswer;
```

`UNKNOWN` is deliberately not folded into `NO`. Callers treat them identically,
that is the fail-safe rule, but keeping them apart is what lets the status
functions distinguish *a cluster that lost quorum* from *a provider that
stopped answering*. During an incident those demand different responses.

The interface asks only for judgements, never for storage. That is what lets a
leader-election-only system such as pgBully sit behind the same four entry
points as etcd, which has a replicated key space, and it is also why the
identity problem below had to be solved without writing anything.

## The fail-safe contract

1. **Uncertainty means no.** Any error, timeout, or `UNKNOWN` produces today's
   conservative behaviour. No configuration inverts this.
2. **Off the hot path.** Never from an apply worker, a walsender, or anything
   a client waits on. Today the only consults are `spock.quorum_status()` and
   `spock.quorum_members()`, which an operator runs by hand.
3. **Deadlines, not hope.** Every call is bounded by `spock.quorum_timeout`
   (default 2s). etcd gets it as an HTTP deadline. The in-database providers
   arm a private timeout (`RegisterTimeout(USER_TIMEOUT)`) around each query
   whose handler raises a cancel, which the subtransaction catches. The first
   implementation used `SET LOCAL statement_timeout`, which does nothing: the
   statement timer is armed when the client's statement starts, and a
   background worker has no client statement at all.
4. **Providers may not throw.** A callback that `ereport(ERROR)`s would abort
   the very tick deciding whether releasing WAL is safe. Callbacks return a
   status and an `errdetail` string. The in-database providers run every
   query inside an internal subtransaction, so a failing backend cannot leave
   the operator's transaction aborted.
5. **One reading per tick.** See above.
6. **Membership is Spock's.** A member the provider reports but `spock.node`
   does not contain is dropped from the reading. A node removed with
   `spock.node_drop()` therefore stops counting at once, however long the
   quorum system goes on listing it.

## Identity: how a provider's member becomes a Spock node

This is where the first implementation was wrong, and where review found the
real bug. The cluster managers speak in integer node ids, Spock speaks in node
names, and the design mapped one to the other by having each node write
`<cluster>/nodes/<id> = <name>` into the manager's key/value store at refresh.
Both pgraft and pgBully accept KV writes **on the leader only**, so a follower
could never publish its mapping, and the layer would have reported a cluster
of one.

The mapping is now read, never written, and each backend supplies it in the
form it naturally has:

| Provider | A member is identified by | Spock matches it to |
|---|---|---|
| etcd | the key it registers under, `<cluster_id>/nodes/<name>` | `spock.node.node_name` |
| pgraft | its raft member name (`pgraft.name`, listed in `initial_cluster`), published by `pgraft.get_nodes_from_raft()` | `spock.node.node_name`: name the raft member after the Spock node |
| pgBully | its connection string, published by `pgbully.peers()` | `spock.node_interface.if_dsn`, host and port, both parsed by `PQconninfoParse` |

No extra configuration, no writes, and node removal is consistent for free:
a dropped node has no `spock.node` row to match.

`spock.quorum_cluster_id` is consequently needed by etcd alone. etcd is shared
by whoever points at it, so the prefix is what keeps two clusters apart; the
in-database managers are one per cluster by construction.

## What the three providers are

| | etcd | pgraft 2.0 | pgBully 1.0 |
|---|---|---|---|
| Transport | HTTP/JSON gateway, libcurl | SPI | SPI |
| Quorum | a linearizable txn completed | `leader_id` set | `leader_id` set **and** a reachable majority of peers |
| Leadership | leased key `<cluster_id>/leader` | `is_leader()` | `is_leader()` |
| Membership | keys under `<cluster_id>/nodes/` | `get_nodes_from_raft()` | `peers()` |
| Liveness | key present (lease renewed) | raft `RecentActive`, leader's view only | `peers().reachable` |
| Last contact | not tracked | not tracked | `peers().last_seen` |

**etcd.** Quorum is proved by completing a linearizable transaction, which
etcd only answers from within a majority; `/v3/maintenance/status` is
deliberately not used, since the Status RPC is answered from the queried
member's own, possibly stale, view. The same transaction reads the nodes
prefix and the leader key, so membership and leader come from one revision.
Registration and the leader campaign (create-if-absent on a leased key) live
in `refresh()`, which only a long-lived worker calls; a backend running the
status functions reads and never registers. The keepalive reply is parsed in
the shape the gateway actually sends, wrapped in `"result"`.

**pgraft.** A leader id is quorum. That is weaker than it looks: without
`CheckQuorum`, an isolated raft leader goes on believing it leads, and a
follower keeps its last leader until the election timeout. Two changes were
made in pgraft (`src/pgraft_go.go`) for this layer: `CheckQuorum` is enabled
in the raft configuration, so a leader that cannot hear a majority steps down
within an election timeout, and `pgraft_go_get_nodes()` reports each
follower's `Progress.RecentActive` rather than marking every entry active.
With those, `active` on the leader is a real liveness signal. A follower has
no such signal and reports every member live, which is the reading that
releases nothing.

**pgBully.** The Bully algorithm has no majority of its own, but its peer
table carries `reachable`, so the provider requires a reachable majority on
top of the leader id. A peer with no verdict yet is treated as live: "no
opinion" is not evidence of failure.

pgraft and pgBully share one implementation, `src/spock_quorum_cluster.c`,
parameterised by a few SQL fragments. They remain two providers, selected by
distinct values of `spock.quorum_provider`.

## Where providers live

Spock ships all three. etcd's HTTP client is the only external dependency,
detected at build time via `curl-config` and never required: without it the
provider still compiles and is still selectable, and reports why it cannot be
used. `NO_LIBCURL=1` forces it off. The guard macro is Spock's own,
`SPOCK_HAVE_LIBCURL`, so PostgreSQL's `HAVE_LIBCURL` cannot pull the curl
calls in without the link flags.

## Testing

| Test | Needs | Covers |
|---|---|---|
| `106_quorum_layer` | nothing | surface, GUC bounds, `none`, missing extension, missing cluster id and its retry, unreachable and malformed etcd, transaction survival, runtime reconfiguration |
| `111_quorum_etcd` | python3, curl | the etcd provider against `t/mock_etcd.py`, a stand-in gateway with fault injection: registration, filtering, leadership, lease lapse, node removal, endpoint rotation, HTTP 500, non-JSON, slow gateway, recovery |
| `112_quorum_cluster_api` | nothing | pgraft and pgBully against stand-in schemas: identity by name and by connection string (keyword and URI forms), liveness, majority rule, leader-only activity, no leader as a definite false, raising and slow backends, the deadline, node removal, the extension vanishing |
| `113_quorum_pgbully_real` | pgBully source or network | the real extension on three nodes: agreement with pgBully, one node down, two down, recovery, node removal |
| `114_quorum_pgraft_real` | pgraft source or network, Go | the real extension on three nodes: agreement with pgraft, a follower going inactive, the leader stepping down, recovery, node removal |
| `115_quorum_etcd_real` | network or an etcd binary | a real single-member etcd: linearizable read, real reply shapes, a lease that expires on its own, node removal |

The real-system tests build what they need when it is missing and skip when
they cannot, so they cost nothing on a machine without network.

## Known limitations

- The etcd gateway is spoken to without authentication or TLS. A local proxy
  covers both.
- pgraft's leader id can still be stale on a follower for up to one election
  timeout. `CheckQuorum` bounds it; it does not remove it.
- pgraft must carry the two changes above. Nothing enforces the version.
- Nothing calls `refresh()` yet, so under etcd no node registers itself until
  the consumer worker exists. The status functions still report quorum (the
  read completes) and whatever the operator or a future worker registered.

## Group-slot integration

Not yet built. This is where the correctness risk lives, so it is last and
starts disabled. The intended shape:

| Provider | Quorum | Member | Behaviour |
|---|---|---|---|
| none | | | Exactly today: block. |
| any | no / unknown | | Block. |
| any | yes | live | Block. It is up, just behind. |
| any | yes | not live | Eligible for release, after a long, explicit grace period, logged, behind `spock.quorum_advance = off`. |

Advancing past what a down node still needs means it can never resume by
replication and will require a full resync. That trade is accepted only
explicitly, and an operator must be able to answer "why does n3 need a
resync?" from the log.
