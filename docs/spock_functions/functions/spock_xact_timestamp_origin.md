## NAME

spock.xact_commit_timestamp_origin()

### SYNOPSIS

spock.xact_commit_timestamp_origin (xid xid, OUT timestamp timestamptz,
OUT roident oid)

### RETURNS

A record containing transaction commit information:

  - timestamp is the commit timestamp of the transaction.
  - roident is the replication origin identifier of the transaction.

### DESCRIPTION

Returns the commit timestamp and replication origin identifier for a given
transaction ID.

This function queries PostgreSQL's commit timestamp tracking system to
retrieve when a specific transaction was committed and which replication
origin it came from. The replication origin identifies the source node in a
multi-node replication topology, allowing you to trace where changes
originated.

The commit timestamp tracking feature (track_commit_timestamp) must be
enabled in PostgreSQL for this function to return meaningful results. If
commit timestamp tracking is disabled, the function may return NULL or
raise an error.

The replication origin identifier (roident) will be 0 for locally-committed
transactions that did not come through replication. For replicated
transactions, it identifies the origin node from which the changes were
received.

This is a read-only query function that does not modify any data.

Returns NULL if the xid argument is NULL.

### ARGUMENTS

xid

    The transaction ID to query.

### EXAMPLE

    SELECT * FROM spock.xact_commit_timestamp_origin('12345'::xid);
