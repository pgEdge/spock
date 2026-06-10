# Demo: pgactive ↔ spock bridge

This sample stands up a 5-node bidirectional replication bridge between a
pgactive cluster (representing the AWS side) and a spock cluster
(representing the on-prem side), using the patches on the
`forward-non-pgactive-origins` (pgactive) and `selective-forward-origins-bridge`
(spock) branches.

The same `samples/bridge/` directory also ships a separate
**spock-only** bridge sample (`setup_spock_only_bridge.sh`) — two
distinct spock clusters joined by a single spock bridge node. That
variant is documented at the bottom of this file.

---

## What you'll end up with

```
                       PGACTIVE CLUSTER (full mesh)

          +--------+                       +--------+
          | node1  | ===================== | node2  |
          | :15431 |                       | :15432 |
          +--------+                       +--------+
                  \\                       //
                   \\                     //
                    \\===== +--------+ ===//
                            | node3  |    <-- BRIDGE
                            | :15433 |        (pgactive + spock)
                            +--------+
                            //         \\
                           //           \\
                          //             \\
                 +--------+               +--------+
                 | spock1 | <-----------> | spock2 |
                 | :25431 |               | :25432 |
                 +--------+               +--------+

                          SPOCK CLUSTER (peer mesh)
```

`node3` runs **both** `pgactive` and `spock`. A write anywhere converges
everywhere.

---

## 1 · Set up your shell environment

The setup scripts call PostgreSQL binaries (`initdb`, `pg_ctl`, `psql`)
unprefixed, so pgEdge Postgres 17 must be on `PATH`. Typical layouts:

| Install style                 | Where PG 17 binaries usually live           |
|-------------------------------|---------------------------------------------|
| pgEdge tarball / installer    | `/opt/pgedge/pg17/bin` (or `~/pgedge/pg17/bin`) |
| pgEdge nodectl                | `~/pgedge/pg17/bin` (under the nodectl home) |
| `pg_config` from your PATH    | wherever `pg_config --bindir` reports       |
| Source build                  | `<your-prefix>/bin`                          |

Pick the directory that contains `pg_ctl` for the PG 17 you want to
demo against, and put it first on `PATH`. For pgEdge's nodectl layout
that typically looks like:

```bash
export PG_HOME="$HOME/pgedge/pg17"          # adjust to your install
export PATH="$PG_HOME/bin:$PATH"
# Some Postgres builds also want LD_LIBRARY_PATH:
export LD_LIBRARY_PATH="$PG_HOME/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
```

Sanity-check:

```bash
which pg_ctl                          # should be in your PG_HOME/bin
pg_config --version                   # should report 17.x
pg_config --pkglibdir                 # where extensions install
```

The scripts also need a writable directory for the five nodes' data
dirs. They use the `BRIDGE_DEMO_DATA` environment variable for this,
defaulting to `$PWD/data` if unset. Pick somewhere with ~1 GB of free
space:

```bash
export BRIDGE_DEMO_DATA="$HOME/pgactive-bridge-demo/data"
mkdir -p "$BRIDGE_DEMO_DATA"
```

---

## 2 · Clone, check out, and install the two extensions

The bridge needs patched builds of both extensions installed into the
**same PG 17 install tree**:

```bash
# pgactive
git clone <pgactive-repo>            # fork that has the bridge work
cd pgactive
git checkout forward-non-pgactive-origins
make -s install                      # uses pg_config from PATH
cd ..

# spock
git clone <spock-repo>
cd spock
git checkout selective-forward-origins-bridge
make -s install
cd ..
```

`make -s install` should finish in a few seconds. The build prints
`Building against PostgreSQL 17` if it found the right `pg_config`. If
it picks the wrong PG, double-check `which pg_config`.

---

## 3 · Stand up the cluster

Two scripts in this order, in any working directory:

```bash
SCRIPTS=<path-to-spock-repo>/samples/bridge

bash "$SCRIPTS/setup_pgactive_cluster.sh"        # data/1, data/2, data/3
bash "$SCRIPTS/setup_spock_cluster.sh"           # data/spock1, data/spock2
                                                  # + spock wiring on node3
```

Each script is idempotent — it stops anything still running on the
relevant ports, wipes the data dirs under `$BRIDGE_DEMO_DATA`, and
starts fresh. Total runtime: ~30–60 seconds for both.

When the second script finishes you'll see a connection cheatsheet:

```
  psql -h localhost -p 25431 -U postgres -d pgadb    # spock1
  psql -h localhost -p 25432 -U postgres -d pgadb    # spock2
  psql -h localhost -p 15433 -U postgres -d pgadb    # node3 (bridge)
```

The pgactive nodes live at ports 15431 (node1), 15432 (node2),
15433 (node3, the bridge).

### Verify everything is up

```bash
for p in 15431 15432 15433 25431 25432; do
    echo "--- :$p ---"
    psql -h localhost -p $p -U postgres -d pgadb -c \
        "SELECT count(*) FROM public.demo"
done
```

All five should return `3` (rows seeded by the pgactive setup).

Quick subscription sanity:

```bash
for label_port in "spock1:25431" "spock2:25432" "node3:15433"; do
    label="${label_port%%:*}"; port="${label_port##*:}"
    echo "--- ${label} ---"
    psql -h localhost -p $port -U postgres -d pgadb -c \
        "SELECT subscription_name, status, provider_node FROM spock.sub_show_status()"
done
```

Every subscription should show `status = replicating`.

---

## 4 · Demo 1 — bidirectional DML

Run concurrent inserts on **all 5 nodes** and confirm everything
converges:

```bash
psql -h localhost -p 15431 -U postgres -d pgadb \
  -c "INSERT INTO public.demo SELECT i, 'node1-'  || i FROM generate_series(100,109) i" &
psql -h localhost -p 15432 -U postgres -d pgadb \
  -c "INSERT INTO public.demo SELECT i, 'node2-'  || i FROM generate_series(200,209) i" &
psql -h localhost -p 15433 -U postgres -d pgadb \
  -c "INSERT INTO public.demo SELECT i, 'node3-'  || i FROM generate_series(300,309) i" &
psql -h localhost -p 25431 -U postgres -d pgadb \
  -c "INSERT INTO public.demo SELECT i, 'spock1-' || i FROM generate_series(400,409) i" &
psql -h localhost -p 25432 -U postgres -d pgadb \
  -c "INSERT INTO public.demo SELECT i, 'spock2-' || i FROM generate_series(500,509) i" &
wait
sleep 8
```

Then read everywhere:

```bash
for label_port in "node1:15431" "node2:15432" "node3:15433" \
                  "spock1:25431" "spock2:25432"; do
    label="${label_port%%:*}"; port="${label_port##*:}"
    echo "--- ${label} ---"
    psql -h localhost -p $port -U postgres -d pgadb -c \
        "SELECT split_part(msg, '-', 1) AS src, count(*)
         FROM public.demo
         WHERE msg ~ '-[0-9]+\$'
         GROUP BY 1 ORDER BY 1"
done
```

**Expected**: every node shows exactly `10` rows from each of the five
origins. A 5×5 grid of 10s = full convergence, no duplicate paths.

Confirm no errors landed in any log:

```bash
for n in 1 2 3 spock1 spock2; do
    log="$BRIDGE_DEMO_DATA/$n/server.log"
    err=$(grep -cE "ERROR|FATAL|TRAP" "$log")
    cw=$(grep -cE "WARNING.*CONFLICT" "$log")
    echo "$n: errors=$err  conflicts=$cw"
done
```

Should all be zero.

---

## 5 · Demo 2 — bidirectional DDL

Run a `CREATE TABLE` on each side and watch it propagate through the
bridge to the other side.

```bash
# pgactive -> spock direction (pgactive's DDL is invoked explicitly)
psql -h localhost -p 15431 -U postgres -d pgadb -c \
  "SELECT pgactive.pgactive_replicate_ddl_command(\$\$
     CREATE TABLE public.t_pg (id int PRIMARY KEY, x text);
   \$\$)"

# spock -> pgactive direction (spock auto-DDL catches plain DDL)
psql -h localhost -p 25431 -U postgres -d pgadb -c \
  "CREATE TABLE public.t_spock (id int PRIMARY KEY, y text)"

sleep 6
```

Confirm both tables exist on all 5 nodes:

```bash
for label_port in "node1:15431" "node2:15432" "node3:15433" \
                  "spock1:25431" "spock2:25432"; do
    label="${label_port%%:*}"; port="${label_port##*:}"
    n=$(psql -h localhost -p $port -U postgres -d pgadb -tAc \
        "SELECT count(*) FROM pg_class
         WHERE relname IN ('t_pg','t_spock')
           AND relnamespace = 'public'::regnamespace")
    echo "${label}: ${n}/2"
done
```

**Expected**: every node says `2/2`.

Then DML through the new tables:

```bash
psql -h localhost -p 15431 -U postgres -d pgadb \
  -c "INSERT INTO public.t_pg    VALUES (1, 'pg-side')"
psql -h localhost -p 25431 -U postgres -d pgadb \
  -c "INSERT INTO public.t_spock VALUES (1, 'spock-side')"
sleep 4

for label_port in "node1:15431" "node2:15432" "node3:15433" \
                  "spock1:25431" "spock2:25432"; do
    label="${label_port%%:*}"; port="${label_port##*:}"
    a=$(psql -h localhost -p $port -U postgres -d pgadb -tAc \
        "SELECT x FROM public.t_pg WHERE id=1" 2>/dev/null)
    b=$(psql -h localhost -p $port -U postgres -d pgadb -tAc \
        "SELECT y FROM public.t_spock WHERE id=1" 2>/dev/null)
    echo "${label}: t_pg='${a}'  t_spock='${b}'"
done
```

Every node should show both values populated.

---

## 6 · How the bridge works (~60 seconds of explanation)

### Why a plain co-install doesn't work

Without these changes in the branches, putting pgactive and
spock on the same node gives you two independent extensions
decoding the same WAL — but neither forwards the *other's*
apply traffic into its own mesh.
Result: writes anywhere outside the bridge node never cross.

### What the patches do

**`pgactive.forward_non_peer_origins`** (a new GUC; set in
`setup_pgactive_cluster.sh`) tells pgactive's apply workers to ask
their upstream slots to forward foreign-origin (non-pgactive) changes.
On the bridge node, this means pgactive's output plugin forwards
spock-applied transactions through pgactive's wire protocol to the
other pgactive peers.

The same GUC also relaxes pgactive's DDL apply-context guards so
spock-applied DDL captured on node3 gets queued for pgactive
replication (via the normal `pgactive_queued_commands` + lock dance).

**`spock.forward_origins`** (per-subscription, set in
`setup_spock_cluster.sh`) is now selective rather than the historical
binary `'all'` / empty. On the bridge ingress subscriptions
(`spock(N) <- node3`) it's configured as `ARRAY['pgactive_*']`, so
`spock1` and `spock2` pull only pgactive-origin traffic from the
bridge — not spock-cluster-internal traffic that also happens to flow
through node3's WAL. That eliminates duplicate paths between the
bridge and the spock peer mesh.

### The asymmetric topology in one table

| Subscription                  | `forward_origins`         | Why                                             |
|-------------------------------|---------------------------|-------------------------------------------------|
| `spock1`, `spock2` ← `node3`  | `ARRAY['pgactive_*']`     | bridge ingress — selective for pgactive traffic |
| `node3` ← `spock1`, `spock2`  | `ARRAY[]::text[]`         | bridge egress — local writes only               |
| `spock1` ↔ `spock2`           | `ARRAY[]::text[]`         | spock peer mesh                                  |

Plus pgactive runs full mesh among node1/node2/node3 with
`forward_non_peer_origins = on` everywhere.

---

## 7 · Stop / restart

```bash
# Stop everything
for d in "$BRIDGE_DEMO_DATA"/*; do
    [ -f "$d/postmaster.pid" ] && pg_ctl -D "$d" stop -m fast
done

# Start everything again (preserves state)
for d in "$BRIDGE_DEMO_DATA"/*; do
    pg_ctl -D "$d" -l "$d/server.log" start
done

# Full wipe-and-rebuild (loses all data)
bash "$SCRIPTS/setup_pgactive_cluster.sh"
bash "$SCRIPTS/setup_spock_cluster.sh"
```

---

## 8 · If something looks wrong

Quick triage in this order:

1. **Server logs** — `$BRIDGE_DEMO_DATA/<node>/server.log`. Look for
   `ERROR`, `FATAL`, `TRAP`. Most setup issues show up clearly.
2. **Subscription status** — `SELECT * FROM spock.sub_show_status()`
   on each spock-running node. Anything `down` is the lead.
3. **Replication origins on node3** — `SELECT roident, roname FROM
   pg_replication_origin ORDER BY roname`. You should see four
   entries: two `pgactive_*` (for node1, node2) and two `spk_pgadb_*`
   (for spock1, spock2).
4. **The GUC on a pgactive node** — `SHOW
   pgactive.forward_non_peer_origins` should return `on` on all
   three pgactive nodes. If it's `off`, the setup script didn't
   apply — re-run it.

---

## Bonus — spock-only bridge

`setup_spock_only_bridge.sh` (in this same directory) stands up a
sibling topology: two distinct **spock-only** clusters joined by a
single spock bridge node. Same selective-`forward_origins` primitive,
but patterns reference `spock.node.node_name` directly. Example
asymmetric config:

```
  bridge <- ca1, ca2, cb1, cb2 : forward_origins = ARRAY[]::text[]
  ca1, ca2 <- bridge           : forward_origins = ARRAY['cb1','cb2']
  cb1, cb2 <- bridge           : forward_origins = ARRAY['ca1','ca2']
  ca1 <-> ca2, cb1 <-> cb2     : forward_origins = ARRAY[]::text[]
```

Stand it up with:

```bash
bash "$SCRIPTS/setup_spock_only_bridge.sh"
```

It uses the same `$BRIDGE_DEMO_DATA` directory but with different node
names (`ca1`, `ca2`, `bridge`, `cb1`, `cb2`) and different ports
(25441–25445), so don't run it in parallel with the pgactive↔spock
demo above without changing one of them.

Operational gotchas this demo exposes are documented in the
`spock.sub_create` reference (under `forward_origins`):

* **Use lowercase, cluster-distinctive node names.** Spock's internal
  `gen_slot_name()` silently replaces any character outside
  `[a-z0-9_]` with `_` when forming slot/origin names, which can
  collide otherwise.
* **Node names must be globally unique across bridged clusters,** since
  the user-facing pattern keys on `node_name`.
