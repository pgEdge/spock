#!/bin/bash

set -ae

peer_names=$1

# ==========Spockbench tests ========== 
#spockbench -h /tmp --spock-num-nodes=3 --spock-node=${HOSTNAME:0-1} -s 10 -T 600 -R 3000 -P 5 -j 16 -c 50 -n --spock-tx-mix=550,225,225 -U admin demo
#spockbench-check -U admin demo > /home/pgedge/spock-private/spockbench-$HOSTNAME.out


spock_version=$(psql -U $DBUSER -d $DBNAME -A -t -h /tmp -c "select spock.spock_version();")

if [ $spock_version == "4.0" ];
then
  #========== Error Log tests ========== 

  # We perform the following tests in two cases:
  # a. Table containing delta-apply columns
  # b. Table without delta-apply columns
  #
  # 1. INSERT: Duplicate pkey, Duplicate secondary constraint
  # 2. UPDATE: Row not found, duplicate secondary constraint
  # 3. DELETE: Row not found

  psql -U $DBUSER -d $DBNAME -h /tmp -c "insert into t2 values(1,100);" &

  PGPASSWORD=$DBPASSWD psql -U $DBUSER -d $DBNAME -h ${peer_names[0]} -c "insert into t2 values(1,200);" &

  wait

  psql -U $DBUSER -d $DBNAME -h /tmp -c "select * from spock.error_log;"
fi
