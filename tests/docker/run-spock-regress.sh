#!/bin/bash
###
### Run the regression tests
###

source "${HOME}/.bashrc"

# PGVER should be previously set in the environment
if [ -z "${PGVER}" ]
then
	echo "The PGVER environment variable must be set before running this command"
	exit 1
fi

cd /home/pgedge/spock/

make regresscheck
RESULT=$?

if [ $RESULT -ne 0 ]
then
	cat /home/pgedge/spock/tests/regress/regression_output/regression.diffs
	echo "Errors in regression checks"
	exit 1
fi

