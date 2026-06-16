use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster
                 get_test_config scalar_query psql_or_bail
                 wait_for_sub_status);

# Verify that updating the same row twice in one transaction does not produce
# a spurious "tiebreaker values are equal" WARNING on the subscriber.
#
# When a single transaction updates the same row twice, both WAL records are
# applied in one apply transaction.  The second update finds xmin equal to the
# current apply transaction XID, so get_tuple_origin() returns
# local_ts == remote_ts, entering the tiebreaker path.  The bug was that
# conflict_resolve_by_timestamp() looked up get_node(local_origin_id) for
# loc_node; in single-writer topology local_origin_id == remote_origin_id
# (both n1.id), so both sides resolved to the same SpockNode and the WARNING
# fired trivially.  The fix uses get_local_node() for loc_node so the
# comparison is always applying-node vs remote-node.

create_cluster(2, 'tiebreaker equal-warning test');

my $config      = get_test_config();
my $ports       = $config->{node_ports};
my $log_dir     = $config->{log_dir};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};

my $conn_n1 = "host=$host dbname=$dbname port=$ports->[0] user=$db_user password=$db_password";
psql_or_bail(2,
    "SELECT spock.sub_create('sub_n2n1', '$conn_n1', " .
    "ARRAY['default','default_insert_only','ddl_sql'], true, true)");

ok(wait_for_sub_status(2, 'sub_n2n1', 'replicating', 30),
   'n2 subscription replicating');

psql_or_bail(1, "
    CREATE TABLE tiebreaker_test (id int PRIMARY KEY, val text);
    INSERT INTO tiebreaker_test VALUES (1, 'initial');
");

for (1..30) {
    last if scalar_query(2, "SELECT val FROM tiebreaker_test WHERE id = 1") eq 'initial';
    sleep 1;
}

is(scalar_query(2, "SELECT val FROM tiebreaker_test WHERE id = 1"),
   'initial', 'initial row replicated');

my $log_file   = "${log_dir}/00$ports->[1].log";
my $log_before = -s $log_file // 0;

psql_or_bail(1, "
    BEGIN;
    UPDATE tiebreaker_test SET val = 'first'  WHERE id = 1;
    UPDATE tiebreaker_test SET val = 'second' WHERE id = 1;
    COMMIT;
");

for (1..30) {
    last if scalar_query(2, "SELECT val FROM tiebreaker_test WHERE id = 1") eq 'second';
    sleep 1;
}

is(scalar_query(2, "SELECT val FROM tiebreaker_test WHERE id = 1"),
   'second', 'final value replicated');

open(my $fh, '<', $log_file)
    or BAIL_OUT("cannot open n2 log $log_file: $!");
seek($fh, $log_before, 0);
my $new_log = do { local $/; <$fh> };
close($fh);

unlike($new_log, qr/equal tiebreaker|tiebreaker.*equal/i,
       'no spurious tiebreaker-equal WARNING after same-row double-update');

destroy_cluster('tiebreaker equal-warning test');
done_testing();
