use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster psql_or_bail
                 scalar_query get_test_config log_offset log_since
                 wait_for_log);

# =============================================================================
# Test: 117_call_rollback_extended_protocol.pl
# =============================================================================
# A CALL sent over the extended query protocol, with a bound parameter, to a
# procedure that runs ROLLBACK or COMMIT must not crash the backend.
#
# spock_ProcessUtility() passed the statement's parse tree to
# autoddl_precheck() after the rest of the ProcessUtility chain had run.  The
# procedure's ROLLBACK releases the portal's cached plan, which owns the parse
# tree; with a parameter the plan is a custom plan nobody else holds, so it is
# freed, and GetCommandLogLevel() then read the node tag from freed memory.
# On an assert-enabled build that memory is wiped, so the server logs
# "unrecognized node type" and treats the statement as non-DDL; with other
# memory contents it could misread the statement or crash.
# spock.wait_for_sync_event() does ROLLBACK in its wait loop, so any driver
# using the extended protocol (psycopg, JDBC) hits this path.  psql uses the
# simple protocol, so the test sends its statements with pgbench -M extended,
# which binds each :variable as a parameter.
#
# The fix decides whether the statement is DDL before the chain runs and looks
# at the parse tree afterwards only for DDL.  The log check catches the read
# on assert-enabled builds; the last check makes sure DDL sent the same way
# still goes through AutoDDL.

create_cluster(1, 'Create single-node cluster for CALL/ROLLBACK test');

my $config  = get_test_config();
my $port    = $config->{node_ports}->[0];
my $pg_bin  = $config->{pg_bin};
my $dbname  = $config->{db_name};

# Run a pgbench script once over the extended query protocol.  Returns
# pgbench's exit code and its output.
sub pgbench_script {
    my ($script) = @_;
    my $file = "/tmp/spock_117_$$.sql";
    open(my $fh, '>', $file) or BAIL_OUT("cannot write $file: $!");
    print $fh $script;
    close($fh);
    my $out = `$pg_bin/pgbench -n -t 1 -M extended -p $port -f $file $dbname 2>&1`;
    my $rc = $? >> 8;
    unlink $file;
    return ($rc, $out);
}

# Make sure everything a previous statement logged has reached the log, then
# return the log written since $offset.
my $mark = 0;
sub log_after {
    my ($offset) = @_;
    $mark++;
    psql_or_bail(1, "DO \$\$BEGIN RAISE LOG 'spock_117_mark_$mark'; END\$\$");
    wait_for_log(1, qr/spock_117_mark_$mark/, $offset)
        or BAIL_OUT("log marker $mark not seen");
    return log_since(1, $offset);
}

sub backend_alive {
    return scalar_query(1, "SELECT 'alive'") eq 'alive';
}

psql_or_bail(1, q{
    CREATE PROCEDURE p117_rollback(n int) LANGUAGE plpgsql AS $$
    BEGIN
        FOR i IN 1..n LOOP ROLLBACK; END LOOP;
    END $$;
    CREATE PROCEDURE p117_commit(n int) LANGUAGE plpgsql AS $$
    BEGIN
        FOR i IN 1..n LOOP COMMIT; END LOOP;
    END $$;
});

my $start_time = scalar_query(1,
    "SELECT extract(epoch FROM pg_postmaster_start_time())");

my $offset = log_offset(1);
my ($rc, $out) = pgbench_script("\\set n 1\nCALL p117_rollback(:n);\n");
is($rc, 0, 'CALL with ROLLBACK over the extended protocol succeeds')
    or diag($out);
unlike(log_after($offset), qr/unrecognized node type/,
       'CALL with ROLLBACK: no read of the freed parse tree');

$offset = log_offset(1);
($rc, $out) = pgbench_script("\\set n 3\nCALL p117_commit(:n);\n");
is($rc, 0, 'CALL with COMMIT over the extended protocol succeeds')
    or diag($out);
unlike(log_after($offset), qr/unrecognized node type/,
       'CALL with COMMIT: no read of the freed parse tree');

ok(backend_alive(), 'server still answers');
is(scalar_query(1,
       "SELECT extract(epoch FROM pg_postmaster_start_time())"),
   $start_time, 'no crash restart happened');

# DDL over the extended protocol still goes through AutoDDL: the new table
# with a primary key lands in the default replication set.
($rc, $out) = pgbench_script(
    "CREATE TABLE t117 (id int PRIMARY KEY, v text);\n");
is($rc, 0, 'CREATE TABLE over the extended protocol succeeds')
    or diag($out);
is(scalar_query(1,
       "SELECT coalesce(string_agg(set_name, ','), '') FROM spock.tables" .
       " WHERE relname = 't117' AND set_name IS NOT NULL"),
   'default', 'AutoDDL still adds the new table to the default repset');

destroy_cluster('CALL/ROLLBACK test');
done_testing();
