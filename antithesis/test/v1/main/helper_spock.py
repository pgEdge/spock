"""Shared helpers for the main test template.

Node nX is host ${NODE_HOST_PREFIX}nX (spock-nX in the compose).  Every
connection is short-lived and has a connect timeout, so a partitioned or
paused node costs a bounded wait, never a hang.
"""

import json
import os
import sys
import time

import psycopg

MESH = ["n1", "n2", "n3"]

# Per-timeline workload shape, drawn once by first_create_ledger.py.  /tmp in
# the workload container lasts for the whole timeline.
PARAMS_FILE = "/tmp/spock-main-params.json"

PREFIX = os.environ.get("NODE_HOST_PREFIX", "")

# Kept short: drivers run under faults and should move on to another node.
CONNECT_TIMEOUT = 5


def log(msg):
    print(f"{os.path.basename(sys.argv[0])}: {msg}", flush=True)


def load_params():
    """The timeline's workload shape, or defaults if first_ has not
    written it (for example when a command is run by hand)."""
    params = {"writer_nodes": MESH, "big_txn_weight": 0.3}
    try:
        with open(PARAMS_FILE) as f:
            params.update(json.load(f))
    except (OSError, ValueError):
        pass
    return params


def save_params(params):
    tmp = PARAMS_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump(params, f)
    os.replace(tmp, PARAMS_FILE)


def connect(node, autocommit=True, connect_timeout=CONNECT_TIMEOUT):
    return psycopg.connect(
        host=PREFIX + node,
        port=int(os.environ.get("PGPORT", "5432")),
        dbname=os.environ.get("PGDATABASE", "demo"),
        user=os.environ.get("PGUSER", "admin"),
        connect_timeout=connect_timeout,
        # A partition in the middle of a query would otherwise leave the
        # client waiting on a dead socket for the kernel's two hours.
        keepalives=1,
        keepalives_idle=5,
        keepalives_interval=2,
        keepalives_count=3,
        autocommit=autocommit,
        application_name=os.path.basename(sys.argv[0]),
    )


def retry_until(deadline, what, fn):
    """Call fn() until it returns without a database error or the
    time.monotonic() deadline passes.  Returns (ok, value_or_last_error)."""
    last = None
    while True:
        try:
            return True, fn()
        except psycopg.Error as e:
            last = e
            log(f"{what}: {e.__class__.__name__}: {str(e).strip()}")
        if time.monotonic() >= deadline:
            return False, last
        time.sleep(1)


# The ledger is insert-only and keyed by (origin, seq), so rows from
# different nodes never conflict.  seq comes from a sequence local to each
# node (sequences are not replicated).
LEDGER_DDL = [
    "CREATE SEQUENCE IF NOT EXISTS ledger_seq",
    """CREATE TABLE IF NOT EXISTS ledger (
        origin  text   NOT NULL,
        seq     bigint NOT NULL,
        txn_tag text   NOT NULL,
        payload text   NOT NULL,
        PRIMARY KEY (origin, seq))""",
]


def ensure_ledger(node):
    """Create the ledger on one node and add it to the default replication
    set.  DDL replication is off, so every mesh node needs this."""
    with connect(node) as conn:
        for stmt in LEDGER_DDL:
            conn.execute(stmt)
        in_set = conn.execute(
            """SELECT count(*) FROM spock.replication_set_table rt
               JOIN spock.replication_set rs USING (set_id)
               WHERE rs.set_name = 'default'
                 AND rt.set_reloid = 'ledger'::regclass""").fetchone()[0]
        if in_set == 0:
            conn.execute("SELECT spock.repset_add_table('default', 'ledger')")
