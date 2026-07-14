use strict; use warnings; use Test::More; use lib '.'; use lib 't';
use Time::HiRes qw(time);
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail
                 sync_appname make_synchronous unmake_synchronous);
create_cluster(2, 'syncrep cluster');
my $c = get_test_config();
is(_show(1,'spock.synchronous_mode'), 'off', 'GUC defaults off');
sub _show { my ($n,$g)=@_; my $p=$c->{node_ports}[$n-1];
    my $o=`timeout 10 $c->{pg_bin}/psql -X -h $c->{host} -p $p -d $c->{db_name} -U $c->{db_user} -tA -c "SHOW $g" 2>/dev/null`;
    $o//=''; $o=~s/\s+//g; return $o; }

# n1 (A) publishes to n2 (S)
psql_or_bail(1, "CREATE TABLE t1 (id int primary key, v text)");
psql_or_bail(2, "SELECT spock.sub_create('sub_n2_n1',
    'host=$c->{host} dbname=$c->{db_name} port=$c->{node_ports}[0] user=$c->{db_user} password=$c->{db_password}',
    ARRAY['default','default_insert_only','ddl_sql'], true, true)");
_wait(60, sub { _scalar(2,"SELECT sub_enabled FROM spock.subscription WHERE sub_name='sub_n2_n1'") eq 't' })
    or BAIL_OUT('sub never enabled');
# sub_enabled only means the subscription metadata is active; the apply
# worker's actual streaming replication connection (application_name
# matching 'spk_%', as opposed to the transient '<sub>_snap' sync worker)
# can take a moment longer to appear in pg_stat_replication. Wait for it
# so sync_appname(1) doesn't race ahead and return empty.
_wait(30, sub { sync_appname(1) ne '' })
    or BAIL_OUT('no spk_ streaming replication connection appeared on n1');
my $app = sync_appname(1);
make_synchronous(1, $app);
# bounded write; timeout wrapper (NOT statement_timeout) bounds a possible hang
my $out = `timeout 20 $c->{pg_bin}/psql -X -h $c->{host} -p $c->{node_ports}[0] -d $c->{db_name} -U $c->{db_user} -c "INSERT INTO t1 VALUES (1,'x')" 2>&1`;
like($out, qr/INSERT 0 1/, 'synchronous write to Spock sync standby succeeds (no self-deadlock)');
unmake_synchronous(1);

sub _scalar { my($n,$s)=@_; my $p=$c->{node_ports}[$n-1];
  my $o=`timeout 10 $c->{pg_bin}/psql -X -h $c->{host} -p $p -d $c->{db_name} -U $c->{db_user} -tA -c "$s" 2>/dev/null`; $o//=''; $o=~s/^\s+|\s+$//g; return $o; }
sub _wait { my($to,$cb)=@_; my $d=time()+$to; while(time()<$d){return 1 if $cb->(); select(undef,undef,undef,1);} return 0; }

destroy_cluster();
done_testing();
