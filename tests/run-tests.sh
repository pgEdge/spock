#!/bin/bash

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
sleep 30
echo "Checking the exception table now..."
elog_entries=$(PGPASSWORD=$DBPASSWD psql -A -t -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "SELECT count(*) from spock.exception_log;")
echo $elog_entries > /home/pgedge/spock/exception-tests.out

spockbench -h /tmp -i -s $SCALEFACTOR demo
psql -U admin -h /tmp -d demo -c "select spock.convert_sequence_to_snowflake('pgbench_history_hid_seq');"
psql -U admin -h /tmp -d demo -c "alter table pgbench_accounts alter column abalance set(log_old_value=true, delta_apply_function=spock.delta_apply);"
psql -U admin -h /tmp -d demo -c "alter table pgbench_branches alter column bbalance set(log_old_value=true, delta_apply_function=spock.delta_apply);"
psql -U admin -h /tmp -d demo -c "alter table pgbench_tellers alter column tbalance set(log_old_value=true, delta_apply_function=spock.delta_apply);"

psql -U admin -h /tmp -d demo -c "select spock.repset_add_all_tables('demo_replication_set', '{public}');"

# ==========Spockbench tests ========== 
spockbench -h /tmp --spock-num-nodes=3 --spock-node=${HOSTNAME:0-1} -s $SCALEFACTOR -T $RUNTIME -R $RATE -P 5 -j $THREADS -c $CONNECTIONS -n --spock-tx-mix=550,225,225 -U admin demo
spockbench-check -U admin demo > /home/pgedge/spock/spockbench-$HOSTNAME.out
