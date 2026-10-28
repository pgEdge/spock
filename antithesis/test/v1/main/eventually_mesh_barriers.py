#!/usr/bin/env python3.12
"""Property mesh-barriers-complete-after-partition-heal.

Faults stop when this command starts.  For every mesh node P it takes
lsn := spock.sync_event() on P, and for every other node S waits with
spock.wait_for_sync_event on S until S has applied P's changes up to lsn.
Every ordered pair must get there within BOUND seconds of the start.

Spock has no relay: n2's changes reach n1 only over sub_n1_n2, so each of
the six channels has to recover on its own.

The bound covers the worst case per pair: the provider keeps the old
walsender until wal_sender_timeout (60 s), the subscriber notices a link
that died with data in flight only after spock.apply_idle_timeout (120 s),
then restart_delay (5 s) and connect_timeout (30 s), plus catch-up.

wait_for_sync_event measures its timeout with the server's wall clock, so a
clock jump can end it early with false.  The deadline here uses the
workload's monotonic clock, and a false result before the deadline just
waits again; a client-side cancel stops a wait that the server's clock
stretches past the deadline.  A pair that misses the deadline gets one
short re-check before it is scored, in case the workload's own clock
jumped; a pass on that re-check is recorded as 'reached_on_recheck'.

Each pair's backlog when faults stopped (provider WAL not yet confirmed by
the subscriber's slot) goes into the assertion details, so triage can tell
a slow catch-up from a channel that never resumed.

sub_show_status() is not used: 'replicating' only means a worker process
exists, not that data arrives.

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

import threading
import time

import psycopg
from antithesis.assertions import always, reachable, sometimes

from helper_restarts import node_history
from helper_spock import MESH, connect, log, retry_until

BOUND = 300

PAIRS = [(p, s) for p in MESH for s in MESH if p != s]

RECHECK_SECS = 5

# How long to wait for terminated writer sessions to go, and to read the
# ledger once the barriers have passed.
WRITERS_GONE_SECS = 10
READ_SECS = 120

# Rows named in the details when the ledgers differ.
DIFF_SAMPLE = 20

# A node restarted after a clean stop has no crash recovery to do.
RESTART_BOUND = 120


def snapshot_slots(deadline):
    """Before waiting, record whether each channel's slot is active on its
    provider, and how many bytes of provider WAL it has not confirmed yet.
    An inactive slot means faults broke that channel, which is what this
    check is for.  Best effort: a node that does not answer within a couple
    of seconds is left out.  Returns {(p, s): backlog bytes}."""
    inactive = []
    backlog = {}
    for p, s in PAIRS:
        if time.monotonic() >= deadline:
            break
        try:
            with connect(s, connect_timeout=2) as conn:
                row = conn.execute(
                    """SELECT sub.sub_slot_name
                       FROM spock.subscription sub
                       JOIN spock.node n ON n.node_id = sub.sub_origin
                       WHERE n.node_name = %s""", (p,)).fetchone()
            if row is None:
                continue
            with connect(p, connect_timeout=2) as conn:
                act = conn.execute(
                    """SELECT active,
                              pg_wal_lsn_diff(pg_current_wal_lsn(),
                                              confirmed_flush_lsn)::bigint
                       FROM pg_replication_slots WHERE slot_name = %s""",
                    (row[0],)).fetchone()
            if act is None or not act[0]:
                inactive.append(f"{p}->{s}")
            if act is not None:
                backlog[(p, s)] = act[1]
        except psycopg.Error as e:
            log(f"slot snapshot {p}->{s}: {e.__class__.__name__}")
    log(f"channels with an inactive slot when faults stopped: {inactive}")
    log("backlog bytes when faults stopped: "
        + ", ".join(f"{p}->{s}={b}" for (p, s), b in backlog.items()))
    sometimes(len(inactive) > 0,
              "a replication slot was inactive on its provider when faults stopped",
              {"inactive": inactive})
    return backlog


def end_writers(p, deadline):
    """Terminate p's ledger writer sessions and wait for them to go.
    Returns how many are left: 0 when they are gone, None when p could not
    be asked."""
    left = None
    while True:
        try:
            with connect(p) as conn:
                left = conn.execute(
                    "SELECT count(pg_terminate_backend(pid))"
                    " FROM pg_stat_activity"
                    " WHERE application_name = 'parallel_driver_write_ledger.py'"
                ).fetchone()[0]
            if left == 0:
                return 0
            log(f"{p}: terminated {left} leftover writer session(s)")
        except psycopg.Error as e:
            log(f"writer sessions on {p}: {e.__class__.__name__}")
        if time.monotonic() >= deadline:
            return left
        time.sleep(1)


def take_lsn(p, deadline, lsns, writers_left):
    writers_left[p] = end_writers(
        p, min(deadline, time.monotonic() + WRITERS_GONE_SECS))

    def fn():
        with connect(p) as conn:
            return conn.execute("SELECT spock.sync_event()::text").fetchone()[0]

    ok, val = retry_until(deadline, f"sync_event on {p}", fn)
    if ok:
        lsns[p] = val
        log(f"sync_event on {p}: {val}")


def barrier_call(p, s, lsn, timeout):
    """One wait_for_sync_event call on s, cancelled from this side if it
    runs well past its timeout."""
    with connect(s, connect_timeout=max(1, min(5, timeout))) as conn:
        timer = threading.Timer(timeout + 10, conn.cancel)
        timer.start()
        try:
            return conn.execute(
                "CALL spock.wait_for_sync_event(NULL, %s::name, %s::pg_lsn, %s, false)",
                (p, lsn, timeout)).fetchone()[0]
        finally:
            timer.cancel()


def wait_pair(p, s, lsn, start, deadline, results):
    """Wait on s for p's sync event.  results[(p, s)] gets a dict with
    outcome 'reached', 'reached_on_recheck', 'timeout' or 'disabled'."""
    attempts = 0
    last_error = None
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        attempts += 1
        try:
            reached = barrier_call(p, s, lsn, max(1, int(remaining)))
            if reached:
                results[(p, s)] = {
                    "outcome": "reached",
                    "elapsed_s": round(time.monotonic() - start, 1),
                    "attempts": attempts,
                }
                return
            # False before our deadline: the server's clock moved; wait again.
        except psycopg.Error as e:
            last_error = f"{e.__class__.__name__}: {str(e).strip()}"
            if "has been disabled" in str(e):
                # Disabled subscriptions belong to the exception/disable
                # properties; wait_if_disabled=false makes the wait refuse.
                results[(p, s)] = {"outcome": "disabled", "error": last_error}
                return
            log(f"wait {p}->{s}: {last_error}")
            time.sleep(1)
    try:
        if barrier_call(p, s, lsn, RECHECK_SECS):
            results[(p, s)] = {
                "outcome": "reached_on_recheck",
                "elapsed_s": round(time.monotonic() - start, 1),
                "attempts": attempts + 1,
            }
            return
    except psycopg.Error as e:
        last_error = f"{e.__class__.__name__}: {str(e).strip()}"
    results[(p, s)] = {
        "outcome": "timeout",
        "elapsed_s": round(time.monotonic() - start, 1),
        "attempts": attempts,
        "last_error": last_error,
    }


def run_pair(p, s, lsn, start, deadline, results):
    # An unexpected exception must still leave a result to score.
    try:
        wait_pair(p, s, lsn, start, deadline, results)
    except Exception as e:
        log(f"wait {p}->{s}: unexpected {e!r}")
        results.setdefault((p, s), {"outcome": "timeout",
                                    "last_error": f"workload: {e!r}"})


def read_ledger(node, deadline):
    """The node's ledger as a sorted list of (origin, seq, md5 of the whole
    row), and its count of exception_log rows for the ledger."""
    def fn():
        with connect(node) as conn:
            rows = conn.execute(
                "SELECT origin, seq, md5(l::text) FROM ledger l"
                " ORDER BY origin, seq").fetchall()
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
    differing = []
    sample = []
    if any(ledgers[n] != ledgers[MESH[0]] for n in MESH[1:]):
        hashes = {n: {(o, q): h for o, q, h in rows}
                  for n, rows in ledgers.items()}
        keys = sorted(set().union(*hashes.values()))
        differing = [k for k in keys
                     if len({hashes[n].get(k) for n in MESH}) > 1]
        for o, q in differing[:DIFF_SAMPLE]:
            row = {n: hashes[n].get((o, q), "missing") for n in MESH}
            sample.append({"origin": o, "seq": q, **row})
            log(f"ledger row {o}:{q}: {row}")
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
    start = time.monotonic()
    deadline = start + BOUND

    backlog = snapshot_slots(start + 30)

    lsns = {}
    writers_left = {}
    threads = [threading.Thread(target=take_lsn,
                                args=(p, deadline, lsns, writers_left))
               for p in MESH]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    results = {}
    threads = []
    for p, s in PAIRS:
        if p not in lsns:
            results[(p, s)] = {"outcome": "timeout",
                               "last_error": f"no sync_event on {p} within the bound"}
            continue
        t = threading.Thread(target=run_pair,
                             args=(p, s, lsns[p], start, deadline, results))
        t.start()
        threads.append(t)
    for t in threads:
        t.join()

    checked = 0
    slowest = 0.0
    all_reached = True
    for p, s in PAIRS:
        r = results.get((p, s), {"outcome": "timeout",
                                 "last_error": "workload: no result"})
        log(f"{p}->{s}: {r}")
        if r["outcome"] == "disabled":
            continue
        checked += 1
        reached = r["outcome"] in ("reached", "reached_on_recheck")
        all_reached = all_reached and reached
        if reached:
            slowest = max(slowest, r["elapsed_s"])
        always(reached,
               "sync barrier P->S completes within 5 minutes after faults stop",
               {"provider": p, "subscriber": s, "lsn": lsns.get(p),
                "bound_s": BOUND, "backlog_bytes": backlog.get((p, s)),
                **r})

    sometimes(checked == len(PAIRS),
              "every ordered mesh pair was checked by the sync barrier",
              {"checked": checked,
               "disabled": [f"{p}->{s}" for (p, s), r in results.items()
                            if r["outcome"] == "disabled"]})
    sometimes(slowest > 30,
              "a sync barrier needed more than 30 s after faults stopped",
              {"slowest_s": slowest})

    # A missed or disabled barrier is reported above; comparing the ledger
    # then would report rows that are only late, not lost.
    ledger = None
    if not (all_reached and checked == len(PAIRS)):
        log("ledger not compared: not every sync barrier passed")
    elif any(n != 0 for n in writers_left.values()):
        log(f"ledger not compared: writer sessions left {writers_left}")
    else:
        ledger = compare_ledgers()

    check_graceful_restarts(ledger)


if __name__ == "__main__":
    main()
