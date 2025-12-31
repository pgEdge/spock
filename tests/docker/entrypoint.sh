#!/bin/bash
set -e

function wait_for_pg()
{
  count=0
  while ! pg_isready -h /tmp; do
    if [ $count -ge 24 ]
    then
      echo "Gave up waiting for PostgreSQL to become ready..."
      exit 1
    fi

    echo "Waiting for PostgreSQL to become ready..."
    sleep 5
  done
}

. /home/pgedge/.bashrc

echo "==========Installing Spockbench=========="
cd ~/spockbench
sudo python3 setup.py install

cd ~/pgedge

# Initialize PostgreSQL if not already done
if [ ! -d "data/pg$PGVER" ]; then
  echo "==========Initializing PostgreSQL $PGVER=========="

  # Initialize the database cluster
  pg${PGVER}/bin/initdb -D data/pg${PGVER} --encoding=UTF8 --locale=C

  # Configure PostgreSQL with settings from regress-postgresql.conf
  cat >> data/pg${PGVER}/postgresql.conf <<EOF

# Spock configuration
shared_preload_libraries = 'spock'
wal_level = logical
max_wal_senders = 20
max_replication_slots = 20
max_worker_processes = 20
track_commit_timestamp = on
max_locks_per_transaction = 1000

# Connection settings
unix_socket_directories = '/tmp'
listen_addresses = '*'
port = 5432

# Logging
log_line_prefix = '[%m] [%p] [%d] '
log_min_messages = debug1

# Performance (for testing)
fsync = off

# Spock settings
spock.synchronous_commit = true
EOF

  # Configure pg_hba.conf for network access
  cat >> data/pg${PGVER}/pg_hba.conf <<EOF

# Allow replication connections
host    replication     all             0.0.0.0/0               trust
host    all             all             0.0.0.0/0               trust
EOF

  # Start PostgreSQL
  pg${PGVER}/bin/pg_ctl -D data/pg${PGVER} -l data/pg${PGVER}/logfile start

  wait_for_pg

  # Create database and user
  export DBUSER=${DBUSER:-pgedge}
  export DBNAME=${DBNAME:-demo}

  pg${PGVER}/bin/createuser -h /tmp -s $DBUSER 2>/dev/null || true
  pg${PGVER}/bin/createdb -h /tmp -O $DBUSER $DBNAME 2>/dev/null || true

  echo "==========PostgreSQL $PGVER initialized successfully=========="
else
  # PostgreSQL already initialized, just start it
  pg${PGVER}/bin/pg_ctl -D data/pg${PGVER} -l data/pg${PGVER}/logfile start
  wait_for_pg
fi

# Ensure environment variables are set
export DBUSER=${DBUSER:-pgedge}
export DBNAME=${DBNAME:-demo}

psql -h /tmp -U $DBUSER -d $DBNAME -c "drop extension if exists spock;"
psql -h /tmp -U $DBUSER -d $DBNAME -c "drop schema public cascade;"
psql -h /tmp -U $DBUSER -d $DBNAME -c "create schema public;"
psql -h /tmp -U $DBUSER -d $DBNAME -c "create extension spock;"

# Restart PostgreSQL to apply all settings
pg${PGVER}/bin/pg_ctl -D data/pg${PGVER} restart -l data/pg${PGVER}/logfile

wait_for_pg

echo "==========Assert Spock version is the latest=========="
expected_line=$(grep '#define SPOCK_VERSION' /home/pgedge/spock/spock.h)
expected_version=$(echo "$expected_line" | grep -oP '"\K[0-9]+\.[0-9]+\.[0-9]+')
expected_major=${expected_version%%.*}
actual_version=$(psql -U $DBUSER -d $DBNAME -X -t -A -c "select spock.spock_version()")
actual_major=${actual_version%%.*}

if (( actual_major >= expected_major )); then
  echo " Actual major version ($actual_major) >= expected ($expected_major)"
else
  echo " Actual major version ($actual_major) is not what we expected ($expected_major)"
  exit 1
fi


echo "==========Creating tables and repsets=========="
./pgedge spock node-create $HOSTNAME "host=$HOSTNAME user=pgedge dbname=$DBNAME" $DBNAME
./pgedge spock repset-create demo_replication_set $DBNAME

IFS=',' read -r -a peer_names <<< "$PEER_NAMES"

for PEER_HOSTNAME in "${peer_names[@]}";
do
  while :
    do
      mapfile -t node_array < <(psql -A -t $DBNAME -h $PEER_HOSTNAME -c "SELECT node_name FROM spock.node;")
      for element in "${node_array[@]}";
      do
        if [[ "$element" == "$PEER_HOSTNAME" ]]; then
            break 2
        fi
      done
      sleep 1
      echo "Waiting for $PEER_HOSTNAME..."
    done
done

# TODO: Re-introduce parallel slots at a later point when the apply worker restarts are handled correctly
# and transactions are not skipped on restart in parallel mode
./pgedge spock sub-create sub_${peer_names[0]}$HOSTNAME   "host=${peer_names[0]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[0]}$HOSTNAME"_1 "host=${peer_names[0]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[0]}$HOSTNAME"_2 "host=${peer_names[0]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[0]}$HOSTNAME"_3 "host=${peer_names[0]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[0]}$HOSTNAME"_4 "host=${peer_names[0]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME

./pgedge spock sub-create sub_${peer_names[1]}$HOSTNAME   "host=${peer_names[1]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[1]}$HOSTNAME"_1 "host=${peer_names[1]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[1]}$HOSTNAME"_2 "host=${peer_names[1]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[1]}$HOSTNAME"_3 "host=${peer_names[1]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME
#./pgedge spock sub-create "sub_${peer_names[1]}$HOSTNAME"_4 "host=${peer_names[1]} port=5432 user=pgedge dbname=$DBNAME" $DBNAME

psql -U $DBUSER -h /tmp -d $DBNAME -c "create table t1 (id serial primary key, data int8);"
psql -U $DBUSER -h /tmp -d $DBNAME -c "create table t2 (id serial primary key, data int8);"
psql -U $DBUSER -h /tmp -d $DBNAME -c "alter table t1 alter column data set (log_old_value=true, delta_apply_function=spock.delta_apply);"

./pgedge spock sub-add-repset sub_${peer_names[0]}$HOSTNAME demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[0]}$HOSTNAME"_1 demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[0]}$HOSTNAME"_2 demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[0]}$HOSTNAME"_3 demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[0]}$HOSTNAME"_4 demo_replication_set $DBNAME

./pgedge spock sub-add-repset sub_${peer_names[1]}$HOSTNAME demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[1]}$HOSTNAME"_1 demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[1]}$HOSTNAME"_2 demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[1]}$HOSTNAME"_3 demo_replication_set $DBNAME
#./pgedge spock sub-add-repset "sub_${peer_names[1]}$HOSTNAME"_4 demo_replication_set $DBNAME


cd /home/pgedge && ./run-tests.sh $peer_names
