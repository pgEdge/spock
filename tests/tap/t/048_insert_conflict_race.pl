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
# Test: 048_insert_conflict_race.pl
# =============================================================================
# An applied INSERT must resolve against a conflicting local row even when
# that row appears after the apply worker has already looked for it and
# found nothing.
#
# The lookup cannot settle the question on its own.  It runs a scan that a
# concurrent local writer can race, and it necessarily runs before the tuple
# is stored, so a row committed in between is missed either way.  The apply
# path therefore stores the tuple speculatively and lets the unique index
# arbitrate: the index sees the key under a page lock, reports a duplicate
# instead of raising one, and only after the competing inserter has
# committed -- so the lookup on the next pass finds that row and hands it to
# conflict resolution.
#
# The race is produced deterministically here rather than by timing: the
# worker is held at 'spock-insert-conflict-stall', which sits exactly in the
# window between the lookup and the store, and the conflicting row is
# committed locally while it waits.  Before the speculative insertion this
# ended in "duplicate key value violates unique constraint" and whatever
# spock.exception_behaviour then decided.
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

create_cluster(2, 'Create 2-node insert-conflict-race cluster');

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

psql_or_bail(1, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");
psql_or_bail(2, "CREATE TABLE conf_tab(a int PRIMARY KEY, data text)");

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

sub wait_for_log {
    my ($offset, $pattern, $timeout) = @_;
    $timeout //= 60;
    for (1 .. $timeout) {
        return 1 if read_log_from($offset) =~ $pattern;
        sleep(1);
    }
    return 0;
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

my $point = 'spock-insert-conflict-stall';

psql_or_bail(2, "SELECT injection_points_attach('$point', 'wait')");

my $log_offset = -s $subscriber_log // 0;

# Insert on the publisher.  It replicates, the apply worker looks for a
# conflicting local row, finds none -- there is none yet -- and stops in the
# window between that answer and storing the tuple.
psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (1, 'frompub')");

ok(wait_for_apply_in_injection_point($point, 60),
    'apply worker is held between the conflict lookup and the insert');

# Now make the lookup's answer stale: commit the conflicting row locally.
psql_or_bail(2, "INSERT INTO conf_tab(a, data) VALUES (1, 'fromsub')");

psql_or_bail(2, "SELECT injection_points_detach('$point')");
psql_or_bail(2, "SELECT injection_points_wakeup('$point')");

# The index reports the duplicate, the next pass finds the row, and the
# insert is resolved as a conflict.
ok(wait_for_log($log_offset, qr/CONFLICT: remote insert_exists/, 60),
    'the insert is reported as an insert_exists conflict');

my $dup_key_error =
    read_log_from($log_offset) =~ /duplicate key value violates unique constraint/;
ok(!$dup_key_error,
    'no duplicate key violation (the index conflict is resolved, not raised)');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating');

# Which row wins is conflict resolution's decision, not this test's business;
# what matters is that exactly one survives and the key is intact.
my $count = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 1");
is($count, '1', 'exactly one row for a=1 survives');

# Replication is still working end to end after the resolved conflict.
psql_or_bail(1, "INSERT INTO conf_tab(a, data) VALUES (2, 'after')");
my $followed = '';
for (1 .. 60) {
    $followed = scalar_query(2, "SELECT count(*) FROM conf_tab WHERE a = 2");
    last if $followed eq '1';
    sleep(1);
}
is($followed, '1', 'a later insert still replicates');

destroy_cluster('Destroy insert-conflict-race cluster');
done_testing();
