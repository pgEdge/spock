# Review Comments on Code Cleanup - Remove Dead Code

The removal of unused conflict resolution functions and the lag tracking lock
represents appropriate technical debt cleanup. The deleted code relates to
legacy conflict resolution mechanisms that have been superseded by current
implementations. All removed declarations and implementations appear to have
no active callers in the codebase.

## Verification: No Active Usage Found

The removed functions from conflict resolution show no active call sites:

```c
// Removed declarations:
extern bool spock_tuple_find_replidx(ResultRelInfo *relinfo,
                                     SpockTupleData *tuple,
                                     TupleTableSlot *oldslot,
                                     Oid *idxrelid);

extern Oid spock_tuple_find_conflict(ResultRelInfo *relinfo,
                                     SpockTupleData *tuple,
                                     TupleTableSlot *oldslot);
```

These functions provided tuple lookup capabilities using replica identity
indexes and general unique indexes for conflict detection. The current
conflict resolution implementation no longer uses these interfaces, having
moved to different mechanisms. The code removal eliminates 166 lines of
unused implementation without affecting functionality.

The lag tracking lock removal from the worker context structure similarly
represents dead code elimination:

```c
// Removed from SpockContext:
LWLock *lag_lock;

// Removed initialization:
SpockCtx->lag_lock = &((GetNamedLWLockTranche("spock")[1]).lock);
```

The lag lock was allocated from the shared lock tranche but never acquired
or released anywhere in the codebase. This suggests the lag tracking feature
was either removed or replaced with a different implementation that does not
require dedicated locking.

## Recommendation: Verify Lock Tranche Allocation

The removal of lag_lock usage means one LWLock from the spock tranche is
now wasted. The current allocation requests two locks but only uses one:

```c
RequestNamedLWLockTranche("spock", 2);  // Currently requests 2 locks

SpockCtx->lock = &((GetNamedLWLockTranche("spock")[0]).lock);
// SpockCtx->lag_lock removed - lock at index [1] now unused
```

Consider reducing the tranche allocation to match actual usage or document
that the second lock slot is reserved for future use. Wasting a lock slot
in shared memory is harmless but indicates incomplete cleanup.


