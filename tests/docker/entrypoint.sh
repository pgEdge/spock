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

echo "==========Installing Spockbench=========="
cd ~/spockbench
sudo python3 setup.py install

cd ~/pgedge

# Paths to the Postgres binaries and CLI
#export PATH=/home/pgedge/pgedge/pg${PGVER}/bin:$PATH
#export LD_LIBRARY_PATH=/home/pgedge/pgedge/pg${PGVER}/lib:/usr/lib64:/lib64

# Initialize the database cluster
# We avoid 'pgedge setup' command to not download meaningless repo. Hence,
# initialise repository in our own.
#mkdir data


echo "PGHOME=`pwd`/pg17" > pg17.env
echo "PGDATA=`pwd`/data/pg17" >> pg17.env
echo "PGUSER=admin" >> pg17.env
echo "PGDATABASE=demo" >> pg17.env
echo "PGPORT=5432" >> pg17.env

pgedge init pg17

mkdir data/pg${PGVER}
~/pgedge/pg${PGVER}/bin/initdb -D data/pg${PGVER} --encoding=UTF8 --locale=C

sed -i '/log_min_messages/s/^#//g' data/pg$PGVER/postgresql.conf
sed -i -e '/log_min_messages =/ s/= .*/= debug1/' data/pg$PGVER/postgresql.conf

pgedge start pg17

wait_for_pg

psql -h /tmp -U $DBUSER -d $DBNAME -c "SELECT version()"
