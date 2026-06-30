#!/usr/bin/perl
# =============================================================================
# Test: 026_no_double_wal_flush.pl
#       Verify that applied remote-origin commits do not trigger an extra
#       XLogFlush.  Prior to the WAL-RMGR removal, handle_commit called
#       spock_apply_progress_add_to_wal() which issued a synchronous
#       XLogFlush after the commit record's own flush -- doubling fsync
#       pressure on the apply hot path.  After the removal, each applied
#       commit should produce exactly one fsync (the commit record itself).
#
# Uses a WAL-fsync counter as an indirect measure.  With
# synchronous_commit=on and no other WAL-generating activity, N applied
# commits should produce ~N fsyncs, not ~2N.
#
# The counter source depends on the server version: PG15-17 expose
# pg_stat_wal.wal_sync, but PG18 removed wal_sync/wal_write from pg_stat_wal
# and relocated WAL I/O accounting to pg_stat_io (object = 'wal').  See
# $wal_sync_query below.
# =============================================================================

use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail
    command_ok get_test_config scalar_query psql_or_bail
    wait_for_sub_status wait_for_pg_ready
);

sub wait_until {
    my ($timeout_s, $probe) = @_;
    my $deadline = time() + $timeout_s;
    while (time() < $deadline) {
        return 1 if $probe->();
        select(undef, undef, undef, 0.20);
    }
    return 0;
}

create_cluster(2, 'Create 2-node cluster');

my $conf      = get_test_config();
my $host      = $conf->{host};
my $pg_bin    = $conf->{pg_bin};
my $ports     = $conf->{node_ports};
my $datadirs  = $conf->{node_datadirs};
my $dbname    = $conf->{db_name};
my $user      = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];
my $sub_dir   = $datadirs->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

# Pick a WAL-fsync counter that exists on the running server.  pg_stat_wal
# lost wal_sync/wal_write in PG18 (moved to pg_stat_io), so use pg_stat_io's
# WAL fsyncs there and fall back to pg_stat_wal.wal_sync on PG15-17.
my $pg_version_num = scalar_query(2, "SELECT current_setting('server_version_num')");
my $wal_sync_query = ($pg_version_num >= 180000)
    ? "SELECT COALESCE(sum(fsyncs), 0)::bigint FROM pg_stat_io WHERE object = 'wal' AND context = 'normal'"
    : "SELECT wal_sync FROM pg_stat_wal";
diag("WAL-fsync counter source (server_version_num=$pg_version_num): $wal_sync_query");

# Force synchronous_commit=on so every commit record is flushed.
psql_or_bail(2, "ALTER SYSTEM SET synchronous_commit = 'on'");
system_or_bail "$pg_bin/pg_ctl", '-D', $sub_dir, 'reload';

psql_or_bail(1, "CREATE TABLE public.wal_flush_test (id int primary key, v text)");
psql_or_bail(2, "CREATE TABLE public.wal_flush_test (id int primary key, v text)");

psql_or_bail(2, "SELECT spock.sub_create('sub', '$prov_dsn', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub', 'replicating', 30), 'subscription is replicating');

# Baseline wal_sync. We CHECKPOINT first so any pending dirty state doesn't
# count against our measurement.
psql_or_bail(2, 'CHECKPOINT');
select(undef, undef, undef, 0.5);

my $before = scalar_query(2, $wal_sync_query);
ok($before =~ /^\d+$/, "baseline wal sync count=$before");

# Apply N commits. Each is a small transaction to minimize non-commit WAL
# volume; bigger transactions would drag in checkpoints, XLogBackgroundFlush
# activity, etc. that muddy the fsync count.
my $N = 30;
for my $i (1 .. $N) {
    psql_or_bail(1, "INSERT INTO public.wal_flush_test VALUES ($i, 'row')");
}
ok(wait_until(30, sub {
    scalar_query(2, "SELECT count(*) FROM public.wal_flush_test") eq "$N"
}), "all $N rows replicated");

# Let any lingering feedback/statistic flushes settle.
select(undef, undef, undef, 1.0);

my $after = scalar_query(2, $wal_sync_query);
my $delta = $after - $before;
diag("wal sync delta over $N applied commits: $delta");

# Before the fix: at least N extra syncs from the per-commit XLogFlush in
# spock_apply_progress_add_to_wal(), independent of synchronous_commit.
# After the fix: walwriter-driven flushing dominates; actual syncs for N
# commits can be far below N when spock.synchronous_commit=off (the default
# for the apply worker).
#
# The regression guard we care about: applied commits must NOT produce a
# sync-per-commit. Assert the delta is well below N.  This catches any
# re-introduction of an XLogFlush in the apply hot path.
cmp_ok($delta, '<', $N,
    "wal sync delta ($delta) is below N=$N -- applied commits do not force a sync per commit");

# Lower bound: zero is unlikely because the walwriter fires periodically,
# but we don't want to require a specific minimum -- the test is about the
# upper bound. Just log the observed value.
diag("For context: zero would require a very quiet walwriter; a huge number would indicate a per-commit XLogFlush regression.");

psql_or_bail(2, "SELECT spock.sub_drop('sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
