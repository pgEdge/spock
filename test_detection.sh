#!/bin/bash
# Test script for recovery.sql and detect.sql

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

DB_USER="${USER}"
DB_NAME="pgedge"
PORT_START=5451

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Testing Detection Procedures ===${NC}\n"

# Step 1: Setup cluster if not running
echo -e "${YELLOW}Step 1: Checking if cluster is running...${NC}"
if ! python3 cluster.py --port-start $PORT_START 2>&1 | grep -q "Cluster must be running"; then
    echo -e "${GREEN}Cluster is running${NC}"
else
    echo -e "${YELLOW}Setting up cluster...${NC}"
    python3 cluster.py --port-start $PORT_START
fi

# Step 2: Run crash scenario
echo -e "\n${YELLOW}Step 2: Running crash scenario...${NC}"
python3 cluster.py --crash --port-start $PORT_START || true

# Step 3: Test detection procedures
echo -e "\n${YELLOW}Step 3: Testing detection procedures...${NC}"

# Get DSNs
SOURCE_DSN="host=localhost port=$((PORT_START + 1)) dbname=$DB_NAME user=$DB_USER"
TARGET_DSN="host=localhost port=$((PORT_START + 2)) dbname=$DB_NAME user=$DB_USER"

# Test recovery.sql (detect_lag)
echo -e "\n${GREEN}Testing recovery.sql (detect_lag)...${NC}"
psql -h localhost -p $((PORT_START + 1)) -U $DB_USER -d $DB_NAME -f recovery.sql
psql -h localhost -p $((PORT_START + 1)) -U $DB_USER -d $DB_NAME -c "
CALL spock.detect_lag(
    failed_node_name := 'n1',
    source_node_name := 'n2',
    source_dsn := '$SOURCE_DSN',
    target_node_name := 'n3',
    target_dsn := '$TARGET_DSN'
);
" || echo -e "${RED}recovery.sql test failed${NC}"

# Test detect.sql (detect_slot_lag)
echo -e "\n${GREEN}Testing detect.sql (detect_slot_lag)...${NC}"
psql -h localhost -p $((PORT_START + 1)) -U $DB_USER -d $DB_NAME -f detect.sql
psql -h localhost -p $((PORT_START + 1)) -U $DB_USER -d $DB_NAME -c "
CALL spock.detect_slot_lag(
    failed_node_name := 'n1',
    source_node_name := 'n2',
    source_dsn := '$SOURCE_DSN',
    target_node_name := 'n3',
    target_dsn := '$TARGET_DSN'
);
" || echo -e "${RED}detect.sql test failed${NC}"

echo -e "\n${GREEN}=== Test Complete ===${NC}"





