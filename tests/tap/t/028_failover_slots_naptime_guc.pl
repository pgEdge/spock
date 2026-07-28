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
# Test: 028_failover_slots_naptime_guc.pl
#
# Verifies the tunable failover-slot worker interval GUCs:
#   spock.failover_slots_naptime
#   spock.failover_slots_feedback_naptime
#
# These control how often the spock_failover_slots worker syncs slot state to
# a physical standby.  A smaller naptime narrows the window in which the
# standby's synchronized slots lag the primary; subsecond values are allowed.
#
# The test checks defaults, unit, bounds, reloadability, that a new value
# takes effect on reload, that subsecond values are accepted, and that
# out-of-range values are rejected.
# =============================================================================

create_cluster(1);

my $cfg  = get_test_config();
my $bin  = $cfg->{pg_bin};
my $host = $cfg->{host};
my $port = $cfg->{node_ports}[0];
my $db   = $cfg->{db_name};
my $user = $cfg->{db_user};

# Run SQL and return (exit_code, combined_output).  ON_ERROR_STOP makes psql
# exit non-zero when the server rejects the statement.
sub psql_try {
    my ($sql) = @_;
    my $out = `$bin/psql -X -h $host -p $port -d $db -U $user -v ON_ERROR_STOP=1 -c "$sql" 2>&1`;
    return ($? >> 8, $out);
}

sub setting_of {
    my ($name) = @_;
    return scalar_query(1,
        "SELECT setting FROM pg_settings WHERE name = '$name'");
}

# --------------------------------------------------------------------------
# Defaults (pg_settings reports the value in the base unit, ms)
# --------------------------------------------------------------------------
is(setting_of('spock.failover_slots_naptime'), '1000',
   'failover_slots_naptime default is 1000 ms');
is(setting_of('spock.failover_slots_feedback_naptime'), '10000',
   'failover_slots_feedback_naptime default is 10000 ms');

# --------------------------------------------------------------------------
# Unit, bounds, and context
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT unit FROM pg_settings WHERE name='spock.failover_slots_naptime'"),
   'ms', 'naptime unit is ms');
is(scalar_query(1, "SELECT min_val||'/'||max_val FROM pg_settings WHERE name='spock.failover_slots_naptime'"),
   '1/3600000', 'naptime bounds are 1..3600000 ms');
is(scalar_query(1, "SELECT context FROM pg_settings WHERE name='spock.failover_slots_naptime'"),
   'sighup', 'naptime is reloadable (sighup), no restart needed');

# The two GUCs are defined by near-identical DefineCustomIntVariable() calls,
# so assert the second one's properties independently rather than assuming it
# inherited the first's.  This also pins the feedback GUC's 1 ms floor.
is(scalar_query(1, "SELECT unit FROM pg_settings WHERE name='spock.failover_slots_feedback_naptime'"),
   'ms', 'feedback_naptime unit is ms');
is(scalar_query(1, "SELECT min_val||'/'||max_val FROM pg_settings WHERE name='spock.failover_slots_feedback_naptime'"),
   '1/3600000', 'feedback_naptime bounds are 1..3600000 ms');
is(scalar_query(1, "SELECT context FROM pg_settings WHERE name='spock.failover_slots_feedback_naptime'"),
   'sighup', 'feedback_naptime is reloadable (sighup), no restart needed');

# --------------------------------------------------------------------------
# A new value takes effect on reload
# --------------------------------------------------------------------------
my ($rc, $out) = psql_try("ALTER SYSTEM SET spock.failover_slots_naptime = '5s'");
is($rc, 0, "ALTER SYSTEM accepts '5s'") or diag($out);
psql_try("SELECT pg_reload_conf()");

# Reload is asynchronous; poll briefly for the change to land.
my $val = '';
for (1 .. 20) {
    $val = setting_of('spock.failover_slots_naptime');
    last if $val eq '5000';
    select(undef, undef, undef, 0.25);
}
is($val, '5000', "naptime becomes 5000 ms after reload");

# --------------------------------------------------------------------------
# Subsecond values are accepted (the minimum is 1 ms, not 1 s)
# --------------------------------------------------------------------------
($rc, $out) = psql_try("ALTER SYSTEM SET spock.failover_slots_naptime = '500ms'");
is($rc, 0, "ALTER SYSTEM accepts a subsecond value ('500ms')") or diag($out);

# --------------------------------------------------------------------------
# Out-of-range values are rejected
# --------------------------------------------------------------------------
($rc, $out) = psql_try("ALTER SYSTEM SET spock.failover_slots_naptime = '2h'");
isnt($rc, 0, "ALTER SYSTEM rejects '2h' (above the 3600000 ms maximum)");
like($out, qr/outside the valid range|invalid value/i,
     "rejection message mentions the valid range");

# Lower bound: the floor is 1 ms, so 0 must still be rejected.  This is the
# boundary the subsecond change moved (it was 1000 ms), so pin it explicitly
# -- 0 would otherwise read as a plausible "disable the nap" value.
($rc, $out) = psql_try("ALTER SYSTEM SET spock.failover_slots_naptime = '0ms'");
isnt($rc, 0, "ALTER SYSTEM rejects '0ms' (below the 1 ms minimum)");

($rc, $out) = psql_try("ALTER SYSTEM SET spock.failover_slots_feedback_naptime = '0ms'");
isnt($rc, 0, "ALTER SYSTEM rejects '0ms' for feedback_naptime (below the 1 ms minimum)");

# Restore the default so the node is clean for teardown.
psql_try("ALTER SYSTEM RESET spock.failover_slots_naptime");
psql_try("SELECT pg_reload_conf()");

destroy_cluster();
done_testing();
