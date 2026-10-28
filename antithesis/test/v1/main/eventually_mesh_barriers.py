#!/usr/bin/env python3.12
"""Eventually checks for the main template.

Property mesh-barriers-complete-after-partition-heal: see helper_barriers.py.

Property committed-ledger-row-reaches-every-node.

Once every pair has passed, the ledger is read on every mesh node as one
md5 per row over all its columns, sorted by key, and the lists are
compared.  The barrier only covers commits made before the sync event, and
a backend whose client was killed after sending COMMIT can still commit
later (the client's packets may be held up by a partition).  So before
taking it the command terminates leftover writer sessions: one already
committing finishes first, one that has not got COMMIT rolls back.  If a
session is still there after that, the ledger is not compared.

Property graceful-restart-preserves-exactly-once.

parallel_driver_graceful_restart.sh (node containers) stops nodes with
pg_ctl stop -m fast.  Each restart it recorded must have accepted
connections within RESTART_BOUND.  In a timeline with at least one clean
stop and no crash recovery on any mesh node, the shutdown checkpoint makes
replication origins durable, so nothing may be applied twice or lost: no
insert_exists resolution on the ledger, no ledger exception_log row, every
subscription enabled, and the same ledger rows on every node.  A crash
anywhere skips these checks, since crash redo (lead L1) can legitimately
explain a resend there.
"""

import time

from antithesis.assertions import always, reachable, sometimes

from helper_barriers import run_barriers
from helper_restarts import node_history
from helper_rows import diff_rows, row_hashes
from helper_spock import MESH, connect, log, retry_until

# How long to read the data once the barriers have passed.
READ_SECS = 120

# Rows named in the details when the ledgers differ.
DIFF_SAMPLE = 20

# A node restarted after a clean stop has no crash recovery to do.
RESTART_BOUND = 120


def read_ledger(node, deadline):
    """The node's ledger as a sorted list of (origin, seq, md5 of the whole
    row), and its count of exception_log rows for the ledger."""
    def fn():
        with connect(node) as conn:
            rows = row_hashes(conn, "ledger", "origin, seq")
            exceptions = conn.execute(
                "SELECT count(*) FROM spock.exception_log"
                " WHERE table_name = 'ledger'").fetchone()[0]
        return rows, exceptions

    return retry_until(deadline, f"read ledger on {node}", fn)


def compare_ledgers():
    """Returns the number of differing rows and each node's ledger
    exception_log count, or None if a ledger could not be read."""
    deadline = time.monotonic() + READ_SECS
    ledgers = {}
    exceptions = {}
    for node in MESH:
        ok, val = read_ledger(node, deadline)
        if not ok:
            log(f"ledger not compared: could not read it on {node}")
            return None
        ledgers[node], exceptions[node] = val

    counts = {n: len(rows) for n, rows in ledgers.items()}
    differing, sample = diff_rows(ledgers, DIFF_SAMPLE)
    for row in sample:
        log(f"ledger row differs: {row}")
    log(f"ledger rows per node: {counts}; {len(differing)} differ;"
        f" ledger exception_log rows per node: {exceptions}")

    always(not differing,
           "every mesh node holds the same ledger rows after sync barriers",
           {"rows_per_node": counts, "differing_rows": len(differing),
            "sample": sample, "ledger_exception_log_rows": exceptions})
    sometimes(min(counts.values()) > 0,
              "ledger rows were compared on every mesh node after sync barriers",
              {"rows_per_node": counts})
    return {"differing_rows": len(differing),
            "ledger_exception_log_rows": exceptions}


def check_graceful_restarts(ledger):
    deadline = time.monotonic() + READ_SECS
    history = {}
    for node in MESH:
        ok, val = retry_until(deadline, f"restart history on {node}",
                              lambda: node_history(node))
        if not ok:
            log(f"graceful restarts not checked: no history from {node}")
            return
        history[node] = val
    log("restart history: " + ", ".join(
        f"{n}: {h['clean_exits']} clean exits, {h['recoveries']} recoveries"
        for n, h in history.items()))

    for node, h in history.items():
        for r in h["graceful"]:
            if r.get("stop_rc") != "0":
                continue
            # The other checks below skip crashes; so does the timing.
            if h["recoveries"]:
                continue
            ready = r.get("ready_s", "")
            ready_ok = (ready.replace(".", "", 1).isdigit()
                        and float(ready) <= RESTART_BOUND)
            # A node pause stretched the driver's clock; not Spock's time.
            if r.get("paused") == "1" and not ready_ok:
                log(f"restart on {node} not timed: node paused {r}")
                continue
            always(ready_ok,
                   "a gracefully stopped node accepts connections within 2 minutes of starting again",
                   {"node": node, "bound_s": RESTART_BOUND, **r})
            sometimes(r.get("writers", "0") not in ("0", "?"),
                      "graceful stop landed while a ledger writer was active on the node",
                      {"node": node, **r})
            sometimes(r.get("apply_in_txn", "0") not in ("0", "?"),
                      "graceful stop landed while an apply worker was inside a remote transaction",
                      {"node": node, **r})

    clean = {n: h["clean_exits"] for n, h in history.items()}
    recoveries = {n: h["recoveries"] for n, h in history.items()}
    if sum(clean.values()) == 0:
        return
    if any(recoveries.values()):
        log(f"exactly-once after graceful restarts not checked: crash"
            f" recoveries {recoveries}")
        return

    disabled = {}
    twice = {}
    for node in MESH:
        def fn():
            with connect(node) as conn:
                d = conn.execute(
                    "SELECT coalesce(array_agg(sub_name::text), '{}')"
                    " FROM spock.subscription WHERE NOT sub_enabled"
                ).fetchone()[0]
                t = conn.execute(
                    "SELECT count(*) FROM spock.resolutions"
                    " WHERE conflict_type = 'insert_exists'"
                    " AND relname = 'public.ledger'").fetchone()[0]
            return d, t

        ok, val = retry_until(deadline, f"subscriptions on {node}", fn)
        if not ok:
            log(f"exactly-once after graceful restarts not checked:"
                f" could not read {node}")
            return
        disabled[node], twice[node] = val

    details = {"clean_exits": clean}
    reachable("exactly-once checked after a graceful restart with no crash",
              details)
    always(not any(disabled.values()),
           "every subscription is enabled after graceful restarts",
           {**details, "disabled": disabled})
    always(not any(twice.values()),
           "no ledger row applied twice across graceful restarts",
           {**details, "insert_exists_rows": twice})
    if ledger is None:
        log("ledger rows after graceful restarts not checked: no comparison")
        return
    always(ledger["differing_rows"] == 0,
           "every mesh node holds the same ledger rows after graceful restarts",
           {**details, **ledger})
    always(not any(ledger["ledger_exception_log_rows"].values()),
           "no ledger transaction discarded across graceful restarts",
           {**details, **ledger})


def main():
    ledger = None
    if run_barriers(["parallel_driver_write_ledger.py"]):
        ledger = compare_ledgers()

    check_graceful_restarts(ledger)


if __name__ == "__main__":
    main()
