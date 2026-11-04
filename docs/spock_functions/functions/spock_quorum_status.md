## NAME

spock.quorum_status()

### SYNOPSIS

spock.quorum_status()

### RETURNS

One row with the columns:

  - provider (text): the quorum provider in force, as set by
    `spock.quorum_provider`.

  - has_quorum (boolean): whether this node is inside a quorum. NULL when no
    answer could be obtained.

  - is_leader (boolean): whether this node is the one that should act for the
    cluster. NULL when no answer could be obtained, and NULL whenever
    has_quorum is not true, since leadership outside a quorum is not
    something Spock would act on.

  - leader (text): the Spock node name of the leader, when known.

  - last_consulted (timestamptz): when the provider last gave a definite
    answer.

  - last_error (text): why the most recent consult failed, or NULL.

### DESCRIPTION

Takes a fresh reading from the configured quorum provider and reports it.
Nothing is cached: an operator calling this is asking about now.

With `spock.quorum_provider = 'none'` every answer column is NULL and
last_error is NULL, because nothing was attempted.

A provider that cannot be consulted never raises an error to the caller. The
function returns NULL answers and names the cause in last_error, and the
caller's transaction is left intact.

last_consulted and last_error describe the consults made from the calling
session: each backend keeps its own, and a new session starts with both NULL.

This function is restricted to superusers.

### EXAMPLE

    SELECT * FROM spock.quorum_status();
     provider | has_quorum | is_leader | leader |        last_consulted         | last_error
    ----------+------------+-----------+--------+-------------------------------+------------
     etcd     | t          | f         | n2     | 2026-10-02 09:14:03.512345+00 |
    (1 row)

See [Consulting a Quorum System](../../managing/quorum_layer.md).
