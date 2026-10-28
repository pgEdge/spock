#!/usr/bin/env python3.12
"""Switch one mesh node into read-only mode and back under load, for
property readonly-toggle-resumes-without-loss.

readonly=all stops the node's apply workers at the next message: each one
breaks out of its loop, stays connected and keeps sending feedback, and
resumes when readonly is lifted; a hold past spock.apply_idle_timeout
makes it reconnect meanwhile.  For local sessions both modes only make
non-superusers read-only (src/spock_readonly.c); the ledger writer is a
superuser, so it keeps writing on the node, and under all the node's
ledger diverges until readonly is lifted and apply catches up.  For
readonly=all the command watches briefly for an apply worker to hold a
remote transaction and switches then; the SUT-side Sometimes "apply loop
stopped for readonly=all inside a remote transaction" shows whether the
stop landed there.

The eventually command sets every node back to off.  One command at a
time per node.  Connection errors are expected under faults; it always
exits 0.
"""

import fcntl
import os
import time

import psycopg
from antithesis.assertions import reachable
from antithesis.random import get_random, random_choice

from helper_readonly import READONLY_DIR, note_toggle, set_readonly
from helper_spock import MESH, connect, load_params, log

MODES = ["all", "local"]

# Seconds to watch for an open remote transaction before switching to
# readonly=all; 0 switches at a random moment.
AIM = [0, 2, 10]

# Seconds read-only: 0 lifts it before the workers may have noticed; 130
# is past spock.apply_idle_timeout (120 s), so stopped workers reconnect.
HOLD = [0, 1, 5, 30, 130]

# What the node goes back to; local keeps replication running.
AFTER = ["off", "local"]


def apply_in_xact(conn):
    return conn.execute(
        "SELECT count(*) FROM pg_stat_activity"
        " WHERE application_name LIKE 'spock apply %'"
        " AND backend_xid IS NOT NULL").fetchone()[0] > 0


def aim(conn, secs):
    end = time.monotonic() + secs
    while True:
        if apply_in_xact(conn):
            return True
        if time.monotonic() >= end:
            return False
        time.sleep(0.05)


def main():
    params = load_params()
    if get_random() % 100 >= params["readonly_percent"]:
        return
    node = random_choice(MESH)
    os.makedirs(READONLY_DIR, exist_ok=True)
    lock = open(f"{READONLY_DIR}/{node}.lock", "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return

    mode = random_choice(MODES)
    hold = random_choice(HOLD)
    after = random_choice(AFTER)
    try:
        with connect(node) as conn:
            in_xact = aim(conn, random_choice(AIM)) if mode == "all" else False
            set_readonly(conn, mode)
            note_toggle(f"{node} {mode} {hold} {after}")
        log(f"{node}: readonly={mode} (apply worker in a transaction:"
            f" {in_xact}), back to {after} in {hold}s")
        time.sleep(hold)
        with connect(node) as conn:
            set_readonly(conn, after)
    except (psycopg.Error, OSError) as e:
        log(f"{node}: {e.__class__.__name__}: {str(e).strip()}")
        return
    log(f"{node}: readonly={after}")
    reachable("node switched to read-only and back under load",
              {"node": node, "mode": mode, "hold_s": hold, "after": after})


if __name__ == "__main__":
    main()
