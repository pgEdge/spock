#!/bin/bash

source "${HOME}/.bashrc"

#set -euo pipefail

IFS=',' read -r -a peer_names <<< "$PEER_NAMES"

function wait_for_pg()
{
  local max_attempts=${1:-24}
  local sleep_seconds=${2:-5}

  # Build list of all hosts to check: local node + all peers
  local hosts=("/tmp")
  for peer in "${peer_names[@]}"; do
    hosts+=("$peer")
  done

  for host in "${hosts[@]}"; do
    count=0
    while ! pg_isready -h "$host"; do
      if [ $count -ge $max_attempts ]; then
        echo "Gave up waiting for PostgreSQL on $host to become ready..."
        exit 1
      fi

      echo "Waiting for PostgreSQL on $host to become ready..."
      sleep $sleep_seconds
      ((count++))
    done
    echo "PostgreSQL on $host is ready"
  done
}

wait_for_pg 10 1

#========== Exception Log tests ==========

# We perform the following tests in two cases:
# a. Table containing delta-apply columns
# b. Table without delta-apply columns
#
# 1. INSERT: Duplicate pkey, Duplicate secondary constraint
# 2. UPDATE: Row not found, duplicate secondary constraint
# 3. DELETE: Row not found

# ----
# Create table and test data on n1
# ----
if [[ $(hostname) == "n1" ]];
then
  psql -h /tmp <<_EOF_
  CREATE TABLE t4 (
    id		integer PRIMARY KEY,
    data	text
  );

  INSERT INTO t4 VALUES (2, 'missing row on UPDATE');
  INSERT INTO t4 VALUES (3, 'missing row on DELETE');

  SELECT spock.repset_add_table(
    set_name := 'default',
    relation := 't4'
  );
_EOF_

  # ----
  # Create table and test data on n2
  # ----
  psql -h ${peer_names[0]} <<_EOF_
  CREATE TABLE t4 (
    id		integer PRIMARY KEY,
    data	text
  );

  INSERT INTO t4 VALUES (1, 'duplicate key on INSERT');
  SELECT spock.repset_add_table(
    set_name := 'default',
    relation := 't4'
  );
_EOF_

  psql -h /tmp <<_EOF_
  INSERT INTO t4 VALUES (1, 'trigger duplicate key');
  UPDATE t4 SET data = 'trigger missing key on UPDATE' WHERE id = 2;
  DELETE FROM t4 WHERE id = 3; -- trigger missing key on DELETE
_EOF_

  # To be sure that conflict resolution has happened we need to wait until the
  # following transaction arrives
  lsn1=$(psql -A -t -h /tmp -c "SELECT spock.sync_event()")
  echo "Wait until XLogRecord $lsn1 arrive and applies from $HOSTNAME to ${peer_names[0]}"
  psql -A -t -h ${peer_names[0]} -c \
    "CALL spock.wait_for_sync_event(true, '$HOSTNAME', '$lsn1'::pg_lsn, 30)"

  echo "Checking the exception table now..."
  elog_entries=$(psql -A -t -h ${peer_names[0]} -c "
  	SELECT count(*)
	FROM spock.exception_log e
	JOIN spock.node n
	ON e.remote_origin = n.node_id
	WHERE e.operation = 'UPDATE'
	AND n.node_name = 'n1'
	AND e.remote_new_tup::text LIKE '%\"trigger missing key on UPDATE\"%';
	")

  if [ "$elog_entries" -ne 1 ];
  then
	  psql -h ${peer_names[0]} -c "select * from spock.exception_log;"
	  echo "Did not find an exception log entry. Exiting..."
	  exit 1
  fi

  resolution_check=$(psql -X -A -t -h ${peer_names[0]} -c \
    "SELECT conflict_type FROM spock.resolutions WHERE relname = 'public.t4'")

  insert_exists_count=$(echo "$resolution_check" | grep -c 'insert_exists')
  delete_missing_count=$(echo "$resolution_check" | grep -c 'delete_missing')

  if [ "$insert_exists_count" -eq 1 ] && [ "$delete_missing_count" -eq 1 ];
  then
    echo "PASS: Found both insert_exists and delete_missing for public.t4"
  else
    psql -h ${peer_names[0]} -c "SELECT * FROM spock.resolutions WHERE relname = 'public.t4'"
    echo "FAIL: Resolution entries for public.t4 are incorrect"
    echo "Resolutions check=$resolution_check"
    echo "Found: insert_exists=$insert_exists_count, delete_missing=$delete_missing_count"
    exit 1
  fi
fi

# The Auto-DDL LR is disabled So, we create the same tables and data on each node
spockbench -h /tmp -i -s $SCALEFACTOR --spock-node=${HOSTNAME:0-1} $PGDATABASE

psql -h /tmp <<_EOF_
  /*
   * Each node adds test tables to replication sets. Hence, further DML will be
   * propagated by LR to other nodes
   */
  SELECT spock.repset_add_all_tables('default', '{public}');
_EOF_

# ==========Spockbench tests ==========

# By default, spockbench enables delta apply and setup this option on the
# 'balance' columns.
spockbench -h /tmp --spock-num-nodes=3 --spock-node=${HOSTNAME:0-1} \
	-s $SCALEFACTOR -T $RUNTIME -R $RATE -P 5 -j $THREADS -c $CONNECTIONS \
	-n --spock-tx-mix=550,225,225 $PGDATABASE

# To be sure each spockbench client finalised their job
# There are still races possible. Should it be OK for our testing purposes?
sleep 5

# To be sure that conflict resolution has happened we need to wait until the
# following transaction arrives
echo "Begin after-Spockbench sync"
for peer in "${peer_names[@]}"; do
  lsn=$(psql -A -t -h $peer -c "SELECT spock.sync_event()")
  echo "Wait until XLogRecord $lsn arrives and applies from $peer to $HOSTNAME"
  psql -A -t -h /tmp -c \
  "CALL spock.wait_for_sync_event(true, '$peer', '$lsn'::pg_lsn, 30)"
done
echo "Finish after-Spockbench sync"

spockbench-check $PGDATABASE > /home/pgedge/spock/spockbench-$HOSTNAME.out
# Check only this node's output file, not all nodes
grep -q "ERROR" /home/pgedge/spock/spockbench-$HOSTNAME.out && exit 1 || exit 0
