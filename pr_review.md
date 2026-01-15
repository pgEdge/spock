# Review Comments on Multi-Protocol Support Implementation

The protocol negotiation logic successfully establishes version compatibility
between publisher and subscriber nodes. The approach of using the minimum of
server and client protocol versions provides proper backward compatibility
during rolling upgrades. The version guard preventing protocol 4 usage on
nodes below version 5.0.0 prevents protocol mismatch issues.

## Critical Issue: Duplicate LSN in Commit Messages

A critical issue exists in the commit message writing path. The protocol 5
conditional correctly prepends the remote insert LSN at the beginning, but
an unconditional write operation immediately follows:

```c
void
spock_write_commit(StringInfo out, SpockOutputData *data,
                   ReorderBufferTXN *txn, XLogRecPtr commit_lsn)
{
    uint8 flags = 0;
    XLogRecPtr remote_insert_lsn = GetXLogWriteRecPtr();

    /* Protocol version 5+ includes remote_insert_lsn at the beginning */
    if (spock_get_proto_version() >= 5)
        pq_sendint64(out, remote_insert_lsn);

    pq_sendint64(out, GetXLogWriteRecPtr());  // <-- DUPLICATE: Remove this line
    pq_sendbyte(out, 'C');
    
    // ... rest of function
    
    /* Protocol version 4 includes remote_insert_lsn at the end */
    if (spock_get_proto_version() == 4)
        pq_sendint64(out, remote_insert_lsn);
}
```

This results in duplicate LSN values being sent for protocol 5 connections.
The unconditional write should be removed as it was needed only for the
legacy protocol 4 format where the LSN appears at the message end.

## Concurrency Issue: Static Protocol Version Variables

The static variable approach for tracking negotiated protocol versions
introduces a concurrency hazard:

```c
static uint32 spock_negotiated_proto_version = SPOCK_PROTO_VERSION_NUM;
static uint32 spock_apply_proto_version = SPOCK_PROTO_MIN_VERSION_NUM;

void
spock_set_proto_version(uint32 version)
{
    spock_negotiated_proto_version = version;  // <-- RACE CONDITION
}
```

Multiple logical replication slots operating simultaneously with different
protocol versions will overwrite each other's state. The protocol version
should be stored in the per-connection output plugin data structure:

```c
// Recommended approach:
typedef struct SpockOutputData
{
    // ... existing fields ...
    uint32 negotiated_proto_version;  // <-- Already added, use this!
} SpockOutputData;

// Then pass 'data' parameter to functions instead of using globals:
uint32 spock_get_proto_version(SpockOutputData *data)
{
    return data->negotiated_proto_version;
}
```

This ensures each replication stream maintains its own negotiated protocol
version independently.

## Documentation: Function Header Comment

The commit reading function correctly handles the protocol difference where
version 4 reads the remote insert LSN from the message end while version 5
obtains it from the message prefix:

```c
void
spock_read_commit(StringInfo in,
                  XLogRecPtr *commit_lsn,
                  XLogRecPtr *end_lsn,
                  TimestampTz *committime,
                  XLogRecPtr *remote_insert_lsn)
{
    // ... read commit data ...
    
    /*
     * Protocol version 4 includes remote_insert_lsn at the end of COMMIT
     * messages. Protocol version 5+ includes it at the beginning of ALL
     * messages (handled in apply_work).
     * 
     * CALLERS: Must check (*remote_insert_lsn != InvalidXLogRecPtr)  <-- ADD THIS
     *          before using the returned value.
     */
    if (spock_apply_get_proto_version() == 4)
        *remote_insert_lsn = pq_getmsgint64(in);
    else
        *remote_insert_lsn = InvalidXLogRecPtr;
}
```

The caller responsibility for checking the invalid LSN sentinel value is
mentioned in code comments but should be emphasized in the function header
documentation to prevent misuse.

## Test Updates

The regression test updates appropriately adjust protocol version parameters
from 3-4 to 4-5 ranges, reflecting the new minimum supported version:

```sql
-- Before:
'min_proto_version', '3',
'max_proto_version', '4',

-- After:
'min_proto_version', '4',  -- Correct: matches SPOCK_PROTO_MIN_VERSION_NUM
'max_proto_version', '5',  -- Correct: matches SPOCK_PROTO_VERSION_NUM
```

These changes ensure tests validate the new protocol negotiation behavior
correctly.

