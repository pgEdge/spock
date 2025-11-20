# Spock Recovery Slot Tracking

## Overview

This directory contains tools for testing and demonstrating Spock's recovery slot minimum position tracking feature, which enables catastrophic node failure recovery.

## Files

- **`recovery.sql`** - SQL procedures for rescue workflow orchestration
- **`cluster.py`** - Python tool for cluster management and testing

## Quick Start

### 1. End-to-End Recovery Test

Complete test of the full recovery workflow:

```bash
# Without Docker (manual setup required)
./test_end_to_end.sh -v

# With Docker (fully automated)
./test_end_to_end.sh --docker -v
```

This test:
- Sets up a 3-node cluster
- Creates lag (n3 behind n2)
- Simulates n1 crash
- Executes recovery workflow
- Verifies n3 catches up

### 2. Test Recovery Slot Tracking

Test just the recovery slot tracking feature:

```bash
# Without Docker (local PostgreSQL)
python3 cluster.py test-recovery -v

# With Docker
python3 cluster.py test-recovery --docker -v
```

### 3. Docker Cluster Setup

Generate and run a 3-node cluster:

```bash
# Generate Docker files
python3 cluster.py generate --nodes 3 --pg-ver 18

# Start cluster
docker compose up -d

# Setup Spock cross-wiring
python3 cluster.py setup

# Test cluster
python3 cluster.py test
```

### 4. Recovery Workflow

Execute the recovery workflow using `recovery.sql`:

```sql
-- On a coordinator node with dblink
CALL spock.recovery(
    failed_node_name := 'n1',
    source_node_name := 'n2',
    source_dsn       := 'host=n2 port=5432 dbname=pgedge user=pgedge',
    target_node_name := 'n3',
    target_dsn       := 'host=n3 port=5432 dbname=pgedge user=pgedge',
    verb             := true
);
```

## Commands

### cluster.py

```bash
# Generate Docker configuration
cluster.py generate --nodes N [--pg-ver 17|18] [--base-delay-ms MS]

# Setup Spock cluster
cluster.py setup [--nodes N] [-v]

# Test cluster
cluster.py test [--nodes N] [-v]

# Test recovery workflow
cluster.py test-recovery [--docker] [-v]
```

## Recovery Slot Tracking

The recovery slot automatically tracks the **minimum LSN** across all peer subscriptions, ensuring WAL is preserved for rescue operations.

### How It Works

1. Manager worker periodically calls `advance_recovery_slot_to_min_position()`
2. Function queries all active peer subscriptions
3. Finds the minimum `remote_lsn` (slowest node)
4. Advances recovery slot to this position
5. WAL preserved from slowest subscriber

### Benefits

- **Historical replay**: Rescue subscriptions can replay old transactions
- **Automatic**: No manual intervention needed
- **Safe**: Never moves backwards, only forward
- **Resilient**: Survives catastrophic node failures

## Testing Scenario

1. Create 3-node cluster (n1, n2, n3)
2. Insert baseline data, verify sync
3. Disable n3's subscription from n1
4. Insert new data on n1
5. n2 receives data, n3 lags
6. Recovery slot on n2 preserves WAL
7. Simulate n1 crash
8. Use recovery.sql to rescue n3 from n2
9. Verify n3 catches up

## Requirements

- PostgreSQL 17 or 18 with Spock extension
- Python 3.7+
- psycopg2-binary (for Python testing)
- Docker (optional, for Docker-based testing)

## Installation

```bash
# Install Python dependencies
pip install psycopg2-binary

# Build and install Spock
cd ../..
make clean && make && make install
```

## Documentation

- See source code comments in `src/spock_recovery.c`
- See procedure comments in `recovery.sql`
- Main project README: `../../README.md`
