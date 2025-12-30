# Implement delta_apply conflict resolution
Spock extension. Commit ddfd95b, branch 'main'.

## GOAL
Remove core patch 'pgXX-030-per-subtrans-commit-ts.diff'

## Tasks

* Analyse current delta_apply logic. Identify any current issues and corner cases of behaviour.
* Re-implement the same feature using tools available for a Postgres extension module.

## How it works right now (an analysis)

This feature is a part of the delta_apply feature which helps to fix conflict resolution on delta_apply column(s).

### Conflict resolution
Function spock_apply_heap.c::spock_handle_conflict_and_apply() detects a conflict between incoming remote tuple and a local one.
Spock finds the local tuple using an IDENTITY - that means the identity fields in the old version of the remote tuple and the local tuple remain the same.
Hopefully, we don't see any columns of the old tuple which weren't changed on remote server (except delta_apply columns). So, we are a little 'blind' about a potential situation when old version of updated tuple has differences with this local one. _XXX1_: Can it potentially happen?
Function `try_resolve_conflict()` resolves the conflict and reports the decision: 'apply'. Now, conflict resolution is based on simple 'last update wins' where the `conflict_resolve_by_timestamp()` routine decides which tuple should stay based on the commit timestamp which introduced/updated this tuple.
For the delta_apply columns this resolution doesn't draw any real consequences. Based on the resolution decision delta_apply chooses base 'current' tuple (remote or local). Function `build_delta_tuple()` creates 'delta' values which are consequently applied to the base tuple. This final version is committed to the table.
_XXX2_: It seems that if delta_apply decides to use remote tuple it still calculates delta values, modifies incoming remote tuple and applies this change. Why is it necessary?

## Play around with case XXX1:

**Setup:** Three instances N1, N2, N3 with active-active logical replication. Timestamps (TS) are sequential numbers that increment monotonically. Clocks are ideally synchronized. Table: `test(X integer PRIMARY KEY, Y integer, Z integer)` where Z is a delta_apply column. Initial state: `(X,Y,Z) = (10,20,30), TS = 0`.

**Scenario:**
1. Node N2 updates: `(10,20,30) => (10,21,31), TS = 1` (Y+1, Z+1)
2. Node N1 receives N2's update, applies it: `(10,21,31), TS = 1`
3. Node N1 immediately makes its own update: `(10,21,31) => (10,22,32), TS = 2` (Y+1, Z+1)
4. Node N3 receives both updates but in uncertain order

**Issue:** When N3 receives N1's update, N1's oldtup shows `(10,20,30)` but N3 might already have `(10,21,31)` from N2.

**Analysis:**
- N1's remote oldtup is `(10,20,30)` but local tuple on N3 is `(10,21,31)`
- For non-delta columns (Y), this is fine - timestamp conflict resolution handles it
- For delta column Z, if we calculate `delta = (32 - 30) + 31 = 33` instead of the correct `(32 - 31) + 31 = 32`
- However, we don't send old values for non-delta columns (line 19: "we don't see any columns of the old tuple which weren't changed on remote server except delta_apply columns")
- So the mismatch only matters for delta_apply columns

**Claude's Conclusion:** This can happen but might not cause issues if the NULL signaling approach is used - when Z wasn't changed on the remote UPDATE, we'd send NULL for old/new Z values, avoiding the stale oldtup problem.

## Play around with case XXX2:

Looking at the code in [spock_apply_heap.c:650-652](src/spock_apply_heap.c#L650-L652), the delta calculation is:
```c
result = OidFunctionCall3Coll(delta_apply_function,
                              InvalidOid, oldtup->values[col],
                              newtup->values[col], loc_value);
```

This computes: `delta = (newtup[col] - oldtup[col]) + loc_value`

The key insight is that `build_delta_tuple()` **always uses `localslot`** as the base for delta calculation (line 647-648), regardless of which tuple won the conflict resolution.

**Why this is necessary:**

Consider the same three-node setup (N1, N2, N3) with table `test(X integer PRIMARY KEY, Y integer, Z integer)` where Z is a delta_apply column. Initial state: `(X,Y,Z) = (10,20,100), TS = 0`.

**Scenario:**
1. Node N2 updates: `(10,20,100) => (10,21,105), TS = 1` (Z increased by 5)
2. Node N1 independently updates: `(10,20,100) => (10,22,103), TS = 2` (Z increased by 3)
3. Node N3 receives N2's update first, applies it: `(10,21,105)`
4. Node N3 then receives N1's update

**At step 4, conflict resolution on N3:**
- Local tuple: `(10,21,105), TS = 1`
- Remote tuple (from N1): `(10,22,103), TS = 2`
- Remote old tuple: `(10,20,100), TS = 0`

Conflict resolution sees `TS = 2 > TS = 1`, so remote tuple wins for non-delta columns (Y becomes 22).

**For delta_apply column Z, if we just used the remote value:**
- We would get Z = 103, losing N2's contribution of +5

**With delta calculation:**
- Delta from N1: `103 - 100 = +3`
- Applied to local Z: `105 + 3 = 108`
- Final tuple: `(10,22,108)`

This correctly preserves both N2's increment (+5) and N1's increment (+3).

**Claude's Answer: YES, this behavior is necessary.** Even when the remote tuple wins the timestamp-based conflict resolution for regular columns, we must calculate and apply the delta for delta_apply columns using the local value as the base. Otherwise, we would lose concurrent modifications to delta_apply columns from other nodes.

### Could we use NULL to signal "unchanged" delta_apply columns?

**Proposal:** If a delta_apply column wasn't changed remotely, send NULL in both oldtup and newtup for that column. This could signal "keep the local value unchanged."

**Analysis with NOT NULL constraint assumption:**

Since delta_apply columns **always have NOT NULL constraint**, using NULL becomes an out-of-band signal that cannot conflict with legitimate data values.

**Simple two-state approach:**

1. **Both old and new are NULL:**
   - Signal: "This delta_apply column was NOT modified remotely"
   - Action: Keep local value unchanged (`deltatup->changed[col] = false`)
   - This avoids unnecessary delta calculation when the column wasn't touched

2. **Neither old nor new is NULL (normal case):**
   - Signal: "Column was modified remotely"
   - Action: Calculate delta `(new - old) + local`

**Benefits:**
- **No semantic conflict**: NOT NULL constraint guarantees NULL never appears in actual data
- **Explicit signaling**: Clear distinction between "unchanged" vs "changed"
- **Optimization**: Skip delta calculation for unchanged columns
- **Helps with XXX1 issue**: If a delta_apply column wasn't modified remotely, we don't care about version mismatches in oldtup for that column
- **Simpler logic**: Only two cases to handle instead of complex delta calculation for every column

**Implementation:**
```c
if (oldtup->nulls[remoteattnum] && newtup->nulls[remoteattnum])
{
    /* Both NULL means column wasn't changed remotely, keep local value */
    deltatup->changed[remoteattnum] = false;
}
else
{
    /* Column was modified remotely: calculate delta */
    loc_value = heap_getattr(TTS_TUP(localslot), remoteattnum + 1, tupdesc, &loc_isnull);
    result = OidFunctionCall3Coll(rel->delta_apply_functions[remoteattnum],
                                  InvalidOid, oldtup->values[remoteattnum],
                                  newtup->values[remoteattnum], loc_value);
    deltatup->values[remoteattnum] = result;
    deltatup->nulls[remoteattnum] = false;
    deltatup->changed[remoteattnum] = true;
}
```

**Claude's Answer: YES, using NULL as "unchanged" signal is viable and beneficial** given the NOT NULL constraint. This provides clearer semantics, optimizations, and helps mitigate the XXX1 versioning issue.

### What about subtransaction commit timestamp change?

Remember, we are inside a transaction already. If 'is_delta_apply' is true that means we need to commit only delta_apply changes over local tuple. In this case Spock updates the tuple inside a subtransaction. Otherwise we just need to apply remote tuple (with possible delta_apply changes) inside current transaction. _XXX3_: why do we need this trick with subtransaction?

**Claude's Answer to XXX3: Preserving correct commit timestamp and origin for delta_apply updates**

Looking at the code ([spock_apply_heap.c:830-846](src/spock_apply_heap.c#L830-L846)) and the patch comments (pg18-030-per-subtrans-commit-ts.diff:218-222), the subtransaction is needed to give the updated row **its own xmin (transaction ID)** with a different commit timestamp than the main replication transaction.

**The core issue - per-row commit timestamps:**

In PostgreSQL, commit timestamps are tracked **per transaction ID (XID)**, not per row. When you query a tuple's commit timestamp, you look up the timestamp for that tuple's `xmin` (the XID that created/modified it).

**The problem without subtransaction:**
- The entire replication apply runs in a single transaction with XID = T_remote
- All rows modified in this transaction would get the same `xmin = T_remote`
- When we commit, `TransactionTreeSetCommitTsData()` sets ONE commit timestamp for T_remote
- All rows modified would share this single commit timestamp (the remote origin's timestamp)
- We cannot have different commit timestamps for different rows within the same transaction

**Why we need a subtransaction:**
When `is_delta_apply=true`:
1. The local tuple won conflict resolution (TS = 2) but we need to update delta columns
2. We want this updated row to **retain the local tuple's original timestamp** (TS = 2, origin = N1)
3. But we're inside a transaction that will get the remote timestamp/origin
4. **Solution:** Create a subtransaction which gets its own XID (T_sub)
5. The UPDATE in the subtransaction gives the row `xmin = T_sub`
6. Call `SubTransactionIdSetCommitTsData(T_sub, local_ts, local_origin)` to override T_sub's commit timestamp
7. Now this one row has a different XID with a different commit timestamp than other rows in the transaction

**Example scenario:**
- Local tuple: `(X,Y,Z) = (10,22,105), xmin = T1, TS = 2, origin = N1`
- Remote tuple: `(X,Y,Z) = (10,21,103), TS = 1, origin = N2`
- Replication transaction: XID = T_remote, will get TS = current, origin = N2

Without subtransaction:
- UPDATE would set `xmin = T_remote`
- Row gets TS = current, origin = N2 ❌ (wrong!)

With subtransaction:
- Subtransaction gets XID = T_sub
- UPDATE sets `xmin = T_sub`
- Override: T_sub gets TS = 2, origin = N1 ✓ (preserves local winner's timestamp)

**Why can't we just override the main transaction's timestamp?**

Because the main transaction might update MULTIPLE rows with different conflict resolutions:
- Row A: remote wins → should get remote timestamp
- Row B: delta_apply (local wins) → should get local timestamp
- Row C: remote wins → should get remote timestamp

We cannot set one timestamp for the entire transaction. Each delta_apply row needs its own XID to have its own independent commit timestamp.

This is the core feature that the patch `pgXX-030-per-subtrans-commit-ts.diff` implements: allowing per-subtransaction (i.e., per-XID) commit timestamp overrides.

## Invent the way to do the same without core patch

What we actually need is to correct subtransaction TS and origin_id, isn't it?
_XXX4_: For me, the main question here: what if the current transaction later changes the same tuple again? Can we find a solution which will correctly survive that?

So, let's make up a solution. After the `ReleaseCurrentSubTransaction()` call we can get the XID of the subtransaction (does `GetCurrentFullTransactionIdIfAny()` serve us here?) and store (XID, TS, origin): write it into the WAL (pre-commit-wal) using custom RMGR and write to a memory cache.
Employ `RegisterXactCallback(spock_commit_callback)`. Process XACT_EVENT_ABORT and XACT_EVENT_COMMIT. At this stage all commit_ts SLRU changes are already made by the call `RecordTransactionCommit()` -> `TransactionTreeSetCommitTsData()`. Am I wrong?
So, we can fix the commit_ts-related SLRU record for our subtransaction and write one more WAL record (post-commit-wal) with the fact of which records have been changed and which have not (we need to process in this callback the case of subtransaction ABORT to remove the specific proposed change). _XXX5_: need to explain this statement with more details.

SLRU may be overwritten on recovery. What is our strategy here? Just read changes into the memory on redo of a pre-commit-wal and fix SLRU on redo of the post-commit-wal. _XXX6_: Should it work?

**Claude's Revised Analysis:**

After reviewing your proposed solution (lines 190-194), I now see a viable approach! Your idea is to **directly modify the commit_ts SLRU after the fact** using custom RMGR and transaction callbacks. This is much more promising than my earlier suggestions.

**Your proposed approach (analyzed):**

1. **During subtransaction:** After `ReleaseCurrentSubTransaction()`, capture the subtransaction's XID and record `(XID, local_ts, local_origin)` in memory
2. **Write pre-commit WAL:** Use custom RMGR to write this override data to WAL before commit
3. **In commit callback:** Use `RegisterXactCallback()` to get control at `XACT_EVENT_COMMIT` time
4. **Modify SLRU directly:** At this point, `TransactionTreeSetCommitTsData()` has already written the parent transaction's timestamp, so we directly overwrite the SLRU entry for our subtransaction XID
5. **Write post-commit WAL:** Record which SLRU pages were modified for recovery
6. **Recovery:** On redo, replay pre-commit WAL (load overrides into memory), then on post-commit WAL redo, apply the SLRU modifications

**Why this could work:**

Unlike my earlier approaches, this doesn't try to work around commit_ts - it **directly fixes the commit_ts SLRU** after PostgreSQL has written it. This is conceptually similar to what the core patch does, but done at a different point in the transaction lifecycle.

**Potential challenges and questions:**

**1. XXX4 - Multiple updates to same tuple:**
If the main transaction later updates the same tuple again (after the delta_apply subtransaction), we'd have:
- Subtransaction T_sub updates row → `xmin = T_sub`
- We override T_sub's commit_ts to local_ts
- Later in same transaction, another UPDATE → `xmin = T_parent` (new version)
- The T_sub version becomes obsolete but its commit_ts override is preserved
- This should be fine - the old version keeps its correct timestamp, new version gets parent timestamp

**2. Accessing subtransaction XID:**
After `ReleaseCurrentSubTransaction()`, can we still get the subtransaction's XID? The subtransaction is released but not yet committed to the parent. Need to verify `GetCurrentTransactionId()` called before release captures the right XID.

**3. SLRU concurrency:**
Directly modifying commit_ts SLRU in the commit callback requires:
- Taking appropriate locks (CommitTsControlLock or CommitTsLock)
- Handling concurrent access to SLRU pages
- Ensuring we're modifying the correct SLRU page/slot

**4. WAL ordering (XXX5 clarification):**
The post-commit WAL record must handle:
- **If main transaction commits:** Post-commit WAL confirms the SLRU modifications are permanent
- **If main transaction aborts:** The pre-commit WAL is replayed on recovery, but then transaction aborts, so SLRU changes must be discarded
- The callback must detect abort and NOT write post-commit WAL, or write a "discard" record

**5. Recovery (XXX6):**
Your strategy seems sound:
- Pre-commit WAL redo: Load `(XID, ts, origin)` overrides into memory hash
- Post-commit WAL redo: Apply the overrides to SLRU
- If transaction aborted, pre-commit WAL is seen but no post-commit WAL, so overrides stay in memory but never applied

**6. SLRU page management:**
Need to ensure the SLRU page containing the subtransaction's entry is:
- Already allocated (it should be, since TransactionTreeSetCommitTsData ran)
- Not evicted before we modify it
- Properly flushed after modification

**Claude's assessment: This approach is VIABLE!**

Your solution is actually more elegant than my earlier suggestions because:
- ✓ Uses existing commit_ts infrastructure (just modifies SLRU)
- ✓ No extra tables or lookups needed
- ✓ Properly WAL-logged for recovery
- ✓ Works with existing conflict resolution code
- ✓ Handles XID wraparound naturally (SLRU does this already)

The main implementation challenges are:
1. Getting SLRU locking right
2. Ensuring WAL replay correctness
3. Handling abort cases
4. Testing recovery scenarios

But these are solvable engineering problems, not fundamental blockers. **This could work as an extension-only solution!**

**Summary:**

The proposed SLRU modification approach is superior to alternative extension-only approaches because it:
- Directly integrates with PostgreSQL's commit_ts infrastructure
- Requires no changes to conflict resolution logic
- Has no performance overhead during normal operation
- Properly handles crash recovery via WAL logging
- Naturally handles XID wraparound through existing SLRU mechanisms

The main engineering effort will be in correctly implementing SLRU locking, WAL replay, and abort handling - all solvable problems with no fundamental blockers.