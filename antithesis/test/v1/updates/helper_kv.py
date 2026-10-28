"""The kv table and this template's per-timeline workload shape.

kv rows are inserted on one node with a key (origin, n) that node owns, so
inserts never conflict.  Updates then rewrite val and writer on rows from
any origin, so concurrent updates of the same row on different nodes are
conflicts that last_update_wins has to settle the same way everywhere.
There are no deletes (DELETE replication currently diverges; a known
issue), and updates only touch keys already present on every mesh node:
an update that reaches a node before the row's insert is update_missing,
which Spock documents as unresolvable.
"""

import json
import os

from helper_spock import MESH, connect

# /tmp in the workload container lasts for the whole timeline.
PARAMS_FILE = "/tmp/spock-updates-params.json"

KV_DDL = [
    "CREATE SEQUENCE IF NOT EXISTS kv_seq",
    """CREATE TABLE IF NOT EXISTS kv (
        origin text   NOT NULL,
        n      bigint NOT NULL,
        val    text   NOT NULL,
        writer text   NOT NULL,
        wseq   bigint NOT NULL,
        PRIMARY KEY (origin, n))""",
]


def ensure_kv(node):
    """Create kv on one node and add it to the default replication set.
    DDL replication is off, so every mesh node needs this."""
    with connect(node) as conn:
        for stmt in KV_DDL:
            conn.execute(stmt)
        in_set = conn.execute(
            """SELECT count(*) FROM spock.replication_set_table rt
               JOIN spock.replication_set rs USING (set_id)
               WHERE rs.set_name = 'default'
                 AND rt.set_reloid = 'kv'::regclass""").fetchone()[0]
        if in_set == 0:
            conn.execute("SELECT spock.repset_add_table('default', 'kv')")


def load_params():
    """The timeline's shape, or defaults if first_ has not written it."""
    params = {"writer_nodes": MESH, "update_weight": 0.6,
              "contested_weight": 0.5, "hot_keys": 10}
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
