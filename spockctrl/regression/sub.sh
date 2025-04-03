#!/bin/bash

set -e

# Test variables
NODE="n1"
SUB_NAME="s1"
DB="pgedge"
PROVIDER_DSN="host=127.0.0.1 port=5432 user=pgedge password=password1"
REPLICATION_SETS="default"
RELATION="public.test_table"
TRUNCATE="true"
IMMEDIATE="true"
REPLICATION_SET="default_set"

# Function to run a test and display status
run_test() {
    local description=$1
    local command=$2

    echo -n "[ ] Running $description ..."
    eval "$command"
}

# Test sub create
run_test "sub create" \
    "./spockctrl sub create --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --provider_dsn=\"$PROVIDER_DSN\" --db=\"$DB\" --replication_sets=\"ARRAY['default', 'default_insert_only', 'ddl_sql']\" --synchronize_structure=\"false\" --synchronize_data=\"false\" --forward_origins=\"'{}'::text[]\" --apply_delay=\"'0'::interval\""

# Test sub drop
run_test "sub drop" \
    "./spockctrl sub drop --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --db=\"$DB\" --ifexists"

# Test sub enable
run_test "sub enable" \
    "./spockctrl sub enable --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --db=\"$DB\" --immediate=\"$IMMEDIATE\""

# Test sub disable
run_test "sub disable" \
    "./spockctrl sub disable --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --db=\"$DB\" --immediate=\"$IMMEDIATE\""

# Test sub show-status
run_test "sub show-status" \
    "./spockctrl sub show-status --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --db=\"$DB\""

# Test sub show-table
run_test "sub show-table" \
    "./spockctrl sub show-table --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --relation=\"$RELATION\" --db=\"$DB\""

# Test sub resync-table
run_test "sub resync-table" \
    "./spockctrl sub resync-table --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --relation=\"$RELATION\" --db=\"$DB\" --truncate=\"$TRUNCATE\""

# Test sub add-repset
run_test "sub add-repset" \
    "./spockctrl sub add-repset --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --replication_set=\"$REPLICATION_SET\" --db=\"$DB\""

# Test sub remove-repset
run_test "sub remove-repset" \
    "./spockctrl sub remove-repset --node=\"$NODE\" --sub_name=\"$SUB_NAME\" --replication_set=\"$REPLICATION_SET\" --db=\"$DB\""

echo "All tests completed successfully."
