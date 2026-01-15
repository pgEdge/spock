# Recovery Slot Cloning - catalog_xmin Bug Fix

## Problem

When cloning a recovery slot for disaster recovery, the `catalog_xmin` from the original recovery slot was **not being copied** to the cloned slot. This caused a critical issue:

1. **Original recovery slot** has a `catalog_xmin` that prevents WAL cleanup
2. **Cloned slot** gets a NEW `catalog_xmin` based on current transaction state
3. The new `catalog_xmin` is typically **much higher** than the original
4. WAL segments that were preserved by the original slot become **eligible for deletion**
5. **Rescue subscription fails** because the required WAL has been removed
6. Recovery procedure gets **stuck** waiting for cleanup that never happens

## Root Cause

In `src/spock_recovery.c`, the `spock_clone_recovery_slot_sql()` function was only copying:
- `confirmed_flush_lsn`
- `restart_lsn`
- `database`
- `plugin`

But it was **NOT copying** `catalog_xmin` and `effective_catalog_xmin` from the original slot.

## Solution

The fix adds code to:

1. **Read `catalog_xmin`** from the original recovery slot
2. **Copy it to the cloned slot** (both `data.catalog_xmin` and `effective_catalog_xmin`)
3. **Update global xmin calculations** using `ReplicationSlotsComputeRequiredXmin()`
4. **Use proper locking** (ProcArrayLock) to ensure thread safety

## Code Changes

### 1. Added include for procarray.h

```c
#include "storage/procarray.h"
```

### 2. Read catalog_xmin from original slot

```c
/* Read LSN positions and catalog_xmin from the original slot */
TransactionId original_catalog_xmin = InvalidTransactionId;
SpinLockAcquire(&original_slot->mutex);
confirmed_flush_lsn = original_slot->data.confirmed_flush;
restart_lsn = original_slot->data.restart_lsn;
original_catalog_xmin = original_slot->data.catalog_xmin;  // NEW
SpinLockRelease(&original_slot->mutex);
```

### 3. Copy catalog_xmin to cloned slot

```c
/*
 * CRITICAL: Copy catalog_xmin from the original recovery slot to preserve
 * WAL segments. Without this, the cloned slot gets a new catalog_xmin based
 * on current transaction state, which could be much higher, causing WAL
 * that was preserved by the original slot to become eligible for deletion.
 * This would cause the rescue subscription to fail because the required WAL
 * has been removed.
 */
if (TransactionIdIsValid(original_catalog_xmin))
{
    LWLockAcquire(ProcArrayLock, LW_EXCLUSIVE);
    SpinLockAcquire(&cloned_slot->mutex);
    cloned_slot->effective_catalog_xmin = original_catalog_xmin;
    cloned_slot->data.catalog_xmin = original_catalog_xmin;
    SpinLockRelease(&cloned_slot->mutex);
    ReplicationSlotsComputeRequiredXmin(true);
    LWLockRelease(ProcArrayLock);

    elog(LOG, "Copied catalog_xmin %u from original recovery slot to cloned slot",
         original_catalog_xmin);
}
else
{
    elog(WARNING, "Original recovery slot has invalid catalog_xmin; cloned slot will use current xmin");
}
```

## Impact

### Before Fix
- Recovery procedure gets stuck
- Rescue subscription cannot complete
- WAL required for recovery is deleted
- Recovery fails silently

### After Fix
- Cloned slot preserves original `catalog_xmin`
- WAL segments remain available for rescue subscription
- Recovery procedure completes successfully
- Rescue subscription can replay missing transactions

## Testing

To verify the fix:

1. **Create crash scenario**:
   ```bash
   python3 cluster.py --crash
   ```

2. **Run recovery**:
   ```sql
   CALL spock.recovery(
       failed_node_name := 'n1',
       source_node_name := 'n3',
       source_dsn := 'host=localhost port=5453 dbname=pgedge user=pgedge',
       target_node_name := 'n2',
       target_dsn := 'host=localhost port=5452 dbname=pgedge user=pgedge',
       verb := true
   );
   ```

3. **Verify**:
   - Recovery completes without getting stuck
   - Rescue subscription reaches cleanup_pending state
   - Both n2 and n3 have same row count (90 rows)
   - Cloned slot's catalog_xmin matches original recovery slot

## Related Files

- `src/spock_recovery.c` - Main fix location
- `samples/recovery/recovery.sql` - Recovery procedures
- `cluster.py` - Test cluster setup script

## Notes

- The original recovery slot's `catalog_xmin` is critical for preserving WAL
- This is why `autovacuum = off` is recommended during recovery testing
- The fix ensures cloned slots maintain the same WAL preservation guarantees as the original



