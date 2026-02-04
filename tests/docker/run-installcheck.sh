#!/bin/bash
###
### Run standard PostgreSQL regression tests on the existing cluster
### using pg_regress directly with the parallel_schedule.
###

source "${HOME}/.bashrc"

# PGDATABASE should be previously set in the environment
if [ -z "${PGDATABASE}" ]; then
	echo "The PGDATABASE environment variable must be set before running this command"
	exit 1
fi

# Get paths from pg_config
BINDIR="$(${PG_CONFIG} --bindir)"
LIBDIR="$(${PG_CONFIG} --libdir)"
PG_REGRESS="${LIBDIR}/postgresql/pgxs/src/test/regress/pg_regress"

# Standard PostgreSQL regression test directory (from source)
# PG_SRCDIR is set in .bashrc (sourced above)
INPUTDIR="${PG_SRCDIR}/src/test/regress"
SCHEDULE="${INPUTDIR}/parallel_schedule"

# Output directory for regression results
OUTPUTDIR="/home/pgedge/installcheck-output"
mkdir -p ${OUTPUTDIR}

echo "# +++ PostgreSQL regression install-check +++"

# Run pg_regress with the parallel_schedule (standard PostgreSQL tests)
${PG_REGRESS} \
	--dlpath=${PG_SRCDIR}/src/test/regress/	\
	--inputdir=${INPUTDIR} \
	--outputdir=${OUTPUTDIR} \
	--bindir=${BINDIR} \
	--schedule=${SCHEDULE} \
	--dbname=${PGDATABASE} \
	--use-existing \
	--host=/tmp \
	--port=${PGPORT} \
	--user=${PGUSER}

RESULT=$?

if [ $RESULT -ne 0 ]; then
	cat ${OUTPUTDIR}/regression.diffs 2>/dev/null
	echo "Errors in installcheck"
	exit 1
fi
