#!/bin/bash
set -e

export PGPASSWORD=1safepassword

echo "=== SPOCK RESCUE WORKFLOW TEST ==="
echo ""

echo "Step 1: Clean start"
cd /Users/ibrarahmed/pgedge/spock-ibrar/samples/recovery
docker compose down -v >/dev/null 2>&1
docker compose up -d
sleep 20

echo "Step 2: Setup Spock (3-node cross-wired cluster)"
python3 cluster.py setup --nodes 3 --host-port-start 15432 --subnet 10.250.0.0/24

echo ""
echo "Step 3: Create test table + add to replication"
for node in pg1 pg2 pg3; do
    docker exec -e PGPASSWORD=1safepassword $node psql -U pgedge -d pgedge -c \
        "CREATE TABLE IF NOT EXISTS rescue_test(id serial PRIMARY KEY, payload text, created_at timestamptz DEFAULT now());" >/dev/null
    docker exec -e PGPASSWORD=1safepassword $node psql -U pgedge -d pgedge -c \
        "SELECT spock.repset_add_table('default', 'public.rescue_test');" >/dev/null
done
echo "  ✓ Table created on all nodes"

echo ""
echo "Step 4: Insert baseline (3 rows) on n1"
docker exec -e PGPASSWORD=1safepassword pg1 psql -U pgedge -d pgedge -c \
    "INSERT INTO rescue_test(payload) VALUES ('base-1'), ('base-2'), ('base-3');" >/dev/null
sleep 5

n2_count=$(docker exec -e PGPASSWORD=1safepassword pg2 psql -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
n3_count=$(docker exec -e PGPASSWORD=1safepassword pg3 psql -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
echo "  ✓ n2 has $n2_count rows, n3 has $n3_count rows"

echo ""
echo "Step 5: Disable n3←n1 subscription (simulate lag)"
docker exec -e PGPASSWORD=1safepassword pg3 psql -U pgedge -d pgedge -c \
    "SELECT spock.sub_disable('sub_n1_n3');" >/dev/null
echo "  ✓ Subscription disabled"

echo ""
echo "Step 6: Insert 2 more rows on n1 (will reach n2 but not n3)"
docker exec -e PGPASSWORD=1safepassword pg1 psql -U pgedge -d pgedge -c \
    "INSERT INTO rescue_test(payload) VALUES ('new-4'), ('new-5');" >/dev/null
sleep 5

n2_count=$(docker exec -e PGPASSWORD=1safepassword pg2 psql -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
n3_count=$(docker exec -e PGPASSWORD=1safepassword pg3 psql -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
echo "  ✓ n2 has $n2_count rows, n3 has $n3_count rows (n3 is lagging)"

echo ""
echo "Step 7: Stop n1 (catastrophic failure)"
docker stop pg1 >/dev/null
echo "  ✓ n1 stopped"

echo ""
echo "Step 8: Run rescue workflow (n2 as coordinator)"
docker exec -e PGPASSWORD=1safepassword pg2 psql -U pgedge -d pgedge <<'SQL'
\i /recovery.sql

CALL spock.recovery(
    failed_node_name => 'n1',
    source_node_name => 'n2',
    source_dsn       => 'host=pg2 port=5432 dbname=pgedge user=pgedge password=1safepassword',
    target_node_name => 'n3',
    target_dsn       => 'host=pg3 port=5432 dbname=pgedge user=pgedge password=1safepassword',
    verb             => true
);
SQL

echo ""
echo "Step 9: Verify final state"
n2_final=$(docker exec -e PGPASSWORD=1safepassword pg2 psql -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")
n3_final=$(docker exec -e PGPASSWORD=1safepassword pg3 psql -U pgedge -d pgedge -tA -c "SELECT count(*) FROM rescue_test;")

echo "  Final counts: n2=$n2_final, n3=$n3_final"

if [ "$n2_final" = "$n3_final" ] && [ "$n2_final" = "5" ]; then
    echo ""
    echo "=== ✓ RESCUE SUCCESSFUL ==="
    exit 0
else
    echo ""
    echo "=== ✗ RESCUE FAILED ==="
    echo "  Expected both nodes to have 5 rows"
    exit 1
fi

