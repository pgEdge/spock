# Spock Recovery Slot System - Deep Analysis

## Overview

This document provides a comprehensive analysis of the Spock recovery slot system for catastrophic node failure recovery, including the cluster setup script (`cluster.py`), recovery procedures (`recovery.sql`), and the underlying recovery slot mechanism.

---

## 1. Recovery Slot System Architecture

### 1.1 Core Concept

**Recovery Slots** are inactive logical replication slots that preserve WAL (Write-Ahead Log) segments for catastrophic failure recovery. They are a critical component of Spock's disaster recovery mechanism.

### 1.2 Key Design Principles

- **One slot per database** (not per subscription or peer node)
- **Inactive** - never used for normal replication
- **Shared across all subscriptions** in the database
- **Automatic creation** by manager worker at database initialization
- **Preserves WAL** for all peer transactions
- **Enables recovery** without cluster rebuild

### 1.3 Slot Naming Convention

```
spk_recovery_{database_name}
```

Example: For database `pgedge`, the recovery slot is named `spk_recovery_pgedge`

### 1.4 Implementation Details

#### Shared Memory Structure

Located in `include/spock_recovery.h` and `src/spock_recovery.c`:

```c
typedef struct SpockRecoverySlotData {
    char        slot_name[NAMEDATALEN];      // Name of the recovery slot
    XLogRecPtr  restart_lsn;                  // Earliest LSN needed for recovery
    XLogRecPtr  confirmed_flush_lsn;         // Latest flushed LSN
    TimestampTz min_unacknowledged_ts;       // Oldest unacknowledged transaction timestamp
    bool        active;                      // Is the slot created and active?
    bool        in_recovery;                  // Currently being used for recovery?
    pg_atomic_uint32 recovery_generation;     // Generation counter for slot recreation
} SpockRecoverySlotData;
```

#### Key Functions

1. **`create_recovery_slot(database_name)`** - Creates the recovery slot
2. **`drop_recovery_slot()`** - Drops the recovery slot
3. **`advance_recovery_slot_to_min_position()`** - Advances slot to minimum position across all subscriptions
4. **`update_recovery_slot_progress()`** - Updates progress tracking
5. **`spock_clone_recovery_slot_sql()`** - Clones recovery slot for disaster recovery

#### Slot Lifecycle

1. **Creation**: Manager worker creates slot automatically when database initializes (if `spock.enable_recovery_slots = on`)
2. **Maintenance**: Slot position is advanced to minimum position across all peer subscriptions
3. **Recovery**: Slot is cloned to create a temporary active slot for rescue subscription
4. **Cleanup**: Cloned slot is dropped after recovery completes

---

## 2. Cluster Setup Script (`cluster.py`)

### 2.1 Purpose

`cluster.py` creates a three-node PostgreSQL cluster (n1, n2, n3) with Spock replication configured for testing catastrophic node failure scenarios.

### 2.2 Cluster Architecture

```
    n1 (origin)
    |
    | (replicates to both)
    |
    +----+----+
    |         |
    v         v
   n2        n3
```

**Replication Setup:**
- n1 → n2: Subscription `sub_n1_n2`
- n1 → n3: Subscription `sub_n1_n3`
- n2 → n3: Subscription `sub_n2_n3`
- n3 → n2: Subscription `sub_n3_n2`

### 2.3 Crash Scenario (`--crash` flag)

The `--crash` option creates a specific failure scenario:

#### Step-by-Step Process:

1. **Initial Setup**:
   - Creates `crash_test` table on all nodes
   - Adds table to default replication set
   - Ensures all subscriptions are enabled

2. **Initial Data Load** (20 rows):
   - Inserts 20 rows on n1
   - Both n2 and n3 receive all 20 rows
   - Verifies replication: `n2 = 20 rows, n3 = 20 rows`

3. **Create Lag**:
   - **Suspends subscription from n1 to n2** (n1→n2 disabled)
   - Keeps n1→n3 active
   - Keeps n3→n2 active (bidirectional replication)

4. **Additional Data Load** (70 rows):
   - Inserts 70 more rows on n1
   - **Only n3 receives** these rows (n2's subscription from n1 is suspended)
   - Result: `n2 = 20 rows, n3 = 90 rows`

5. **Crash n1**:
   - Terminates n1 process
   - n2 and n3 remain healthy
   - Final state:
     - **n2**: 20 rows (behind, needs recovery)
     - **n3**: 90 rows (ahead, source for recovery)

### 2.4 Crash2 Scenario (`--crash2` flag)

Similar to `--crash`, but additionally:
- After crashing n1, **suspends all subscriptions on n2 and n3** (except `sub_n2_n3`)
- This **freezes XID advancement** for recovery testing
- Prevents catalog_xmin advancement that could invalidate recovery slots

### 2.5 Key Configuration

The script configures PostgreSQL with:
- `wal_level = logical` (required for logical replication)
- `track_commit_timestamp = on` (required for origin tracking)
- `autovacuum = off` (critical for recovery - keeps recovery slot's catalog_xmin valid)
- Spock-specific settings for DDL replication
- Network settings for replication

---

## 3. Recovery Procedures (`recovery.sql`)

### 3.1 Overview

`recovery.sql` provides SQL procedures to orchestrate catastrophic node failure recovery using recovery slots. The recovery process involves:

1. **Precheck** - Validates prerequisites
2. **Clone Slot** - Clones recovery slot on source node
3. **Create Rescue Subscription** - Creates temporary subscription on target
4. **Wait for Completion** - Monitors rescue subscription
5. **Finalize** - Cleans up and resumes normal replication

### 3.2 Main Procedures

#### 3.2.1 `spock.recover_precheck()`

**Purpose**: Validates connectivity, Spock versions, recovery slot availability, and absence of existing rescue subscriptions.

**Key Validations**:
- Source and target nodes are reachable
- Spock extension installed on both nodes
- Spock versions match
- Source node has active recovery slot
- Target node has no existing rescue subscriptions
- Target node has subscriptions from failed node (recovery needed)
- Compares lag_tracker LSNs to determine if recovery is needed

**Output**: `recovery_needed` boolean

#### 3.2.2 `spock.recover_phase_clone()`

**Purpose**: Clones the recovery slot on source node, suspends peer subscriptions on target, and creates a temporary rescue subscription.

**Process**:
1. Calls `spock.clone_recovery_slot()` on source node
   - Creates a temporary active slot from the inactive recovery slot
   - Returns cloned slot name and restart LSN
2. Determines skip LSN (target's current position) and stop LSN (source's position)
3. Suspends all peer subscriptions on target node (except rescue subscription)
4. Creates rescue subscription on target node using cloned slot
   - Uses `spock.create_rescue_subscription()` function
   - Sets `rescue_temporary = true`
   - Configures skip_lsn and stop_lsn

**Output**: `cloned_slot_name` (for later cleanup)

#### 3.2.3 `spock.recover_run()`

**Purpose**: Orchestrates the complete recovery process automatically.

**Process**:
1. Calls `recover_precheck()` - validates prerequisites
2. Calls `recover_phase_clone()` - clones slot and creates rescue subscription
3. Waits for rescue subscription to complete (monitors `sub_rescue_cleanup_pending`)
4. Calls `recover_finalize()` - cleans up and resumes normal replication

**Usage**:
```sql
CALL spock.recover_run(
    failed_node_name := 'n1',
    source_node_name := 'n3',  -- Node with most complete data
    source_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>',
    target_node_name := 'n2',  -- Node that needs recovery
    target_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
    stop_lsn         := NULL,  -- Optional: specific LSN to stop at
    skip_lsn         := NULL,  -- Optional: LSN to skip to
    stop_timestamp   := NULL,  -- Optional: timestamp to stop at
    verb             := true
);
```

#### 3.2.4 `spock.recover_finalize()`

**Purpose**: Finalizes recovery by resuming peer subscriptions and dropping cloned slot.

**Process**:
1. Resumes all peer subscriptions on target node
2. Drops cloned recovery slot on source node
3. Verifies recovery completion

**Usage**:
```sql
CALL spock.recover_finalize(
    target_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
    target_node_name := 'n2',
    failed_node_name := 'n1',
    source_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>',
    cloned_slot_name := '<slot name from recover_run>',
    verb             := true
);
```

### 3.3 Recovery Flow Example

**Scenario**: n1 crashed, n2 has 20 rows, n3 has 90 rows

1. **Detection**: Run `spock.recover_precheck()` to identify n3 as source (ahead) and n2 as target (behind)

2. **Recovery**: Run `spock.recover_run()`:
   - Clones recovery slot on n3: `spk_recovery_pgedge` → `spk_recovery_pgedge_clone_<timestamp>`
   - Suspends peer subscriptions on n2 (from n1)
   - Creates rescue subscription on n2 that streams from cloned slot
   - Rescue subscription replays WAL from n3 to n2 until catch-up

3. **Monitoring**: Check `spock.subscription` for `sub_rescue_cleanup_pending = true`

4. **Finalization**: `spock.recover_finalize()` automatically called by `recover_run()`

5. **Result**: n2 now has 90 rows, matching n3

---

## 4. Recovery Slot Cloning

### 4.1 Purpose

When a node fails, the recovery slot on a healthy peer node is cloned to create a temporary active slot. This cloned slot is used by a rescue subscription to stream WAL data to the lagging node.

### 4.2 Cloning Process

**Function**: `spock.clone_recovery_slot()`

**Process**:
1. Validates recovery slot exists and is active
2. Gets original slot's restart_lsn and confirmed_flush_lsn
3. Creates new temporary slot with name: `{original_slot_name}_clone_{timestamp}`
4. Sets cloned slot's restart_lsn to original slot's restart_lsn
5. Marks cloned slot as active (temporary)
6. Returns cloned slot name and metadata

**Key Points**:
- Original recovery slot remains inactive
- Cloned slot is temporary and must be dropped after recovery
- Cloned slot preserves WAL from the original recovery slot's restart_lsn

### 4.3 Rescue Subscription

A rescue subscription is a temporary subscription with:
- `rescue_temporary = true` - Marks it as temporary
- `rescue_suspended = false` - Not suspended
- `rescue_stop_lsn` - Target LSN to stop replay at
- `rescue_cleanup_pending = false` initially, set to `true` when ready for cleanup

The rescue subscription:
- Streams from the cloned recovery slot
- Replays WAL from skip_lsn to stop_lsn
- Automatically sets `rescue_cleanup_pending = true` when complete
- Is automatically dropped by manager worker when cleanup_pending is true

---

## 5. Data Flow in Recovery

### 5.1 Normal Replication (Before Crash)

```
n1 (origin)
  ├─→ n2 (20 rows received)
  └─→ n3 (90 rows received)
```

### 5.2 After Crash

```
n1 (CRASHED)
  ├─→ n2 (20 rows, behind)
  └─→ n3 (90 rows, ahead)
```

### 5.3 Recovery Process

```
n3 (source, has recovery slot)
  │
  │ Clone recovery slot → spk_recovery_pgedge_clone_<ts>
  │
  │ Create rescue subscription on n2
  │
  v
n2 (target, receives missing data via rescue subscription)
  │
  └─→ Streams WAL from cloned slot
      Replays missing transactions (70 rows)
      Result: n2 now has 90 rows
```

### 5.4 After Recovery

```
n2 (recovered, 90 rows)
n3 (source, 90 rows)
```

Both nodes are now synchronized.

---

## 6. Key Files and Locations

### 6.1 Core Implementation

- **`include/spock_recovery.h`** - Header file with recovery slot data structures
- **`src/spock_recovery.c`** - C implementation of recovery slot functions
- **`src/spock_manager.c`** - Manager worker that creates and maintains recovery slots
- **`src/spock_functions.c`** - SQL-callable wrapper functions

### 6.2 SQL Procedures

- **`samples/recovery/recovery.sql`** - Recovery procedures (precheck, clone, finalize)
- **`sql/spock--6.0.0-devel.sql`** - SQL function definitions for recovery slots

### 6.3 Testing and Setup

- **`cluster.py`** - Three-node cluster setup script
- **`samples/recovery/cluster.py`** - Alternative cluster setup (if exists)
- **`tests/tap/t/009_recovery_slots.pl`** - TAP tests for recovery slots

### 6.4 Documentation

- **`docs/catastrophic_node_failure.md`** - User-facing documentation

---

## 7. Important Considerations

### 7.1 Recovery Slot Maintenance

- Recovery slots must be **advanced regularly** to prevent WAL accumulation
- Manager worker calls `advance_recovery_slot_to_min_position()` periodically
- Slot position is set to minimum position across all peer subscriptions

### 7.2 Catalog XMIN

- **Critical**: `autovacuum = off` is recommended during recovery testing
- Recovery slots have a `catalog_xmin` that prevents WAL cleanup
- If catalog_xmin advances too far, recovery may fail (WAL already removed)

### 7.3 LSN Tracking

- `spock.lag_tracker` tracks commit LSNs for each origin→receiver pair
- Used to determine which node is ahead/behind
- Used to determine skip_lsn and stop_lsn for rescue subscription

### 7.4 Rescue Subscription Lifecycle

1. Created with `rescue_temporary = true`
2. Manager worker monitors for completion
3. When `rescue_stop_lsn` reached, sets `rescue_cleanup_pending = true`
4. Manager worker drops subscription when cleanup_pending is true
5. Cloned slot must be manually dropped (via `recover_finalize()`)

---

## 8. Usage Example

### 8.1 Setup Cluster with Crash Scenario

```bash
python3 cluster.py --crash
```

This creates:
- n1, n2, n3 cluster
- n1 crashes after creating lag (n2=20 rows, n3=90 rows)

### 8.2 Run Recovery

```sql
-- Connect to any node (coordinator)
\c pgedge

-- Run recovery (automated)
CALL spock.recover_run(
    failed_node_name := 'n1',
    source_node_name := 'n3',
    source_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>',
    target_node_name := 'n2',
    target_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
    stop_lsn         := NULL,
    skip_lsn         := NULL,
    stop_timestamp   := NULL,
    verb             := true
);
```

### 8.3 Verify Recovery

```sql
-- Check row counts
SELECT 'n2' as node, COUNT(*) FROM dblink('host=localhost port=5452 dbname=pgedge', 'SELECT COUNT(*) FROM crash_test') AS t(cnt int);
SELECT 'n3' as node, COUNT(*) FROM dblink('host=localhost port=5453 dbname=pgedge', 'SELECT COUNT(*) FROM crash_test') AS t(cnt int);

-- Both should show 90 rows
```

---

## 9. Summary

The recovery slot system provides a robust mechanism for recovering from catastrophic node failures:

1. **Recovery slots** preserve WAL for all peer transactions
2. **Cloning** creates temporary active slots for rescue
3. **Rescue subscriptions** stream missing data to lagging nodes
4. **Automated procedures** orchestrate the entire recovery process
5. **Cluster script** creates test scenarios for validation

The system enables recovery without cluster rebuild, preserving data integrity and minimizing downtime.



