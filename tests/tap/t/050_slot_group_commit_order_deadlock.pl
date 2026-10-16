use strict;
use warnings;
use Test::More;
use POSIX qw(WNOHANG);
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status log_offset log_since
);

# =============================================================================
# Test 050: commit-order deadlock between apply workers of one slot group
# =============================================================================
# Subscriptions sub_1 and sub_2 from the same provider get slots ending in _1
# and _2, so the provider's walsenders form a slot group: each transaction is
# sent by whichever of them claims it first, and the subscriber's apply
# workers commit in the provider's commit order.
#
# That order is enforced at commit, after the rows are applied, so a worker
# waiting for its turn holds row locks while it sleeps on a condition
# variable.  The lock manager sees only lock waits, so a cycle that runs
# through that sleep is invisible to the deadlock detector, and before the
# fix both workers waited forever.  The later transaction must now give way:
# roll back, and apply the same transaction again from its replay queue,
# without restarting.  A restart would lose it, because the provider's slot
# group has already handed it out and does not send it a second time.
#
# Two shapes of the cycle are forced, each with a local session on the
# subscriber holding a row lock at the right moment:
#
#   direct   A: rows 1, 2    B: row 2     A stalls on row 1, held locally;
#            B applies row 2 and waits for A's commit; A then needs row 2.
#            B is waiting for A, A is waiting for B.
#
#   indirect A: row 2        B: row 1     the local session holds row 2 and
#            then asks for row 1, which B holds while waiting for A's commit;
#            A is blocked on the local session.  B is waiting for A, A for
#            the session, the session for B: the wait reaches B through a
#            process that is not an apply worker at all.
#
# Which walsender claims a transaction is normally a race between them.  A
# carries a few megabytes of filler after its first update, so that while
# A's apply worker is blocked on the local session its walsender fills the
# connection and stops decoding; the other walsender then has to claim B.
# Each trial is driven by state, not by timers: the test waits until the
# local session holds its lock before it writes on the provider, and the
# local session waits until one apply worker is blocked on it and two are
# mid-transaction before it takes its next step.  Should A and B still go to
# the same worker, that state never comes, the session gives up after a few
# seconds, and the trial is repeated.
# =============================================================================

my $TRIALS = 10;

create_cluster(2, 'Create 2-node cluster for the slot-group deadlock test');

my $config  = get_test_config();
my $host    = $config->{host};
my $dbname  = $config->{db_name};
my $db_user = $config->{db_user};
my $pw      = $config->{db_password};
my @ports   = @{$config->{node_ports}};
my $pg_bin  = $config->{pg_bin};
my $log_dir = $config->{log_dir};

my $provider_dsn = "host=$host dbname=$dbname port=$ports[0] user=$db_user password=$pw";

psql_or_bail(1, "CREATE TABLE t (id int PRIMARY KEY, v int NOT NULL)");
psql_or_bail(1, "INSERT INTO t VALUES (1, 0), (2, 0)");
psql_or_bail(1, "CREATE TABLE filler (id bigserial PRIMARY KEY, pad text)");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_1', '$provider_dsn', ARRAY['default'], true, true)");
ok(wait_for_sub_status(2, 'sub_1', 'replicating', 60), 'sub_1 is replicating');
psql_or_bail(2,
    "SELECT spock.sub_create('sub_2', '$provider_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub_2', 'replicating', 60), 'sub_2 is replicating');

is(scalar_query(2, "SELECT count(*) FROM t"), '2', 'the table reached the subscriber');
is(scalar_query(2, "SELECT count(*) FROM filler"), '0', 'so did the filler table');

# Enough data in one transaction to fill a stalled walsender's connection.
my $filler = "INSERT INTO filler (pad) SELECT repeat('x', 200) FROM generate_series(1, 20000);";
like(scalar_query(1,
    "SELECT string_agg(slot_name, ',' ORDER BY slot_name) FROM pg_replication_slots " .
    " WHERE slot_name LIKE 'spk_%'"),
    qr/_sub_1,.*_sub_2$/, 'the two slots share a slot-group name');

# Wait until the subscriber holds the provider's values.
sub converged {
    my ($secs) = @_;
    my $want = scalar_query(1, "SELECT string_agg(id || '=' || v, ',' ORDER BY id) || '; filler=' || " .
                 "(SELECT count(*) FROM filler) FROM t");
    for (1 .. $secs * 2) {
        my $got = scalar_query(2, "SELECT string_agg(id || '=' || v, ',' ORDER BY id) || '; filler=' || " .
                 "(SELECT count(*) FROM filler) FROM t");
        return 1 if defined $got && $got eq $want;
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

# Inside the local session: wait until an apply worker is blocked on a lock
# and two apply workers are in the middle of a transaction, which is the
# state the cycle needs, for at most five seconds.
my $await_cycle = q{
DO $$
DECLARE
    i int := 0;
BEGIN
    LOOP
        EXIT WHEN i >= 100 OR (
            EXISTS (SELECT 1 FROM pg_stat_activity
                     WHERE backend_type LIKE 'spock apply%'
                       AND wait_event_type = 'Lock')
            AND (SELECT count(*) FROM pg_locks l
                   JOIN pg_stat_activity a USING (pid)
                  WHERE a.backend_type LIKE 'spock apply%'
                    AND l.locktype = 'transactionid'
                    AND l.mode = 'ExclusiveLock'
                    AND l.granted) >= 2);
        PERFORM pg_sleep(0.05);
        i := i + 1;
    END LOOP;
END
$$;
};

# Run one shape of the cycle until a trial produces the deadlock.  The local
# session's statements run in one psql so that its locks stay held between
# them; its output is checked afterwards, since it must commit cleanly once
# the victim has given way.
sub run_shape {
    my ($label, $holder_sql, $txn_a, $txn_b) = @_;
    my $deadlocks = 0;

    for my $trial (1 .. $TRIALS) {
        my $log_off = log_offset(2);
        my $holder_out = "$log_dir/050_${label}_holder_$trial.out";
        my $holder = fork();
        die "fork failed" unless defined $holder;
        if ($holder == 0) {
            open(STDOUT, '>', $holder_out) or exit(1);
            open(STDERR, '>&', \*STDOUT);
            $ENV{PGAPPNAME} = '050_holder';
            exec("$pg_bin/psql", '-X', '-h', $host, '-p', $ports[1], '-d', $dbname,
                 '-U', $db_user, '-At', '-v', 'ON_ERROR_STOP=1', '-c', $holder_sql)
                or exit(1);
        }

        # FOR UPDATE gives the session a transaction id; once it holds that,
        # it holds the row lock too.
        my $locked = 0;
        for (1 .. 40) {
            if (scalar_query(2,
                    "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING (pid) " .
                    " WHERE a.application_name = '050_holder' " .
                    "   AND l.locktype = 'transactionid' AND l.granted") ne '0') {
                $locked = 1;
                last;
            }
            select(undef, undef, undef, 0.25);
        }
        unless ($locked) {
            kill 'KILL', $holder;
            waitpid($holder, 0);
            fail("$label, trial $trial: the local session took its row lock");
            last;
        }

        psql_or_bail(1, $txn_a);
        psql_or_bail(1, $txn_b);

        # If the cycle is not broken, the local session never finishes; bound
        # the wait so the trial fails instead of hanging the suite.
        my $holder_rc;
        for (1 .. 120) {
            if (waitpid($holder, WNOHANG) == $holder) {
                $holder_rc = $? >> 8;
                last;
            }
            select(undef, undef, undef, 0.5);
        }
        unless (defined $holder_rc) {
            kill 'KILL', $holder;
            waitpid($holder, 0);
            fail("$label, trial $trial: the local session finished within 60s");
            last;
        }

        my $ok = converged(60);
        ok($ok, "$label, trial $trial: the subscriber caught up with the provider");

        my $log = log_since(2, $log_off);
        next unless $log =~ /deadlock between apply workers of the same apply group/;

        $deadlocks++;
        like($log, qr/applying the transaction again/,
             "$label, trial $trial: the victim applied its transaction again in place");
        unlike($log, qr/apply worker .* exiting with error/,
               "$label, trial $trial: no apply worker exited");
        is($holder_rc, 0, "$label, trial $trial: the local session committed");
        last;
    }

    ok($deadlocks, "$label: the commit-order deadlock was detected and broken")
        or diag("$label: the two transactions never went to different workers in $TRIALS trials");
}

run_shape('direct',
    "BEGIN; SELECT v FROM t WHERE id = 1 FOR UPDATE; $await_cycle COMMIT;",
    "BEGIN; UPDATE t SET v = v + 1 WHERE id = 1; $filler UPDATE t SET v = v + 10 WHERE id = 2; COMMIT;",
    "UPDATE t SET v = v + 100 WHERE id = 2");

run_shape('indirect',
    "BEGIN; SELECT v FROM t WHERE id = 2 FOR UPDATE; $await_cycle " .
    "SELECT v FROM t WHERE id = 1 FOR UPDATE; COMMIT;",
    "BEGIN; UPDATE t SET v = v + 1 WHERE id = 2; $filler COMMIT;",
    "UPDATE t SET v = v + 10 WHERE id = 1");

# --------------------------------------------------------------------------
# A lock timeout in a slot-group transaction
#
# Any abort that restarts the worker loses a slot-group transaction, because
# the provider's slot group has already handed it out and skips it when the
# restarted walsender decodes it again.  A real lock wait that ends in
# lock_timeout, or a real deadlock, must therefore be retried in place too.
# --------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM SET lock_timeout = '500ms'");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(1);

{
    my $log_off = log_offset(2);
    my $holder = fork();
    die "fork failed" unless defined $holder;
    if ($holder == 0) {
        open(STDOUT, '>', "$log_dir/050_lock_timeout_holder.out") or exit(1);
        open(STDERR, '>&', \*STDOUT);
        $ENV{PGAPPNAME} = '050_holder';
        exec("$pg_bin/psql", '-X', '-h', $host, '-p', $ports[1], '-d', $dbname,
             '-U', $db_user, '-At', '-v', 'ON_ERROR_STOP=1', '-c',
             "SET lock_timeout = 0; BEGIN; SELECT v FROM t WHERE id = 1 FOR UPDATE; " .
             "SELECT pg_sleep(4); COMMIT;")
            or exit(1);
    }
    my $locked = 0;
    for (1 .. 40) {
        if (scalar_query(2,
                "SELECT count(*) FROM pg_locks l JOIN pg_stat_activity a USING (pid) " .
                " WHERE a.application_name = '050_holder' " .
                "   AND l.locktype = 'transactionid' AND l.granted") ne '0') {
            $locked = 1;
            last;
        }
        select(undef, undef, undef, 0.25);
    }
    ok($locked, 'lock timeout: the local session took its row lock');

    psql_or_bail(1, "UPDATE t SET v = v + 1000 WHERE id = 1");
    waitpid($holder, 0);

    ok(converged(60), 'lock timeout: the subscriber caught up with the provider');
    my $log = log_since(2, $log_off);
    like($log, qr/canceling statement due to lock timeout; applying the transaction again/,
         'lock timeout: the transaction was applied again in place');
    unlike($log, qr/apply worker .* exiting with error/,
           'lock timeout: no apply worker exited');
}

psql_or_bail(2, "ALTER SYSTEM RESET lock_timeout");
psql_or_bail(2, "SELECT pg_reload_conf()");

is(scalar_query(2,
    "SELECT count(*) FROM spock.sub_show_status() WHERE status = 'replicating'"),
   '2', 'both subscriptions are still replicating');

destroy_cluster('Destroy cluster after the slot-group deadlock test');
done_testing();
