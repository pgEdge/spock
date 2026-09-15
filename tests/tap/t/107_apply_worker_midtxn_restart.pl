use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail system_maybe
    wait_for_sub_status poll_query_until
    log_offset log_since apply_worker_pid
);

# =============================================================================
# Test: 107_apply_worker_midtxn_restart.pl
# =============================================================================
# handle_begin() stamps exception_log->commit_lsn on every BEGIN, not just
# ones that fail. A worker restart landing mid-transaction let the
# provider's ordinary retransmission of that same transaction match the
# stale commit_lsn on the replacement worker's first BEGIN, misreading it
# as a prior apply failure and, under spock.exception_behaviour =
# sub_disable, disabling a healthy subscription for a transaction that
# never actually errored. Fixed by clearing the marker via
# clear_transient_exception_state() when apply_work() exits on got_SIGTERM.
#
# This is a v5_STABLE port of scenario 1 from pgEdge/spock PR 607's
# 046_apply_worker_exception_misclassification.pl (upstream commit
# addab034 on ups/main). That upstream test drives the restart via
# spock.sub_alter_options() toggling apply_delay, which does not exist on
# this branch (main/6.0-only RPC). Here the apply worker is bounced
# directly with pg_terminate_backend() instead -- both routes deliver a
# plain SIGTERM to the worker, so both exercise the same got_SIGTERM exit
# path in apply_work() that the fix touches. Scenario 2 (apply-idle-timeout
# misclassification) is out of scope: it depends on spock.apply_idle_timeout
# and the injection_points test module, neither of which exist on this
# branch.
# =============================================================================

create_cluster(2, 'Create 2-node apply-worker mid-transaction restart cluster');

my $config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin = $config->{pg_bin};
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $conn = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = sub_disable");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(1, "CREATE TABLE midtxn_restart (id bigint PRIMARY KEY, val text)");
psql_or_bail(1, "CREATE SEQUENCE midtxn_restart_id_seq");

# A PROCEDURE (not a DO block) can issue its own internal COMMITs, so a
# single long-lived connection produces a continuous stream of separately
# committed, multi-row transactions -- wide enough for a worker restart to
# land mid-transaction -- without the overhead of spawning one psql process
# per transaction.
psql_or_bail(1, q{
    CREATE PROCEDURE midtxn_restart_load(n_batches int, batch_rows int)
    LANGUAGE plpgsql AS $$
    DECLARE i int;
    BEGIN
        FOR i IN 1..n_batches LOOP
            INSERT INTO midtxn_restart
                SELECT nextval('midtxn_restart_id_seq'), 'x' || g
                FROM generate_series(1, batch_rows) g;
            COMMIT;
            -- Bulk INSERT...SELECT is fast enough to keep the apply side
            -- perpetually behind, so some transaction is always in flight
            -- (committed upstream, not yet fully applied downstream) when
            -- the restart loop below fires -- without that, a restart could
            -- always land between transactions and never actually exercise
            -- the bug.
            PERFORM pg_sleep(0.02);
        END LOOP;
    END $$;
});

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], true, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

my $offset = log_offset(2);

# Background writer, left running for the duration of the restart loop
# below. Killing the *client* process on its own would not reliably stop
# it -- Postgres does not proactively notice a dropped client connection
# while a backend is busy inside a single long-running CALL (no
# client_connection_check_interval by default) -- so it is stopped
# server-side afterwards via pg_terminate_backend().
my $writer_pid = fork();
die "fork() failed: $!" unless defined $writer_pid;
if ($writer_pid == 0) {
    exec("$pg_bin/psql", '-X', '-p', $p1, '-d', $dbname,
         '-c', "CALL midtxn_restart_load(100000, 500)")
        or exit(127);
}

note("Testing: repeated mid-transaction apply-worker restart via pg_terminate_backend");

# Bounce the apply worker with a direct SIGTERM (pg_terminate_backend) while
# the writer is running. handle_sigterm() in spock_worker.c is the same
# handler a manager-initiated restart would deliver to, so this reaches
# apply_work()'s got_SIGTERM exit path exactly as the original
# sub_alter_options()-driven restart did upstream. apply_worker_pid() polls
# for the current worker, so each iteration naturally waits out however long
# the manager actually takes to respawn one -- no guessed sleep between
# kills.
my $kills_issued = 0;
for my $i (1 .. 8) {
    my $apply_pid = apply_worker_pid(2, 'sub_n1_n2', 20);
    last unless $apply_pid;
    if (system_maybe("$pg_bin/psql", '-X', '-p', $p2, '-d', $dbname, '-c',
            "SELECT pg_terminate_backend($apply_pid)")) {
        $kills_issued++;
    }
}
ok($kills_issued >= 3,
    "issued at least 3 mid-load apply-worker restarts (got $kills_issued)");

# Stop the writer at the server: terminate the backend actually running the
# CALL, then confirm it is gone before treating n1's row count as final.
system_or_bail("$pg_bin/psql", '-X', '-p', $p1, '-d', $dbname, '-c',
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity " .
    "WHERE query LIKE 'CALL midtxn_restart_load%' AND pid <> pg_backend_pid()");
ok(poll_query_until(1,
        "SELECT count(*) FROM pg_stat_activity " .
        "WHERE query LIKE 'CALL midtxn_restart_load%'", '0', 30),
    'writer backend stopped');
kill('TERM', $writer_pid);
waitpid($writer_pid, 0);

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 90),
    'subscription is still replicating after repeated mid-load worker restarts');

is(scalar_query(2,
       "SELECT sub_enabled FROM spock.subscription WHERE sub_name = 'sub_n1_n2'"),
   't', 'SUB_DISABLE subscription remains enabled after repeated restarts');

my $count1 = scalar_query(1, "SELECT count(*) FROM midtxn_restart");
ok(poll_query_until(2, "SELECT count(*) FROM midtxn_restart", $count1, 120),
    'no rows lost/discarded across the restarts');

is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"),
   '0', 'no exceptions were ever logged');

# Verify the mechanism, not just the outcome: confirm the fix's code path
# actually ran, and that the misclassification it prevents never fired.
my $new_log = log_since(2, $offset);

like($new_log,
     qr/cleared transient exception state after subscription worker restart/,
     'mid-transaction SIGTERM restart path cleared the transient exception marker');
unlike($new_log,
       qr/disabling subscription sub_n1_n2 due to exceptions/,
       'no spurious SUB_DISABLE was triggered by the restarts');

destroy_cluster('Destroy apply-worker mid-transaction restart cluster');
done_testing();
