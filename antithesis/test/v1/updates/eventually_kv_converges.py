#!/usr/bin/env python3.12
"""Property contested-rows-converge-after-quiesce (inserts and updates, no
deletes, no TOAST or delta columns yet).

After the sync barriers in helper_barriers.py pass, every mesh node must
hold the same kv rows: one md5 per row over all its columns, sorted by
key.  Updates only touch keys present on every node, so no update can be
update_missing, and no kv transaction may be discarded into
spock.exception_log.  Concurrent updates of one row on different nodes are
settled by last_update_wins, which must pick the same version everywhere.
"""

import time

from antithesis.assertions import always, sometimes

from helper_barriers import run_barriers
from helper_rows import diff_rows, row_hashes
from helper_spock import MESH, connect, log, retry_until

# How long to read the data once the barriers have passed.
READ_SECS = 120

# Rows named in the details when the nodes differ.
DIFF_SAMPLE = 20


def read_kv(node, deadline):
    """kv as sorted (origin, n, md5) rows, the number of rows last updated
    by a node other than their origin, and the kv exception_log count."""
    def fn():
        with connect(node) as conn:
            rows = row_hashes(conn, "kv", "origin, n")
            cross = conn.execute(
                "SELECT count(*) FROM kv WHERE writer <> origin").fetchone()[0]
            exceptions = conn.execute(
                "SELECT count(*) FROM spock.exception_log"
                " WHERE table_name = 'kv'").fetchone()[0]
        return rows, cross, exceptions

    return retry_until(deadline, f"read kv on {node}", fn)


def main():
    if not run_barriers(["parallel_driver_update_kv.py"]):
        return

    deadline = time.monotonic() + READ_SECS
    rows = {}
    cross = {}
    exceptions = {}
    for node in MESH:
        ok, val = read_kv(node, deadline)
        if not ok:
            log(f"kv not compared: could not read it on {node}")
            return
        rows[node], cross[node], exceptions[node] = val

    counts = {n: len(r) for n, r in rows.items()}
    differing, sample = diff_rows(rows, DIFF_SAMPLE)
    for row in sample:
        log(f"kv row differs: {row}")
    log(f"kv rows per node: {counts}; {len(differing)} differ;"
        f" rows last updated by another node: {cross};"
        f" kv exception_log rows: {exceptions}")

    always(not differing,
           "every mesh node holds the same kv rows after sync barriers",
           {"rows_per_node": counts, "differing_rows": len(differing),
            "sample": sample, "kv_exception_log_rows": exceptions})
    always(not any(exceptions.values()),
           "no kv transaction is discarded on any mesh node",
           {"kv_exception_log_rows": exceptions})
    sometimes(min(counts.values()) > 0,
              "kv rows were compared on every mesh node after sync barriers",
              {"rows_per_node": counts})
    sometimes(max(cross.values()) > 0,
              "a kv row was last updated by a node other than its origin",
              {"rows_last_updated_by_another_node": cross})


if __name__ == "__main__":
    main()
