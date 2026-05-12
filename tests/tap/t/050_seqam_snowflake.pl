use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail
                 run_on_node scalar_query wait_for_pg_ready);

# =============================================================================
# 050_seqam_snowflake.pl
# =============================================================================
# Verifies the multi-master uniqueness invariant of the Spock Snowflake
# sequence access method.
#
# Setup:
#   2-node Spock cluster, each node assigned a distinct
#   spock.snowflake_node_id GUC.
#
# Scenario:
#   On each node, in parallel: INSERT 500 rows into a table whose primary
#   key defaults to nextval() of a snowflake-managed sequence.
#
# Invariant under test:
#   After both inserts complete and Spock replication converges:
#   - SELECT count(*) returns 1000 on each node
#   - SELECT count(DISTINCT id) returns 1000 on each node
#   - Every id decodes to one of the two configured node ids
#   - Each node id produced exactly 500 values
#
# Without snowflake, two stock sequences starting at 1 would produce 500
# primary-key collisions on replication.  This test exercises the entire
# stack: nextval_hook, the dispatcher, the snowflake CAS loop, the shmem
# slot allocator, and the user_catalog_table replication of
# spock.sequence_kind.
# =============================================================================

# 2-node cluster
create_cluster(2, 'Create 2-node cluster for snowflake sequence test');

my $config         = get_test_config();
my $node_ports     = $config->{node_ports};
my $node_datadirs  = $config->{node_datadirs};
my $host           = $config->{host};
my $pg_bin         = $config->{pg_bin};

# Set a distinct spock.snowflake_node_id on each node via append_conf +
# pg_ctl restart.  PGC_POSTMASTER so the GUC requires a full restart.
sub set_snowflake_node_id {
    my ($node_num, $value) = @_;
    my $datadir = $node_datadirs->[$node_num - 1];
    open(my $fh, '>>', "$datadir/postgresql.conf") or die "open: $!";
    print $fh "spock.snowflake_node_id = $value\n";
    close($fh);
    system("$pg_bin/pg_ctl", '-D', $datadir, '-m', 'fast', 'restart',
           '-l', "$datadir/restart.log") == 0
        or die "pg_ctl restart failed for node $node_num";
    wait_for_pg_ready($host, $node_ports->[$node_num - 1], $pg_bin, 30)
        or die "node $node_num did not come back up";
}

note('Configure snowflake_node_id per node and restart');
set_snowflake_node_id(1, 101);
set_snowflake_node_id(2, 202);

# Create the sequence first, then the table with a default referencing it.
# (v1 had the table before the sequence -- caught in review.)
note('Create test schema on node 1; DDL replicates to node 2');
psql_or_bail(1, q{CREATE SEQUENCE sf_test_id_seq});
psql_or_bail(1, q{CREATE TABLE sf_test (id BIGINT PRIMARY KEY DEFAULT nextval('sf_test_id_seq'), payload TEXT)});

# Assign snowflake on node 1 only; the user_catalog_table row replicates
# to node 2 via Spock.
psql_or_bail(1, q{SELECT spock.alter_sequence_set_kind('sf_test_id_seq'::regclass, 'snowflake')});

# Sanity probe: spock.seq_hook_available on both nodes
is(scalar_query(1, q{SELECT spock.seq_hook_available()::text}), 't',
   'nextval_hook attached on node 1');
is(scalar_query(2, q{SELECT spock.seq_hook_available()::text}), 't',
   'nextval_hook attached on node 2');

# Wait briefly for replication of the table + the sequence_kind row.  We
# poll until the table is visible on node 2.
my $ready = 0;
for (1 .. 30) {
    my $r = scalar_query(2,
        q{SELECT count(*) FROM pg_class WHERE relname = 'sf_test'});
    if ($r eq '1') { $ready = 1; last; }
    sleep 1;
}
ok($ready, 'sf_test table replicated to node 2');

note('Run concurrent inserts on both nodes (500 rows each)');
my @pids;
for my $n (1, 2) {
    my $pid = fork();
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        # child
        my $rc = system("$pg_bin/psql", '-X', '-p', $node_ports->[$n - 1],
                        '-d', $config->{db_name}, '-q', '-c',
                        "INSERT INTO sf_test (payload) " .
                        "SELECT 'node-' || current_setting('spock.snowflake_node_id') || '-row-' || g " .
                        "FROM generate_series(1, 500) g");
        exit($rc == 0 ? 0 : 1);
    }
    push @pids, $pid;
}
for my $pid (@pids) {
    waitpid($pid, 0);
    is($? >> 8, 0, "insert child $pid exited cleanly");
}

# Wait for replication convergence: both nodes should see 1000 rows.
my $converged = 0;
for (1 .. 60) {
    my $c1 = scalar_query(1, 'SELECT count(*) FROM sf_test');
    my $c2 = scalar_query(2, 'SELECT count(*) FROM sf_test');
    if ($c1 eq '1000' && $c2 eq '1000') { $converged = 1; last; }
    sleep 1;
}
ok($converged, 'both nodes see 1000 rows after replication');

# Invariant 1: id values are globally unique
for my $n (1, 2) {
    is(scalar_query($n, 'SELECT count(DISTINCT id) FROM sf_test'), '1000',
       "node $n: every id is distinct (no snowflake collisions)");
}

# Invariant 2: every id decodes to one of the two configured node ids
my $bad = scalar_query(1, q{
    SELECT count(*) FROM sf_test
    WHERE (spock.seq_snowflake_decode(id)).node_id NOT IN (101, 202)
});
is($bad, '0', 'all ids decode to a configured node id');

# Invariant 3: each node produced exactly 500 rows
for my $node_id (101, 202) {
    is(scalar_query(1, qq{
        SELECT count(*) FROM sf_test
        WHERE (spock.seq_snowflake_decode(id)).node_id = $node_id
    }), '500', "node id $node_id produced exactly 500 rows");
}

destroy_cluster();
done_testing();
