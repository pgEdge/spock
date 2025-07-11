#!/bin/bash
###
### Run the regression tests
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

CWD=`pwd`
cd /home/pgedge/spock/

make regresscheck
RESULT=$?

if [ $RESULT -ne 0 ]
then
	cat /home/pgedge/spock/regression_output/regression.diffs
	echo "Errors in regression checks"
	exit 1
fi

