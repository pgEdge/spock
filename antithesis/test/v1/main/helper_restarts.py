"""Restart history of a node, read with pg_read_file() from the files that
node-entrypoint.sh and parallel_driver_graceful_restart.sh keep under
/data/state, and from the server log.
"""

from helper_spock import connect

STATE = "/data/state"

# Written by the startup process after every unclean stop: a killed
# container, a killed postmaster, or a backend crash that made the
# postmaster restart in place (that last one leaves no line in exits.log).
RECOVERY_LINE = "automatic recovery in progress"


def fields(line):
    return dict(f.split("=", 1) for f in line.split() if "=" in f)


def node_history(node):
    """Returns {'clean_exits', 'recoveries', 'graceful'}: postmaster exits
    with code 0 (pg_ctl stop or a container stop), crash recoveries and
    failed postmaster exits, and the graceful-restart driver's records as
    dicts."""
    with connect(node) as conn:
        def read(path):
            return conn.execute(
                "SELECT coalesce(pg_read_file(%s, true), '')",
                (path,)).fetchone()[0]

        exits = [fields(line) for line in
                 read(f"{STATE}/exits.log").splitlines()]
        graceful = [fields(line) for line in
                    read(f"{STATE}/graceful.log").splitlines() if line]
        # Counted on the server: the log can be large.
        recoveries = conn.execute(
            """SELECT (length(f) - length(replace(f, %s, ''))) / length(%s)
               FROM (SELECT coalesce(pg_read_file('log/postgresql.log', true),
                                     '') AS f) s""",
            (RECOVERY_LINE, RECOVERY_LINE)).fetchone()[0]
    # A non-zero postmaster exit counts too, in case the log line was lost
    # (a full disk stops the logging collector as well).
    return {
        "clean_exits": sum(1 for e in exits if e.get("exit") == "0"),
        "recoveries": recoveries + sum(1 for e in exits
                                       if e.get("exit", "0") != "0"),
        "graceful": graceful,
    }
