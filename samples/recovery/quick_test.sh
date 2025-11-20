#!/bin/bash
set -e

export PGPASSWORD=1safepassword
P1=15432
P2=15433
P3=15434

echo "=== Step 1: Clean up and restart ==="
cd /Users/ibrarahmed/pgedge/spock-ibrar/samples/recovery
docker compose down -v
docker compose up -d
sleep 15

echo "=== Step 2: Setup Spock cluster ==="
python3 cluster.py setup --nodes 3 --host-port-start 15432 --subnet 10.250.0.0/24

echo "=== Step 3: Create test table on all nodes ==="
for port in $P1 $P2 $P3; do
    psql -h 127.0.0.1 -p $port -U pgedge -d pgedge <<SQL
CREATE TABLE IF NOT EXISTS rescue_test(
    id serial PRIMARY KEY,
    payload text NOT NULL,
    created_at timestamptz DEFAULT now()
);
SELECT spock.repset_add_table('default', 'public.rescue_test');
SQL
done

echo "=== Step 4: Insert baseline data on n1 ==="
psql -h 127.0.0.1 -p $P1 -U pgedge -d pgedge -c "INSERT INTO rescue_test(payload) VALUES ('baseline-1'), ('baseline-2'), ('baseline-3');"
sleep 5

echo "=== Step 5: Verify replication to n2 and n3 ==="
for port in $P2 $P3; do
    count=$(psql -h 127.0.0.1 -p $port -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
    echo "  Node on port $port has $count rows"
done

echo "=== Step 6: Disable n3←n1 subscription ==="
psql -h 127.0.0.1 -p $P3 -U pgedge -d pgedge -c "SELECT spock.sub_disable('sub_n1_n3');"

echo "=== Step 7: Insert new data on n1 (simulating LSN12) ==="
psql -h 127.0.0.1 -p $P1 -U pgedge -d pgedge -c "INSERT INTO rescue_test(payload) VALUES ('new-4'), ('new-5');"
sleep 5

echo "=== Step 8: Verify n2 got the data but n3 didn't ==="
count2=$(psql -h 127.0.0.1 -p $P2 -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
count3=$(psql -h 127.0.0.1 -p $P3 -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
echo "  n2 has $count2 rows, n3 has $count3 rows"

echo "=== Step 9: Stop n1 (simulating crash) ==="
docker stop pg1

echo "=== Step 10: Try to re-enable n3←n1 (will fail) ==="
psql -h 127.0.0.1 -p $P3 -U pgedge -d pgedge -c "SELECT spock.sub_enable('sub_n1_n3');" || echo "  (Expected failure - n1 is down)"

echo "=== Step 11: Run rescue procedure ==="
psql -h 127.0.0.1 -p $P2 -U pgedge -d pgedge <<SQL
\i /Users/ibrarahmed/pgedge/spock-ibrar/samples/recovery/recovery.sql

CALL spock.recovery(
    failed_node_name => 'n1',
    source_node_name => 'n2',
    source_dsn       => 'host=10.250.0.12 port=5432 dbname=pgedge user=pgedge password=1safepassword',
    target_node_name => 'n3',
    target_dsn       => 'host=10.250.0.13 port=5432 dbname=pgedge user=pgedge password=1safepassword',
    verb             => true
);
SQL

echo "=== Step 12: Verify data synchronization ==="
count3_after=$(psql -h 127.0.0.1 -p $P3 -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
echo "  n3 now has $count3_after rows (should be 5)"

echo "=== Step 13: Check subscription status ==="
psql -h 127.0.0.1 -p $P3 -U pgedge -d pgedge -c "SELECT sub_name, sub_enabled, sub_rescue_temporary, sub_rescue_cleanup_pending FROM spock.subscription;"

echo "=== SUCCESS ==="

