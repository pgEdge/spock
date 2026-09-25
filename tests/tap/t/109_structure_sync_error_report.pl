use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config scalar_query
                 psql_or_bail log_offset log_since wait_for_log
                 wait_for_sub_status);

# =============================================================================
# Test: 109_structure_sync_error_report.pl
# =============================================================================
# The sync worker runs pg_dump and pg_restore as child processes while it
# synchronizes the structure of a new subscription.  When one of them fails,
# the error has to say how the child exited.  Reporting errno instead gave a
# message like 'could not execute pg_dump ("..."): Success', because a child
# that ran and exited non-zero leaves errno untouched.
#
# Two failures are provoked on the subscriber:
#   1. spock.temp_directory points to a directory that does not exist, so
#      pg_dump cannot open its output file and exits with code 1.
#   2. The table already exists on the subscriber, so pg_restore, run with
#      --exit-on-error, fails and exits with code 1.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for structure sync error test');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};

my $conn_string = "host=$host dbname=$dbname port=$node_ports->[0] "
                . "user=$db_user password=$db_password";

# Something for the structure sync to dump.  The test cluster adds new
# tables to the default replication set by itself.
psql_or_bail(1, "CREATE TABLE sync_report (id integer PRIMARY KEY, data text)");

# ---- 1. pg_dump cannot write its output file --------------------------------
my $missing_dir = "$config->{log_dir}/no_such_directory_$$";
psql_or_bail(2, "ALTER SYSTEM SET spock.temp_directory = '$missing_dir'");
psql_or_bail(2, "SELECT pg_reload_conf()");

my $offset = log_offset(2);
psql_or_bail(2,
    "SELECT spock.sub_create('sub_sync_report', '$conn_string', "
    . "ARRAY['default'], true, false)");

ok(wait_for_log(2,
        qr/could not execute pg_dump \(".*pg_dump"\): child process exited with exit code 1/,
        $offset, 60),
    'pg_dump failure reports how the child exited');

unlike(log_since(2, $offset),
    qr/could not execute pg_dump \(".*"\): (Success|No such file or directory|Undefined error)/,
    'pg_dump failure does not report a stale errno');

# ---- Recovery: a failed structure sync is not retried, so set up again -----
psql_or_bail(2, "SELECT spock.sub_drop('sub_sync_report')");
psql_or_bail(2, "ALTER SYSTEM RESET spock.temp_directory");
psql_or_bail(2, "SELECT pg_reload_conf()");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_sync_report', '$conn_string', "
    . "ARRAY['default'], true, false)");

ok(wait_for_sub_status(2, 'sub_sync_report', 'replicating', 120),
    'subscription replicates once pg_dump can write its file');
is(scalar_query(2, "SELECT count(*) FROM pg_class WHERE relname = 'sync_report'"),
    '1', 'structure was restored on the subscriber');

# ---- 2. pg_restore fails on an existing table -------------------------------
psql_or_bail(2, "SELECT spock.sub_drop('sub_sync_report')");

$offset = log_offset(2);
psql_or_bail(2,
    "SELECT spock.sub_create('sub_sync_report', '$conn_string', "
    . "ARRAY['default'], true, false)");

ok(wait_for_log(2,
        qr/could not execute pg_restore \(".*pg_restore"\): child process exited with exit code 1/,
        $offset, 60),
    'pg_restore failure reports how the child exited');

unlike(log_since(2, $offset),
    qr/could not execute pg_restore \(".*"\): (Success|No such file or directory|Undefined error)/,
    'pg_restore failure does not report a stale errno');

psql_or_bail(2, "SELECT spock.sub_drop('sub_sync_report')");

destroy_cluster('Destroy cluster');
done_testing();
