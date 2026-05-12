use strict;
use warnings;
use Test::More;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config psql_or_bail
                 scalar_query);

# =============================================================================
# 050_seqam_snowflake.pl
# =============================================================================
# Verifies the multi-master uniqueness invariant of the Spock Snowflake
# sequence access method.
#
# Setup:
#   2-node Spock cluster, each node assigned a distinct
#   spock.snowflake_node_id.
#
# Scenario:
#   On each node, in parallel: INSERT 1000 rows into a table whose primary
#   key defaults to nextval() of a snowflake-managed sequence.
#
# Invariant under test:
#   After both inserts complete and Spock replication converges:
#   - SELECT count(*) returns 2000 on each node
#   - SELECT count(DISTINCT id) returns 2000 on each node
#   - No primary-key violations in any node's server log
#
# The same scenario with the snowflake hook NOT attached (i.e. kind = local)
# would produce hundreds of conflicts because both nodes start their
# sequence at 1.  This test is the canonical demonstration of the feature.
# =============================================================================

# Two nodes
create_cluster(2, 'Create 2-node cluster for snowflake sequence test');

my $config         = get_test_config();
my $node_ports     = $config->{node_ports};
my $host           = $config->{host};
my $dbname         = $config->{db_name};
my $db_user        = $config->{db_user};

# Helper: run a psql command on node $n
sub on_node {
	my ($n, $sql) = @_;
	psql_or_bail($host, $node_ports->[$n - 1], $db_user, $dbname, $sql);
}

# Configure distinct snowflake_node_id on each node.  Then bounce
# (postgresql.conf-based GUC, PGC_POSTMASTER) -- SpockTest's restart
# helper handles waiting for the supervisor to come back up.
note('Configure snowflake_node_id per node');
SpockTest::set_node_guc(1, 'spock.snowflake_node_id', '101');
SpockTest::set_node_guc(2, 'spock.snowflake_node_id', '202');
SpockTest::restart_node(1);
SpockTest::restart_node(2);

# Create a replicated table on node 1; structure replicates to node 2
# via Spock's existing DDL replication.
note('Create test table on node 1, replicated to node 2');
on_node(1, q{
	CREATE TABLE sf_test (id BIGINT PRIMARY KEY DEFAULT nextval('sf_test_id_seq'),
	                     payload TEXT);
	CREATE SEQUENCE sf_test_id_seq;
	ALTER TABLE sf_test ALTER COLUMN id SET DEFAULT nextval('sf_test_id_seq');
});

# Wait for DDL to replicate
SpockTest::wait_for_replication();

# Assign snowflake on node 1 -- replicates to node 2 via user_catalog_table
on_node(1, q{
	SELECT spock.alter_sequence_set_kind('sf_test_id_seq'::regclass,
	                                     'snowflake');
});
SpockTest::wait_for_replication();

# Sanity: spock.seq_hook_available() should be true on both nodes
my $hook1 = scalar_query(1, q{SELECT spock.seq_hook_available()::text});
my $hook2 = scalar_query(2, q{SELECT spock.seq_hook_available()::text});
is($hook1, 't', 'nextval_hook attached on node 1');
is($hook2, 't', 'nextval_hook attached on node 2');

# Parallel concurrent inserts: 1000 rows on each node.
# We fork two psql processes and wait for both.
note('Run concurrent inserts on both nodes (1000 rows each)');
my @pids;
for my $n (1, 2) {
	my $pid = fork();
	die "fork: $!" unless defined $pid;
	if ($pid == 0) {
		# child
		on_node($n, q{
			INSERT INTO sf_test (payload)
			SELECT 'node-' || current_setting('spock.snowflake_node_id') ||
			       '-row-' || g
			FROM generate_series(1, 1000) g;
		});
		exit 0;
	}
	push @pids, $pid;
}
waitpid($_, 0) for @pids;

# Wait for replication convergence
SpockTest::wait_for_replication();

# Invariant 1: each node sees 2000 rows
for my $n (1, 2) {
	my $cnt = scalar_query($n, 'SELECT count(*) FROM sf_test');
	is($cnt, '2000', "node $n sees 2000 rows after replication");
}

# Invariant 2: id values are globally unique
for my $n (1, 2) {
	my $distinct = scalar_query($n, 'SELECT count(DISTINCT id) FROM sf_test');
	is($distinct, '2000',
	   "node $n: every id is distinct (no snowflake collisions)");
}

# Invariant 3: every id decodes to the node that produced it
my $bad = scalar_query(1, q{
	SELECT count(*)
	FROM sf_test
	WHERE (spock.seq_snowflake_decode(id)).node_id NOT IN (101, 202)
});
is($bad, '0', 'all ids decode to a known node id');

# Invariant 4: half the rows came from each node id
for my $node_id (101, 202) {
	my $cnt = scalar_query(1, qq{
		SELECT count(*) FROM sf_test
		WHERE (spock.seq_snowflake_decode(id)).node_id = $node_id
	});
	is($cnt, '1000',
	   "node id $node_id produced exactly 1000 rows");
}

# No PK-violation noise in the server logs
note('Scan logs for primary-key conflicts');
for my $n (1, 2) {
	my $log = SpockTest::slurp_node_log($n);
	unlike($log,
		qr/duplicate key value violates unique constraint .*sf_test_pkey/,
		"node $n log has no sf_test_pkey conflicts");
}

destroy_cluster();
done_testing();
