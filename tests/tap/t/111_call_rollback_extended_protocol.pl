use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster psql_or_bail
                 scalar_query get_test_config);

# =============================================================================
# Test: 111_call_rollback_extended_protocol.pl
# =============================================================================
# A CALL sent over the extended query protocol, with a bound parameter, to a
# procedure that runs ROLLBACK or COMMIT must not crash the backend.
#
# spock_ProcessUtility() passed pstmt to spock_autoddl_process() after the
# rest of the ProcessUtility chain had run.  The procedure's ROLLBACK
# releases the portal's cached plan, which owns pstmt; with a parameter the
# plan is a custom plan nobody else holds, so it is freed, and AutoDDL then
# read pstmt->utilityStmt from freed memory (SIGSEGV, and a crash restart of
# the whole node).  spock.wait_for_sync_event() does ROLLBACK in its wait
# loop, so any driver using the extended protocol (psycopg, JDBC) could crash
# a node with it.  psql uses the simple protocol unless told to \bind.
#
# The fix calls AutoDDL only for DDL, decided before the chain runs; the last
# check makes sure DDL sent the same way still goes through AutoDDL.

create_cluster(1, 'Create single-node cluster for CALL/ROLLBACK test');

my $config  = get_test_config();
my $port    = $config->{node_ports}->[0];
my $pg_bin  = $config->{pg_bin};
my $dbname  = $config->{db_name};

# \bind needs psql 16 or later.
my $server_num = scalar_query(1, "SHOW server_version_num");
if ($server_num < 160000) {
    destroy_cluster('CALL/ROLLBACK test');
    plan skip_all => 'psql \bind needs PostgreSQL 16 or later';
}

# Run psql statements from a script so backslash commands work.  Returns
# psql's exit code and its output.
sub psql_script {
    my ($script) = @_;
    my $file = "/tmp/spock_111_$$.sql";
    open(my $fh, '>', $file) or BAIL_OUT("cannot write $file: $!");
    print $fh $script;
    close($fh);
    my $out = `$pg_bin/psql -X -At -v ON_ERROR_STOP=1 -p $port -d $dbname -f $file 2>&1`;
    my $rc = $? >> 8;
    unlink $file;
    return ($rc, $out);
}

sub backend_alive {
    return scalar_query(1, "SELECT 'alive'") eq 'alive';
}

psql_or_bail(1, q{
    CREATE PROCEDURE p111_rollback(n int) LANGUAGE plpgsql AS $$
    BEGIN
        FOR i IN 1..n LOOP ROLLBACK; END LOOP;
    END $$;
    CREATE PROCEDURE p111_commit(n int) LANGUAGE plpgsql AS $$
    BEGIN
        FOR i IN 1..n LOOP COMMIT; END LOOP;
    END $$;
});

my $start_time = scalar_query(1,
    "SELECT extract(epoch FROM pg_postmaster_start_time())");

my ($rc, $out) = psql_script("CALL p111_rollback(\$1) \\bind 1 \\g\n");
is($rc, 0, 'CALL with ROLLBACK over the extended protocol succeeds')
    or diag($out);

($rc, $out) = psql_script("CALL p111_commit(\$1) \\bind 3 \\g\n");
is($rc, 0, 'CALL with COMMIT over the extended protocol succeeds')
    or diag($out);

ok(backend_alive(), 'server still answers');
is(scalar_query(1,
       "SELECT extract(epoch FROM pg_postmaster_start_time())"),
   $start_time, 'no crash restart happened');

# DDL over the extended protocol still goes through AutoDDL: the new table
# with a primary key lands in the default replication set.
($rc, $out) = psql_script(
    "CREATE TABLE t111 (id int PRIMARY KEY, v text) \\bind \\g\n");
is($rc, 0, 'CREATE TABLE over the extended protocol succeeds')
    or diag($out);
is(scalar_query(1,
       "SELECT coalesce(string_agg(set_name, ','), '') FROM spock.tables" .
       " WHERE relname = 't111' AND set_name IS NOT NULL"),
   'default', 'AutoDDL still adds the new table to the default repset');

destroy_cluster('CALL/ROLLBACK test');
done_testing();
