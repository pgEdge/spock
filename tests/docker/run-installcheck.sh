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

# Output directory for regression results
OUTPUTDIR="/home/pgedge/installcheck-output"
mkdir -p ${OUTPUTDIR}

# rowtypes_alter and attribute_version (new in 15.20, 16.16,
# 17.12, 18.7 and 19rc2) store composite values that can no longer
# be read, on purpose.  Decoding those INSERTs has to read them, so
# every output plugin, pgoutput included, fails there and this
# node's walsenders never get past it.  Leave the two tests out.
SCHEDULE="${OUTPUTDIR}/parallel_schedule"
if ! awk '/^test:/ {
		s = "test:"
		for (i = 2; i <= NF; i++)
			if ($i != "rowtypes_alter" && $i != "attribute_version")
				s = s " " $i
		if (s != "test:") print s
		next
	} { print }' "${INPUTDIR}/parallel_schedule" >"${SCHEDULE}" ||
	! grep -q '^test:' "${SCHEDULE}"; then
	echo "could not filter ${INPUTDIR}/parallel_schedule" >&2
	exit 1
fi

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
