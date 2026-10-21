use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail
    wait_for_sub_status wait_for_pg_ready log_offset log_since
);

# =============================================================================
# Test: 112_resync_apply_race.pl
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

my $log_offset = log_offset(2);

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

ok(log_since(2, $log_offset) !~ /did not find row to be updated/,
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

# Only a partitioned table is synchronized, as a whole, while its partitions
# replicate under their own names.  A change held for a partition must be
# skipped when the parent is resynchronized, which empties the partition too.
# The subscription exists by now, so the tables and rows replicate.
psql_or_bail(1, "CREATE TABLE rs_part(id int PRIMARY KEY, v text) PARTITION BY RANGE (id)");
psql_or_bail(1, "CREATE TABLE rs_part_1 PARTITION OF rs_part FOR VALUES FROM (1) TO (100)");
psql_or_bail(1, "INSERT INTO rs_part SELECT g, 'old' FROM generate_series(1, 3) g");

my $replicated = '';
for (1 .. 60) {
    $replicated = scalar_query(2, "SELECT count(*) FROM rs_part_1");
    last if defined $replicated && $replicated eq '3';
    sleep(1);
}
is($replicated, '3', 'the partitioned table replicates before the resync');

psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");
$log_offset = log_offset(2);

psql_or_bail(1, "UPDATE rs_part SET v = 'new' WHERE id = 1");
ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is held before applying the UPDATE to the partition');

psql_or_bail(2, "SELECT spock.sub_resync_table('sub_n1_n2', 'rs_part')");
is(scalar_query(2, "SELECT count(*) FROM rs_part_1"), '0',
    'the resync of the parent emptied the partition while the apply worker was held');

psql_or_bail(2, "SELECT injection_points_detach('$point')");
psql_or_bail(2, "SELECT injection_points_wakeup('$point')");

$status = '';
for (1 .. 120) {
    $status = scalar_query(2,
        "SELECT sync_status FROM spock.local_sync_status " .
        "WHERE sync_relname = 'rs_part'");
    last if defined $status && $status eq 'r';
    sleep(1);
}
is($status, 'r', 'the partitioned table finished synchronizing');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating after the partitioned resync');

ok(log_since(2, $log_offset) !~ /did not find row to be updated/,
    'the held UPDATE did not fail on the emptied partition');

is(scalar_query(2, "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM rs_part"),
    '1:new,2:old,3:old',
    'the partitioned table holds the provider data, including the held UPDATE');

# Hold an UPDATE to $leaf at the injection point, resync $parent while it
# waits, then release it and check that the resync completes and the
# subscription survives without logging an exception.
sub resync_with_held_update {
    my ($parent, $leaf, $update, $what) = @_;

    psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");
    my $offset = log_offset(2);

    psql_or_bail(1, $update);
    ok(wait_for_apply_in_injection_point($point, 60),
        "$what: apply worker is held before applying the UPDATE");

    psql_or_bail(2, "SELECT spock.sub_resync_table('sub_n1_n2', '$parent')");
    is(scalar_query(2, "SELECT count(*) FROM $leaf"), '0',
        "$what: the resync emptied $leaf while the apply worker was held");

    psql_or_bail(2, "SELECT injection_points_detach('$point')");
    psql_or_bail(2, "SELECT injection_points_wakeup('$point')");

    my $st = '';
    for (1 .. 120) {
        $st = scalar_query(2,
            "SELECT sync_status FROM spock.local_sync_status " .
            "WHERE sync_relname = '$parent'");
        last if defined $st && $st eq 'r';
        sleep(1);
    }
    is($st, 'r', "$what: the parent finished synchronizing");

    ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
        "$what: subscription is still replicating");
    ok(log_since(2, $offset) !~ /did not find row to be updated/,
        "$what: the held UPDATE did not fail on the emptied partition");
    is(scalar_query(2, "SELECT count(*) FROM spock.exception_log"), '0',
        "$what: no exception was logged");
}

# Only some of the partitions are replicated.  The held change is for one of
# them; the copy of the parent brings the rows of all of them.
psql_or_bail(1, "CREATE TABLE rs_multi(id int PRIMARY KEY, v text) PARTITION BY RANGE (id)");
for my $i (1 .. 3)
{
    my ($lo, $hi) = ($i * 100 - 99, $i * 100 + 1);
    psql_or_bail(1, "CREATE TABLE rs_multi_$i PARTITION OF rs_multi FOR VALUES FROM ($lo) TO ($hi)");
}
psql_or_bail(1, "SELECT spock.repset_remove_partition('rs_multi', 'rs_multi_3')");
psql_or_bail(1, "INSERT INTO rs_multi SELECT g, 'old' FROM generate_series(1, 300, 50) g");

my $partial = '';
for (1 .. 60) {
    $partial = scalar_query(2, "SELECT count(*) FROM rs_multi_1") +
        scalar_query(2, "SELECT count(*) FROM rs_multi_2");
    last if $partial == 4;
    sleep(1);
}
is($partial, '4', 'the replicated partitions receive their rows');
is(scalar_query(2, "SELECT count(*) FROM rs_multi_3"), '0',
    'the partition outside the replication set receives nothing');

resync_with_held_update('rs_multi', 'rs_multi_1',
    "UPDATE rs_multi SET v = 'new' WHERE id = 1", 'partial partitions');

is(scalar_query(2,
    "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM rs_multi WHERE id <= 200"),
    '1:new,51:old,101:old,151:old',
    'partial partitions: the replicated partitions hold the provider data');

# The parent has a row filter, which its partitions inherit.  The held change
# is for a row that passes it.
psql_or_bail(1, "CREATE TABLE rs_filt(id int PRIMARY KEY, v text) PARTITION BY RANGE (id)");
psql_or_bail(1, "CREATE TABLE rs_filt_1 PARTITION OF rs_filt FOR VALUES FROM (1) TO (101)");
psql_or_bail(1, "CREATE TABLE rs_filt_2 PARTITION OF rs_filt FOR VALUES FROM (101) TO (201)");
psql_or_bail(1, "SELECT spock.repset_remove_table('default', 'rs_filt')");
psql_or_bail(1,
    "SELECT spock.repset_add_table('default', 'rs_filt', false, NULL, 'id % 2 = 1', true)");
psql_or_bail(1,
    "INSERT INTO rs_filt SELECT g, 'old' FROM generate_series(1, 6) g " .
    "UNION ALL SELECT g, 'old' FROM generate_series(101, 106) g");

my $filtered = '';
for (1 .. 60) {
    $filtered = scalar_query(2, "SELECT count(*) FROM rs_filt");
    last if $filtered eq '6';
    sleep(1);
}
is($filtered, '6', 'only the rows passing the filter are replicated');

resync_with_held_update('rs_filt', 'rs_filt_1',
    "UPDATE rs_filt SET v = 'new' WHERE id = 1", 'row filter');

is(scalar_query(2, "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM rs_filt"),
    '1:new,3:old,5:old,101:old,103:old,105:old',
    'row filter: the table holds the filtered provider data');

# The parent is renamed after its partition has been applied to, so the
# partition's cached mapping predates the rename.  The resync names the parent
# by its new name.
psql_or_bail(1, "CREATE TABLE rs_ren(id int PRIMARY KEY, v text) PARTITION BY RANGE (id)");
psql_or_bail(1, "CREATE TABLE rs_ren_1 PARTITION OF rs_ren FOR VALUES FROM (1) TO (101)");
psql_or_bail(1, "INSERT INTO rs_ren SELECT g, 'old' FROM generate_series(1, 3) g");

my $ren = '';
for (1 .. 60) {
    $ren = scalar_query(2, "SELECT count(*) FROM rs_ren_1");
    last if defined $ren && $ren eq '3';
    sleep(1);
}
is($ren, '3', 'the partitioned table replicates before the rename');

psql_or_bail(1, "ALTER TABLE rs_ren RENAME TO rs_ren2");
my $renamed = '';
for (1 .. 60) {
    $renamed = scalar_query(2, "SELECT to_regclass('rs_ren2') IS NOT NULL");
    last if defined $renamed && $renamed eq 't';
    sleep(1);
}
is($renamed, 't', 'the rename reached the subscriber');

resync_with_held_update('rs_ren2', 'rs_ren_1',
    "UPDATE rs_ren2 SET v = 'new' WHERE id = 1", 'renamed parent');

is(scalar_query(2, "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM rs_ren2"),
    '1:new,2:old,3:old',
    'renamed parent: the table holds the provider data');

destroy_cluster('Destroy 2-node resync-apply-race cluster');

done_testing();
