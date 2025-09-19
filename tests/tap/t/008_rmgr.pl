use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
  create_cluster destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail
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


# 1) create 2-node cluster (provider n1, subscriber n2) with Spock
create_cluster(2, 'Create a 2-node cluster');

# DSN for provider
my $conf = get_test_config();
my $host = $conf->{host};
my $pg_bin = $conf->{pg_bin};
my $ports = $conf->{node_ports};
my $datadirs = $conf->{node_datadirs};
my $dbname = $conf->{db_name};
my $user   = $conf->{db_user};

my $prov_port = $ports->[0];
my $sub_port  = $ports->[1];

my $prov_dsn = "host=$host port=$prov_port dbname=$dbname user=$user";

# Create a table on provider and a subscription on subscriber
psql_or_bail(1, "CREATE TABLE public.test_progress (id int primary key, data text)");
psql_or_bail(2, "SELECT spock.sub_create('test_sub', '$prov_dsn', ARRAY['default'], true, true)");

# Wait for structure to appear on subscriber
ok(wait_until(30, sub {
  scalar_query(2, "SELECT to_regclass('public.test_progress') IS NOT NULL") eq 't'
}), 'subscriber has table after initial sync');


# 2) DML on provider; progress on subscriber;
psql_or_bail(1, "INSERT INTO public.test_progress SELECT g, 'Test Val' FROM generate_series(1,3) g");

# Save provider LSN after insert
my $prov_lsn_after_insert = scalar_query(1, "SELECT pg_current_wal_lsn()");
ok($prov_lsn_after_insert =~ /^[0-9A-F]+\/[0-9A-F]+$/, "provider LSN after insert: $prov_lsn_after_insert");

# wait for rows to replicate
ok(wait_until(30, sub {
  scalar_query(2, "SELECT count(*) FROM public.test_progress") eq '3'
}), 'subscriber has 3 rows');

# progress rows should exist on subscriber
my $rows = scalar_query(2, q{
  SELECT count(*) FROM spock.apply_group_progress()
});
ok($rows ne '' && $rows >= 1, "apply_group_progress() yields at least one row");

# fetch latest progress and compare LSNs against provider current LSN
my $prog = scalar_query(2, q{
  SELECT remote_commit_lsn || '|' || remote_insert_lsn
  FROM spock.apply_group_progress()
  ORDER BY last_updated_ts DESC LIMIT 1
});
ok($prog =~ /\S+\|\S+/, "fetched progress LSNs from subscriber: $prog");

# compare LSN's of provider and subscriber
my ($commit_lsn, $insert_lsn) = split(/\|/, $prog, 2);
# Make sure progress LSNs are <= provider current LSN
my $cmp_commit = scalar_query(2, "SELECT (pg_lsn '$commit_lsn') <= (pg_lsn '$prov_lsn_after_insert')");
is($cmp_commit, 't', "remote_commit_lsn <= provider current LSN");

my $cmp_insert = scalar_query(2, "SELECT (pg_lsn '$insert_lsn') <= (pg_lsn '$prov_lsn_after_insert')");
is($cmp_insert, 't', "remote_insert_lsn <= provider current LSN");


# 3) Clean restart subscriber; File load should seed shmem;

# capture latest progress timestamp
my $before_ts = scalar_query(2, q{ SELECT max(remote_commit_ts) FROM spock.apply_group_progress() });
ok($before_ts ne '', "captured remote_commit_ts before clean restart: $before_ts");

# stop subscriber cleanly; dump file should be written;
system_or_bail "$pg_bin/pg_ctl", '-D', $datadirs->[1], '-m', 'fast', 'stop';
ok((-f $datadirs->[1] . "/spock/resource.dat"), "resource.dat exists on subscriber after clean stop");

# start subscriber again
system_or_bail "$pg_bin/pg_ctl", '-D', $datadirs->[1], '-o', "-p $sub_port", 'start';

# after restart; progress should be present, seeded;
ok(wait_until(30, sub {
  my $ts = scalar_query(2, q{ SELECT max(remote_commit_ts) FROM spock.apply_group_progress() });
  ($ts ne '');
}), 'progress present after clean restart');

my $after_ts = scalar_query(2, q{
  SELECT max(remote_commit_ts)
  FROM spock.apply_group_progress()
});
ok($after_ts ge $before_ts, "progress is same before and after clean restart");

# 4) Crash restart; WAL REDO must advance progress

# generate more WAL on provider
psql_or_bail(1, "INSERT INTO public.test_progress SELECT g, 'x' FROM generate_series(4,60) g");
my $prov_lsn_after_bulk = scalar_query(1, "SELECT pg_current_wal_lsn()");
ok($prov_lsn_after_bulk =~ /^[0-9A-F]+\/[0-9A-F]+$/, "provider LSN after bulk: $prov_lsn_after_bulk");

# stop subscriber immediately (simulate crash)
system_or_bail "$pg_bin/pg_ctl", '-D', $datadirs->[1], '-m', 'immediate', 'stop';

# start subscriber; redo should replay our progress
system_or_bail "$pg_bin/pg_ctl", '-D', $datadirs->[1], '-o', "-p $sub_port", 'start';

# wait until counts match again
ok(wait_until(40, sub {
  scalar_query(1, "SELECT count(*) FROM public.test_progress") eq
  scalar_query(2, "SELECT count(*) FROM public.test_progress")
}), 'subscriber caught up after crash via WAL REDO');

# verify progress advanced and still <= provider LSN
my $final_prog = scalar_query(2, q{
  SELECT remote_commit_lsn || '|' || remote_insert_lsn || '|' || remote_commit_ts
  FROM spock.apply_group_progress()
  ORDER BY remote_commit_ts DESC LIMIT 1
});
ok($final_prog =~ /\S+\|\S+\|\S+/, "latest progress after crash restart: $final_prog");

my ($commit_lsn, $insert_lsn, $commit_ts) = split (/\|/, $final_prog, 3);
ok($commit_ts ge $after_ts, "remote_commit_ts advanced after crash restart");

my $cmp_f_commit = scalar_query(2, "SELECT (pg_lsn '$commit_lsn') <= (pg_lsn '$prov_lsn_after_bulk')");
is($cmp_f_commit, 't', "remote_commit_lsn <= provider current LSN");

my $cmp_f_insert = scalar_query(2, "SELECT (pg_lsn '$insert_lsn') <= (pg_lsn '$prov_lsn_after_bulk')");
is($cmp_f_insert, 't', "remote_insert_lsn <= provider current LSN");

my $q1 = scalar_query(2, "SELECT count(*) FROM public.test_progress");
my $q2 = scalar_query(1, "SELECT count(*) FROM public.test_progress");

# Final sanity
is($q1, $q2, "row counts equal at end");
# psql_or_bail(1, "SELECT spock.wait_slot_confirm_lsn(NULL, NULL)");

# Cleanup
psql_or_bail(2, "SELECT spock.sub_drop('test_sub')");
destroy_cluster('Destroy 2-node cluster');
done_testing();
