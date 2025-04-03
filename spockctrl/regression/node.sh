#!/bin/bash

set -e

# Test variables
NODE="n1"
DB="pgedge"
DSN="host=127.0.0.1 port=5432 user=pgedge password=password1"
INTERFACE_NAME="interface1"
LOCATION="location1"
COUNTRY="country1"
INFO="info1"

# Function to run a test and display status
run_test() {
    local description=$1
    local command=$2
    eval "$command"
}
# Test node create
run_test "node create" \
    "./spockctrl node create --node_name=\"$NODE\" --dsn=\"$DSN\" --location=\"$LOCATION\" --country=\"$COUNTRY\" --info=\"$INFO\""

exit 0

# Test node drop
run_test "node drop" \
    "./spockctrl node drop --node_name=\"$NODE\" --ifexists"

# Test node spock-version
run_test "node spock-version" \
    "./spockctrl node spock-version --node=\"$NODE\" --db=\"$DB\""

# Test node pg-version
run_test "node pg-version" \
    "./spockctrl node pg-version --node=\"$NODE\" --db=\"$DB\""

# Test node status
run_test "node status" \
    "./spockctrl node status --node=\"$NODE\" --db=\"$DB\""

# Test node gucs
run_test "node gucs" \
    "./spockctrl node gucs --node=\"$NODE\" --db=\"$DB\""

# Test node create
run_test "node create" \
    "./spockctrl node create --node_name=\"$NODE\" --dsn=\"$DSN\" --location=\"$LOCATION\" --country=\"$COUNTRY\" --info=\"$INFO\""

# Test node drop
run_test "node drop" \
    "./spockctrl node drop --node_name=\"$NODE\" --ifexists"

# Test node add-interface
run_test "node add-interface" \
    "./spockctrl node add-interface --node_name=\"$NODE\" --interface_name=\"$INTERFACE_NAME\" --dsn=\"$DSN\""

# Test node drop-interface
run_test "node drop-interface" \
    "./spockctrl node drop-interface --node_name=\"$NODE\" --interface_name=\"$INTERFACE_NAME\""

echo "All tests completed successfully."
