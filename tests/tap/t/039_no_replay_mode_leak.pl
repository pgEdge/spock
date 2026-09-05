use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status
    log_offset log_since wait_for_log sync_nodes apply_worker_pid
    poll_query_until
);

# An ERROR raised in the apply worker BETWEEN two remote transactions sends
# apply_work() into replay mode with an empty replay queue -- handle_commit()
# reset the queue when the last transaction committed, so there is nothing
# queued to replay.  MyApplyWorker->use_try_block lives in the worker's shared
# memory slot rather than in per-transaction state, so it then belongs to
# whichever transaction the provider sends next: one that has never been
# attempted, let alone failed.
#
# handle_begin() is where that has to be caught.  The exception log entry
# carries the commit_lsn of the recorded failure, and an incoming transaction
# whose commit_lsn does not match it is not that failure, so replay mode must
# be turned off and the entry dropped.  Left on under transdiscard or
# sub_disable, every action of the healthy transaction runs in a subtransaction
# that is rolled back unconditionally: the pass applies nothing, and what the
# operator sees is the exception policy firing on data that never failed.
#
# pg_cancel_backend() is what makes the window reachable from SQL.  An idle
# apply worker sits in WaitLatchOrSocket() followed by CHECK_FOR_INTERRUPTS(),
# which is between remote transactions by construction, and the cancel raises
# 57014 there exactly once -- ProcessInterrupts() clears QueryCancelPending
# before it throws.  57014 is not one of the transient SQLSTATEs covered by
# 035_deadlock_retry.pl, so it takes the replay path rather than the
# rethrow-and-restart path, which is the whole point: the worker stays up,
# carrying replay mode into the next transaction.

create_cluster(2, 'Create 2-node replay mode leak cluster');

my $config = get_test_config();
my $p1 = $config->{node_ports}->[0];
my $conn = "host=$config->{host} dbname=$config->{db_name} port=$p1 " .
           "user=$config->{db_user} password=$config->{db_password}";

# Both modes discard the whole transaction on exception, so both turn a
# leaked replay pass into a transaction the subscriber never applies.  discard
# is not covered: it commits each successful action, so a healthy transaction
# replayed under it still lands and there is nothing to observe.
#
# leaked is what handle_commit() logs when it takes the branch guarded by
#
#     !xact_had_exception && MyApplyWorker->use_try_block &&
#     (exception_behaviour == TRANSDISCARD || SUB_DISABLE)
#
# which is the leak itself: a transaction that raised nothing, running under a
# use_try_block left on by an earlier failure.  The two modes word it
# differently, so the pattern belongs to the phase.
my @modes = (
    { mode   => 'transdiscard',
      table  => 'leak_transdiscard',
      leaked => qr/Transaction discarded in TRANSDISCARD mode/ },
    { mode   => 'sub_disable',
      table  => 'leak_sub_disable',
      leaked => qr/Transaction failed, subscription will be disabled/ },
);

# Created before sub_create so that no DDL is replicated during the test.
for my $phase (@modes) {
    psql_or_bail(1, "CREATE TABLE $phase->{table} (id int PRIMARY KEY, val text)");
    psql_or_bail(2, "CREATE TABLE $phase->{table} (id int PRIMARY KEY, val text)");
}

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

for my $phase (@modes) {
    my $t    = $phase->{table};
    my $mode = $phase->{mode};

    psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = $mode");
    psql_or_bail(2, "SELECT pg_reload_conf()");

    # pg_reload_conf() only signals the postmaster, so the running worker can
    # still hold the old value.  Restart it rather than race.  A forked
    # bgworker inherits the postmaster's settings rather than re-reading the
    # file, so what makes this safe is that the postmaster applies a pending
    # reload before it reaps and respawns children, and the reload above is
    # requested before the terminate below.  The manager then respawns after
    # restart_delay, which handle_begin() leaves at 0.
    my $stale = apply_worker_pid(2, 'sub_n1_n2');
    psql_or_bail(2, "SELECT pg_terminate_backend($stale)");
    ok(poll_query_until(2,
           "SELECT pid <> $stale FROM pg_stat_activity " .
           "WHERE application_name LIKE 'spock apply %:' || " .
           "(SELECT sub_id FROM spock.subscription " .
           "WHERE sub_name = 'sub_n1_n2')::text", 't', 60),
       "$mode: apply worker restarts under the new exception_behaviour");

    # A clean transaction first: it is what leaves a commit_lsn behind in the
    # worker's exception log slot, which is what the incoming transaction is
    # compared against after the cancel.
    psql_or_bail(1, "INSERT INTO $t VALUES (1, 'before cancel')");

    # Leaves the worker between transactions with nothing queued, the state
    # the cancel needs.
    ok(sync_nodes(1, 2),
        "$mode: apply worker drained and idle before the cancel");

    is(scalar_query(2, "SELECT count(*) FROM $t WHERE id = 1"), '1',
        "$mode: baseline transaction replicates");

    my $pid_before = apply_worker_pid(2, 'sub_n1_n2');
    like($pid_before, qr/^\d+$/, "$mode: found the apply worker ($pid_before)");

    my $offset = log_offset(2);
    is(scalar_query(2, "SELECT pg_cancel_backend($pid_before)"), 't',
        "$mode: cancel signal sent to the apply worker");

    ok(wait_for_log(2,
            qr/caught initial exception.*57014.*canceling statement due to user request/,
            $offset, 30),
        "$mode: worker takes the replay path for the cancel");

    # It caught its own error rather than exiting, so it is now sitting in
    # replay mode with an empty queue.  Without that, the rest proves nothing.
    is(apply_worker_pid(2, 'sub_n1_n2'), $pid_before,
        "$mode: worker stays up in replay mode after the cancel");

    # The transaction that must not be treated as the recorded failure.
    psql_or_bail(1, "INSERT INTO $t VALUES (2, 'after cancel')");
    ok(sync_nodes(1, 2),
        "$mode: worker consumes the stream past the next transaction");

    is(scalar_query(2, "SELECT count(*) FROM $t WHERE id = 2"), '1',
        "$mode: the next transaction applies");

    unlike(log_since(2, $offset), $phase->{leaked},
        "$mode: the transaction is not replayed as if it had failed");
    is(apply_worker_pid(2, 'sub_n1_n2'), $pid_before,
        "$mode: worker is not restarted by the healthy transaction");
    is(scalar_query(2,
           "SELECT count(*) FROM spock.exception_log WHERE table_name = '$t'"),
       '0', "$mode: nothing is logged to exception_log");
    is(scalar_query(2,
           "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
       't', "$mode: subscription is not disabled");
    ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
        "$mode: subscription stays in replicating state");
}

destroy_cluster('Destroy replay mode leak cluster');
done_testing();
