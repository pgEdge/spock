#!/bin/bash
set -eo pipefail

# Load PostgreSQL environment variables
# Temporarily disable -u (unbound variable check) to avoid issues with system bashrc
set +u
source "${HOME}/.bashrc"
set -u

echo "=========================================="
echo "Initializing PostgreSQL for Spock Testing"
echo "=========================================="

# Configure core dumps for crash debugging
if [ -d "/cores" ]; then
	echo "Configuring core dumps..."
	# Try to set core pattern to write to /cores directory
	# Note: /proc/sys/kernel/core_pattern is host-level and usually read-only in Docker
	# Format: core.<hostname>.<executable>.<pid>.<timestamp>
	if echo "/cores/core.${HOSTNAME}.%e.%p.%t" > /proc/sys/kernel/core_pattern 2>/dev/null; then
		echo "✓ Core pattern set successfully"
	else
		echo "Note: Cannot set core_pattern (host-level setting)"
		echo "	  Core dumps will use host pattern but ulimit is unlimited"
	fi
	# Verify ulimit
	ulimit -c unlimited
	echo "Core dumps enabled: $(ulimit -c)"
	echo "Core pattern: $(cat /proc/sys/kernel/core_pattern 2>/dev/null || echo 'Unable to read')"
	echo "Core dumps will be saved with debug symbols (-g -O0)"
else
	echo "Warning: /cores directory not mounted - core dumps may not persist"
fi

# Ensure data directory exists and has correct permissions
echo "Checking data directory permissions..."
PGDATA_PARENT=$(dirname "${PGDATA}")
if [ ! -d "${PGDATA_PARENT}" ]; then
	echo "Creating parent directory: ${PGDATA_PARENT}"
	mkdir -p "${PGDATA_PARENT}"
fi

# Check if we can write to the directory
if [ ! -w "${PGDATA_PARENT}" ]; then
	echo "ERROR: Cannot write to ${PGDATA_PARENT}"
	echo "Current user: $(whoami) (UID: $(id -u))"
	echo "Directory ownership: $(ls -ld ${PGDATA_PARENT})"
	exit 1
fi
echo "Data directory permissions OK"

# Initialize PostgreSQL cluster
if [ ! -d "${PGDATA}" ]; then
	echo "Initializing PostgreSQL ${PGVER} cluster..."
	mkdir -p "${PGDATA}"
	initdb -D "${PGDATA}" -U "${PGUSER}" --encoding=UTF8 --locale=C

	# Configure PostgreSQL for logical replication
	cat >> "${PGDATA}/postgresql.conf" <<EOF
# Core setting specific for the Spock
wal_level = logical
track_commit_timestamp = 'on'
max_worker_processes = 32
max_replication_slots = 32
max_wal_senders = 32
log_min_messages = log

# Network configuration for multi-node cluster
listen_addresses = '*'

# Spock Configuration
shared_preload_libraries = 'spock'
spock.conflict_resolution = 'last_update_wins'
spock.save_resolutions = 'on'
EOF

	# Configure client authentication for Docker network
	cat >> "${PGDATA}/pg_hba.conf" <<EOF
# Allow connections from Docker network (all containers)
host    all             all             0.0.0.0/0               trust
EOF
	echo "PostgreSQL cluster initialized"

	# Start PostgreSQL in background for initialization
	echo "Starting PostgreSQL for initialization..."
	pg_ctl -D "${PGDATA}" -l "${HOME}/logfile.log" -o "-k /tmp" -w start

	# Solely for DEBUGGING purposes
	cat ${HOME}/logfile.log

	createdb -h /tmp "${PGDATABASE}"

	# Create spock extension and node only if HOSTNAME and PEER_NAMES are set
	if [ -n "${HOSTNAME:-}" ] && [ -n "${PEER_NAMES:-}" ]; then
		echo ""
		echo "=========================================="
		echo "Setting up Spock Node"
		echo "=========================================="
		echo "Node Name: ${HOSTNAME}"
		echo "Peers: ${PEER_NAMES}"
		echo ""

		psql -h /tmp -c "CREATE EXTENSION spock"

		if [[ $HOSTNAME == "n1" ]]; then
		  # First node specific action
		  psql -h /tmp -c "
		    SELECT spock.node_create(
				node_name := '${HOSTNAME}',
				dsn := 'host=n1 port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER}',
				country := 'ESP', location := 'Madrid',
				info := '{\"tiebreaker\" : \"1\"}')"
		else
		  # Add node to the existing cluster using Z0DAN
		  psql -h /tmp -c "CREATE EXTENSION dblink"
		  psql -h /tmp -f ${SPOCK_SOURCE_DIR}/samples/Z0DAN/zodan.sql
		  psql -h /tmp -c "CALL spock.add_node(
			src_node_name := 'n1',
			src_dsn := 'host=n1 port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER}',
            new_node_name := '${HOSTNAME}',
			new_node_dsn := 'host=${HOSTNAME} port=${PGPORT} dbname=${PGDATABASE} user=${PGUSER}',
			verb := true,
			new_node_country := 'USA',
			new_node_location := 'NYC',
			new_node_info := '{}');"
		fi
	else
		echo "HOSTNAME and/or PEER_NAMES not set"
		exit 1
	fi

	# Stop PostgreSQL gracefully using smart mode
	# This waits for all connections to close - if it hangs, it indicates a problem
	# that should be fixed (e.g., forgotten connection, long transaction)
	pg_ctl -D "${PGDATA}" -m smart -t 60 stop

	# Mark initialization complete for healthcheck
	touch /tmp/spock_init_complete
else
	echo "Using existing PostgreSQL cluster at ${PGDATA}"
	# Ensure marker exists for container restarts
	touch /tmp/spock_init_complete
fi
