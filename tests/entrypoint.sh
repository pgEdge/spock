#!/bin/bash
set -e

#echo "Setting up pgedge..."
#cd /home/pgedge
#curl -fsSL https://pgedge-download.s3.amazonaws.com/REPO/install.py > /home/pgedge/install.py
#sudo -u pgedge python3 /home/pgedge/install.py
#cd pgedge && ./pgedge setup -U $DBUSER -P $DBPASSWD -d $DBNAME --pg_ver=$PGVER && ./pgedge stop
#

. /home/pgedge/pgedge/pg$PGVER/pg$PGVER.env
. /home/pgedge/.bashrc

echo "==========Installing Spockbench=========="
cd ~/spockbench
sudo python3 setup.py install

cd ~/pgedge
sed -i '/log_min_messages/s/^#//g' data/pg$PGVER/postgresql.conf
sed -i -e '/log_min_messages =/ s/= .*/= debug1/' data/pg$PGVER/postgresql.conf
./pgedge restart

while ! pg_isready -h /tmp; do
  echo "Waiting for PostgreSQL to become ready..."
  sleep 1
done

psql -h /tmp -U $DBUSER -d $DBNAME -c "drop extension spock;"
psql -h /tmp -U $DBUSER -d $DBNAME -c "drop schema public cascade;"
psql -h /tmp -U $DBUSER -d $DBNAME -c "create schema public;"
psql -h /tmp -U $DBUSER -d $DBNAME -c "create extension spock;"

./pgedge restart

while ! pg_isready -h /tmp; do
  echo "Waiting for PostgreSQL to become ready..."
  sleep 1
done

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
