#!/bin/bash

#set -euo pipefail

peer_names=$1

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
  psql -U $DBUSER -d $DBNAME -h /tmp <<_EOF_
  CREATE TABLE t4 (
    id		integer PRIMARY KEY,
    data	text
  );

  INSERT INTO t4 VALUES (2, 'missing row on UPDATE');
  INSERT INTO t4 VALUES (3, 'missing row on DELETE');

  SELECT spock.repset_add_table(
    set_name := 'demo_replication_set',
    relation := 't4'
  );
_EOF_

  # ----
  # Create table and test data on n2
  # ----
  PGPASSWORD=$DBPASSWD psql -U $DBUSER -d $DBNAME -h ${peer_names[0]} <<_EOF_
  CREATE TABLE t4 (
    id		integer PRIMARY KEY,
    data	text
  );

  INSERT INTO t4 VALUES (1, 'duplicate key on INSERT');
  SELECT spock.repset_add_table(
    set_name := 'demo_replication_set',
    relation := 't4'
  );
_EOF_

  psql -U $DBUSER -d $DBNAME -h /tmp <<_EOF_
  INSERT INTO t4 VALUES (1, 'trigger duplicate key');
  UPDATE t4 SET data = 'trigger missing key on UPDATE' WHERE id = 2;
  DELETE FROM t4 WHERE id = 3; -- trigger missing key on DELETE
_EOF_

  echo "Waiting for apply worker timeouts..."
  sleep 5
  echo "Checking the exception table now..."
  elog_entries=$(PGPASSWORD=$DBPASSWD psql -A -t -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "
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
	  PGPASSWORD=$DBPASSWD psql -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "select * from spock.exception_log;"
	  echo "Did not find an exception log entry. Exiting..."
	  exit 1
  fi


  resolution_check=$(PGPASSWORD=$DBPASSWD psql -X -A -t -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c " SELECT conflict_type FROM spock.resolutions WHERE relname = 'public.t4'")

  insert_exists_count=$(echo "$resolution_check" | grep -c 'insert_exists')
  delete_delete_count=$(echo "$resolution_check" | grep -c 'delete_delete')

  if [ "$insert_exists_count" -eq 1 ] && [ "$delete_delete_count" -eq 1 ];
  then
    echo "PASS: Found both insert_exists and delete_delete for public.t4"
  else
    PGPASSWORD=$DBPASSWD psql -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "select * from spock.resolutions where relname = 'public.t4'"
    echo "FAIL: Resolution entries for public.t4 are incorrect"
    echo "Resolutions check=$resolution_check"
    echo "Found: insert_exists=$insert_exists_count, delete_delete=$delete_delete_count"
    exit 1
  fi
fi

spockbench -h /tmp -i -s $SCALEFACTOR demo
psql -U admin -h /tmp -d demo -c "alter table pgbench_accounts alter column abalance set(log_old_value=true, delta_apply_function=spock.delta_apply);"
psql -U admin -h /tmp -d demo -c "alter table pgbench_branches alter column bbalance set(log_old_value=true, delta_apply_function=spock.delta_apply);"
psql -U admin -h /tmp -d demo -c "alter table pgbench_tellers alter column tbalance set(log_old_value=true, delta_apply_function=spock.delta_apply);"

psql -U admin -h /tmp -d demo -c "select spock.repset_add_all_tables('demo_replication_set', '{public}');"

# ==========Spockbench tests ==========
spockbench -h /tmp --spock-num-nodes=3 --spock-node=${HOSTNAME:0-1} -s $SCALEFACTOR -T $RUNTIME -R $RATE -P 5 -j $THREADS -c $CONNECTIONS -n --spock-tx-mix=550,225,225 -U admin demo
spockbench-check -U admin demo > /home/pgedge/spock/spockbench-$HOSTNAME.out
grep -q "ERROR" /home/pgedge/spock/spockbench-*.out && exit 1 || exit 0
