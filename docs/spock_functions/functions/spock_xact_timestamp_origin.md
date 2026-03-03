## NAME

`spock.xact_commit_timestamp_origin()`

### SYNOPSIS

`spock.xact_commit_timestamp_origin (xid xid)`

### DESCRIPTION

Returns the commit timestamp and replication origin identifier for a given transaction ID. The `track_commit_timestamp` setting must be enabled for this function to return results. The replication origin identifier (`roident`) is 0 for locally-committed transactions.

### EXAMPLE

`SELECT * FROM spock.xact_commit_timestamp_origin('12345'::xid);`

### ARGUMENTS
    xid
        The transaction ID to query.
