#!/bin/bash

IFS=',' read -r -a peer_names <<< "$1"

# The nodes share /home/pgedge/spock.  A node that exits takes its
# PostgreSQL with it, so no node exits until all of them are done.
marker_dir=/home/pgedge/spock
rm -f $marker_dir/ready-$HOSTNAME $marker_dir/confirmed-$HOSTNAME $marker_dir/done-$HOSTNAME

function wait_for_all()
{
  for attempt in $(seq 1 600); do
    [ $(ls $marker_dir/$1-* 2>/dev/null | wc -l) -ge 3 ] && return 0
    sleep 1
  done
  echo "FAIL: gave up waiting for all nodes to reach '$1'"
  exit 1
}

# A peer must be replicating demo_replication_set from n1 before n1
# changes t4, or the changes are filtered out and never reach it.
# Adding the set restarts the peer's apply worker, and the old one
# still reports replicating while it exits, so require two readings
# in a row.
function wait_for_sub_from_n1()
{
  echo "Waiting for sub_n1$1 on $1..."
  ready_count=0
  for attempt in $(seq 1 60); do
    sub_ready=$(PGPASSWORD=$DBPASSWD psql -X -A -t -U $DBUSER -d $DBNAME -h $1 -c "
      SELECT count(*)
      FROM spock.sub_show_status('sub_n1$1')
      WHERE status = 'replicating'
      AND 'demo_replication_set' = ANY (replication_sets);
      ") || sub_ready=""
    if [ "$sub_ready" = 1 ]; then
      ready_count=$((ready_count + 1))
      [ $ready_count -ge 2 ] && return 0
      sleep 3
    else
      ready_count=0
      sleep 1
    fi
  done
  echo "FAIL: sub_n1$1 on $1 is not replicating demo_replication_set"
  exit 1
}

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

  # ----
  # Create the table on n3 with n1's rows, so that n1's changes apply
  # there cleanly instead of failing on a missing relation
  # ----
  PGPASSWORD=$DBPASSWD psql -U $DBUSER -d $DBNAME -h ${peer_names[1]} <<_EOF_
  CREATE TABLE t4 (
    id		integer PRIMARY KEY,
    data	text
  );

  INSERT INTO t4 VALUES (2, 'missing row on UPDATE');
  INSERT INTO t4 VALUES (3, 'missing row on DELETE');
_EOF_

  wait_for_sub_from_n1 ${peer_names[0]}
  wait_for_sub_from_n1 ${peer_names[1]}

  psql -U $DBUSER -d $DBNAME -h /tmp <<_EOF_
  INSERT INTO t4 VALUES (1, 'trigger duplicate key');
  UPDATE t4 SET data = 'trigger missing key on UPDATE' WHERE id = 2;
  DELETE FROM t4 WHERE id = 3; -- trigger missing key on DELETE
_EOF_

  # The apply worker on n2 retries before logging, so poll for the
  # expected rows rather than sleeping a fixed time.  On 4.0 the
  # duplicate key on INSERT and the missing rows on UPDATE and DELETE
  # are all errors, so each one should leave one exception log entry.
  echo "Waiting for the exception log on ${peer_names[0]}..."
  for attempt in $(seq 1 60); do
    elog_entries=$(PGPASSWORD=$DBPASSWD psql -X -A -t -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "
      SELECT string_agg(e.operation, ',' ORDER BY e.operation)
      FROM spock.exception_log e
      JOIN spock.node n
      ON e.remote_origin = n.node_id
      WHERE n.node_name = 'n1'
      AND e.table_name = 't4';
      ") || elog_entries=""

    if [ "$elog_entries" = "DELETE,INSERT,UPDATE" ]; then
      break
    fi
    sleep 1
  done

  if [ "$elog_entries" = "DELETE,INSERT,UPDATE" ];
  then
    echo "PASS: Found the INSERT, UPDATE and DELETE exception log entries for t4"
  else
    PGPASSWORD=$DBPASSWD psql -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "select * from spock.exception_log;"
    echo "FAIL: Exception log entries for t4 are incorrect (found: '${elog_entries}')"
    exit 1
  fi
fi

spockbench -h /tmp -i -s $SCALEFACTOR demo || exit 1
psql -U admin -h /tmp -d demo -c "select spock.convert_sequence_to_snowflake('pgbench_history_hid_seq');" || exit 1
psql -U admin -h /tmp -d demo -c "alter table pgbench_accounts alter column abalance set(log_old_value=true, delta_apply_function=spock.delta_apply);" || exit 1
psql -U admin -h /tmp -d demo -c "alter table pgbench_branches alter column bbalance set(log_old_value=true, delta_apply_function=spock.delta_apply);" || exit 1
psql -U admin -h /tmp -d demo -c "alter table pgbench_tellers alter column tbalance set(log_old_value=true, delta_apply_function=spock.delta_apply);" || exit 1

psql -U admin -h /tmp -d demo -c "select spock.repset_add_all_tables('demo_replication_set', '{public}');" || exit 1

# n1 runs the exception log test first, so wait until every node has
# its pgbench tables loaded and in the set before any of them sends
# changes.
touch $marker_dir/ready-$HOSTNAME
wait_for_all ready

# ==========Spockbench tests ========== 
spockbench -h /tmp --spock-num-nodes=3 --spock-node=${HOSTNAME:0-1} -s $SCALEFACTOR -T $RUNTIME -R $RATE -P 5 -j $THREADS -c $CONNECTIONS -n --spock-tx-mix=550,225,225 -U admin demo || exit 1
spockbench-check -U admin demo > /home/pgedge/spock/spockbench-$HOSTNAME.out || exit 1
grep -q "ERROR" /home/pgedge/spock/spockbench-$HOSTNAME.out && exit 1

# Every subscriber must have received everything this node wrote.  A
# subscriber whose apply worker keeps failing never confirms it, so
# this fails rather than hangs.  The peers stay up until all nodes are
# done, so they are there to confirm.
psql -X -U admin -h /tmp -d demo -c "SET statement_timeout = '300s'; SELECT spock.wait_slot_confirm_lsn(NULL, NULL);" || {
  echo "FAIL: subscribers of $HOSTNAME did not catch up"
  exit 1
}

# Once every node is past that, each has applied everything its peers
# wrote, so its exception log is complete.
touch $marker_dir/confirmed-$HOSTNAME
wait_for_all confirmed

# A transaction that failed to apply is logged and skipped, and still
# counts as confirmed above, so look for any beyond the three t4
# entries the exception log test expects on n2.
unexpected=$(psql -X -A -t -U admin -h /tmp -d demo -c "SELECT count(*) FROM spock.exception_log WHERE table_name IS DISTINCT FROM 't4'") || exit 1
if [ "$unexpected" != 0 ]; then
  psql -X -U admin -h /tmp -d demo -c "SELECT * FROM spock.exception_log WHERE table_name IS DISTINCT FROM 't4'"
  echo "FAIL: $unexpected unexpected exception log entries on $HOSTNAME"
  exit 1
fi

touch $marker_dir/done-$HOSTNAME
wait_for_all done
exit 0
