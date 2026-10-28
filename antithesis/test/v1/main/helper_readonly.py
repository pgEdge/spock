"""Bookkeeping shared by parallel_driver_readonly_toggle.py and the
eventually command.  /tmp in the workload container lasts for the whole
timeline.

Only the driver sets spock.readonly in this harness, so the eventually
command puts every mesh node back to off without needing a record.  Every
toggle the driver makes adds a line to TOGGLES_LOG.
"""

import os

from helper_spock import MESH, connect, log, retry_until

READONLY_DIR = "/tmp/spock-readonly"
TOGGLES_LOG = f"{READONLY_DIR}/toggles.log"

# The driver's application_name, which the eventually command terminates
# before resetting, so an ALTER SYSTEM still running cannot land after.
DRIVER_APP = "parallel_driver_readonly_toggle.py"


def set_readonly(conn, mode):
    """ALTER SYSTEM cannot take a parameter, so mode is checked here."""
    assert mode in ("off", "local", "all")
    conn.execute(f"ALTER SYSTEM SET spock.readonly = '{mode}'")
    conn.execute("SELECT pg_reload_conf()")


def note_toggle(line):
    os.makedirs(READONLY_DIR, exist_ok=True)
    with open(TOGGLES_LOG, "a") as f:
        f.write(line + "\n")


def toggles_made():
    try:
        with open(TOGGLES_LOG) as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def reset_readonly(deadline):
    """Set spock.readonly back to off on every mesh node.  Returns the
    nodes where that failed."""
    failed = []
    for node in MESH:
        def fn():
            with connect(node) as conn:
                set_readonly(conn, "off")

        ok, _ = retry_until(deadline, f"readonly off on {node}", fn)
        if not ok:
            failed.append(node)
    if failed:
        log(f"readonly not reset on {failed}")
    return failed
