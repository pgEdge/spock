use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
  create_cluster destroy_cluster system_or_bail command_ok get_test_config
  scalar_query psql_or_bail wait_for_sub_status wait_for_pg_ready
);


sub wait_until {
  my ($timeout_s, $probe) = @_;
  my $deadline = time() + $timeout_s;
  while (time() < $deadline) {
    return 1 if $probe->();
    select(undef, undef, undef, 0.20); # 200ms
  }
  return 0;
}


# =============================================================================
# Setup: 3-node cluster
# n1 and n2 are used throughout; n3 is introduced in Phase 5.
# =============================================================================

create_cluster(3, 'Create a 3-node cluster');

my $conf = get_test_config();
my $host = $conf->{host};
my $pg_bin = $conf->{pg_bin};
my $ports = $conf->{node_ports};
my $datadirs = $conf->{node_datadirs};
my $dbname = $conf->{db_name};
my $user   = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];
my $n3_port   = $ports->[2];

my $prov_dir = $datadirs->[0];
my $sub_dir  = $datadirs->[1];
my $n3_dir   = $datadirs->[2];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";
my $n3_dsn   = "host=$host port=$n3_port  dbname=$dbname user=$user";


# =============================================================================
# Phase 1: DML replication and initial progress
# =============================================================================

psql_or_bail(1, "CREATE TABLE public.test_progress (id int primary key, data text)");
psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], true, true)");

ok(wait_until(30, sub {
  scalar_query(2, "SELECT to_regclass('public.test_progress') IS NOT NULL") eq 't'
}), 'subscriber has table after initial sync');

psql_or_bail(1, "INSERT INTO public.test_progress SELECT g, 'Test Val' FROM generate_series(1,3) g");

my $prov_lsn_after_insert = scalar_query(1, "SELECT pg_current_wal_lsn()");
ok($prov_lsn_after_insert =~ /^[0-9A-F]+\/[0-9A-F]+$/, "provider LSN after insert: $prov_lsn_after_insert");

ok(wait_until(30, sub {
  scalar_query(2, "SELECT count(*) FROM public.test_progress") eq '3'
}), 'subscriber has 3 rows');

my $rows = scalar_query(2, q{
  SELECT count(*) FROM spock.apply_group_progress()
});
ok($rows ne '' && $rows >= 1, "apply_group_progress() yields at least one row");

my $prog = scalar_query(2, q{
  SELECT remote_commit_lsn || '|' || remote_insert_lsn
  FROM spock.apply_group_progress()
  ORDER BY last_updated_ts DESC LIMIT 1
});
ok($prog =~ /\S+\|\S+/, "fetched progress LSNs from subscriber: $prog");

my ($commit_lsn, $insert_lsn) = split(/\|/, $prog, 2);
my $cmp_commit = scalar_query(2, "SELECT (pg_lsn '$commit_lsn') <= (pg_lsn '$prov_lsn_after_insert')");
is($cmp_commit, 't', "remote_commit_lsn <= provider current LSN");

my $cmp_insert = scalar_query(2, "SELECT (pg_lsn '$insert_lsn') <= (pg_lsn '$prov_lsn_after_insert')");
is($cmp_insert, 't', "remote_insert_lsn <= provider current LSN");


# =============================================================================
# Phase 2: Clean restart — resource.dat seeds shmem
# =============================================================================

my $before_ts = scalar_query(2, q{ SELECT max(remote_commit_ts) FROM spock.apply_group_progress() });
ok($before_ts ne '', "captured remote_commit_ts before clean restart: $before_ts");

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok((-f "$sub_dir/spock/resource.dat"), "resource.dat exists after clean stop");

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", 'start';

ok(wait_until(30, sub {
  my $ts = scalar_query(2, q{ SELECT max(remote_commit_ts) FROM spock.apply_group_progress() });
  ($ts ne '');
}), 'progress present after clean restart');

my $after_ts = scalar_query(2, q{
  SELECT max(remote_commit_ts) FROM spock.apply_group_progress()
});
ok($after_ts ge $before_ts, "progress is same before and after clean restart");


# =============================================================================
# Phase 3: Crash restart — WAL REDO must advance progress
# =============================================================================

psql_or_bail(1, "INSERT INTO public.test_progress SELECT g, 'x' FROM generate_series(4,60) g");
my $prov_lsn_after_bulk = scalar_query(1, "SELECT pg_current_wal_lsn()");
ok($prov_lsn_after_bulk =~ /^[0-9A-F]+\/[0-9A-F]+$/, "provider LSN after bulk: $prov_lsn_after_bulk");

system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'immediate', 'stop';
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", 'start';

ok(wait_until(40, sub {
  scalar_query(1, "SELECT count(*) FROM public.test_progress") eq
  scalar_query(2, "SELECT count(*) FROM public.test_progress")
}), 'subscriber caught up after crash via WAL REDO');

my $final_prog = scalar_query(2, q{
  SELECT remote_commit_lsn || '|' || remote_insert_lsn || '|' || remote_commit_ts
  FROM spock.apply_group_progress()
  ORDER BY remote_commit_ts DESC LIMIT 1
});
ok($final_prog =~ /\S+\|\S+\|\S+/, "latest progress after crash restart: $final_prog");

my ($commit_lsn, $insert_lsn, $commit_ts) = split(/\|/, $final_prog, 3);
ok($commit_ts ge $after_ts, "remote_commit_ts advanced after crash restart");

my $cmp_f_commit = scalar_query(2, "SELECT (pg_lsn '$commit_lsn') <= (pg_lsn '$prov_lsn_after_bulk')");
is($cmp_f_commit, 't', "remote_commit_lsn <= provider current LSN");

my $cmp_f_insert = scalar_query(2, "SELECT (pg_lsn '$insert_lsn') <= (pg_lsn '$prov_lsn_after_bulk')");
is($cmp_f_insert, 't', "remote_insert_lsn <= provider current LSN");

my $q1 = scalar_query(2, "SELECT count(*) FROM public.test_progress");
my $q2 = scalar_query(1, "SELECT count(*) FROM public.test_progress");
is($q1, $q2, "row counts equal after crash restart");


# =============================================================================
# Phase 4: Stale resource.dat and missing entries after crash
#
# Scenario A — stale values:
#   n1 replicates batch-1 to n2. Clean stop n2 → resource.dat written with
#   batch-1 values (stale baseline). n1 replicates batch-2 → WAL progress
#   records written. SIGKILL n2 (resource.dat stays at batch-1). After
#   recovery: WAL replay must advance n1 progress to batch-2, not regress to
#   the batch-1 values in resource.dat.
#
# Scenario B — missing entries:
#   n3 subscribes to n2 AFTER resource.dat was written. n3's progress entry
#   exists in WAL but not in resource.dat. SIGKILL n2. After recovery: WAL
#   replay must create n3's entry from scratch (not silently drop it).
#
# Separate tables (t_n1, t_n3) prevent PK conflicts on n2 so that
# exception_behaviour / sub_disable cannot mask the bug.
# =============================================================================

psql_or_bail(1, "CREATE TABLE public.t_n1 (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.t_n1 (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('sub_n1_n2', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30), 'sub_n1_n2 is replicating');

# Batch-1: 100 rows from n1 — these become the stale resource.dat baseline
psql_or_bail(1, "INSERT INTO public.t_n1 SELECT g, 'b1_' || g FROM generate_series(1,100) g");
ok(wait_until(30, sub {
    scalar_query(2, "SELECT count(*) FROM public.t_n1") eq '100'
}), 'n2 has batch-1 rows (100)');

ok(wait_until(30, sub {
    my $c = scalar_query(2, "SELECT count(*) FROM spock.progress");
    defined $c && $c >= 1
}), 'n2 has progress entry for n1');

my $batch1_n1 = scalar_query(2, q{
    SELECT p.remote_commit_ts || '|' || p.remote_commit_lsn
    FROM spock.progress p
    JOIN spock.node n ON n.node_id = p.remote_node_id
    WHERE n.node_name = 'n1'
});
ok($batch1_n1 =~ /\S+\|\S+/, "captured batch-1 n1 progress: $batch1_n1");
my ($b1_ts) = split(/\|/, $batch1_n1, 2);
diag("Batch-1 progress (stale resource.dat baseline): $batch1_n1");

# Clean stop n2 → spock_checkpoint_hook writes resource.dat with batch-1 values
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-m', 'fast', 'stop';
ok(-f "$sub_dir/spock/resource.dat", 'resource.dat written after clean stop of n2');
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'n2 back up after clean restart');

# Scenario B setup: add n3 AFTER resource.dat was written — n3 never in resource.dat
psql_or_bail(3, "CREATE TABLE public.t_n3 (id int primary key, val text)");
psql_or_bail(2, "CREATE TABLE public.t_n3 (id int primary key, val text)");

psql_or_bail(2, "SELECT spock.sub_create('sub_n3_n2', '$n3_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub_n3_n2', 'replicating', 30), 'sub_n3_n2 is replicating');

psql_or_bail(3, "INSERT INTO public.t_n3 SELECT g, 'n3_' || g FROM generate_series(1,50) g");
ok(wait_until(30, sub {
    scalar_query(2, "SELECT count(*) FROM public.t_n3") eq '50'
}), 'n2 received 50 rows from n3');

# Batch-2 from n1 — newer WAL progress records on top of stale resource.dat
psql_or_bail(1, "INSERT INTO public.t_n1 SELECT g, 'b2_' || g FROM generate_series(101,200) g");
ok(wait_until(30, sub {
    scalar_query(2, "SELECT count(*) FROM public.t_n1") eq '200'
}), 'n2 has batch-2 rows (200)');

my $pre_crash_count = scalar_query(2, "SELECT count(*) FROM spock.progress");
ok($pre_crash_count >= 2, "n2 has progress entries for n1 AND n3 ($pre_crash_count entries)");

my $batch2_n1 = scalar_query(2, q{
    SELECT p.remote_commit_ts || '|' || p.remote_commit_lsn
    FROM spock.progress p
    JOIN spock.node n ON n.node_id = p.remote_node_id
    WHERE n.node_name = 'n1'
});
ok($batch2_n1 =~ /\S+\|\S+/, "captured batch-2 n1 progress: $batch2_n1");

my $batch2_n3 = scalar_query(2, q{
    SELECT p.remote_commit_ts || '|' || p.remote_commit_lsn
    FROM spock.progress p
    JOIN spock.node n ON n.node_id = p.remote_node_id
    WHERE n.node_name = 'n3'
});
ok($batch2_n3 =~ /\S+\|\S+/, "captured batch-2 n3 progress (NOT in resource.dat): $batch2_n3");

my ($b2_n1_ts) = split(/\|/, $batch2_n1, 2);
ok($b2_n1_ts gt $b1_ts, "batch-2 n1 ts ($b2_n1_ts) newer than stale resource.dat ts ($b1_ts)");

diag("Batch-2 n1 (newer than resource.dat): $batch2_n1");
diag("Batch-2 n3 (absent from resource.dat): $batch2_n3");

# Stop providers so apply workers on n2 cannot reconnect after restart;
# resource.dat retains batch-1 n1 only (n3 never written to resource.dat)
system_or_bail "$pg_bin/pg_ctl", '-D', $prov_dir, '-m', 'fast', 'stop';
system_or_bail "$pg_bin/pg_ctl", '-D', $n3_dir,   '-m', 'fast', 'stop';
pass('n1 and n3 stopped — apply workers on n2 cannot reconnect after crash');

select(undef, undef, undef, 1.0);

# SIGKILL n2 — no shmem_exit, no resource.dat update
my $pid_file = "$sub_dir/postmaster.pid";
open(my $fh, '<', $pid_file) or die "Cannot open $pid_file: $!";
my $n2_pid = <$fh>; chomp($n2_pid); close($fh);
diag("SIGKILLing n2 (PID $n2_pid) — resource.dat has batch-1 n1 only");
kill 'KILL', $n2_pid;
pass('n2 SIGKILLed');

select(undef, undef, undef, 2.0);

# Restart n2 with providers still down — only WAL replay can restore progress
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, '-o', "-p $sub_port", '-w', 'start';
ok(wait_for_pg_ready($host, $sub_port, $pg_bin, 30), 'n2 accepting connections after crash recovery');

# Assert Scenario A: n1 progress must be batch-2, not regressed to batch-1
my $post_count = scalar_query(2, "SELECT count(*) FROM spock.progress");
is($post_count, $pre_crash_count,
    "progress row count preserved ($pre_crash_count rows) — FAIL = missing entries (Scenario B)");

my $post_n1 = scalar_query(2, q{
    SELECT p.remote_commit_ts || '|' || p.remote_commit_lsn
    FROM spock.progress p
    JOIN spock.node n ON n.node_id = p.remote_node_id
    WHERE n.node_name = 'n1'
});
is($post_n1, $batch2_n1,
    "n1 progress = batch-2 after recovery — FAIL = stale values regression (Scenario A)");

# Assert Scenario B: n3 entry must exist (was never in resource.dat)
my $post_n3 = scalar_query(2, q{
    SELECT p.remote_commit_ts || '|' || p.remote_commit_lsn
    FROM spock.progress p
    JOIN spock.node n ON n.node_id = p.remote_node_id
    WHERE n.node_name = 'n3'
});
is($post_n3, $batch2_n3,
    "n3 progress entry exists and correct — FAIL = missing entry (Scenario B)");

# Restart providers for cleanup
system_or_bail "$pg_bin/pg_ctl", '-D', $prov_dir, '-o', "-p $prov_port", '-w', 'start';
system_or_bail "$pg_bin/pg_ctl", '-D', $n3_dir,   '-o', "-p $n3_port",   '-w', 'start';


# =============================================================================
# Cleanup
# =============================================================================

psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
psql_or_bail(2, "SELECT spock.sub_drop('sub_n1_n2')");
psql_or_bail(2, "SELECT spock.sub_drop('sub_n3_n2')");
destroy_cluster('Destroy 3-node cluster');
done_testing();
