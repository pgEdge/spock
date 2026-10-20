use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
    wait_for_sub_status log_offset log_since
);

# =============================================================================
# Test: 113_tablesync_same_txn.pl
# =============================================================================
# A table added to a replication set with synchronize_data = true reaches the
# subscriber as a queued table-sync request.  The apply worker records the
# table as pending synchronization and starts a sync worker for it.
#
# The same provider transaction may go on to change the table.  Those changes
# arrive after the request in the same remote transaction, and the apply worker
# has to see the table's new synchronization state by then: it must skip them,
# because the sync worker brings the table's contents, and it must still start
# the sync worker.  Losing the state leaves the table unsynchronized for good.
# =============================================================================

create_cluster(2, 'Create 2-node tablesync-same-txn cluster');

my $config = get_test_config();
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};
my $p1 = $config->{node_ports}->[0];
my $conn = "host=$host dbname=$dbname port=$p1 user=$db_user password=$db_password";

for my $node (1, 2)
{
    psql_or_bail($node, "CREATE TABLE ts_tab(id int PRIMARY KEY, v text)");
    psql_or_bail($node, "CREATE TABLE ts_tab2(id int PRIMARY KEY, v text)");
    psql_or_bail($node, "CREATE TABLE ts_tab3(id int PRIMARY KEY)");
}

# The harness adds a new table to the default set; take it out so that adding
# it below is the event under test.
psql_or_bail(1, "SELECT spock.repset_remove_table('default', 'ts_tab')");
psql_or_bail(1, "SELECT spock.repset_remove_table('default', 'ts_tab3')");

psql_or_bail(2,
    "SELECT spock.sub_create('sub_n1_n2', '$conn', " .
    "ARRAY['default', 'default_insert_only', 'ddl_sql'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription starts in replicating state');

# Add the table with a data sync and change it in the same transaction.
psql_or_bail(1,
    "BEGIN; " .
    "INSERT INTO ts_tab VALUES (1, 'before'); " .
    "SELECT spock.repset_add_table('default', 'ts_tab', true); " .
    "INSERT INTO ts_tab VALUES (2, 'after'); " .
    "COMMIT");

my $status = '';
for (1 .. 120) {
    $status = scalar_query(2,
        "SELECT sync_status FROM spock.local_sync_status " .
        "WHERE sync_relname = 'ts_tab'");
    last if defined $status && $status eq 'r';
    sleep(1);
}
is($status, 'r', 'the table was synchronized');

is(scalar_query(2, "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM ts_tab"),
    '1:before,2:after',
    'the table holds both rows');

ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 30),
    'subscription is still replicating');

# Replication of the table works after the sync.
psql_or_bail(1, "INSERT INTO ts_tab VALUES (3, 'later')");
my $followed = '';
for (1 .. 60) {
    $followed = scalar_query(2, "SELECT count(*) FROM ts_tab WHERE id = 3");
    last if $followed eq '1';
    sleep(1);
}
is($followed, '1', 'a later insert replicates');

# A table that is already replicated is added to another set with a data sync,
# after an unrelated sync request has marked a synchronization as pending and
# after the table's own changes were applied.  Changes made to it after its
# sync request must still be skipped.
my $offset = log_offset(2);
psql_or_bail(1,
    "BEGIN; " .
    "SELECT spock.repset_add_table('default', 'ts_tab3', true); " .
    "INSERT INTO ts_tab2 VALUES (1, 'before'); " .
    "DELETE FROM ts_tab2 WHERE id = 1; " .
    "SELECT spock.repset_add_table('default_insert_only', 'ts_tab2', true); " .
    "INSERT INTO ts_tab2 VALUES (2, 'after'); " .
    "COMMIT");

$status = '';
for (1 .. 120) {
    $status = scalar_query(2,
        "SELECT sync_status FROM spock.local_sync_status " .
        "WHERE sync_relname = 'ts_tab2'");
    last if defined $status && $status eq 'r';
    sleep(1);
}
is($status, 'r', 'the already replicated table was synchronized');

is(scalar_query(2, "SELECT string_agg(id || ':' || v, ',' ORDER BY id) FROM ts_tab2"),
    '2:after',
    'the synchronized table holds the provider data');

like(log_since(2, $offset), qr/skipping change to public\.ts_tab2 /,
    'a change after the sync request is skipped although the table was judged before');

destroy_cluster('Destroy 2-node tablesync-same-txn cluster');

done_testing();
