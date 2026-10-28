#!/usr/bin/env python3.12
"""Create the kv table on every mesh node, add it to the default
replication set, and draw this timeline's workload shape.  Runs before any
driver, with no faults."""

import time

from antithesis.assertions import reachable
from antithesis.random import random_choice

from helper_kv import ensure_kv, save_params
from helper_spock import MESH, log, retry_until


def main():
    deadline = time.monotonic() + 300
    for node in MESH:
        ok, err = retry_until(deadline, f"create kv on {node}",
                              lambda: ensure_kv(node))
        if not ok:
            # No faults run during first_, so this is a setup failure.
            log(f"gave up creating kv on {node}: {err}")
            raise SystemExit(1)
    log("kv ready on " + ", ".join(MESH))
    reachable("kv table created on every mesh node", {"nodes": MESH})

    # Swarm per timeline: writers on one to three nodes; mostly inserts or
    # mostly updates; updates only on each node's own rows (no conflicts),
    # only on other nodes' rows, or a mix; and a hot set of 1, 10 or 1000
    # keys per origin, where 1 makes every contested update collide.
    writer_nodes = [n for n in MESH if random_choice([True, True, False])]
    if not writer_nodes:
        writer_nodes = [random_choice(MESH)]
    params = {
        "writer_nodes": writer_nodes,
        "update_weight": random_choice([0.2, 0.6, 0.95]),
        "contested_weight": random_choice([0.0, 0.5, 1.0]),
        "hot_keys": random_choice([1, 10, 1000]),
    }
    save_params(params)
    log(f"timeline params: {params}")


if __name__ == "__main__":
    main()
