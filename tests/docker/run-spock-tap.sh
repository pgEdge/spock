#!/bin/bash
###
### Run selected TAP tests iteratively
###


export PG_CONFIG=/home/pgedge/pgedge/pg${PGVER}/bin/pg_config
export PATH=/home/pgedge/pgedge/pg${PGVER}/bin:$PATH
export LD_LIBRARY_PATH=/home/pgedge/pgedge/pg${PGVER}/lib/:$LD_LIBRARY_PATH

# PGVER should be previously set in the environment
if [ -z "${PGVER}" ]
then
	echo "The PGVER environment variable must be set before running this command"
	exit 1
fi

proven_tests="$1"
iterations="$2"
if [[ -z "$proven_tests" || -z "$iterations" ]]; then
    echo "Command-line parameters are set incorrectly"
    exit 1
fi

cd /home/pgedge/spock/

status=0
for i in $(seq 1 $iterations); do
    echo "Iteration $i: running make check..."
    env PROVE_TESTS="$proven_tests" make check_prove 1>out.txt 2>err.txt
    status=$?
    if [ $status -ne 0 ]; then
        echo "make check failed with status $status on iteration $i"
        break
    fi
done

if [ $status -ne 0 ]
then
	echo "Errors in regression checks"
	exit 1
fi
