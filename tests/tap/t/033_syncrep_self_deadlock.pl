use strict; use warnings; use Test::More; use lib '.'; use lib 't';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail
                 sync_appname make_synchronous unmake_synchronous);
create_cluster(2, 'syncrep cluster');
my $c = get_test_config();
is(_show(1,'spock.synchronous_mode'), 'off', 'GUC defaults off');
sub _show { my ($n,$g)=@_; my $p=$c->{node_ports}[$n-1];
    my $o=`timeout 10 $c->{pg_bin}/psql -X -h $c->{host} -p $p -d $c->{db_name} -U $c->{db_user} -tA -c "SHOW $g" 2>/dev/null`;
    $o//=''; $o=~s/\s+//g; return $o; }
destroy_cluster();
done_testing();
