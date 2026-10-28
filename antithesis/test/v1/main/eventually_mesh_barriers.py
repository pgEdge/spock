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

Property fast-shutdown-completes-within-bound.

Every stop the graceful-restart driver signalled must end, measured by the
entrypoint's exits.log line, within the node's wal_sender_timeout plus 60
seconds, and no process of the old postmaster may still be alive then.
Stops during a node pause are not timed.

Property readonly-toggle-resumes-without-loss.

parallel_driver_readonly_toggle.py switches nodes to readonly all or local
and back.  This command first sets every mesh node back to off.  In a
timeline with at least one toggle and no crash, the same four checks run
under their own names, plus the reset itself.

Property sub-disable-enable-cycle-loses-and-duplicates-nothing.

parallel_driver_sub_cycle.py disables and re-enables subscriptions, or
switches their interface, under load.  This command first ends that
driver's sessions and re-enables what it recorded as left disabled.  In a
timeline where it issued at least one change and no mesh node crashed, the
same four checks run under their own names: every subscription enabled, no
insert_exists resolution on the ledger, no ledger exception_log row, and
the same ledger rows on every node.
"""

import time

from antithesis.assertions import always, reachable, sometimes

from helper_barriers import end_writers, run_barriers
from helper_restarts import node_history
from helper_rows import diff_rows, row_hashes
from helper_spock import MESH, connect, log, retry_until
from helper_readonly import DRIVER_APP as READONLY_APP
from helper_readonly import reset_readonly, toggles_made
from helper_subcycle import DRIVER_APP as SUB_CYCLE_APP
from helper_subcycle import cycles_issued, reenable_recorded

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


def read_history():
    """Each mesh node's restart history (helper_restarts.py), or None."""
    deadline = time.monotonic() + READ_SECS
    history = {}
    for node in MESH:
        ok, val = retry_until(deadline, f"restart history on {node}",
                              lambda: node_history(node))
        if not ok:
            log(f"lifecycle checks skipped: no restart history from {node}")
            return None
        history[node] = val
    log("restart history: " + ", ".join(
        f"{n}: {h['clean_exits']} clean exits, {h['recoveries']} recoveries"
        for n, h in history.items()))
    return history


def read_after_state():
    """Disabled subscriptions and ledger insert_exists resolutions on each
    mesh node, or None."""
    deadline = time.monotonic() + READ_SECS
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
            log(f"lifecycle checks skipped: could not read {node}")
            return None
        disabled[node], twice[node] = val
    return {"disabled": disabled, "insert_exists_rows": twice}


def check_fast_shutdown(node, r):
    """Property fast-shutdown-completes-within-bound, for one stop the
    graceful-restart driver signalled and saw finish or time out.  A stop
    still hanging when this command starts leaves no record; that node then
    never answers and fails the sync barrier instead."""
    wst = r.get("wst_s", "")
    if not wst.isdigit():
        log(f"stop on {node} not timed: wal_sender_timeout unknown {r}")
        return
    bound = int(wst) + 60
    exited = r["stop_rc"] != "timeout"
    in_bound = exited and float(r["stop_s"]) <= bound
    # A node pause stretched the driver's clock; not Spock's time.
    if r.get("paused") == "1" and not in_bound:
        log(f"stop on {node} not timed: node paused {r}")
        return
    details = {"node": node, "bound_s": bound, **r}
    always(in_bound,
           "a fast shutdown finishes within wal_sender_timeout plus 60 seconds",
           details)
    if exited and r.get("old_left", "").isdigit():
        always(r["old_left"] == "0",
               "no process of the old postmaster outlives a fast shutdown",
               details)
    sometimes(exited and float(r["stop_s"]) > 5,
              "a fast shutdown took more than 5 seconds", details)


def check_restart_records(history):
    for node, h in history.items():
        for r in h["graceful"]:
            if "stop_s" in r:
                check_fast_shutdown(node, r)
            if r.get("stop_rc") != "0":
                continue
            # The exactly-once checks skip crashes; so does the timing.
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
            # The driver asks pg_xact_status() after the restart, so these
            # count only transactions the stop really cut short.
            sometimes(r.get("writers_cut", "0").isdigit()
                      and int(r.get("writers_cut", "0")) > 0,
                      "graceful stop cut short a ledger writer's transaction",
                      {"node": node, **r})
            sometimes(r.get("apply_cut", "0").isdigit()
                      and int(r.get("apply_cut", "0")) > 0,
                      "graceful stop cut short an apply worker's remote transaction",
                      {"node": node, **r})


def check_graceful_restarts(history, after, ledger):
    clean = {n: h["clean_exits"] for n, h in history.items()}
    if sum(clean.values()) == 0:
        return
    details = {"clean_exits": clean}
    reachable("exactly-once checked after a graceful restart with no crash",
              details)
    always(not any(after["disabled"].values()),
           "every subscription is enabled after graceful restarts",
           {**details, "disabled": after["disabled"]})
    always(not any(after["insert_exists_rows"].values()),
           "no ledger row applied twice across graceful restarts",
           {**details, "insert_exists_rows": after["insert_exists_rows"]})
    if ledger is None:
        log("ledger rows after graceful restarts not checked: no comparison")
        return
    always(ledger["differing_rows"] == 0,
           "every mesh node holds the same ledger rows after graceful restarts",
           {**details, **ledger})
    always(not any(ledger["ledger_exception_log_rows"].values()),
           "no ledger transaction discarded across graceful restarts",
           {**details, **ledger})


def check_sub_cycles(after, ledger, not_reenabled):
    cycles = cycles_issued()
    if cycles == 0:
        return
    details = {"cycles": cycles}
    reachable("exactly-once checked after subscription disable/enable cycles with no crash",
              details)
    always(not any(after["disabled"].values()) and not not_reenabled,
           "every subscription is enabled after subscription disable/enable cycles",
           {**details, "disabled": after["disabled"],
            "not_reenabled": not_reenabled})
    always(not any(after["insert_exists_rows"].values()),
           "no ledger row applied twice across subscription disable/enable cycles",
           {**details, "insert_exists_rows": after["insert_exists_rows"]})
    if ledger is None:
        log("ledger rows after subscription cycles not checked: no comparison")
        return
    always(ledger["differing_rows"] == 0,
           "every mesh node holds the same ledger rows after subscription disable/enable cycles",
           {**details, **ledger})
    always(not any(ledger["ledger_exception_log_rows"].values()),
           "no ledger transaction discarded across subscription disable/enable cycles",
           {**details, **ledger})


def check_readonly_toggles(after, ledger, not_reset):
    toggles = toggles_made()
    if toggles == 0:
        return
    details = {"toggles": toggles}
    reachable("exactly-once checked after read-only toggles with no crash",
              details)
    always(not not_reset,
           "every node returns to readonly=off after read-only toggles",
           {**details, "not_reset": not_reset})
    always(not any(after["disabled"].values()),
           "every subscription is enabled after read-only toggles",
           {**details, "disabled": after["disabled"]})
    always(not any(after["insert_exists_rows"].values()),
           "no ledger row applied twice across read-only toggles",
           {**details, "insert_exists_rows": after["insert_exists_rows"]})
    if ledger is None:
        log("ledger rows after read-only toggles not checked: no comparison")
        return
    always(ledger["differing_rows"] == 0,
           "every mesh node holds the same ledger rows after read-only toggles",
           {**details, **ledger})
    always(not any(ledger["ledger_exception_log_rows"].values()),
           "no ledger transaction discarded across read-only toggles",
           {**details, **ledger})


def main():
    # Undo what killed lifecycle drivers left behind, after ending their
    # sessions so a sub_disable or ALTER SYSTEM still running cannot land
    # afterwards.  readonly first, so apply resumes before the barriers.
    # A node may still be restarting when faults stop, so allow it time to
    # come back before calling its sessions unknown.
    deadline = time.monotonic() + READ_SECS
    left = {node: end_writers(node, deadline, [SUB_CYCLE_APP, READONLY_APP])
            for node in MESH}
    not_reset = reset_readonly(time.monotonic() + READ_SECS)
    not_reenabled = reenable_recorded(time.monotonic() + READ_SECS)

    ledger = None
    if run_barriers(["parallel_driver_write_ledger.py"]):
        ledger = compare_ledgers()

    history = read_history()
    if history is None:
        return
    check_restart_records(history)
    recoveries = {n: h["recoveries"] for n, h in history.items()}
    if any(recoveries.values()):
        # Crash redo (lead L1) can legitimately explain a resend.
        log(f"exactly-once checks skipped: crash recoveries {recoveries}")
        return
    after = read_after_state()
    if after is None:
        return
    if any(n != 0 for n in left.values()):
        # A sub_disable or ALTER SYSTEM may still land, so subscription and
        # readonly state are not final.
        log(f"exactly-once checks skipped: driver sessions left {left}")
        return
    check_graceful_restarts(history, after, ledger)
    check_sub_cycles(after, ledger, not_reenabled)
    check_readonly_toggles(after, ledger, not_reset)


if __name__ == "__main__":
    main()
