# Review Comments on Sync Event Machinery Improvements

## Critical Issue: Transaction Context NULL Check Removed

The reorganization of variable declarations in the output plugin removes a
defensive NULL check that prevents crashes:

```c
// Current code:
case SPOCK_SYNC_EVENT_MSG:
{
    MemoryContext oldctx;
    SpockOutputData* data = (SpockOutputData*) ctx->output_plugin_private;
    TransactionId xid = InvalidTransactionId;

    if (txn != NULL)
        xid = txn->xid;
    
    oldctx = MemoryContextSwitchTo(data->context);
    
    OutputPluginPrepareWrite(ctx, true);
    spock_write_message(ctx->out,
                        xid,           // Uses InvalidTransactionId if NULL
                        message_lsn,
                        true,
                        prefix,
                        message_size,
                        message);
}
```

The proposed change replaces the NULL check with an Assert and directly
accesses the transaction ID:

```c
// Proposed change:
case SPOCK_SYNC_EVENT_MSG:
{
    MemoryContext oldctx;
    SpockOutputData *data;

    Assert(txn != NULL);
    
    data = (SpockOutputData*) ctx->output_plugin_private;
    oldctx = MemoryContextSwitchTo(data->context);
    
    OutputPluginPrepareWrite(ctx, true);
    spock_write_message(ctx->out,
                        txn->xid,      // Direct dereference without NULL check
                        message_lsn,
                        true,
                        prefix,
                        message_size,
                        message);
}
```

This change assumes txn can never be NULL for sync event messages. The
Assert only triggers in debug builds, so production builds will crash with
a segmentation fault if txn is unexpectedly NULL. The original code handled
this case gracefully by passing InvalidTransactionId. If the protocol
guarantees txn is always valid for sync events, this should be documented.

