#!/usr/bin/env python3.12
"""Create the ledger table on every mesh node and add it to the default
replication set.  Runs before any driver, with no faults."""

import time

from antithesis.assertions import reachable
from antithesis.random import random_choice

from helper_spock import MESH, ensure_ledger, log, retry_until, save_params


def main():
    deadline = time.monotonic() + 300
    for node in MESH:
        ok, err = retry_until(deadline, f"create ledger on {node}",
                              lambda: ensure_ledger(node))
        if not ok:
            # No faults run during first_, so this is a setup failure.
            log(f"gave up creating the ledger on {node}: {err}")
            raise SystemExit(1)
    log("ledger ready on " + ", ".join(MESH))
    reachable("ledger table created on every mesh node", {"nodes": MESH})

    # Swarm the writers per timeline: some timelines write on one node only
    # (the other channels stay idle, so only keepalives cross them), others
    # on all three.  15% of transactions are large: enough to have one in
    # flight when a partition starts, without filling the disk.
    writer_nodes = [n for n in MESH if random_choice([True, True, False])]
    if not writer_nodes:
        writer_nodes = [random_choice(MESH)]
    params = {
        "writer_nodes": writer_nodes,
        "big_txn_weight": 0.15,
    }
    save_params(params)
    log(f"timeline params: {params}")


if __name__ == "__main__":
    main()
