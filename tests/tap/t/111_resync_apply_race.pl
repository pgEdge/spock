use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    wait_for_sub_status wait_for_pg_ready
);

# =============================================================================
# Test: 111_resync_apply_race.pl
# =============================================================================
# A table resync must not make a change that is already on its way through the
# apply worker fail.
#
# spock.sub_resync_table() marks the table as being synchronized and truncates
# it in one transaction.  The apply worker learns about the new state through
# a signal sent at that commit, but it keeps a cached list of the tables under
# synchronization.  A remote UPDATE that was already being applied when the
# resync committed met the emptied table, found no row to update, and under
# spock.exception_behaviour = sub_disable disabled the subscription.  The
# table's contents come from the sync worker, so such a change has to be
# skipped instead.
#
# The window is produced deterministically here rather than by timing: the
# worker is held at 'spock-apply-update-stall', which sits before the target
# relation is opened, and the resync runs to completion of its own transaction
# while it waits.
#
# Needs PostgreSQL's core injection_points module, which exists only when the
# server was configured with --enable-injection-points; the test skips
# otherwise.  No patched core is required.
# =============================================================================

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};

my $pkglibdir = `"$pg_bin/pg_config" --pkglibdir`;
chomp $pkglibdir;

unless ((-e "$pkglibdir/injection_points.so")
        || (-e "$pkglibdir/injection_points.dylib"))
{
    plan skip_all =>
        "server not built with --enable-injection-points " .
        "(no injection_points test module in $pkglibdir)";
}

create_cluster(2, 'Create 2-node resync-apply-race cluster');

$config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $p1 = $config->{node_ports}->[0];
my $p2 = $config->{node_ports}->[1];
my $datadir2 = $config->{node_datadirs}->[1];
my $log_file = $config->{log_file};
my $subscriber_log = "$config->{log_dir}/00${p2}.log";
my $conn = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

# The injection point fires in the subscriber's apply worker, so it is n2
# that needs the module preloaded.  That is a postmaster-start GUC, so set
# it and restart the node before any subscription exists.
open(my $conf, '>>', "$datadir2/postgresql.conf")
    or die "Cannot open $datadir2/postgresql.conf: $!";
print $conf "shared_preload_libraries='spock,injection_points'\n";
close($conf);

system_or_bail("$pg_bin/pg_ctl", '-D', $datadir2, '-w', '-m', 'fast', 'stop');
system("$pg_bin/postgres -D $datadir2 >> '$log_file' 2>&1 &");
ok(wait_for_pg_ready($host, $p2, $pg_bin, 30), 'n2 restarted with injection_points preloaded');

psql_or_bail(2, "CREATE EXTENSION injection_points");

for my $node (1, 2)
{
    psql_or_bail($node, "CREATE TABLE rs_tab(id int PRIMARY KEY, v text)");
    psql_or_bail($node, "INSERT INTO rs_tab SELECT g, 'old' FROM generate_series(1, 3) g");
}

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

sub read_log_from {
    my ($offset) = @_;
    open(my $lf, '<', $subscriber_log) or return '';
    seek($lf, $offset, 0);
    local $/;
    my $data = <$lf> // '';
    close($lf);
    return $data;
}

# The injection point reports a wait event named after itself, so the worker
# sitting in it is visible in pg_stat_activity.
sub wait_for_apply_in_injection_point {
    my ($point, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        my $n = scalar_query(2,
            "SELECT count(*) FROM pg_stat_activity " .
            "WHERE application_name LIKE 'spock apply %' " .
            "AND wait_event = '$point'");
        return 1 if defined $n && $n >= 1;
        sleep(1);
    }
    return 0;
}

my $point = 'spock-apply-update-stall';

psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

my $log_offset = -s $subscriber_log // 0;

# The UPDATE reaches the apply worker, which stops before opening the table.
psql_or_bail(1, "UPDATE rs_tab SET v = 'new' WHERE id = 1");

ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is held before applying the UPDATE');

# Resync the table while the worker waits.  The resync marks it as being
# synchronized and truncates it, all of it committed by the time this returns.
psql_or_bail(2, "SELECT spock.sub_resync_table('sub_n1_n2', 'rs_tab')");

is(scalar_query(2, "SELECT count(*) FROM rs_tab"), '0',
    'the resync emptied the table while the apply worker was held');

psql_or_bail(2, "SELECT injection_points_detach('$point')");
psql_or_bail(2, "SELECT injection_points_wakeup('$point')");

# The table is resynchronized and the held UPDATE is not applied to it.
my $status = '';
for (1 .. 120) {
    $status = scalar_query(2,
        "SELECT sync_status FROM spock.local_sync_status " .
        "WHERE sync_relname = 'rs_tab'");
    last if defined $status && $status eq 'r';
    sleep(1);
}
is($status, 'r', 'the table finished synchronizing');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating');

is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"), '0',
    'no exception was logged');

ok(read_log_from($log_offset) !~ /did not find row to be updated/,
    'the held UPDATE did not fail on the emptied table');

is(scalar_query(2, "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM rs_tab"),
    '1:new,2:old,3:old',
    'the table holds the provider data, including the held UPDATE');

# Replication is still working end to end.
psql_or_bail(1, "UPDATE rs_tab SET v = 'later' WHERE id = 2");
my $followed = '';
for (1 .. 60) {
    $followed = scalar_query(2, "SELECT v FROM rs_tab WHERE id = 2");
    last if $followed eq 'later';
    sleep(1);
}
is($followed, 'later', 'a later UPDATE still replicates');

destroy_cluster('Destroy 2-node resync-apply-race cluster');

done_testing();
