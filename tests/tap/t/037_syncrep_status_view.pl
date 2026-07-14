use strict; use warnings; use Test::More; use lib '.'; use lib 't';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail sync_appname make_synchronous unmake_synchronous);
use Time::HiRes qw(time);

create_cluster(2,'syncrep status');
my $c=get_test_config();
sub sc{my($n,$s)=@_;my $p=$c->{node_ports}[$n-1];my $o=`timeout 10 $c->{pg_bin}/psql -X -h $c->{host} -p $p -d $c->{db_name} -U $c->{db_user} -tA -c "$s" 2>/dev/null`;$o//='';$o=~s/^\s+|\s+$//g;return $o;}
sub w{my($to,$cb)=@_;my $d=time()+$to;while(time()<$d){return 1 if $cb->();select(undef,undef,undef,1);}return 0;}

psql_or_bail(1,"CREATE TABLE t1(id int primary key)");
psql_or_bail(2,"SELECT spock.sub_create('sub_n2_n1','host=$c->{host} dbname=$c->{db_name} port=$c->{node_ports}[0] user=$c->{db_user} password=$c->{db_password}',ARRAY['default','default_insert_only','ddl_sql'],true,true)");
w(60,sub{ sc(2,"SELECT sub_enabled FROM spock.subscription WHERE sub_name='sub_n2_n1'") eq 't'}) or BAIL_OUT('sub');

# sync_appname races the spk_% streaming connection: sub_enabled only means
# the subscription metadata is active, the apply worker's actual streaming
# replication connection can take a moment longer to show up in
# pg_stat_replication. Wait for it before reading the appname / enabling
# sync rep, else make_synchronous configures an appname that never matches
# and sync rep is silently disabled (the view would then show no
# synchronous row).
w(30,sub{ sync_appname(1) ne ''}) or BAIL_OUT('no spk_ streaming replication connection appeared on n1');

my $app = sync_appname(1);
make_synchronous(1, $app);
select(undef,undef,undef,1);

is(sc(1,"SELECT count(*) FROM spock.synchronous_replica_status WHERE is_synchronous AND is_logical AND connected"),'1','one synchronous logical connected replica shown');

unmake_synchronous(1); destroy_cluster(); done_testing();
