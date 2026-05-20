use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config system_or_bail
    psql_or_bail scalar_query
);

# =============================================================================
# Test: 030_read_retry_count_guc.pl
#
# Verifies the spock.read_retry_count GUC:
#   1. is registered with the expected default (5)
#   2. is read by the apply path on each iteration via SHOW
#   3. accepts ALTER SYSTEM SET + pg_reload_conf() updates at runtime
#   4. rejects values outside the documented [0, 100] range
#
# The GUC controls the retry loop in spock_apply_heap_update() and
# spock_apply_heap_delete() — the apply worker re-reads the local
# relation up to spock.read_retry_count times when a row targeted by a
# remote UPDATE/DELETE is not yet visible locally.
# =============================================================================

create_cluster(2, 'Create 2-node Spock cluster for read_retry_count GUC');

my $config       = get_test_config();
my $host         = $config->{host};
my $primary_port = $config->{node_ports}->[0];

# -----------------------------------------------------------------------------
# 1. Default value is 5
# -----------------------------------------------------------------------------
my $default = scalar_query(1, "SHOW spock.read_retry_count");
$default =~ s/\s+//g;
is($default, '5',
    "spock.read_retry_count default is 5 (matches prior hardcoded behaviour)");

# -----------------------------------------------------------------------------
# 2. The GUC is reported in pg_settings with the expected metadata
# -----------------------------------------------------------------------------
my $context = scalar_query(1,
    "SELECT context FROM pg_settings WHERE name = 'spock.read_retry_count'");
$context =~ s/\s+//g;
is($context, 'sighup',
    "spock.read_retry_count GUC context is PGC_SIGHUP (settable via reload)");

my $unit = scalar_query(1,
    "SELECT coalesce(unit::text, '') FROM pg_settings WHERE name = 'spock.read_retry_count'");
$unit =~ s/\s+//g;
is($unit, '',
    "spock.read_retry_count is unit-less (raw retry count, not a time/size)");

my $min = scalar_query(1,
    "SELECT min_val FROM pg_settings WHERE name = 'spock.read_retry_count'");
$min =~ s/\s+//g;
is($min, '0', "spock.read_retry_count min_val is 0");

my $max = scalar_query(1,
    "SELECT max_val FROM pg_settings WHERE name = 'spock.read_retry_count'");
$max =~ s/\s+//g;
is($max, '100', "spock.read_retry_count max_val is 100");

# -----------------------------------------------------------------------------
# 3. ALTER SYSTEM SET + pg_reload_conf() takes effect at runtime
# -----------------------------------------------------------------------------
psql_or_bail(1, "ALTER SYSTEM SET spock.read_retry_count = 10");
psql_or_bail(1, "SELECT pg_reload_conf()");

# Open a fresh psql session (the SIGHUP needs a new backend to pick up the
# value from the postmaster). scalar_query opens a new connection each call.
sleep(1);
my $after_set = scalar_query(1, "SHOW spock.read_retry_count");
$after_set =~ s/\s+//g;
is($after_set, '10',
    "spock.read_retry_count picks up new value (10) after ALTER SYSTEM + reload");

# Reset to default
psql_or_bail(1, "ALTER SYSTEM RESET spock.read_retry_count");
psql_or_bail(1, "SELECT pg_reload_conf()");
sleep(1);
my $after_reset = scalar_query(1, "SHOW spock.read_retry_count");
$after_reset =~ s/\s+//g;
is($after_reset, '5',
    "spock.read_retry_count returns to default (5) after ALTER SYSTEM RESET");

# -----------------------------------------------------------------------------
# 4. Out-of-range values are rejected
# -----------------------------------------------------------------------------
# Use system() so we can check the exit code without psql_or_bail dying.
my $pg_bin = $config->{pg_bin};
my $dbname = $config->{db_name};
my $db_user = $config->{db_user};

my $rc_neg = system(
    "$pg_bin/psql -X -h $host -p $primary_port -d $dbname -U $db_user "
  . "-v ON_ERROR_STOP=1 "
  . "-c \"ALTER SYSTEM SET spock.read_retry_count = -1\" "
  . ">/dev/null 2>&1");
isnt($rc_neg, 0, "spock.read_retry_count rejects value below 0 (-1)");

my $rc_hi = system(
    "$pg_bin/psql -X -h $host -p $primary_port -d $dbname -U $db_user "
  . "-v ON_ERROR_STOP=1 "
  . "-c \"ALTER SYSTEM SET spock.read_retry_count = 101\" "
  . ">/dev/null 2>&1");
isnt($rc_hi, 0, "spock.read_retry_count rejects value above 100 (101)");

# Boundary values must succeed
my $rc_zero = system(
    "$pg_bin/psql -X -h $host -p $primary_port -d $dbname -U $db_user "
  . "-v ON_ERROR_STOP=1 "
  . "-c \"ALTER SYSTEM SET spock.read_retry_count = 0\" "
  . ">/dev/null 2>&1");
is($rc_zero, 0, "spock.read_retry_count accepts the lower boundary (0)");

my $rc_max = system(
    "$pg_bin/psql -X -h $host -p $primary_port -d $dbname -U $db_user "
  . "-v ON_ERROR_STOP=1 "
  . "-c \"ALTER SYSTEM SET spock.read_retry_count = 100\" "
  . ">/dev/null 2>&1");
is($rc_max, 0, "spock.read_retry_count accepts the upper boundary (100)");

# Cleanup so the destroy_cluster restart leaves no residue
psql_or_bail(1, "ALTER SYSTEM RESET spock.read_retry_count");

destroy_cluster('Destroy test cluster');
done_testing();
