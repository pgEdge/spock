#!/usr/bin/perl
# =============================================================================
# Test: 018_forward_origins.pl - Verify sub_alter_options changes forward_origins
# =============================================================================
# This test verifies that spock.sub_alter_options() correctly changes the
# forward_origins setting and that the change takes effect after the apply
# worker is restarted.
#
# Topology:
#   n1 -> n2 -> n3
#         forward_origins='' (default) on both subscriptions initially
#
# Test flow:
#   Phase 1 (forwarding disabled on n3):
#     - Insert on n1 => n2 gets it, n3 does NOT
#     - Insert on n2 => n3 gets it (n2-local data always forwarded)
#   Phase 2 (forwarding enabled on n3 via sub_alter_options):
#     - alter_subscription() sends SIGTERM at commit; manager restarts worker
#     - Insert on n1 => n3 now gets it (forwarding active)
# =============================================================================

use strict;
use warnings;
use Test::More tests => 19;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config scalar_query psql_or_bail wait_for_sub_status);

# Poll $node_num until the scalar result of $query equals $expected,
# or until $timeout seconds elapse.  Returns 1 on success, 0 on timeout.
sub wait_for_count {
	my ($node_num, $query, $expected, $timeout) = @_;
	$timeout //= 30;
	for (1 .. $timeout) {
		my $got = scalar_query($node_num, $query);
		return 1 if defined $got && $got eq $expected;
		sleep(1);
	}
	return 0;
}

# =============================================================================
# SETUP: Create 3-node cluster
# =============================================================================

create_cluster(3, 'Create 3-node cluster');

my $config     = get_test_config();
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $host       = $config->{host};

my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";
my $conn_n2 = "host=$host port=$node_ports->[1] dbname=$dbname";

# =============================================================================
# SETUP: Test table and subscriptions
# =============================================================================

# Create the table on n1 first so that synchronize_structure copies it to
# n2 and n3 when their subscriptions are established below.
psql_or_bail(1, "CREATE TABLE test_fwd (id integer primary key, origin text)");

# n2 subscribes to n1.  synchronize_structure=true copies the table schema;
# synchronize_data=true copies any existing rows.  forward_origins defaults
# to '{}' (empty): n1 has no upstream anyway, so this has no practical effect.
psql_or_bail(2, "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', ARRAY['default'], true, true)");
pass('Created subscription n2->n1');
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60), 'Subscription n1->n2 is replicating');

# n3 subscribes to n2.  forward_origins defaults to '{}' (empty) — n1
# transactions are NOT forwarded to n3 yet.
psql_or_bail(3, "SELECT spock.sub_create('sub_n2_n3', '$conn_n2', ARRAY['default'], true, true)");
pass('Created subscription n3->n2 with forward_origins empty');
ok(wait_for_sub_status(3, 'sub_n2_n3', 'replicating', 60), 'Subscription n2->n3 is replicating');

wait_for_count(2, "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename='test_fwd'", '1', 30);
wait_for_count(3, "SELECT COUNT(*) FROM pg_tables WHERE schemaname='public' AND tablename='test_fwd'", '1', 30);
pass('Test table present on all nodes');

# =============================================================================
# PHASE 1: Verify that n3 only sees n2-local inserts
# =============================================================================

# Insert on n1 — forwarding is disabled on n3, so n3 should not receive it.
psql_or_bail(1, "INSERT INTO test_fwd (id, origin) VALUES (1, 'from_n1_before_fwd')");

ok(wait_for_count(2, "SELECT COUNT(*) FROM test_fwd WHERE origin = 'from_n1_before_fwd'", '1', 30),
	'n2 received n1 insert');

# Capture the current WAL position on n2, then block on n3 until it has
# consumed n2's stream past that point.  A forwarded n1 row would have
# arrived before this LSN — if it hasn't arrived by now, it never will.
my $sync_lsn = scalar_query(2, "SELECT spock.sync_event()");
psql_or_bail(3, "CALL spock.wait_for_sync_event(NULL, 'n2', '$sync_lsn', 30)");

my $n3_no_fwd = scalar_query(3, "SELECT COUNT(*) FROM test_fwd WHERE origin = 'from_n1_before_fwd'");
is($n3_no_fwd, '0', 'n3 did not receive n1 insert (forwarding disabled)');

# Insert directly on n2 — n2-local changes are always forwarded to n3.
psql_or_bail(2, "INSERT INTO test_fwd (id, origin) VALUES (2, 'from_n2_direct')");

ok(wait_for_count(3, "SELECT COUNT(*) FROM test_fwd WHERE origin = 'from_n2_direct'", '1', 30),
	'n3 received n2-local insert');

# =============================================================================
# PHASE 2: Enable forwarding via sub_alter_options, restart apply worker
# =============================================================================

psql_or_bail(3, "SELECT spock.sub_alter_options('sub_n2_n3'::name, '{\"forward_origins\": [\"all\"]}'::jsonb)");
pass('Enabled forward_origins=all on n3 via sub_alter_options');

# alter_subscription() sends SIGTERM to the apply worker at commit; the
# manager restarts it automatically with the updated settings.
wait_for_sub_status(3, 'sub_n2_n3', 'down', 3);
ok(wait_for_sub_status(3, 'sub_n2_n3', 'replicating', 60),
	'Apply worker restarted with new forward_origins setting');

# Insert on n1 — n3 should now receive it via n2 (forwarding active).
# Walk the sync chain n1 -> n2 -> n3 to guarantee the row arrived before
# we check: if n3 has exactly 2 rows it means the new n1 insert arrived AND
# the pre-forwarding n1 insert (id=1) still did not.
psql_or_bail(1, "INSERT INTO test_fwd (id, origin) VALUES (3, 'from_n1_after_fwd')");
$sync_lsn = scalar_query(1, "SELECT spock.sync_event()");
psql_or_bail(2, "CALL spock.wait_for_sync_event(NULL, 'n1', '$sync_lsn', 30)");
$sync_lsn = scalar_query(2, "SELECT spock.sync_event()");
psql_or_bail(3, "CALL spock.wait_for_sync_event(NULL, 'n2', '$sync_lsn', 30)");

my $n3_count = scalar_query(3, "SELECT COUNT(*) FROM test_fwd");
ok($n3_count eq '2', 'n3 has exactly 2 rows: n2-direct + forwarded n1 insert');

# =============================================================================
# CLEANUP
# =============================================================================

destroy_cluster('Cleanup');
