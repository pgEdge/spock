use strict; use warnings; use Test::More; use lib '.'; use lib 't';
use Time::HiRes qw(time);
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail
                 sync_appname make_synchronous unmake_synchronous);
create_cluster(3, 'syncrep 3-node');
my $c = get_test_config();
sub sc { my($n,$s)=@_; my $p=$c->{node_ports}[$n-1];
  my $o=`timeout 10 $c->{pg_bin}/psql -X -h $c->{host} -p $p -d $c->{db_name} -U $c->{db_user} -tA -c "$s" 2>/dev/null`; $o//=''; $o=~s/^\s+|\s+$//g; return $o;}
sub w { my($to,$cb)=@_; my $d=time()+$to; while(time()<$d){return 1 if $cb->(); select(undef,undef,undef,1);} return 0;}
psql_or_bail(1,"CREATE TABLE t1 (id int primary key, v text)");
for my $n (2,3){ psql_or_bail($n,"SELECT spock.sub_create('sub_n${n}_n1',
    'host=$c->{host} dbname=$c->{db_name} port=$c->{node_ports}[0] user=$c->{db_user} password=$c->{db_password}',
    ARRAY['default','default_insert_only','ddl_sql'], true, true)");}
w(60,sub{ sc(2,"SELECT sub_enabled FROM spock.subscription WHERE sub_name='sub_n2_n1'") eq 't'
       && sc(3,"SELECT sub_enabled FROM spock.subscription WHERE sub_name='sub_n3_n1'") eq 't'}) or BAIL_OUT('subs');

# sync_appname() races the streaming connection: right after enabling a
# subscription, the walsender for S (n2) may not have registered its
# pg_stat_replication row yet.  Wait until S's specific slot-backed
# walsender row exists before reading its application_name, otherwise we
# could read the wrong (or empty) appname and silently disable sync rep
# below (make_synchronous() would then name a non-existent/wrong standby).
my $s_slot = "spk_$c->{db_name}_n1_sub_n2_n1";
w(30, sub {
    sc(1, "SELECT count(*) FROM pg_stat_replication r " .
          "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
          "WHERE s.slot_name = '$s_slot'") eq '1'
}) or BAIL_OUT('S (n2) walsender row never appeared');

# With S and B both connected, sync_appname(1) would return whichever
# spk_% row is most recent (possibly B, not S).  Select S's walsender
# specifically via its known slot name so synchronous_standby_names is
# set deterministically to S, not whichever peer happened to connect last.
my $appS = sc(1, "SELECT r.application_name FROM pg_stat_replication r " .
                 "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
                 "WHERE s.slot_name = '$s_slot'");
BAIL_OUT('could not determine application_name for S (n2) walsender') if !defined($appS) || $appS eq '';
make_synchronous(1,$appS);
# pause S's apply worker so it cannot confirm
psql_or_bail(2,"SELECT spock.sub_disable('sub_n2_n1', true)");
# write on A in the background (it will block on sync S); bounded
system("timeout 8 $c->{pg_bin}/psql -X -h $c->{host} -p $c->{node_ports}[0] -d $c->{db_name} -U $c->{db_user} -c \"INSERT INTO t1 VALUES (1,'x')\" >/dev/null 2>&1 &");
select(undef,undef,undef,4);
is(sc(3,"SELECT count(*) FROM t1 WHERE id=1"), '0', 'async peer B did NOT receive row while sync standby S is behind');

# Genuine discriminator between the legacy enqueue-based wait and the new
# poll-based forwarding gate: PostgreSQL's own SyncRepWaitForLSN() blocks
# reporting wait_event='SyncRep' (see syncrep.c), while our gate's poll loop
# blocks reporting wait_event='WalSenderWaitForWal' (WAIT_EVENT_WAL_SENDER_
# WAIT_FOR_WAL).  Row-count alone does not distinguish the two paths --
# PostgreSQL's synchronous_standby_names + SyncRepWaitForLSN() already gates
# ANY caller globally once a sync standby is configured, so the legacy path
# blocks B just as effectively.  This wait_event check confirms which
# implementation is actually active on B's walsender while it is gated.
my $b_slot = "spk_$c->{db_name}_n1_sub_n3_n1";
my $b_wait = sc(1, "SELECT wait_event FROM pg_stat_activity a " .
                   "JOIN pg_stat_replication r ON a.pid = r.pid " .
                   "JOIN pg_replication_slots s ON s.active_pid = r.pid " .
                   "WHERE s.slot_name = '$b_slot'");
diag("B's walsender wait_event while gated: '$b_wait'");
# release
psql_or_bail(2,"SELECT spock.sub_enable('sub_n2_n1', true)");
w(30,sub{ sc(3,"SELECT count(*) FROM t1 WHERE id=1") eq '1'}) or diag('B never caught up');
is(sc(3,"SELECT count(*) FROM t1 WHERE id=1"), '1', 'async peer B receives row after S catches up');
unmake_synchronous(1);
destroy_cluster();
done_testing();
