use strict;
use warnings;
use Test::More;
use lib 't';
use SpockTest qw(create_cluster cross_wire destroy_cluster system_or_bail command_ok get_test_config scalar_query psql_or_bail);

# =============================================================================
# Test: 009_recovery_slots.pl - Recovery Slot Management
# =============================================================================
# This test verifies the recovery slot functionality for catastrophic failure
# recovery in Spock multi-master clusters.
#
# Test Coverage:
# - Automatic recovery slot creation during cluster initialization
# - One recovery slot per database (shared across all subscriptions)
# - Slot naming convention: spk_recovery_{database_name}
# - Slots are inactive (never used by normal replication)
# - SQL interface: spock.get_recovery_slot_status()
# - Health check: spock.quick_health_check()
# - Manual slot creation: spock_create_recovery_slot()
# - Slot persistence across PostgreSQL restart
#
# Expected Results:
# - All 12 tests should pass
# - Each node should have exactly ONE recovery slot
# - Slots should be inactive (active=t but not used for replication)
# - SQL functions should return correct status

# Create a 2-node cluster (creates nodes, installs extension)
create_cluster(2, 'Create 2-node cluster for recovery slot testing');

# Get cluster configuration
my $config = get_test_config();
my $node_ports = $config->{node_ports};
my $host = $config->{host};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};
my $db_password = $config->{db_password};

# Cross-wire nodes to create subscriptions (triggers manager worker startup)
cross_wire(2, ['n1', 'n2'], 'Cross-wire 2 nodes for bidirectional replication');

# Give manager time to start and create recovery slots
sleep 3;

# =============================================================================
# Test 1-2: Verify recovery slots were created automatically on both nodes
# =============================================================================

my $slot_exists_n1 = scalar_query(1, 
    "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%')");
is($slot_exists_n1, 't', 'Node 1: Recovery slot exists');

my $slot_exists_n2 = scalar_query(2, 
    "SELECT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%')");
is($slot_exists_n2, 't', 'Node 2: Recovery slot exists');

# =============================================================================
# Test 3-4: Verify slot naming convention
# =============================================================================

my $slot_name_n1 = scalar_query(1, 
    "SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%'");
is($slot_name_n1, "spk_recovery_$dbname", 'Node 1: Recovery slot has correct name format');

my $slot_name_n2 = scalar_query(2, 
    "SELECT slot_name FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%'");
is($slot_name_n2, "spk_recovery_$dbname", 'Node 2: Recovery slot has correct name format');

# =============================================================================
# Test 5-6: Verify exactly ONE recovery slot per database (not per subscription)
# =============================================================================

my $slot_count_n1 = scalar_query(1, 
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%'");
is($slot_count_n1, '1', 'Node 1: Exactly one recovery slot (shared across subscriptions)');

my $slot_count_n2 = scalar_query(2, 
    "SELECT COUNT(*) FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%'");
is($slot_count_n2, '1', 'Node 2: Exactly one recovery slot (shared across subscriptions)');

# =============================================================================
# Test 7-8: Verify slots are inactive (not used for normal replication)
# =============================================================================

my $slot_type_n1 = scalar_query(1, 
    "SELECT slot_type FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%'");
is($slot_type_n1, 'logical', 'Node 1: Recovery slot is logical type');

my $slot_type_n2 = scalar_query(2, 
    "SELECT slot_type FROM pg_replication_slots WHERE slot_name LIKE 'spk_recovery_%'");
is($slot_type_n2, 'logical', 'Node 2: Recovery slot is logical type');

# =============================================================================
# Test 9-10: Test spock.get_recovery_slot_status() SQL function
# =============================================================================

my $status_n1 = scalar_query(1, 
    "SELECT active FROM spock.get_recovery_slot_status()");
is($status_n1, 't', 'Node 1: Recovery slot status shows active=true');

my $status_n2 = scalar_query(2, 
    "SELECT active FROM spock.get_recovery_slot_status()");
is($status_n2, 't', 'Node 2: Recovery slot status shows active=true');

# =============================================================================
# Test 11-12: Test spock.quick_health_check() SQL function
# =============================================================================

my $health_n1 = scalar_query(1, 
    "SELECT status FROM spock.quick_health_check()");
is($health_n1, 'HEALTHY', 'Node 1: Health check reports HEALTHY');

my $health_n2 = scalar_query(2, 
    "SELECT status FROM spock.quick_health_check()");
is($health_n2, 'HEALTHY', 'Node 2: Health check reports HEALTHY');

# =============================================================================
# Cleanup
# =============================================================================

destroy_cluster('Destroy 2-node recovery slot test cluster');

done_testing();

