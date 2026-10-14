# replicated-values-mean-same-on-every-node — Replicated values are identical on every node

## Synthesis note

Merged from `replicated-values-mean-same-on-every-node` (F11) and
`replicated-values-identical-across-transfer-modes` (F4). Same guarantee and
same oracle (ordered row text checksum per table under fixed session settings,
compared across nodes after quiescence). The two focuses found different ways
to break it:

- F11 (concrete, high confidence): `decide_datum_transfer` sends a domain over
  a user array/composite as `'b'` (domains pass the send/recv test), and the
  receiver's `array_recv`/`record_recv` raises 42804 when OIDs differ, so
  TRANSDISCARD drops the whole transaction; OID-alias types (`regclass`,
  `regtype`, `oid`) go as raw `'i'` bytes and silently name another object.
  Reachable in v1 because n4 gets its schema through ZODAN's
  pg_dump/pg_restore, so OIDs differ.
- F4 (regression guard, low confidence): text vs binary vs internal transfer
  and per-node DateStyle/TimeZone/IntervalStyle/`lc_monetary`.

Kept as one property with three distinctly named `Always` messages: rows
render identically; no exception_log rows for type mismatch on valid data; a
`force_text_transfer` subscription agrees with binary ones. Both chose
`Always`.

## Evaluation refinements (2026-10-13)

Raised by the evaluation lenses (antithesis-fit (TAP territory), wildcard W2); see `evaluation/synthesis.md`.

Current catalog line: Priority: P1 · Topology: v1 (schema with domains over user arrays on n4 after add_node) · Faults: none required; reconnects

- Placement: Expected to fire deterministically — confirm with TAP first, then gate out of the main template. (Domain-over-user-array and OID-alias cases: they fail whenever OIDs differ, which ZODAN's pg_dump/pg_restore makes true on n4 every time.)
- Evaluation note (2026-10-13): after a TAP test with one domain column and one `regclass` column, the Antithesis part is binary/text negotiation after reconnects; P1 is a severity rank.

## Open questions

- Is the raw `'i'` transfer of OID-alias types (`regclass`, `regtype`, `oid`, ...) accepted, given no doc says binary transfer needs identical OIDs? `(needs human input)`
- Is `money` supported across nodes with different `lc_monetary`? `(partial: default 'i' transfer copies the raw int64, so the amount keeps its digits but its currency/scale follow each node's locale; text transfer parses under each side's unpinned lc_monetary)`

Resolved (see log): `force_text_transfer := true` makes every column go as
text, which avoids both the domain-over-user-array/composite failure and the
OID-alias problem (names are mapped through output/input functions). The
per-node DateStyle/TimeZone question is a harness choice, not a product
question: the v1 harness should set different DateStyle, TimeZone and
IntervalStyle per node in each node's `postgresql.conf`, because the
replication connection pins only `datestyle=ISO`, `intervalstyle=postgres` and
`extra_float_digits=3` (`src/spock.c:436`) and that pinning is what this
property guards.

## Source: `replicated-values-mean-same-on-every-node` (F11 Wildcard)

### Why this property exists

Convergence checks usually compare rows by hash or by value equality. They
assume a replicated value is the same value on every node. Spock's binary
transfer modes ship some values in a node-local form:

1. **Domains over user-defined arrays or composite types** are shipped with
   send/recv, which embeds the provider's type OIDs. The subscriber's
   `array_recv` / `record_recv` rejects a different local OID with
   `ERRCODE_DATATYPE_MISMATCH` (42804). That is not on the transient list, so
   under the default TRANSDISCARD the whole upstream transaction is dropped
   (with an `exception_log` row). Valid data, rejected because of OID
   numbering.
2. **OID-alias types** (`regclass`, `regtype`, `regproc`, `regnamespace`,
   `regrole`, `oid`) are builtin, plain, pass-by-value: they go as `'i'` raw
   internal bytes. The subscriber stores the provider's OID number, which names
   a different object (or nothing) locally. No error at all; the value's
   meaning silently changes. Text transfer would have mapped by name.

Nobody tests heterogeneous OID numbering because test clusters are built by
the same script and usually get the same OIDs. In this topology they will
differ: n4 gets its schema through `pg_dump`/`pg_restore` structure sync, after
`CREATE EXTENSION spock` and `dblink`; any temp table, extension or dropped
object on one node shifts the OID counter.

### Code path (HEAD 69d9228f)

- `decide_datum_transfer`, `src/spock_proto_native.c:641-671`:
  - `'i'` when `typtype == 'b' && atttypid < FirstNormalObjectId && typelem ==
    0` -> includes `regclass`, `regtype`, `oid`, etc.
  - `'b'` when `typreceive` valid and (builtin or `typtype != 'c'`) and
    (builtin or `typelem == 0`). The comment says "we can't use send/recv for
    array or composite types for now due to the embedded oids", but a domain
    has `typtype = 'd'` and `typelem = 0`, so a domain over a user array or a
    user composite passes both tests.
- Confirmed with a scratch PG18 instance: `d_enumarr` (domain over
  `myenum[]`), `d_comp` (domain over composite) both have `typtype=d,
  typelem=0, typreceive=domain_recv`, user OID; `regclass`/`regtype`/`oid` have
  `typtype=b, typelem=0`, builtin OID.
- Receive `'b'`, `src/spock_proto_native.c:~999-1050`: the type-mismatch check
  is skipped for user OIDs (comment: "only built-in types have OIDs that are
  stable enough"), then `OidReceiveFunctionCall(domain_recv)` -> base
  `array_recv`/`record_recv`, which compares the embedded element/column OIDs
  with the local ones and errors.
- Binary is on by default: `spock_start_replication` sends
  `binary.want_internal_basetypes` and `binary.want_binary_basetypes` = 1
  unless `force_text_transfer` (`src/spock.c:686-726`); the provider allows it
  when sizes/endianness/major match (`src/spock_output_plugin.c:~488-495`), as
  they do in this homogeneous cluster.
- Error classifier (sut-analysis §5.1): 42804 is a "data error" -> replay ->
  TRANSDISCARD drops the transaction.

### Failure scenarios

A. Table `t(id pk, tags d_enumarr)` on n1..n3 created in an order that gives
`myenum` different OIDs on some node. Every INSERT/UPDATE touching `tags` from
n1 is dropped on that node, with an `exception_log` row whose message is "wrong
element type" or similar. Under `sub_disable` the subscription disables. Same
for `d_comp`.

B. Table `audit(id pk, rel regclass)`; n1 inserts `('accounts'::regclass)`.
On n2, `rel::text` shows another table name or a bare number.

### Property

After quiescence, for every replicated table, `row::text` (rendered on each
node in its own session with the same DateStyle/TimeZone/extra_float_digits)
is identical on all nodes, and no `exception_log` row has SQLSTATE class 42
caused by type OID mismatch.

- Workload-side `Always` at each quiescent check: per-table ordered text
  checksum equal across nodes. Message: "replicated rows render identically on
  all nodes". The usual convergence checker already does this if it compares
  text; it does **not** if it compares hashes computed from binary values or
  compares OIDs as integers.
- Workload-side `Always`: "no exception_log rows for type mismatch on valid
  data" (filter `error_message` for "element type"/"wrong data type" or
  SQLSTATE 42804 if recorded).
- SUT-side (missing, no existing assertions): `Unreachable` in
  `decide_datum_transfer` returning `'b'` for a domain whose base type is a
  user array/composite, and `Unreachable` returning `'i'`/`'b'` for an OID
  alias type. Both are cheap and fire on the first row; a SUT assertion is
  better than waiting for divergence.

### Workload requirements

- One table with a domain over a user enum array and one with a domain over a
  user composite; one table with a `regclass` column.
- Make OIDs differ on purpose: on one node create an unrelated type or temp
  table before the test schema, or rely on n4's `pg_restore`.
- Keep this in a separate table set so it does not hide other convergence
  failures (it fails deterministically, not under faults).

### Fault requirements

None. This is a configuration/data-shape property. It belongs in the catalog
because it breaks the convergence oracle the fault-driven properties rely on,
and because a TRANSDISCARD drop on these tables looks exactly like the
fault-triggered silent-discard bugs (L5) during triage.

### Confidence

High for the domain case (catalog values checked on PG18, code path read on
both sides). High for the OID-alias case (pass-by-value builtin, `'i'`). Medium
on impact: how often users store `regclass` or domains over user arrays in
replicated tables is unknown.

### Original open-question notes (detail for the combined list above)
- Is the `'i'` transfer of OID-alias types known and accepted? PostgreSQL's own
  binary logical replication has the same limitation for some types; if Spock
  documents "binary transfer requires identical OIDs" somewhere, scenario B
  drops to a doc gap. Not found in `docs/`.
- Does a domain over a **builtin** array (`int[]`) behave? Its element OID is
  builtin and stable, so it should be fine; included in the workload as a
  control case.
- Would `force_text_transfer` on the subscription avoid both? Expected yes
  (text in/out by name), not run.

## Source: `replicated-values-identical-across-transfer-modes` (F4 Protocol)

### Summary

A column value arrives on the subscriber in one of three encodings, chosen per
column by `decide_datum_transfer` (`src/spock_proto_native.c:641-671`):
`'i'` internal binary (built-in non-array base types, when the binary
compatibility check passes), `'b'` send/recv (same PG major, `binary.*`
parameters match), or `'t'` text (`force_text_transfer`, mixed PG majors, or
types not eligible). Text values are produced by output functions in the
walsender session and parsed by input functions in the apply worker, under
whatever session settings each side has. Commits 34d473dc and f21e71bc pin the
peer session to `datestyle=ISO`, `intervalstyle=postgres`,
`extra_float_digits=3` (`spock_connect_base`, `src/spock.c:366-475`) because
different settings had made "the same value denote a different instant ... a
different day. Neither case reports that anything has happened."

The property: whatever the transfer mode and whatever DateStyle, TimeZone,
IntervalStyle, `lc_monetary` or float settings each node runs with, a
replicated value is equal on every node.

### What can still differ (by reading)

- `TimeZone` is not pinned. Fine for `timestamptz` (ISO output carries the
  offset) but worth exercising for `timetz` and for values near DST changes.
- `lc_monetary` is not pinned; `money` text output/input depends on it.
- The apply worker's own DateStyle/IntervalStyle come from server settings; ISO
  and `postgres` interval input are unambiguous under any setting, so this
  should be safe.
- `'b'` for user enums uses label text (`enum_send`), safe across differing
  enum OIDs; `'i'` is limited to built-in types.

### Invariant

Workload-side `Always` ("typed value equal on every node"):

- Insert-only table with node-unique keys (no conflicts) and columns of type
  `timestamptz, timestamp, date, timetz, interval, float4, float8 (incl. NaN,
  -0, ±Infinity), numeric (incl. NaN, large scale), text (multibyte), bytea,
  jsonb, int4[], uuid, inet`, a user enum and a user composite.
- Node configs differ: e.g. n1 `DateStyle='SQL, DMY'`, `TimeZone='Pacific/Chatham'`;
  n2 `DateStyle='German'`, `IntervalStyle='sql_standard'`, `TimeZone='UTC'`;
  n3 defaults. At least one subscription per node created with
  `force_text_transfer := true`.
- After quiescence: compare per row `md5(row_to_json)` computed in a session
  with fixed settings (`SET DateStyle=ISO; SET TimeZone=UTC; SET
  extra_float_digits=3; SET IntervalStyle=postgres`) on each node.

### Why it matters

A wrong value replicated through text is silent: it applies cleanly and every
later comparison of that row treats it as legitimate data.

### Confidence notes

No current bug is known here; this is a regression guard for a contract the
team recently tightened. `money` is the most likely type to differ; decide
whether to include it (see open questions).

### Original open-question notes (detail for the combined list above)
- Is `money` replication across nodes with different `lc_monetary` supported?
  If not, exclude it from the table; if yes, it is the first place to look.
  `(needs human input)`
- Will the v1 harness set different DateStyle/TimeZone per node? Without that,
  this property only exercises the text path with identical settings, which is
  much weaker.

### Investigation Log

#### Is the `'i'` transfer of OID-alias types documented or accepted?

- Examined: `docs/` (all user docs, grep for regclass/oid/binary/force_text_transfer),
  `decide_datum_transfer` (`src/spock_proto_native.c:640-671`),
  `docs/spock_functions/sub_mgmt.md:53-56`.
- Found: `regclass` etc. are builtin, `typtype='b'`, `typelem=0`, so they go
  as raw internal bytes. Docs describe `force_text_transfer` only as slower
  and useful for changing a column type; nothing says binary transfer
  assumes matching OIDs. PostgreSQL's own binary logical replication would
  also send the OID number (`oidsend`), so this is a known class of issue
  upstream, but Spock enables binary by default.
- Conclusion: `(needs human input)` on whether it is accepted.

#### Does `force_text_transfer` avoid both cases?

- Examined: `spock_start_replication` (`src/spock.c:686-726`),
  `src/spock_output_plugin.c:480-500`, `decide_datum_transfer`.
- Found: with `force_text_transfer` the subscriber sends
  `binary.want_internal_basetypes '0'` and `binary.want_binary_basetypes '0'`;
  the provider then leaves `allow_internal_basetypes` and
  `allow_binary_basetypes` false, and `decide_datum_transfer` returns `'t'`
  for every column. Text output of `regclass`/`regtype` is a name, and
  `domain_in` -> `array_in`/`record_in` parse by local type, so OID numbering
  no longer matters. Caveat: an unqualified `regclass` name is resolved
  through the apply worker's `search_path`.
- Conclusion: resolved by code reading (not run). Use it as the third
  `Always` ("force_text_transfer subscription agrees with binary ones").

#### Is `money` across different `lc_monetary` supported?

- Examined: `src/spock.c:436` (pinned settings), `decide_datum_transfer`,
  docs for lc_monetary/money.
- Found: `lc_monetary` is not pinned on the replication connection. `money`
  is builtin, pass-by-value, `typelem=0`, so by default it goes `'i'` (raw
  int64 in minor units); its displayed value then depends on each node's
  `lc_monetary` (currency symbol and fraction digits). With text transfer,
  `cash_out` on the provider and `cash_in` on the subscriber use their own
  `lc_monetary`. Docs say nothing about money.
- Conclusion: partial; supported-or-not needs the team.

#### Will the v1 harness vary DateStyle/TimeZone per node?

- Examined: `antithesis/scratchbook/deployment-topology.md`, `src/spock.c:366-475`.
- Found: the topology does not set per-node session settings yet; nothing in
  the product prevents it.
- Conclusion: resolved as a harness decision: set them per node (recommended
  above). Without it the property only checks the text path with identical
  settings.
