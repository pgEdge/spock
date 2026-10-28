#!/usr/bin/env python3.12
"""Insert kv rows and update existing ones on one mesh node, in a few
transactions.

An update picks keys from its own node's rows (uncontested) or from any
origin's (contested, chance contested_weight), with n in the timeline's hot
set, then keeps only keys it finds on every mesh node: an update that
reaches a node before the row does is update_missing, which Spock does not
resolve.  With no deletes, a key on every node stays there.  If a node
cannot be asked, the update is skipped.

Connection errors are expected under faults; the command logs them and
moves on.  It always exits 0.
"""

import os

import psycopg
from antithesis.assertions import reachable, sometimes
from antithesis.random import get_random, random_choice

from helper_kv import load_params
from helper_spock import MESH, connect, log

TXNS_PER_RUN = [1, 3, 10]

# Rows per insert: 1 and 2 are the smallest transactions; 100 keeps a
# transaction in flight long enough for a fault to land in it.
INSERT_ROWS = [1, 2, 10, 100]

# Keys per update transaction.  More than one lets two nodes' updates of
# the same rows interleave in different orders.
UPDATE_KEYS = [1, 2, 10]

# A key check on a node that does not answer within this costs the update.
CHECK_TIMEOUT = 3


def unit():
    return get_random() / 2**64


def pick_keys(conn, node, params):
    """Candidate (origin, n) keys from node's own copy of kv."""
    count = random_choice(UPDATE_KEYS)
    keys = set()
    max_n = {}
    for _ in range(count):
        if unit() < params["contested_weight"]:
            origin = random_choice(MESH)
        else:
            origin = node
        if origin not in max_n:
            max_n[origin] = conn.execute(
                "SELECT max(n) FROM kv WHERE origin = %s",
                (origin,)).fetchone()[0]
        if not max_n[origin]:
            continue
        hot = min(params["hot_keys"], max_n[origin])
        keys.add((origin, 1 + get_random() % hot))
    return sorted(keys)


def on_every_node(keys):
    """The subset of keys present on every mesh node, or [] if a node
    could not be asked."""
    origins = [k[0] for k in keys]
    ns = [k[1] for k in keys]
    found = set(keys)
    for node in MESH:
        try:
            with connect(node, connect_timeout=CHECK_TIMEOUT) as conn:
                rows = conn.execute(
                    """SELECT origin, n FROM kv
                       WHERE (origin, n) IN
                             (SELECT * FROM unnest(%s::text[], %s::bigint[]))""",
                    (origins, ns)).fetchall()
        except psycopg.Error as e:
            log(f"key check on {node}: {e.__class__.__name__}")
            return []
        found &= {(o, n) for o, n in rows}
    return sorted(found)


def do_insert(conn, node, tag):
    rows = random_choice(INSERT_ROWS)
    conn.execute(
        """INSERT INTO kv (origin, n, val, writer, wseq)
           SELECT %s, nextval('kv_seq'), %s, %s, 0
           FROM generate_series(1, %s)""",
        (node, tag, node, rows))


def do_update(conn, node, tag, params):
    keys = on_every_node(pick_keys(conn, node, params))
    if not keys:
        return None
    conn.execute(
        """UPDATE kv SET val = %s, writer = %s, wseq = wseq + 1
           WHERE (origin, n) IN
                 (SELECT * FROM unnest(%s::text[], %s::bigint[]))""",
        (tag, node, [k[0] for k in keys], [k[1] for k in keys]))
    return keys


def main():
    params = load_params()
    node = random_choice(params["writer_nodes"])
    n_txns = random_choice(TXNS_PER_RUN)
    inserts = updates = skipped = 0
    for i in range(n_txns):
        tag = f"{node}:{os.getpid()}:{i}"
        is_update = unit() < params["update_weight"]
        try:
            with connect(node, autocommit=False) as conn:
                if is_update:
                    keys = do_update(conn, node, tag, params)
                    if keys is None:
                        # Nothing written; leaving the block ends the
                        # read-only transaction.
                        skipped += 1
                        continue
                else:
                    do_insert(conn, node, tag)
                conn.commit()
            if is_update:
                updates += 1
                contested = any(o != node for o, _ in keys)
                reachable("kv update committed on keys present on every mesh node",
                          {"node": node, "keys": len(keys)})
                sometimes(contested,
                          "kv update committed on a row another node inserted",
                          {"node": node, "keys": [list(k) for k in keys]})
            else:
                inserts += 1
        except psycopg.Error as e:
            log(f"{tag} {'update' if is_update else 'insert'} failed: "
                f"{e.__class__.__name__}: {str(e).strip()}")
    log(f"{node}: {n_txns} transactions: {inserts} inserts and {updates}"
        f" updates committed, {skipped} updates skipped")


if __name__ == "__main__":
    main()
