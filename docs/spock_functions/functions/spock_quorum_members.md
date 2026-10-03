## NAME

spock.quorum_members()

### SYNOPSIS

spock.quorum_members()

### RETURNS

One row per member, with the columns:

  - member_name (text): the Spock node name.

  - live (boolean): whether the quorum system considers the member
    reachable.

  - voting (boolean): whether the member counts toward a majority.

  - last_seen (timestamptz): when the quorum system last heard from the
    member, or NULL when it does not track that.

### DESCRIPTION

Takes a fresh reading from the configured quorum provider and lists the
members this node would act on: the provider's view of the cluster,
restricted to nodes present in `spock.node`. A member the quorum system knows
but Spock does not is left out, and a node dropped with `spock.node_drop()`
disappears from this list at once, even while the quorum system still lists
it.

The result is empty when this node is not inside a quorum, because a node
outside a quorum has no trustworthy opinion about who else is alive, and
empty with `spock.quorum_provider = 'none'`.

This function is restricted to superusers.

### EXAMPLE

    SELECT * FROM spock.quorum_members();
     member_name | live | voting |           last_seen
    -------------+------+--------+-------------------------------
     n1          | t    | t      | 2026-10-02 09:14:03.498211+00
     n2          | t    | t      | 2026-10-02 09:14:03.501730+00
     n3          | f    | t      | 2026-10-02 09:11:40.077402+00
    (3 rows)

See [Consulting a Quorum System](../../managing/quorum_layer.md).
