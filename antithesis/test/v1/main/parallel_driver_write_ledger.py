#!/usr/bin/env python3.12
"""Insert ledger rows on one mesh node, in a few transactions of varied size.

Keeps replication channels busy so partitions and pauses catch data in
flight, not only idle links: a link that drops while a large transaction is
streaming is noticed only by spock.apply_idle_timeout, while an idle one is
noticed by TCP keepalives.

Connection errors are expected under faults; the command logs them and
moves on.  It always exits 0.
"""

import os

import psycopg
from antithesis.assertions import reachable
from antithesis.random import get_random, random_choice

from helper_spock import connect, load_params, log

# Rows per transaction.  1 and 2 are the smallest transactions; 5000 rows of
# the larger payloads take long enough to decode and send that a fault can
# land mid-stream.
SMALL_ROWS = [1, 2, 10, 100]
BIG_ROWS = [1000, 5000]

# Payload bytes.  1900 stays inline; 3000 is just over the 2 kB TOAST
# threshold; 20000 compresses (repeated text) and 8200 random hex does not.
PAYLOAD_SIZES = [0, 16, 1900, 3000, 8200, 20000]

TXNS_PER_RUN = [1, 3, 10]

# Payload bytes per transaction and per run.  Catch-up after a partition
# has to fit in the barrier check's 5 minute bound together with the
# reconnect delays (about 215 s), and parallel runs add up over a long
# partition, so no run writes more than this.
MAX_TXN_BYTES = 10_000_000
MAX_RUN_BYTES = 25_000_000


def unit():
    return get_random() / 2**64


def payload_sql(size):
    if size == 8200:
        # Not compressible: TOASTed out of line.
        return "(SELECT string_agg(md5(random()::text), '') FROM generate_series(1, 257))"
    return f"repeat('x', {size})"


def main():
    params = load_params()
    node = random_choice(params["writer_nodes"])
    n_txns = random_choice(TXNS_PER_RUN)
    committed = 0
    written = 0
    for i in range(n_txns):
        if unit() < params["big_txn_weight"]:
            rows = random_choice(BIG_ROWS)
        else:
            rows = random_choice(SMALL_ROWS)
        size = random_choice(PAYLOAD_SIZES)
        if size:
            rows = max(1, min(rows, MAX_TXN_BYTES // size))
        if written + rows * size > MAX_RUN_BYTES:
            break
        written += rows * size
        tag = f"{node}:{os.getpid()}:{i}"
        try:
            with connect(node, autocommit=False) as conn:
                conn.execute(
                    f"""INSERT INTO ledger (origin, seq, txn_tag, payload)
                        SELECT %s, nextval('ledger_seq'), %s, {payload_sql(size)}
                        FROM generate_series(1, %s)""",
                    (node, tag, rows))
                conn.commit()
            committed += 1
            if rows >= 1000:
                reachable("writer committed a large ledger transaction",
                          {"node": node, "rows": rows, "payload": size})
        except psycopg.Error as e:
            log(f"{tag} ({rows} rows x {size} B) failed: "
                f"{e.__class__.__name__}: {str(e).strip()}")
    log(f"{node}: committed {committed} of {n_txns} transactions,"
        f" {written} payload bytes attempted")


if __name__ == "__main__":
    main()
