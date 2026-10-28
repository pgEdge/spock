"""Sync barriers after faults stop, shared by the templates' eventually
commands (other templates reach this file through a symlink).

Property mesh-barriers-complete-after-partition-heal.

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

Before taking the sync events, run_barriers() terminates the template's
leftover writer sessions.  The barrier only covers commits made before the
sync event, and a backend whose client was killed after sending COMMIT can
still commit later (the client's packets may be held up by a partition).
Terminating it settles that: one already committing finishes first, one
that has not got COMMIT rolls back.
"""

import threading
import time

import psycopg
from antithesis.assertions import always, sometimes

from helper_spock import MESH, connect, log, retry_until

BOUND = 300

PAIRS = [(p, s) for p in MESH for s in MESH if p != s]

RECHECK_SECS = 5

# How long to wait for terminated writer sessions to go.
WRITERS_GONE_SECS = 10


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


def end_writers(p, deadline, writer_apps):
    """Terminate p's sessions whose application_name is in writer_apps and
    wait for them to go.  Returns how many are left: 0 when they are gone,
    None when p could not be asked."""
    left = None
    while True:
        try:
            with connect(p) as conn:
                left = conn.execute(
                    "SELECT count(pg_terminate_backend(pid))"
                    " FROM pg_stat_activity"
                    " WHERE application_name = ANY(%s)",
                    (writer_apps,)).fetchone()[0]
            if left == 0:
                return 0
            log(f"{p}: terminated {left} leftover writer session(s)")
        except psycopg.Error as e:
            log(f"writer sessions on {p}: {e.__class__.__name__}")
        if time.monotonic() >= deadline:
            return left
        time.sleep(1)


def take_lsn(p, deadline, lsns, writers_left, writer_apps):
    writers_left[p] = end_writers(
        p, min(deadline, time.monotonic() + WRITERS_GONE_SECS), writer_apps)

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


def run_barriers(writer_apps):
    """Run the sync barrier on every ordered mesh pair and score it.
    writer_apps names the template's writer commands.  Returns True when
    every pair passed and no writer session was left, so the data on the
    nodes can be compared."""
    start = time.monotonic()
    deadline = start + BOUND

    backlog = snapshot_slots(start + 30)

    lsns = {}
    writers_left = {}
    threads = [threading.Thread(target=take_lsn,
                                args=(p, deadline, lsns, writers_left,
                                      writer_apps))
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

    if not (all_reached and checked == len(PAIRS)):
        log("data not compared: not every sync barrier passed")
        return False
    if any(n != 0 for n in writers_left.values()):
        log(f"data not compared: writer sessions left {writers_left}")
        return False
    return True
