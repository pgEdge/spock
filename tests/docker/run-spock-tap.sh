#!/bin/bash
###
### Run selected TAP tests iteratively
###

source "${HOME}/.bashrc"

# TAP tests create their own PostgreSQL instances via initdb, which only have
# the OS user (pgedge) as superuser. Unset Docker-specific credentials to avoid
# "role does not exist" errors.
unset PGUSER PGPASSWORD PGDATABASE

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

# How many trailing lines of each captured log to echo when a run fails.
# A nightly run produces tens of thousands of lines, so the complete files stay
# in the uploaded artifact and only the tail is printed here: enough to name the
# failing test and show its diagnostics, without drowning the workflow log.
fail_log_lines="${FAIL_LOG_LINES:-80}"

# Echo the captured output of a failed run to stdout.
#
# make's own output is redirected to out.txt/err.txt so that the workflow log
# does not carry the full TAP stream. The side effect used to be that a failing
# job showed nothing but "Process completed with exit code 1", and the actual
# cause could only be read by downloading the artifact. Print the tails here so
# the reason is visible in the job log itself.
report_failure()
{
    echo "=============================================================="
    echo "TAP run failed - last $fail_log_lines lines of each captured log"
    echo "(complete logs are in the uploaded artifact)"
    echo "=============================================================="

    for f in out.txt err.txt; do
        if [ -s "$f" ]; then
            echo "----- $f -----"
            tail -n "$fail_log_lines" "$f"
        fi
    done

    # A tail on its own is not always enough: when a test breaks early and then
    # spends the rest of its run timing out, the one error that explains it has
    # long scrolled past, and it is usually in a node's server log rather than
    # in the test's own log. So summarise the distinct errors across every log
    # the run produced, most frequent first. Digit runs are folded together so
    # that PIDs, OIDs and LSNs do not split one message into hundreds.
    if ls tests/tap/logs/*.log >/dev/null 2>&1; then
        echo "----- most frequent errors across all logs -----"
        grep -hoE '(FATAL|PANIC|ERROR):.*' tests/tap/logs/*.log \
            | sed 's/[0-9]\{4,\}/N/g' | sort | uniq -c | sort -rn | head -n 20
    fi

    # prove's summary block names every test file that failed; print the tail of
    # each one's own log for the immediate context around the failure.
    for t in $(awk '/^Test Summary Report/,0' out.txt 2>/dev/null \
               | sed -n 's|^t/\([0-9A-Za-z_]*\)\.pl .*|\1|p' | sort -u); do
        if [ -s "tests/tap/logs/$t.log" ]; then
            echo "----- tests/tap/logs/$t.log -----"
            tail -n "$fail_log_lines" "tests/tap/logs/$t.log"
        fi
    done
}

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
	report_failure
	echo "Errors in regression checks"
	exit 1
fi
