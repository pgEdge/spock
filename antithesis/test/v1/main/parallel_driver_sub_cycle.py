#!/usr/bin/env python3.12
"""Disable and re-enable, or re-set the interface of, one live
subscription under load, for property
sub-disable-enable-cycle-loses-and-duplicates-nothing.

Every subscription change kills the apply worker at COMMIT
(signal_worker_xact_callback); sub_disable(immediate := true) kills it at
once.  The command watches briefly for the worker to open a remote
transaction and acts then, so the SIGTERM lands mid-transaction; the
SUT-side Sometimes "apply worker SIGTERM landed inside a remote
transaction" shows whether it did.

A subscription it disables is recorded first (helper_subcycle.py), so the
eventually command can re-enable it if this command is killed.  One
command at a time per subscription.  Connection errors are expected under
faults; it always exits 0.
"""

import fcntl
import os
import time

import psycopg
from antithesis.assertions import reachable
from antithesis.random import get_random, random_choice

from helper_spock import MESH, connect, load_params, log, retry_until
from helper_subcycle import (CYCLE_DIR, drop_record, note_cycle,
                             write_record)

OPS = ["disable_enable", "disable_immediate_enable", "alter_interface"]

# Suffix of the second interface alter_interface switches to.
ALT = "_alt"

# Seconds to watch for an open remote transaction before acting; 0 acts at
# a random moment.
AIM = [0, 2, 10]

# Seconds disabled: 0 re-enables before the old worker may have exited; 5
# is spock.restart_delay_default, the manager's restart tick; 30 lets a
# backlog build.
DISABLED = [0, 1, 5, 30]

# How long to keep trying sub_enable before leaving it to the eventually
# command.
ENABLE_SECS = 120


def worker_has_xact(conn, app):
    return conn.execute(
        "SELECT count(*) FROM pg_stat_activity"
        " WHERE application_name = %s AND backend_xid IS NOT NULL",
        (app,)).fetchone()[0] > 0


def aim(conn, app, secs):
    """Wait up to secs for the subscription's apply worker to hold a
    transaction.  Returns whether it did when we stopped watching."""
    end = time.monotonic() + secs
    while True:
        if worker_has_xact(conn, app):
            return True
        if time.monotonic() >= end:
            return False
        time.sleep(0.05)


def main():
    params = load_params()
    if get_random() % 100 >= params["sub_cycle_percent"]:
        return
    node = random_choice(MESH)
    os.makedirs(CYCLE_DIR, exist_ok=True)
    try:
        with connect(node) as conn:
            subs = conn.execute(
                """SELECT s.sub_name, s.sub_id, n.node_name, i.if_name,
                          i.if_dsn,
                          (SELECT oid FROM pg_database
                           WHERE datname = current_database())
                   FROM spock.subscription s
                   JOIN spock.node n ON n.node_id = s.sub_origin
                   JOIN spock.node_interface i ON i.if_id = s.sub_origin_if
                   WHERE s.sub_enabled
                   ORDER BY s.sub_name""").fetchall()
            if not subs:
                return
            sub, sub_id, origin, if_name, dsn, dboid = random_choice(subs)

            lock = open(f"{CYCLE_DIR}/{sub}.lock", "w")
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return

            op = random_choice(OPS)
            in_xact = aim(conn, f"spock apply {dboid}:{sub_id}",
                          random_choice(AIM))
            if op == "alter_interface":
                # Re-setting the current interface is a no-op, so switch
                # between it and a second one with the same DSN.
                alt = (if_name[:-len(ALT)] if if_name.endswith(ALT)
                       else if_name + ALT)
                if conn.execute(
                        """SELECT count(*) FROM spock.node_interface i
                           JOIN spock.node n ON n.node_id = i.if_nodeid
                           WHERE n.node_name = %s AND i.if_name = %s""",
                        (origin, alt)).fetchone()[0] == 0:
                    conn.execute("SELECT spock.node_add_interface(%s, %s, %s)",
                                 (origin, alt, dsn))
                conn.execute("SELECT spock.sub_alter_interface(%s, %s)",
                             (sub, alt))
                note_cycle(f"{node} {sub} {op}")
                log(f"{node}: re-set interface of {sub} (worker in a"
                    f" transaction: {in_xact})")
                reachable("subscription interface re-set under load",
                          {"node": node, "sub": sub})
                return

            write_record(sub, node)
            immediate = op == "disable_immediate_enable"
            conn.execute("SELECT spock.sub_disable(%s, %s)",
                         (sub, immediate))
            note_cycle(f"{node} {sub} {op}")
            disabled = random_choice(DISABLED)
            log(f"{node}: disabled {sub} (immediate: {immediate}, worker in"
                f" a transaction: {in_xact}), enabling in {disabled}s")
    except (psycopg.Error, OSError) as e:
        log(f"{node}: {e.__class__.__name__}: {str(e).strip()}")
        return

    time.sleep(disabled)

    def enable():
        with connect(node) as conn:
            conn.execute("SELECT spock.sub_enable(%s)", (sub,))

    ok, err = retry_until(time.monotonic() + ENABLE_SECS,
                          f"enable {sub} on {node}", enable)
    if ok:
        try:
            drop_record(sub)
        except OSError as e:
            log(f"record for {sub} not removed: {e}")
        log(f"{node}: re-enabled {sub}")
        reachable("subscription disabled and re-enabled under load",
                  {"node": node, "sub": sub, "immediate": immediate,
                   "disabled_s": disabled})
    else:
        log(f"{node}: {sub} left disabled for the eventually command: {err}")


if __name__ == "__main__":
    main()
