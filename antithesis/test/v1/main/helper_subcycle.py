"""Bookkeeping shared by parallel_driver_sub_cycle.py and the eventually
command.  /tmp in the workload container lasts for the whole timeline.

A subscription the driver disables gets a record, written before
sub_disable and removed after sub_enable succeeds, so the eventually
command can re-enable whatever a killed driver left disabled, and only
that: a disabled subscription without a record was not the driver's.
Every subscription change the driver issues adds a line to CYCLES_LOG.
"""

import os

from helper_spock import connect, log, retry_until

CYCLE_DIR = "/tmp/spock-subcycle"
CYCLES_LOG = f"{CYCLE_DIR}/cycles.log"

# The driver's application_name, which the eventually command terminates
# before re-enabling, so a sub_disable still running cannot commit after.
DRIVER_APP = "parallel_driver_sub_cycle.py"


def record_path(sub):
    return f"{CYCLE_DIR}/{sub}.disabled"


def write_record(sub, node):
    """Atomic, so a driver killed mid-write leaves no empty record."""
    os.makedirs(CYCLE_DIR, exist_ok=True)
    tmp = record_path(sub) + ".tmp"
    with open(tmp, "w") as f:
        f.write(node)
    os.replace(tmp, record_path(sub))


def drop_record(sub):
    try:
        os.remove(record_path(sub))
    except FileNotFoundError:
        pass


def note_cycle(line):
    os.makedirs(CYCLE_DIR, exist_ok=True)
    with open(CYCLES_LOG, "a") as f:
        f.write(line + "\n")


def cycles_issued():
    try:
        with open(CYCLES_LOG) as f:
            return sum(1 for _ in f)
    except FileNotFoundError:
        return 0


def reenable_recorded(deadline):
    """Enable every subscription a driver left disabled.  Returns the
    subscriptions it could not enable."""
    failed = []
    try:
        names = [f for f in os.listdir(CYCLE_DIR) if f.endswith(".disabled")]
    except FileNotFoundError:
        return failed
    for name in names:
        sub = name[:-len(".disabled")]
        with open(f"{CYCLE_DIR}/{name}") as f:
            node = f.read().strip()
        if not node:
            drop_record(sub)
            continue

        def fn():
            with connect(node) as conn:
                conn.execute("SELECT spock.sub_enable(%s)", (sub,))

        ok, err = retry_until(deadline, f"re-enable {sub} on {node}", fn)
        if ok:
            log(f"re-enabled {sub} on {node}, left disabled by a driver")
            drop_record(sub)
        else:
            failed.append(f"{node}:{sub}")
    return failed
