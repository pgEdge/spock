#!/bin/bash
# End-to-End Recovery Test
# Tests complete recovery workflow: setup, failure, rescue, verification

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

USE_DOCKER=false
VERBOSE=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --docker)
            USE_DOCKER=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--docker] [-v|--verbose]"
            echo ""
            echo "Options:"
            echo "  --docker    Use Docker environment (default: local PostgreSQL)"
            echo "  -v          Verbose output"
            echo ""
            echo "Test scenario:"
            echo "  1. Setup 3-node cluster (n1, n2, n3)"
            echo "  2. Insert baseline data, verify sync"
            echo "  3. Disable n3 subscription from n1"
            echo "  4. Insert more data on n1"
            echo "  5. Verify n2 receives it, n3 lags"
            echo "  6. Simulate n1 crash"
            echo "  7. Execute recovery workflow"
            echo "  8. Verify n3 catches up from n2"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

echo "════════════════════════════════════════════════════════════════"
echo "END-TO-END RECOVERY TEST"
echo "════════════════════════════════════════════════════════════════"
echo ""
echo "Environment: $([ "$USE_DOCKER" = true ] && echo "Docker" || echo "Local PostgreSQL")"
echo "Verbose: $VERBOSE"
echo ""

if [ "$USE_DOCKER" = true ]; then
    echo "────────────────────────────────────────────────────────────────"
    echo "DOCKER TEST"
    echo "────────────────────────────────────────────────────────────────"
    
    # Check if Docker is available
    if ! command -v docker &> /dev/null; then
        echo "❌ Docker not found. Please install Docker."
        exit 1
    fi
    
    # Cleanup
    echo ""
    echo "→ Cleaning up existing containers..."
    docker compose down -v 2>/dev/null || true
    docker rm -f pg1 pg2 pg3 2>/dev/null || true
    
    # Generate
    echo ""
    echo "→ Generating cluster configuration..."
    python3 cluster.py generate --nodes 3 --pg-ver 18
    
    # Check if Dockerfile exists (generated name is Dockerfile.pg17-spock or pg18-spock)
    if [ ! -f "Dockerfile.pg17-spock" ] && [ ! -f "Dockerfile.pg18-spock" ]; then
        echo "❌ Dockerfile not generated"
        exit 1
    fi
    
    # Use whichever Dockerfile was generated
    DOCKERFILE=$(ls Dockerfile.pg*-spock 2>/dev/null | head -1)
    
    # Build and start
    echo ""
    echo "→ Building Docker images (this may take a few minutes)..."
    if ! docker compose build 2>&1 | tail -3; then
        echo "❌ Docker build failed"
        echo "Note: PG17 has compiler warnings, use --pg-ver 18"
        exit 1
    fi
    
    echo ""
    echo "→ Starting containers..."
    docker compose up -d
    
    # Wait for PostgreSQL
    echo ""
    echo "→ Waiting for PostgreSQL to be ready..."
    for i in 1 2 3; do
        timeout=60
        while [ $timeout -gt 0 ]; do
            if docker exec pg$i pg_isready -U postgres >/dev/null 2>&1; then
                echo "  ✓ pg$i ready"
                break
            fi
            sleep 2
            timeout=$((timeout - 2))
        done
        if [ $timeout -le 0 ]; then
            echo "  ❌ pg$i failed to start"
            docker logs pg$i 2>&1 | tail -20
            exit 1
        fi
    done
    
    # Setup Spock
    echo ""
    echo "→ Setting up Spock cross-wiring..."
    if [ "$VERBOSE" = true ]; then
        python3 cluster.py setup --nodes 3 -v
    else
        python3 cluster.py setup --nodes 3 2>&1 | grep -E "Creating|subscription|✓|ERROR"
    fi
    
    # Create test table
    echo ""
    echo "→ Creating test table on all nodes..."
    for i in 1 2 3; do
        docker exec pg$i psql -U postgres -d pgedge <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS recovery_test (
    id SERIAL PRIMARY KEY,
    payload TEXT,
    node TEXT,
    created_at TIMESTAMPTZ DEFAULT now()
);
SELECT spock.repset_add_table('default', 'recovery_test');
SQL
    done
    
    # Insert baseline
    echo ""
    echo "→ Inserting baseline data on n1..."
    docker exec pg1 psql -U postgres -d pgedge -c \
        "INSERT INTO recovery_test(payload, node) VALUES ('baseline-1', 'n1'), ('baseline-2', 'n1'), ('baseline-3', 'n1');" \
        >/dev/null
    
    sleep 10
    
    c1=$(docker exec pg1 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    c2=$(docker exec pg2 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    c3=$(docker exec pg3 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    
    echo "  Counts: n1=$c1, n2=$c2, n3=$c3"
    
    if [ "$c1" = "3" ] && [ "$c2" = "3" ] && [ "$c3" = "3" ]; then
        echo "  ✅ Baseline synchronized"
    else
        echo "  ❌ Sync failed"
        exit 1
    fi
    
    # Create lag
    echo ""
    echo "→ Disabling n3 subscription from n1 (creating lag)..."
    docker exec pg3 psql -U postgres -d pgedge -c \
        "SELECT spock.sub_disable('sub_n1_n3');" >/dev/null
    
    sleep 3
    
    # Insert more data
    echo ""
    echo "→ Inserting new data on n1 (n3 won't receive)..."
    docker exec pg1 psql -U postgres -d pgedge -c \
        "INSERT INTO recovery_test(payload, node) VALUES ('new-4', 'n1'), ('new-5', 'n1');" \
        >/dev/null
    
    sleep 10
    
    c1=$(docker exec pg1 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    c2=$(docker exec pg2 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    c3=$(docker exec pg3 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    
    echo "  Counts: n1=$c1, n2=$c2, n3=$c3"
    
    if [ "$c1" = "5" ] && [ "$c2" = "5" ] && [ "$c3" = "3" ]; then
        echo "  ✅ Lag created (n2 has data, n3 is behind)"
    else
        echo "  ⚠ Unexpected counts"
    fi
    
    # Check recovery slot on n2
    echo ""
    echo "→ Checking recovery slot on n2..."
    docker exec pg2 psql -U postgres -d pgedge <<'SQL'
SELECT 
    slot_name,
    restart_lsn,
    confirmed_flush_lsn,
    active
FROM pg_replication_slots 
WHERE slot_name LIKE 'spk_recovery_%';
SQL
    
    # Stop n1
    echo ""
    echo "→ Stopping n1 (simulating crash)..."
    docker stop pg1 >/dev/null
    echo "  ✓ n1 stopped"
    
    sleep 3
    
    # Execute recovery
    echo ""
    echo "→ Executing recovery workflow..."
    echo "  Note: This uses recovery.sql procedures via dblink"
    
    # Copy recovery.sql to pg2
    docker cp recovery.sql pg2:/tmp/recovery.sql
    
    # Create and execute recovery script
    cat > /tmp/run_recovery.sql <<'EOSQL'
\i /tmp/recovery.sql

-- Execute recovery
CALL spock.recovery(
    failed_node_name := 'n1',
    source_node_name := 'n2',
    source_dsn       := 'host=10.250.0.12 port=5432 dbname=pgedge user=postgres',
    target_node_name := 'n3',
    target_dsn       := 'host=10.250.0.13 port=5432 dbname=pgedge user=postgres',
    verb             := true
);
EOSQL
    
    docker cp /tmp/run_recovery.sql pg2:/tmp/run_recovery.sql
    
    echo "  Running rescue workflow..."
    docker exec pg2 psql -U postgres -d pgedge -f /tmp/run_recovery.sql 2>&1 | \
        grep -E "NOTICE|ERROR|recovery" | head -30 || true
    
    # Wait and verify
    echo ""
    echo "→ Waiting for data to sync (30 seconds)..."
    sleep 30
    
    c2=$(docker exec pg2 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    c3=$(docker exec pg3 psql -U postgres -d pgedge -tA -c "SELECT count(*) FROM recovery_test;")
    
    echo ""
    echo "→ Final verification:"
    echo "  n1: DOWN"
    echo "  n2: $c2 rows"
    echo "  n3: $c3 rows"
    
    if [ "$c2" = "5" ] && [ "$c3" = "5" ]; then
        echo ""
        echo "✅ SUCCESS: n3 caught up! Recovery workflow successful."
        SUCCESS=true
    else
        echo ""
        echo "⚠ PARTIAL: n3 still at $c3 rows (expected 5)"
        echo "   This may indicate:"
        echo "   - Recovery slot not tracking minimum position"
        echo "   - Rescue subscription not applying transactions"
        echo "   - Need more time for catch-up"
        SUCCESS=false
    fi
    
    # Cleanup
    echo ""
    echo "→ Cleaning up..."
    docker compose down -v >/dev/null 2>&1
    rm -f Dockerfile.pg*-spock docker-compose.yml /tmp/run_recovery.sql
    
    [ "$SUCCESS" = true ] && exit 0 || exit 1
    
else
    echo "────────────────────────────────────────────────────────────────"
    echo "LOCAL TEST"
    echo "────────────────────────────────────────────────────────────────"
    
    echo ""
    echo "⚠ Local testing requires manual setup:"
    echo ""
    echo "Prerequisites:"
    echo "  - PostgreSQL 17/18 with Spock installed"
    echo "  - Three instances on ports 5451, 5452, 5453"
    echo "  - User 'pgedge' with permissions"
    echo ""
    echo "Steps:"
    echo "  1. Initialize three data directories"
    echo "  2. Configure postgresql.conf with Spock settings"
    echo "  3. Start all three instances"
    echo "  4. Create 'pgedge' database on each"
    echo "  5. Install Spock and dblink extensions"
    echo "  6. Run: python3 cluster.py setup --nodes 3"
    echo "  7. Create test table and add to replication sets"
    echo "  8. Insert baseline data, verify sync"
    echo "  9. Disable n3's subscription from n1"
    echo " 10. Insert more data on n1"
    echo " 11. Stop n1 (pg_ctl stop)"
    echo " 12. Execute recovery.sql from n2"
    echo " 13. Verify n3 catches up"
    echo ""
    echo "For automated local testing, see the manual test scripts."
    echo ""
    
    exit 0
fi

