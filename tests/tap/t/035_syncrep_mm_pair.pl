use strict; use warnings; use Test::More; use lib '.'; use lib 't';
use Time::HiRes qw(time);
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail
                 sync_appname make_synchronous unmake_synchronous);
create_cluster(2, 'syncrep mm pair');
my $c = get_test_config();
sub sc { my($n,$s)=@_; my $p=$c->{node_ports}[$n-1];
  my $o=`timeout 10 $c->{pg_bin}/psql -X -h $c->{host} -p $p -d $c->{db_name} -U $c->{db_user} -tA -c "$s" 2>/dev/null`; $o//=''; $o=~s/^\s+|\s+$//g; return $o;}
sub w { my($to,$cb)=@_; my $d=time()+$to; while(time()<$d){return 1 if $cb->(); select(undef,undef,undef,1);} return 0;}
psql_or_bail(1,"CREATE TABLE t1 (id int primary key, v text)");
psql_or_bail(2,"SELECT spock.sub_create('sub_n2_n1',
    'host=$c->{host} dbname=$c->{db_name} port=$c->{node_ports}[0] user=$c->{db_user} password=$c->{db_password}',
    ARRAY['default','default_insert_only','ddl_sql'], true, true)");
w(60,sub{ sc(2,"SELECT sub_enabled FROM spock.subscription WHERE sub_name='sub_n2_n1'") eq 't'}) or BAIL_OUT('sub n2');
w(30,sub{ sc(2,"SELECT to_regclass('public.t1') IS NOT NULL") eq 't'}) or BAIL_OUT('t1 on n2');
psql_or_bail(1,"SELECT spock.sub_create('sub_n1_n2',
    'host=$c->{host} dbname=$c->{db_name} port=$c->{node_ports}[1] user=$c->{db_user} password=$c->{db_password}',
    ARRAY['default','default_insert_only','ddl_sql'], false, false)");
w(60,sub{ sc(1,"SELECT sub_enabled FROM spock.subscription WHERE sub_name='sub_n1_n2'") eq 't'}) or BAIL_OUT('sub n1');

# sync_appname() races the streaming connection: right after enabling a
# subscription, the peer's walsender may not have registered its
# pg_stat_replication row yet.  Wait until each side's specific slot-backed
# walsender row exists, then read its application_name via the known slot
# name -- see 034_syncrep_forwarding_gate.pl for why this avoids picking the
# wrong (or empty) appname when more than one spk_% connection exists.
my $n1_slot = "spk_$c->{db_name}_n1_sub_n2_n1"; # slot on n1 feeding n2's pull
my $n2_slot = "spk_$c->{db_name}_n2_sub_n1_n2"; # slot on n2 feeding n1's pull
w(30, sub {
    sc(1, "SELECT count(*) FROM pg_stat_replication r " .
          "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
          "WHERE s.slot_name = '$n1_slot'") eq '1'
}) or BAIL_OUT('walsender for n1_slot never appeared');
w(30, sub {
    sc(2, "SELECT count(*) FROM pg_stat_replication r " .
          "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
          "WHERE s.slot_name = '$n2_slot'") eq '1'
}) or BAIL_OUT('walsender for n2_slot never appeared');
my $app1 = sc(1, "SELECT r.application_name FROM pg_stat_replication r " .
                 "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
                 "WHERE s.slot_name = '$n1_slot'");
my $app2 = sc(2, "SELECT r.application_name FROM pg_stat_replication r " .
                 "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
                 "WHERE s.slot_name = '$n2_slot'");
BAIL_OUT('could not determine application_name for n1 walsender') if !defined($app1) || $app1 eq '';
BAIL_OUT('could not determine application_name for n2 walsender') if !defined($app2) || $app2 eq '';
make_synchronous(1, $app1);
make_synchronous(2, $app2);

# Deterministic (non-timing) mechanism check: append_feedback_position()
# logs "queued sync-hold" at DEBUG2 every time the feedback hold is NOT
# bypassed. Bump n2's log level so this shows up, then confirm this exact
# line is ABSENT for the upcoming write's apply on n2 (sub_n2_n1): with the
# peer-aware bypass active, n2's apply worker must skip the hold entirely
# (both nodes have spock.synchronous_mode=standby and a synchronous standby
# defined) and report feedback via the normal get_flush_position path
# instead. This is a hard behavioral check independent of wall-clock noise.
sc(2, "ALTER SYSTEM SET log_min_messages = 'debug2'");
sc(2, "SELECT pg_reload_conf()");
select(undef,undef,undef,2); # apply worker's ConfigReloadPending is polled at most once per 1000ms
my $n2_datadir = $c->{node_datadirs}[1];
my $n2_logdir = $c->{log_dir};
my $n2_logfile = ($n2_logdir =~ m{^/}) ? "$n2_logdir/00$c->{node_ports}[1].log"
                                        : "$n2_datadir/$n2_logdir/00$c->{node_ports}[1].log";
my $log_offset = -s $n2_logfile;
$log_offset //= 0;

my $t0=time();
my $out=`timeout 15 $c->{pg_bin}/psql -X -h $c->{host} -p $c->{node_ports}[0] -d $c->{db_name} -U $c->{db_user} -c "INSERT INTO t1 VALUES (10,'mm')" 2>&1`;
my $el=time()-$t0;
diag("MM-pair write elapsed: ${el}s");
like($out, qr/INSERT 0 1/, 'MM-pair synchronous write succeeds');
# NOTE on this threshold: investigation (see task-4-report.md) found that in
# this minimal 2-node/single-write topology, the pre-fix and post-fix elapsed
# times are statistically indistinguishable (~1.0s in both), because that
# ~1s is dominated by an orthogonal PostgreSQL/apply-worker cadence (the
# apply worker's own 1000ms WaitLatchOrSocket poll interval interacting with
# spock's default asynchronous local commit for apply workers), not by the
# feedback-hold round-trip this fix removes. An isolated experiment forcing
# synchronous local commits (spock.synchronous_commit=on, which requires a
# full restart since it is PGC_POSTMASTER) dropped elapsed to ~8ms in BOTH
# builds -- confirming there is no genuine deadlock (matching the spike's
# finding) but also confirming this specific topology never puts real
# pending work on the reverse channel for the hold to gate on, so it cannot
# be used to build a tight fix-discriminating threshold here. Kept generous
# (matching the brief's fallback) so it still catches genuine hangs/regressions
# without fabricating a pass/fail signal the fix doesn't actually control.
ok($el < 3, "MM-pair write completes without hanging (elapsed ${el}s)");
w(20,sub{ sc(2,"SELECT count(*) FROM t1 WHERE id=10") eq '1'}) or diag('row not on n2');
is(sc(2,"SELECT count(*) FROM t1 WHERE id=10"),'1','row replicated A->S');

# Give the syslogger a moment to flush, then read only what was appended
# since just before the write.
select(undef,undef,undef,1);
my $new_log = '';
if (open(my $fh, '<', $n2_logfile)) {
    seek($fh, $log_offset, 0);
    local $/;
    $new_log = <$fh> // '';
    close($fh);
} else {
    diag("could not open n2 log file [$n2_logfile]: $!");
}
unlike($new_log, qr/queued sync-hold/,
       'peer-aware bypass: n2 apply worker does not enqueue a feedback-hold entry for the MM peer');
unmake_synchronous(1); unmake_synchronous(2);
destroy_cluster();
done_testing();
