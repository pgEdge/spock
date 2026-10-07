#!/usr/bin/perl
# =============================================================================
# Test: 082_create_subscriber_basebackup.pl - spock_create_subscriber command
#       line, base backup, and data directory reuse
# =============================================================================
#   1  command-line validation: missing/conflicting options and out-of-range
#      values are rejected with a specific message (no cluster needed)
#   2  --extra-basebackup-args containing shell metacharacters is rejected
#      before any state is created, and the injected command never runs
#   3  the pg_basebackup command line requests streamed WAL and a fast
#      checkpoint (-X s -c fast)
#   4  with checkpoint_timeout = 1h and write load on the source, the join
#      completes promptly: a spread checkpoint would pace itself against
#      checkpoint_timeout, so completion proves the checkpoint is immediate
#   5  the WAL carried in the new node's pg_wal is bounded by the WAL the
#      source generated during the join plus recycling slack -- WAL that
#      pre-dates the backup is not copied
#   6  replication slots on the source are not carried into the new node
#   7  an existing non-empty --pgdata is accepted only if it is a base backup
#      of the source that has not been promoted; otherwise it is rejected
#      before any slot, sidecar, or change to the directory
#   8  the node left behind is a plain primary: no standby/recovery signal
#      files, not in recovery, stays one across a restart, and the catchup
#      recovery settings (primary_conninfo, recovery_target_*) are not left
#      in postgresql.auto.conf
# =============================================================================

use strict;
use warnings;
use Test::More;
use File::Path qw(remove_tree make_path);
use Time::HiRes qw(time);
use POSIX qw(WNOHANG);
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail
                 system_maybe get_test_config scalar_query
                 wait_for_pg_ready wait_for_sub_status
                 output_plugin_libraries_conf);

# Source WAL pre-generated before the join, and the allowance on top of the
# WAL generated during the join: segments recycled by n3's own startup and
# the partially filled segment at each end.
my $PREFILL_ROWS     = 1_000_000;
my $WAL_SLACK_SEGS   = 6;
my $JOIN_TIMEOUT_SEC = 300;

# =============================================================================
# Locate spock_create_subscriber binary
# =============================================================================
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

# =============================================================================
# 1. Command-line validation.  Every case is rejected while parsing arguments,
# before any connection is attempted, so no cluster is needed.
# =============================================================================
{
    # Unreachable on purpose: a case that wrongly gets past validation fails to
    # connect instead of touching a real server.
    my $PROV = 'host=127.0.0.1 port=1 dbname=x';
    my $SUB  = 'host=127.0.0.1 port=2 dbname=x';
    my $DIR  = '/tmp/tmp_spock_061_cli_pgdata';
    remove_tree($DIR) if -d $DIR;

    # Run with the given argument list; returns (exit status, combined output).
    sub scs {
        my @args = @_;
        my $cmd = join(' ', map { "'$_'" } ($SCS_BIN, @args)) . ' 2>&1';
        my $out = qx{$cmd};
        return ($? >> 8, $out);
    }

    my @base = ('--pgdata', $DIR, '--subscriber-name', 'n3',
                '--provider-dsn', $PROV, '--subscriber-dsn', $SUB);

    # [ description, [args], expected exit, message pattern ]
    my @cases = (
        [ 'no --pgdata',
          [ '--subscriber-name', 'n3', '--provider-dsn', $PROV,
            '--subscriber-dsn', $SUB ],
          1, qr/No data directory specified/ ],
        [ 'no --subscriber-name',
          [ '--pgdata', $DIR, '--provider-dsn', $PROV, '--subscriber-dsn', $SUB ],
          1, qr/No subscriber name specified/ ],
        [ 'no --provider-dsn',
          [ '--pgdata', $DIR, '--subscriber-name', 'n3',
            '--subscriber-dsn', $SUB ],
          1, qr/Provider connection string must be specified/ ],
        [ 'no --subscriber-dsn',
          [ '--pgdata', $DIR, '--subscriber-name', 'n3',
            '--provider-dsn', $PROV ],
          1, qr/Subscriber connection string must be specified/ ],
        [ '--cleanup without --bidirectional',
          [ '--pgdata', $DIR, '--cleanup' ],
          1, qr/--cleanup requires --bidirectional/ ],
        [ '--force without --cleanup',
          [ @base, '--bidirectional', '--force' ],
          1, qr/--force requires --cleanup/ ],
        [ '--replication-sets combined with --bidirectional',
          [ @base, '--bidirectional', '--replication-sets', 'default' ],
          1, qr/--replication-sets cannot be combined with --bidirectional/ ],
        [ '--apply-delay negative',
          [ @base, '--apply-delay', '-1' ],
          1, qr/Apply delay cannot be negative/ ],
        [ '--apply-delay above the maximum',
          [ @base, '--apply-delay', '86401' ],
          1, qr/Apply delay cannot be more than 86400/ ],
        [ '--apply-delay not an integer',
          [ @base, '--apply-delay', 'soon' ],
          1, qr/--apply-delay requires an integer value/ ],
        [ '--stall-timeout zero',
          [ @base, '--bidirectional', '--stall-timeout', '0' ],
          1, qr/--stall-timeout must be a positive integer/ ],
        [ '--stall-timeout negative',
          [ @base, '--bidirectional', '--stall-timeout', '-5' ],
          1, qr/--stall-timeout must be a positive integer/ ],
        [ '--max-wait negative',
          [ @base, '--bidirectional', '--max-wait', '-1' ],
          1, qr/--max-wait must be a non-negative integer/ ],
        [ '--postgresql-conf naming a missing file',
          [ @base, '--postgresql-conf', '/nonexistent_061/postgresql.conf' ],
          1, qr/postgresql\.conf file does not exist/ ],
        [ '--hba-conf naming a missing file',
          [ @base, '--hba-conf', '/nonexistent_061/pg_hba.conf' ],
          1, qr/pg_hba\.conf file does not exist/ ],
        [ '--postgresql-auto-conf naming a missing file',
          [ @base, '--postgresql-auto-conf', '/nonexistent_061/auto.conf' ],
          1, qr/postgresql\.auto\.conf file does not exist/ ],
        [ 'unknown option',
          [ @base, '--no-such-option' ],
          1, qr/(Unknown option|unrecognized option)/ ],
    );

    for my $c (@cases) {
        my ($desc, $args, $want_rc, $want_msg) = @$c;
        note("Testing: $desc");
        my ($rc, $out) = scs(@$args);
        is($rc, $want_rc, "$desc: exit status");
        like($out, $want_msg, "$desc: message");
    }

    # --cleanup needs neither a subscriber name nor DSNs
    note('Testing: --cleanup --bidirectional needs only --pgdata');
    my ($rc, $out) = scs('--bidirectional', '--cleanup', '--pgdata', $DIR);
    is($rc, 0, '--cleanup of a nonexistent directory exits 0');
    like($out, qr/nothing to clean up/, '--cleanup reports there is nothing to do');

    ok(!-e $DIR, 'no data directory was created by any rejected invocation');
    ok(!-e "$DIR.spock_bidir_pending.json",
       'no sidecar was created by any rejected invocation');

}

# Total size of WAL segment files in a data directory's pg_wal.
sub wal_segments_bytes {
    my ($datadir) = @_;
    my $total = 0;
    opendir(my $dh, "$datadir/pg_wal") or die "cannot open $datadir/pg_wal: $!";
    for my $f (readdir $dh) {
        next unless $f =~ /^[0-9A-F]{24}$/;
        $total += -s "$datadir/pg_wal/$f";
    }
    closedir $dh;
    return $total;
}

# check_preconditions() requires zero outbound replication lag on the source.
sub wait_for_zero_lag {
    my ($node_num, $timeout) = @_;
    for (1 .. $timeout) {
        my $lag = scalar_query($node_num,
            "SELECT COUNT(*) FROM pg_replication_slots" .
            " WHERE slot_type = 'logical' AND plugin = 'spock_output'" .
            " AND (confirmed_flush_lsn IS NULL" .
            " OR confirmed_flush_lsn < pg_current_wal_lsn())");
        return 1 if defined $lag && $lag eq '0';
        sleep(1);
    }
    return 0;
}

# =============================================================================
# SETUP
# =============================================================================
create_cluster(2, 'Create bidirectional 2-node cluster');

my $config      = get_test_config();
my $node_ports  = $config->{node_ports};
my $dbname      = $config->{db_name};
my $host        = $config->{host};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};
my $pg_bin      = $config->{pg_bin};
my $n1_datadir  = $config->{node_datadirs}->[0];
my $n1_port     = $node_ports->[0];

my $n1_dsn = "host=$host port=$n1_port dbname=$dbname"
           . " user=$db_user password=$db_password";

cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 <-> n2 bidirectionally');

my $n3_port    = $node_ports->[1] + 1;
my $n3_datadir = '/tmp/tmp_spock_node_2_datadir_061_basebackup';
my $n3_sidecar = "${n3_datadir}.spock_bidir_pending.json";
my $n3_dsn     = "host=$host port=$n3_port dbname=$dbname"
               . " user=$db_user password=$db_password";
remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_sidecar) if -f $n3_sidecar;

# n3's postgresql.conf is copied from n1 by the backup, port included; all
# nodes share a host here, so n3 gets its own port.
my $n3_conf = '/tmp/tmp_spock_node_2_postgresql.conf.override_061';
open my $conf_fh, '>', $n3_conf or die "Cannot write $n3_conf: $!";
print $conf_fh "shared_preload_libraries='spock'\n";
print $conf_fh output_plugin_libraries_conf($pg_bin);
print $conf_fh "wal_level=logical\n";
print $conf_fh "spock.enable_ddl_replication=on\n";
print $conf_fh "spock.include_ddl_repset=on\n";
print $conf_fh "spock.allow_ddl_from_functions=on\n";
print $conf_fh "spock.exception_behaviour=sub_disable\n";
print $conf_fh "spock.conflict_resolution=last_update_wins\n";
print $conf_fh "track_commit_timestamp=on\n";
print $conf_fh "min_wal_size=32MB\n";
print $conf_fh "port=$n3_port\n";
print $conf_fh "listen_addresses='*'\n";
print $conf_fh "logging_collector=on\n";
print $conf_fh "log_directory='" . $config->{log_dir} . "'\n";
print $conf_fh "log_filename='00${n3_port}.log'\n";
close $conf_fh;

my @scs_join = (
    $SCS_BIN, '--bidirectional',
    '--pgdata',          $n3_datadir,
    '--subscriber-name', 'n3',
    '--provider-dsn',    $n1_dsn,
    '--subscriber-dsn',  $n3_dsn,
    '--postgresql-conf', $n3_conf,
);

# =============================================================================
# 2. Shell metacharacters in --extra-basebackup-args are rejected up front
# =============================================================================
note('Testing: unsafe --extra-basebackup-args are rejected before any state exists');

my $marker = '/tmp/tmp_spock_061_injected_marker';
unlink($marker) if -e $marker;

my @unsafe = (
    "--label=x;touch $marker",
    "--label=x|touch $marker",
    "--label=x&touch $marker",
    "--label=x`touch $marker`",
    "--label=\$(touch $marker)",
    "--label=x>$marker",
    "--label=x<$marker",
);

for my $bad (@unsafe) {
    my $cmd = qq{"$SCS_BIN" --bidirectional --pgdata "$n3_datadir" }
            . qq{--subscriber-name n3 --provider-dsn "$n1_dsn" }
            . qq{--subscriber-dsn "$n3_dsn" }
            . qq{--extra-basebackup-args '$bad' 2>&1};
    my $out = qx{$cmd};
    my $rc = $? >> 8;
    isnt($rc, 0, "rejected with non-zero exit: $bad");
    like($out, qr/unsafe shell characters/,
         "rejection names the cause: $bad");
}

ok(!-e $marker, 'no injected command ran');
ok(!-e $n3_datadir, 'no data directory created by rejected invocations');
ok(!-e $n3_sidecar, 'no pending-cleanup sidecar left by rejected invocations');
is(scalar_query(1, "SELECT COUNT(*) FROM pg_replication_slots " .
                   "WHERE slot_name LIKE 'spk_%n3%'"),
   '0', 'no source slot created by rejected invocations');

# =============================================================================
# 3. pg_basebackup command line: streamed WAL, fast checkpoint
# =============================================================================
note('Testing: pg_basebackup is invoked with -X s -c fast');

# A backup that fails immediately keeps this cheap; -v -v prints the command
# before it runs.
my $bb_cmd = qq{"$SCS_BIN" -v -v --bidirectional --pgdata "$n3_datadir" }
           . qq{--subscriber-name n3 }
           . qq{--provider-dsn "$n1_dsn sslpassword=ssl_secret_061" }
           . qq{--subscriber-dsn "$n3_dsn" }
           . qq{--extra-basebackup-args '--waldir=/nonexistent_061_waldir' 2>&1};
my $cmd_out = qx{$bb_cmd};
isnt($? >> 8, 0, 'backup with an unusable --waldir fails');
like($cmd_out, qr/Running pg_basebackup: .*-X s -c fast/,
     'pg_basebackup requested with streamed WAL and fast checkpoint');
unlike($cmd_out, qr/(?<!ssl)password=/,
       'the password is not on the pg_basebackup command line or in debug output');
like($cmd_out, qr/secret option other than the password/,
     'a secret option that cannot be moved off the command line is warned about');

is(system($SCS_BIN, '--bidirectional', '--cleanup', '--force',
          '--pgdata', $n3_datadir),
   0, '--cleanup --force removes the failed attempt');
remove_tree($n3_datadir) if -d $n3_datadir;

# A failed connection must not echo the password from the connection string.
note('Testing: connection errors do not include the password');
{
    my $secret = 's3cr3t_061_pw';
    my $ssl_secret = 's3cr3t_061_ssl';
    my $unreachable = qq{"$SCS_BIN" --bidirectional --pgdata "$n3_datadir" }
        . qq{--subscriber-name n3 }
        . qq{--provider-dsn "host=127.0.0.1 port=1 dbname=x user=u password=$secret sslpassword=$ssl_secret" }
        . qq{--subscriber-dsn "$n3_dsn" 2>&1};
    my $out = qx{$unreachable};
    isnt($? >> 8, 0, 'join against an unreachable provider fails');
    like($out, qr/Connection to database failed.*connection string was:/s,
         'the connection failure is reported with the connection string');
    unlike($out, qr/\Q$secret\E/, 'the password is not in the error output');
    unlike($out, qr/\Q$ssl_secret\E/, 'sslpassword is not in the error output');
    ok(!-e $n3_datadir, 'no data directory created');
}

# =============================================================================
# 4-6. Join under write load with a long checkpoint_timeout
# =============================================================================
note('Testing: join with checkpoint_timeout=1h and write load on the source');

# A stray slot on the source; slots must not be carried into the new node.
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "SELECT pg_create_physical_replication_slot('bb_probe_slot')";

system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "CREATE TABLE bb_load (id bigserial PRIMARY KEY, pad text)";

# Pre-existing WAL on the source, kept in n1's pg_wal, that a correct backup
# must not copy.
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "ALTER SYSTEM SET wal_keep_size = '2GB'";
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "ALTER SYSTEM SET max_wal_size = '4GB'";
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "ALTER SYSTEM SET checkpoint_timeout = '1h'";
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "SELECT pg_reload_conf()";
system_or_bail "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "INSERT INTO bb_load (pad) SELECT repeat('x', 200) " .
    "FROM generate_series(1, $PREFILL_ROWS)";

ok(wait_for_zero_lag(1, 120), 'source outbound replication drained before the join');

my $n1_wal_before = wal_segments_bytes($n1_datadir);
my $seg_size = scalar_query(1,
    "SELECT setting::bigint FROM pg_settings " .
    "WHERE name = 'wal_segment_size'");
$seg_size = 16 * 1024 * 1024 unless $seg_size =~ /^\d+$/ && $seg_size > 0;
my $slack = $WAL_SLACK_SEGS * $seg_size;

# The join runs as a child; write load starts once the source slot exists
# (check_preconditions() has passed by then), so the backup itself runs
# against a busy source.
my $start_lsn = scalar_query(1, "SELECT pg_current_wal_lsn()");
my $t0 = time();

my $join_pid = fork();
die "fork failed: $!" unless defined $join_pid;
if ($join_pid == 0) {
    exec(@scs_join) or die "exec failed: $!";
}

my $manifest = "$n3_datadir/spock_bidirectional_manifest.json";
my $slot_seen = 0;
for (1 .. 60) {
    if (-f $n3_sidecar || -f $manifest) { $slot_seen = 1; last; }
    last if waitpid($join_pid, WNOHANG) != 0;
    sleep(1);
}

my $writer_pid = fork();
die "fork failed: $!" unless defined $writer_pid;
if ($writer_pid == 0) {
    setpgrp(0, 0);
    exec('sh', '-c',
         "while :; do $pg_bin/psql -q -p $n1_port -d $dbname -c " .
         "\"INSERT INTO bb_load (pad) SELECT repeat('y', 200) " .
         "FROM generate_series(1, 5000)\" || exit 1; sleep 1; done")
        or die "exec failed: $!";
}

my $join_rc;
for (1 .. $JOIN_TIMEOUT_SEC) {
    my $w = waitpid($join_pid, WNOHANG);
    if ($w == $join_pid) { $join_rc = $? >> 8; last; }
    sleep(1);
}
my $elapsed = time() - $t0;

kill('TERM', -$writer_pid);
waitpid($writer_pid, 0);

unless (defined $join_rc) {
    kill('KILL', $join_pid);
    waitpid($join_pid, 0);
}

ok($slot_seen, 'source slot created (join passed its preconditions)');
is($join_rc, 0, 'join exits 0 with write load and checkpoint_timeout=1h');
cmp_ok($elapsed, '<', $JOIN_TIMEOUT_SEC,
       sprintf('join completed in %.0fs, not paced by checkpoint_timeout', $elapsed));

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');

# 5. WAL volume
note('Testing: new node pg_wal does not carry WAL older than the backup');

my $generated = scalar_query(1,
    "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), '$start_lsn')");
my $n3_wal = wal_segments_bytes($n3_datadir);
my $bound  = $generated + $slack;

note(sprintf('n1 pg_wal before join: %d MB; WAL generated during join: %d MB; ' .
             'n3 pg_wal: %d MB; bound: %d MB',
             $n1_wal_before / 1048576, $generated / 1048576,
             $n3_wal / 1048576, $bound / 1048576));

cmp_ok($n3_wal, '<=', $bound,
       'n3 pg_wal bounded by WAL generated during the join plus slack');
cmp_ok($n1_wal_before, '>', $bound > $n3_wal ? $n3_wal : $bound,
       'source held more pre-existing WAL than n3 carries (check is discriminating)');

# 6. Slots are not carried over
note('Testing: source replication slots are not carried into the new node');

is(scalar_query(1,
       "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'bb_probe_slot'"),
   '1', 'probe slot exists on n1');
my $n3_slots = `$pg_bin/psql -p $n3_port -d $dbname -t -A -c "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name = 'bb_probe_slot'"`;
$n3_slots =~ s/\s+//g;
is($n3_slots, '0', 'probe slot absent from n3');
ok(!-e "$n3_datadir/pg_replslot/bb_probe_slot",
   'probe slot directory absent from n3 pg_replslot');

# =============================================================================
# 7-8. Reuse of an existing --pgdata, and the state the new node is left in.
# The join above is torn down first so n3 can be joined again.
# =============================================================================
system_maybe $SCS_BIN, '--bidirectional', '--cleanup', '--force',
    '--pgdata', $n3_datadir;
remove_tree($n3_datadir) if -d $n3_datadir;
unlink($n3_sidecar) if -f $n3_sidecar;

sub slurp {
    my ($path) = @_;
    return '' unless -f $path;
    open my $fh, '<', $path or die "cannot read $path: $!";
    local $/;
    my $c = <$fh>;
    close $fh;
    return $c // '';
}

# Run the join; returns (exit status, combined output).  Output goes to a file
# because a successful join leaves a running postmaster that would hold a pipe
# open.
sub join_n3 {
    my ($pgdata, @extra) = @_;
    my $cmd = join(' ', map { "'$_'" } (
        $SCS_BIN, '--bidirectional',
        '--pgdata',          $pgdata,
        '--subscriber-name', 'n3',
        '--provider-dsn',    $n1_dsn,
        '--subscriber-dsn',  $n3_dsn,
        '--postgresql-conf', $n3_conf,
        @extra));
    my $log = '/tmp/tmp_spock_061_join.out';
    my $rc  = system("$cmd > '$log' 2>&1 < /dev/null") >> 8;
    return ($rc, slurp($log));
}

sub n3_slots_on_n1 {
    return scalar_query(1,
        "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_%n3%'");
}

sub backup_of_n1 {
    my ($dir) = @_;
    remove_tree($dir) if -d $dir;
    local $ENV{PGPASSWORD} = $db_password;
    return system("$pg_bin/pg_basebackup -D '$dir' -d '$n1_dsn' -X stream " .
                  "-c fast > /dev/null 2>&1");
}

# Assert a rejected attempt changed nothing outside the directory it was given.
sub assert_nothing_created {
    my ($what) = @_;
    is(n3_slots_on_n1(), '0', "$what: no source slot created");
    ok(!-e $n3_sidecar, "$what: no pending-cleanup sidecar created");
}

my @tmp_dirs = ('/tmp/tmp_spock_061_notpg', '/tmp/tmp_spock_061_othercluster',
                '/tmp/tmp_spock_061_promoted');


remove_tree($_) for @tmp_dirs;
ok(wait_for_zero_lag(1, 120), 'source outbound replication drained');

# =============================================================================
# 7a. Not a postgres data directory
# =============================================================================
note('Testing: a non-empty directory that is not a data directory is rejected');

my $notpg = '/tmp/tmp_spock_061_notpg';
make_path($notpg);
open my $fh, '>', "$notpg/keep.txt" or die $!;
print $fh "keep me\n";
close $fh;

{
    my ($rc, $out) = join_n3($notpg);
    isnt($rc, 0, 'non-data directory: join rejected');
    like($out, qr/exists but is not valid postgres data directory/,
         'non-data directory: rejection names the cause');
    ok(-f "$notpg/keep.txt", 'non-data directory: content left in place');
    assert_nothing_created('non-data directory');
}

# =============================================================================
# 7b. Another cluster's data directory
# =============================================================================
note("Testing: another cluster's data directory is rejected (system identifier)");

my $other = '/tmp/tmp_spock_061_othercluster';
is(system("$pg_bin/initdb -D '$other' -U postgres > /dev/null 2>&1"), 0,
   'initdb of an unrelated cluster');
my $other_ctl_before = `$pg_bin/pg_controldata '$other'`;

{
    my ($rc, $out) = join_n3($other);
    isnt($rc, 0, 'other cluster: join rejected');
    like($out, qr/not basebackup of remote node/,
         'other cluster: rejection names the system identifier mismatch');
    is(`$pg_bin/pg_controldata '$other'`, $other_ctl_before,
       'other cluster: control file unchanged');
    ok(!-e "$other/postmaster.pid", 'other cluster: not started');
    assert_nothing_created('other cluster');
}

# =============================================================================
# 7c. A copy already past the source's timeline
# =============================================================================
note("Testing: a copy of the source already on a later timeline is rejected");

my $promoted = '/tmp/tmp_spock_061_promoted';
is(backup_of_n1($promoted), 0, 'base backup of n1 taken');
is(system("$pg_bin/pg_resetwal -f -l 000000020000000100000000 '$promoted' " .
          "> /dev/null 2>&1"), 0,
   'timeline of the copy advanced with pg_resetwal');
like(`$pg_bin/pg_controldata '$promoted'`,
     qr/Latest checkpoint's TimeLineID:\s+2\b/,
     'the copy is on timeline 2');

{
    my ($rc, $out) = join_n3($promoted);
    isnt($rc, 0, 'promoted copy: join rejected');
    like($out, qr/already on timeline 2, past the source's current timeline 1/,
         'promoted copy: rejection names the timelines');
    ok(!-e "$promoted/postmaster.pid", 'promoted copy: not started');
    assert_nothing_created('promoted copy');
}

# =============================================================================
# 7d. A valid base backup: the join resumes from it
# =============================================================================
note('Testing: a valid base backup of the source is reused');

is(backup_of_n1($n3_datadir), 0, 'base backup of n1 taken as the n3 data directory');
ok(wait_for_zero_lag(1, 60), 'source outbound replication drained');

{
    my ($rc, $out) = join_n3($n3_datadir, '-v', '-v');
    is($rc, 0, 'join from an existing base backup exits 0')
        or diag("output:\n$out");
    like($out, qr/Reusing existing data directory/,
         'the existing directory was reused, not re-backed-up');
    unlike($out, qr/Running pg_basebackup/, 'pg_basebackup was not run');
}

ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 postgres is running');
ok(wait_for_sub_status(3, 'sub_n3_n2', 'replicating', 30),
   'direct peer subscription is replicating on n3');
is(scalar_query(3, 'SHOW spock.readonly'), 'off', 'spock.readonly lifted on n3');

# =============================================================================
# 8. State the new node is left in
# =============================================================================
note('Testing: the new node is a plain primary with no recovery leftovers');

ok(!-e "$n3_datadir/standby.signal", 'no standby.signal');
ok(!-e "$n3_datadir/recovery.signal", 'no recovery.signal');
is(scalar_query(3, 'SELECT pg_is_in_recovery()'), 'f', 'n3 is not in recovery');

my $auto = slurp("$n3_datadir/postgresql.auto.conf");
unlike($auto, qr/^\s*primary_conninfo\s*=/m,
       'primary_conninfo is not left in postgresql.auto.conf');
unlike($auto, qr/^\s*recovery_target/m,
       'recovery_target_* settings are not left in postgresql.auto.conf');
unlike($auto, qr/\Q$db_password\E/,
       'the source password is not left in postgresql.auto.conf');

note('Testing: n3 stays a primary and keeps replicating across a restart');

is(system("$pg_bin/pg_ctl restart -D '$n3_datadir' -m fast -s " .
          "-l '$config->{log_dir}/n3_065_restart.log' > /dev/null 2>&1"), 0,
   'n3 restarted');
ok(wait_for_pg_ready($host, $n3_port, $pg_bin, 30), 'n3 accepts connections after the restart');
is(scalar_query(3, 'SELECT pg_is_in_recovery()'), 'f',
   'n3 is still not in recovery after the restart');
ok(wait_for_sub_status(3, 'sub_n3_n2', 'replicating', 30),
   'direct peer subscription still replicating after the restart');

# =============================================================================
# CLEANUP
# =============================================================================
system_maybe "$pg_bin/pg_ctl", 'stop', '-D', $n3_datadir, '-m', 'immediate';
system_maybe "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "SELECT pg_drop_replication_slot('bb_probe_slot')";
system_maybe "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "ALTER SYSTEM RESET wal_keep_size";
system_maybe "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "ALTER SYSTEM RESET max_wal_size";
system_maybe "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "ALTER SYSTEM RESET checkpoint_timeout";
system_maybe "$pg_bin/psql", '-q', '-p', $n1_port, '-d', $dbname, '-c',
    "DROP TABLE IF EXISTS bb_load";
remove_tree($_) for $n3_datadir, @tmp_dirs;
unlink($n3_conf) if -f $n3_conf;
unlink($marker) if -e $marker;
destroy_cluster('Cleanup');

done_testing();
