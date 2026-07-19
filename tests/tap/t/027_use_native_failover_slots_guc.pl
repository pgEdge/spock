use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query
);

# =============================================================================
# Test: 027_use_native_failover_slots_guc.pl
#
# Properties of the spock.use_native_failover_slots GUC (the PG17+ opt-in that
# switches spock from its own failover-slot worker to PostgreSQL's native
# slotsync).  End-to-end behaviour is covered by 018_failover_slots.pl; this
# checks the GUC itself: default, type, and that it is restart-only
# (PGC_POSTMASTER) and takes effect after ALTER SYSTEM + restart.
# =============================================================================

create_cluster(1);

my $cfg     = get_test_config();
my $bin     = $cfg->{pg_bin};
my $host    = $cfg->{host};
my $port    = $cfg->{node_ports}[0];
my $db      = $cfg->{db_name};
my $user    = $cfg->{db_user};
my $datadir = $cfg->{node_datadirs}[0];

my $GUC = 'spock.use_native_failover_slots';

# Run SQL, return (exit_code, combined_output).
sub psql_try {
    my ($sql) = @_;
    my $out = `$bin/psql -X -h $host -p $port -d $db -U $user -v ON_ERROR_STOP=1 -c "$sql" 2>&1`;
    return ($? >> 8, $out);
}

sub field {
    my ($col) = @_;
    return scalar_query(1, "SELECT $col FROM pg_settings WHERE name = '$GUC'");
}

# Restart the node (the GUC is PGC_POSTMASTER) and wait for it to accept SQL.
sub restart_node {
    system("$bin/pg_ctl -D $datadir -w restart >/dev/null 2>&1");
    for (1 .. 30) {
        return 1 if scalar_query(1, "SELECT 1") eq '1';
        select(undef, undef, undef, 0.5);
    }
    return 0;
}

# --------------------------------------------------------------------------
# Properties
# --------------------------------------------------------------------------
is(field('setting'),  'off',        "$GUC defaults to off");
is(field('boot_val'), 'off',        "$GUC boot default is off");
is(field('vartype'),  'bool',       "$GUC is boolean");
is(field('context'),  'postmaster', "$GUC is restart-only (PGC_POSTMASTER)");

# --------------------------------------------------------------------------
# Restart-only: SET is rejected at runtime
# --------------------------------------------------------------------------
my ($rc, $out) = psql_try("SET $GUC = on");
isnt($rc, 0, "SET $GUC is rejected at runtime");
like($out, qr/cannot be changed|without restarting/i,
     'rejection message mentions a restart is required');

# --------------------------------------------------------------------------
# Takes effect via ALTER SYSTEM + restart
# --------------------------------------------------------------------------
psql_try("ALTER SYSTEM SET $GUC = on");
ok(restart_node(), 'node restarts after enabling the GUC');
is(field('setting'), 'on', "$GUC is on after ALTER SYSTEM + restart");

# --------------------------------------------------------------------------
# Restore default so teardown is clean
# --------------------------------------------------------------------------
psql_try("ALTER SYSTEM RESET $GUC");
ok(restart_node(), 'node restarts after resetting the GUC');
is(field('setting'), 'off', "$GUC is back to off after reset + restart");

destroy_cluster();
done_testing();
