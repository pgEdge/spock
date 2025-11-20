# Spock Recovery Slot Testing

This directory contains tools for testing Spock recovery slot functionality with local PostgreSQL clusters.

## Setup

1. Create and activate a virtual environment:
   ```bash
   python3 -m venv venv
   source venv/bin/activate
   ```

2. Install dependencies:
   ```bash
   pip install -r requirements.txt
   ```

## Prerequisites

- 3 PostgreSQL instances running on ports 5451, 5452, 5453 (or specify custom ports)
- Database: `pgedge`
- User: `pgedge`
- Password: `1safepassword`
- Spock extension installed on all instances

## Usage

```bash
# Activate virtual environment first
source venv/bin/activate

# Run recovery slot test
python3 cluster.py --nodes 3 --port-start 5451 -v
```

## Test Scenario

The script tests recovery slot functionality:

1. Creates 3-node cluster and cross-wires with Spock
2. Inserts baseline data and verifies sync
3. Disables n3 subscription from n1 (creates lag)
4. Inserts more data (n2 receives, n3 doesn't)
5. Checks LSNs and recovery slot status
6. Simulates n1 crash
7. Loads and executes `recovery.sql` to rescue n3 from n2
8. Verifies n3 catches up (both n2 and n3 have same LSN)

## Files

- `cluster.py` - Main test script
- `recovery.sql` - Recovery workflow procedures
- `requirements.txt` - Python dependencies

