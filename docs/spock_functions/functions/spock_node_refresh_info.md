## NAME

spock.node_refresh_info()

### SYNOPSIS

spock.node_refresh_info (p_node_name name DEFAULT NULL)

### RETURNS

`true` if the refresh (or, with no argument, every refresh attempted)
succeeded; `false` if one or more nodes could not be refreshed when called
with no argument. Raises an error if called with a specific `node_name`
that does not exist or that names the local node, or if refreshing that
node fails for any reason -- including an unreachable or misconfigured
interface, a dsn that now answers as a different node, or any other error
from the remote fetch.

### DESCRIPTION

Re-fetches a known peer node's `location`, `country`, and `info` (including
any `tiebreaker` key within `info`) directly from that node, and overwrites
this node's locally cached copy.

`spock.node` is a local catalog: each node populates its row for a peer
once, either when that node is created or when a subscription to it is
first created. A peer's later `location`/`country`/`info` change -- most
commonly to assign a custom `tiebreaker` and resolve an equal-tiebreaker
collision -- now propagates automatically to every node that subscribes to
that peer *directly* (see
[Automatic Node Metadata Propagation](../node_mgmt.md#automatic-node-metadata-propagation)),
with no call to this function needed. This function remains necessary for
a node that is not a direct subscriber of the peer that changed (a cascade
topology, or a subscription not currently active), and is convenient right
after `spock.sub_create` or to force a specific peer's info to be
re-fetched on demand. See the Tiebreaker section in
[conflict_types.md](../../conflict_types.md) for why this matters and why
`spock.node` is not simply replicated wholesale.

Called with a specific `node_name`, only that node's row is refreshed and
any failure refreshing it is reported as an error. Called with no
argument, every known node other than the local one is refreshed on a
best-effort basis: a node that fails to refresh for any reason logs a
`WARNING` and does not stop the others from being refreshed, and the
overall return value is `false` if any node failed.

This command must be executed by a superuser.

### ARGUMENTS

p_node_name

    Optional. The name of a single peer node to refresh. If omitted (or
    NULL), every node other than the local one is refreshed.

### EXAMPLE

After assigning a custom tiebreaker on `n1` to resolve a collision:

    n1=# UPDATE spock.node SET info = COALESCE(info, '{}'::jsonb) ||
           '{"tiebreaker": 42}' WHERE node_name = 'n1';

Refresh that on every other node:

    n2=# SELECT spock.node_refresh_info('n1');
     node_refresh_info
    --------------------
     t
    (1 row)

Or refresh everything this node knows about in one call:

    n3=# SELECT spock.node_refresh_info();
     node_refresh_info
    --------------------
     t
    (1 row)
