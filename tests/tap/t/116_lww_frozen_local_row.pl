use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config
                 scalar_query psql_or_bail wait_for_sub_status
                 poll_query_until sync_nodes);

# last_update_wins must still see the commit timestamp of a local row after
# VACUUM has frozen it.
#
# Freezing sets HEAP_XMIN_FROZEN in t_infomask but keeps the original xid in
# the header.  HeapTupleHeaderGetXmin() reports such a row as
# FrozenTransactionId, so get_tuple_origin() used to treat it as having no
# commit timestamp (local_ts = 0), and any remote UPDATE won -- even one older
# than the local change.  The fix reads the raw xmin instead.
#
# Scenario: n2 subscribes to n1.  With the subscription disabled, the row is
# updated on n1 and then, later, on n2.  n2 freezes the table and the
# subscription is re-enabled, so n1's older UPDATE arrives after n2's newer
# one.  n2 must keep its own value.
#
# Needs the pageinspect extension to confirm the row is frozen; the test skips
# without it.

my $config   = get_test_config();
my $sharedir = `"$config->{pg_bin}/pg_config" --sharedir`;
chomp $sharedir;

plan skip_all => 'pageinspect extension not available'
    unless -f "$sharedir/extension/pageinspect.control";

create_cluster(2, 'LWW frozen local row test');

$config         = get_test_config();
my $ports       = $config->{node_ports};
my $host        = $config->{host};
my $dbname      = $config->{db_name};
my $db_user     = $config->{db_user};
my $db_password = $config->{db_password};

psql_or_bail(2, "CREATE EXTENSION pageinspect");

my $conn_n1 = "host=$host dbname=$dbname port=$ports->[0] "
            . "user=$db_user password=$db_password";
psql_or_bail(2,
    "SELECT spock.sub_create('sub_n2n1', '$conn_n1', "
  . "ARRAY['default','default_insert_only','ddl_sql'], true, true)");
ok(wait_for_sub_status(2, 'sub_n2n1', 'replicating', 30),
   'n2 subscription replicating');

# Keep autovacuum away so the test controls when the row is frozen.
psql_or_bail(1, "
    CREATE TABLE frozen_lww (id int PRIMARY KEY, val text)
        WITH (autovacuum_enabled = false);
    INSERT INTO frozen_lww VALUES (1, 'initial');
");
ok(poll_query_until(2,
       "SELECT val FROM frozen_lww WHERE id = 1", 'initial', 30),
   'initial row replicated to n2');

psql_or_bail(2, "SELECT spock.sub_disable('sub_n2n1')");
ok(wait_for_sub_status(2, 'sub_n2n1', 'disabled', 30),
   'n2 subscription disabled');

# The older change, held back on n1.  The marker row tells us later when
# n2 has applied everything up to and including it.
psql_or_bail(1, "UPDATE frozen_lww SET val = 'from_n1' WHERE id = 1");
psql_or_bail(1, "INSERT INTO frozen_lww VALUES (2, 'marker')");

# Make sure n2's commit timestamp is strictly later.
sleep(1);
psql_or_bail(2, "UPDATE frozen_lww SET val = 'from_n2' WHERE id = 1");

# Freeze the row on n2.  Retry in case a concurrent snapshot holds the
# freeze horizon back.
my $frozen_q = "SELECT (h.t_infomask & 768) = 768 "
             . "FROM heap_page_items(get_raw_page('frozen_lww', 0)) h "
             . "JOIN frozen_lww f ON f.ctid = ('(0,' || h.lp || ')')::tid "
             . "WHERE f.id = 1";
my $frozen = 0;
for (1 .. 30) {
    psql_or_bail(2, "VACUUM (FREEZE) frozen_lww");
    if (scalar_query(2, $frozen_q) eq 't') { $frozen = 1; last; }
    sleep(1);
}
ok($frozen, 'n2 row has HEAP_XMIN_FROZEN set after VACUUM (FREEZE)');

# The original xid is still in the header.
is(scalar_query(2,
       "SELECT h.t_xmin::text::bigint >= 3 "
     . "FROM heap_page_items(get_raw_page('frozen_lww', 0)) h "
     . "JOIN frozen_lww f ON f.ctid = ('(0,' || h.lp || ')')::tid "
     . "WHERE f.id = 1"),
   't', 'frozen row keeps a normal raw xmin');

psql_or_bail(2, "SELECT spock.sub_enable('sub_n2n1')");
ok(wait_for_sub_status(2, 'sub_n2n1', 'replicating', 30),
   'n2 subscription replicating again');
ok(poll_query_until(2,
       "SELECT val FROM frozen_lww WHERE id = 2", 'marker', 30),
   'held-back changes from n1 applied on n2');

is(scalar_query(2, "SELECT val FROM frozen_lww WHERE id = 1"),
   'from_n2',
   'n2 keeps its newer value over the older remote UPDATE');

destroy_cluster('LWW frozen local row test');
done_testing();
