# =============================================================================
# Test: 083_create_subscriber_enable_order.pl
#
# spock_create_subscriber must not let a sync worker touch the provider slot
# or the replication origin between sub_create() and the point where the
# origin is positioned at the base backup's restore point.  Creating the
# subscription enabled leaves it in sync status INIT, and the INIT path drops
# and recreates the slot and advances the origin on its own.
#
# SPOCK_CREATE_SUBSCRIBER_TEST_PAUSE_BEFORE=subscribe_enable freezes the
# utility after the subscription is created and its origin positioned, and
# before it is enabled.  While frozen, the subscription must be disabled with
# local sync status READY and its origin must exist.  After the resume it must
# replicate.
#
# Also covers the plain (non-bidirectional) path's failure handling: a failed
# base backup must not leave its provider slot behind, and DROP EXTENSION must
# not run while a non-spock object depends on spock.  The restore point name
# must carry a per-run suffix.
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree);
use POSIX qw(WNOHANG);
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail
                 get_test_config scalar_query wait_for_pg_ready
                 output_plugin_libraries_conf);

my $SCS_BIN;
for my $dir (split(':', $ENV{PATH} // '')) {
    my $c = "$dir/spock_create_subscriber";
    if (-x $c) { $SCS_BIN = $c; last; }
}
unless (defined $SCS_BIN) {
    my $bt = '../../utils/spock_create_subscriber/spock_create_subscriber';
    $SCS_BIN = $bt if -x $bt;
}
BAIL_OUT("spock_create_subscriber binary not found; run 'make install' first")
    unless defined $SCS_BIN;

create_cluster(1, 'Create provider cluster');

my $config      = get_test_config();
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my $log_dir     = $config->{log_dir};
my $n1_port     = $config->{node_ports}->[0];

my $n1_dsn = "host=$host port=$n1_port dbname=$dbname"
           . " user=$db_user password=$db_password";

my $n2_port    = $n1_port + 1;
my $n2_datadir = '/tmp/tmp_spock_node_1_datadir_083_enable_order';
my $n2_dsn     = "host=$host port=$n2_port dbname=$dbname"
               . " user=$db_user password=$db_password";
remove_tree($n2_datadir) if -d $n2_datadir;

my $n2_conf = '/tmp/tmp_spock_node_1_postgresql.conf.override_083';
open my $conf_fh, '>', $n2_conf or die "Cannot write $n2_conf: $!";
print $conf_fh "shared_preload_libraries='spock'\n";
print $conf_fh output_plugin_libraries_conf($pg_bin);
print $conf_fh "wal_level=logical\n";
print $conf_fh "track_commit_timestamp=on\n";
print $conf_fh "port=$n2_port\n";
print $conf_fh "listen_addresses='*'\n";
print $conf_fh "logging_collector=on\n";
print $conf_fh "log_directory='$log_dir'\n";
print $conf_fh "log_filename='00${n2_port}.log'\n";
close $conf_fh;

system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    'CREATE TABLE t083 (id int PRIMARY KEY, v text)';
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "INSERT INTO t083 SELECT g, 'pre' FROM generate_series(1, 100) g";

sub n2_query {
    my ($sql) = @_;
    my $out = `$pg_bin/psql -X -p $n2_port -d $dbname -t -A -c "$sql" 2>&1`;
    chomp $out;
    return $out;
}

sub run_scs {
    my (@extra) = @_;
    my $out = `"$SCS_BIN" --pgdata "$n2_datadir" --subscriber-name n2 --provider-dsn "$n1_dsn" --subscriber-dsn "$n2_dsn" --postgresql-conf "$n2_conf" @extra 2>&1`;
    return ($? >> 8, $out);
}

sub provider_slots {
    return scalar_query(1, "SELECT count(*) FROM pg_replication_slots"
                         . " WHERE slot_type = 'logical' AND plugin = 'spock_output'");
}

# A failed base backup must not leave its slot pinning WAL on the provider.
{
    my ($rc, $out) = run_scs("--extra-basebackup-args '--waldir=/nonexistent_083_waldir'");
    isnt($rc, 0, 'a failed base backup makes the utility fail');
    is(provider_slots(), '0', 'the failed run left no slot on the provider');
    remove_tree($n2_datadir) if -d $n2_datadir;
}

# A configuration that cannot host spock must stop the run, with the slot dropped.
for my $case (
    [ 'wal_level=replica',                  qr/wal_level is "replica" .* must be "logical"/ ],
    [ "shared_preload_libraries=''",        qr/shared_preload_libraries .* does not include "spock"/ ],
) {
    my ($setting, $re) = @$case;
    my $auto = '/tmp/tmp_spock_node_1_auto.conf.override_083';
    open my $af, '>', $auto or die $!;
    print $af "$setting\n";
    close $af;
    my ($rc, $out) = run_scs("--postgresql-auto-conf '$auto'");
    isnt($rc, 0, "$setting makes the utility fail");
    like($out, $re, "the rejection names the setting for $setting");
    is(provider_slots(), '0', "the run left no slot on the provider for $setting");
    remove_tree($n2_datadir) if -d $n2_datadir;
    unlink($auto);
}

# A copy already past the source's timeline is refused; --cleanup does not
# apply to the plain path, so the hint must say to remove the directory.
{
    local $ENV{PGPASSWORD} = $db_password;
    is(system("$pg_bin/pg_basebackup -D '$n2_datadir' -d '$n1_dsn' -X stream "
              . "-c fast > /dev/null 2>&1"), 0, 'base backup of the provider taken');
    is(system("$pg_bin/pg_resetwal -f -l 000000020000000100000000 '$n2_datadir' "
              . "> /dev/null 2>&1"), 0, 'timeline of the copy advanced');
    my ($rc, $out) = run_scs();
    isnt($rc, 0, 'a copy on a later timeline makes the utility fail');
    like($out, qr/already on timeline 2, past the source's current timeline 1.*remove the data directory and retry/s,
         'the hint is to remove the data directory');
    is(provider_slots(), '0', 'the failed run left no slot on the provider');
    remove_tree($n2_datadir) if -d $n2_datadir;
}

# A non-spock object depending on spock must stop the run before anything is dropped.
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    'CREATE VIEW v083 AS SELECT * FROM spock.node';
{
    my ($rc, $out) = run_scs();
    isnt($rc, 0, 'a dependent object makes the utility fail');
    like($out, qr/depend on it and would be collaterally dropped.*v083/s,
         'the dependent object is named');
    is(provider_slots(), '0', 'the failed run left no slot on the provider');
    remove_tree($n2_datadir) if -d $n2_datadir;
}
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    'DROP VIEW v083';

# SIGTERM while the utility waits: it must clean up from the main flow,
# drop the provider slot and stop the new node.
{
    my $cpaused = "${n2_datadir}.spock_bidir_test_paused";
    my $clog    = "$log_dir/scs_cancel.log";
    unlink($clog, $cpaused);

    my $cpid = fork();
    die "fork() failed: $!" unless defined $cpid;
    if ($cpid == 0) {
        open(my $fh, '>>', $clog) or die $!;
        open(STDOUT, '>&', $fh) or die $!;
        open(STDERR, '>&', $fh) or die $!;
        $ENV{SPOCK_CREATE_SUBSCRIBER_TEST_PAUSE_BEFORE} = 'subscribe_enable';
        exec($SCS_BIN,
             '--pgdata',          $n2_datadir,
             '--subscriber-name', 'n2',
             '--provider-dsn',    $n1_dsn,
             '--subscriber-dsn',  $n2_dsn,
             '--postgresql-conf', $n2_conf) or exit(127);
    }

    my $creached = 0;
    for (1 .. 120) {
        if (-e $cpaused) { $creached = 1; last; }
        last if waitpid($cpid, WNOHANG) == $cpid;
        sleep(1);
    }
    ok($creached, 'utility reached the pause')
        or do { diag(`tail -30 $clog`); done_testing(); exit 1; };
    is(provider_slots(), '1', 'the plain path holds a provider slot while paused');

    kill('TERM', $cpid);
    my $crc;
    for (1 .. 60) {
        if (waitpid($cpid, WNOHANG) == $cpid) { $crc = $? >> 8; last; }
        sleep(1);
    }
    is($crc, 1, 'SIGTERM makes the utility exit with status 1');
    open my $lf, '<', $clog or die $!;
    local $/;
    my $log = <$lf>;
    close $lf;
    like($log, qr/Canceling\.\.\./, 'the cancellation is reported');
    is(provider_slots(), '0', 'the cancelled run dropped its provider slot');
    ok(!-e "$n2_datadir/postmaster.pid", 'the new node was stopped');
    unlink($cpaused);
    remove_tree($n2_datadir) if -d $n2_datadir;
}

my $paused = "${n2_datadir}.spock_bidir_test_paused";
my $resume = "${n2_datadir}.spock_bidir_test_resume";
my $scs_log = "$log_dir/scs_enable_order.log";
unlink($scs_log, $paused, $resume);

my $pid = fork();
die "fork() failed: $!" unless defined $pid;
if ($pid == 0) {
    open(my $fh, '>>', $scs_log) or die $!;
    open(STDOUT, '>&', $fh) or die $!;
    open(STDERR, '>&', $fh) or die $!;
    $ENV{SPOCK_CREATE_SUBSCRIBER_TEST_PAUSE_BEFORE} = 'subscribe_enable';
    exec($SCS_BIN,
         '--pgdata',          $n2_datadir,
         '--subscriber-name', 'n2',
         '--provider-dsn',    $n1_dsn,
         '--subscriber-dsn',  $n2_dsn,
         '--postgresql-conf', $n2_conf) or exit(127);
}

my $reached = 0;
for (1 .. 120) {
    if (-e $paused) { $reached = 1; last; }
    last if waitpid($pid, WNOHANG) == $pid;
    sleep(1);
}
ok($reached, 'utility reached the pause before enabling the subscription')
    or do { diag(`tail -30 $scs_log`); done_testing(); exit 1; };

# Give a worker the chance to act if one were going to.
sleep(5);

is(n2_query("SELECT sub_enabled FROM spock.subscription"), 'f',
   'subscription is disabled while the origin is being positioned');
is(n2_query("SELECT sync_status FROM spock.local_sync_status"), 'r',
   'local sync status is READY, not INIT');
is(n2_query("SELECT count(*) FROM pg_replication_origin"), '1',
   'replication origin exists');
is(n2_query("SELECT count(*) FROM pg_replication_origin_status"
          . " WHERE remote_lsn <> '0/0'"), '1',
   'origin is positioned at the restore point');
is(scalar_query(1, "SELECT count(*) FROM pg_replication_slots"
                 . " WHERE slot_type = 'logical' AND NOT active"
                 . " AND plugin = 'spock_output'"), '1',
   'provider slot is untouched');

open(my $rf, '>', $resume) or die $!;
close($rf);

my $deadline = time() + 120;
my $rc;
while (time() < $deadline) {
    my $r = waitpid($pid, WNOHANG);
    if ($r == $pid) { $rc = $? >> 8; last; }
    sleep(1);
}
is($rc, 0, 'utility finished successfully') or diag(`tail -30 $scs_log`);

{
    open my $lf, '<', $scs_log or die $!;
    local $/;
    my $log = <$lf>;
    close $lf;
    like($log, qr/restore point "spock_create_subscriber_[0-9a-f]{13}_[0-9a-f]+_[0-9a-f]+"/,
         'the restore point name carries a per-run suffix');
}

is(n2_query("SELECT sub_enabled FROM spock.subscription"), 't',
   'subscription is enabled after the resume');
is(n2_query("SELECT count(*) FROM t083"), '100',
   'pre-existing rows are present exactly once');

system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "INSERT INTO t083 VALUES (1000, 'post')";
my $got = '0';
for (1 .. 30) {
    $got = n2_query("SELECT count(*) FROM t083 WHERE id = 1000");
    last if $got eq '1';
    sleep(1);
}
is($got, '1', 'a row written after the join replicates to the new node');
is(n2_query("SELECT count(*) FROM t083"), '101',
   'no row was replayed twice');

system("$pg_bin/pg_ctl -D $n2_datadir -m fast stop >/dev/null 2>&1");
remove_tree($n2_datadir);
unlink($n2_conf);
destroy_cluster('Destroy provider cluster');
done_testing();
