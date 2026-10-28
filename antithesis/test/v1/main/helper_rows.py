"""Compare a table across the mesh nodes as one md5 per row over all its
columns, sorted by key."""

from helper_spock import MESH


def row_hashes(conn, table, key):
    """The table as a sorted list of (key columns..., md5 of the row).  table
    and key are SQL fragments from the workload, never user input."""
    return conn.execute(
        f"SELECT {key}, md5(t::text) FROM {table} t ORDER BY {key}"
    ).fetchall()


def diff_rows(rows_by_node, sample_size):
    """rows_by_node maps each mesh node to row_hashes() output.  Returns the
    keys whose hash differs or is missing on some node, and up to
    sample_size of them with each node's hash."""
    if all(rows_by_node[n] == rows_by_node[MESH[0]] for n in MESH[1:]):
        return [], []
    hashes = {n: {tuple(r[:-1]): r[-1] for r in rows}
              for n, rows in rows_by_node.items()}
    keys = sorted(set().union(*hashes.values()))
    differing = [k for k in keys
                 if len({hashes[n].get(k) for n in MESH}) > 1]
    sample = [{"key": list(k),
               **{n: hashes[n].get(k, "missing") for n in MESH}}
              for k in differing[:sample_size]]
    return differing, sample
