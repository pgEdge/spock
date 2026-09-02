use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config scalar_query psql_or_bail
);

# =============================================================================
# Test: 106_quorum_layer.pl
#
# Covers the quorum layer's fail-safe surface.
#
# Deliberately runs no external quorum system.  The property that matters most
# is what happens when the layer CANNOT get an answer -- provider absent,
# endpoint unset, endpoint unreachable, provider switched at runtime -- and all
# of that is reachable without an etcd daemon or a Raft cluster.  Keeping the
# suite free of external services also keeps it runnable in CI.
#
# The one invariant every case below shares: an answer that could not be
# obtained is reported as NULL, never as false, and never as an error to the
# caller.
# =============================================================================

create_cluster(1, 'Create 1-node cluster for quorum-layer tests');

my $cfg    = get_test_config();
my $bin    = $cfg->{pg_bin};
my $host   = $cfg->{host};
my $port   = $cfg->{node_ports}[0];
my $db     = $cfg->{db_name};
my $user   = $cfg->{db_user};
my $datadir;

# Run SQL, returning (combined output, exit code).
sub psql_try {
    my ($sql) = @_;
    local $ENV{PGOPTIONS} = '-c client_min_messages=error';
    my $out = `$bin/psql -X -h $host -p $port -d $db -U $user -v ON_ERROR_STOP=1 -tAc "$sql" 2>&1`;
    my $rc  = ($? >> 8);
    chomp $out;
    return ($out, $rc);
}

# One field of the single quorum_status() row, with NULL rendered as 'NULL'.
sub status_field {
    my ($field) = @_;
    my ($out, $rc) = psql_try(
        "SELECT coalesce($field\::text, 'NULL') FROM spock.quorum_status()");
    return $rc == 0 ? $out : "ERROR:$out";
}

# Change a GUC in postgresql.conf and reload.  ALTER SYSTEM is avoided so the
# provider can be switched even when a value is rejected as out of range.
sub set_guc_reload {
    my ($name, $value) = @_;
    psql_or_bail(1, "ALTER SYSTEM SET $name = '$value'");
    psql_or_bail(1, "SELECT pg_reload_conf()");
    sleep(1);
}

sub reset_guc_reload {
    my ($name) = @_;
    psql_or_bail(1, "ALTER SYSTEM RESET $name");
    psql_or_bail(1, "SELECT pg_reload_conf()");
    sleep(1);
}

# --------------------------------------------------------------------------
# Version and surface
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT extversion FROM pg_extension WHERE extname = 'spock'"),
   '6.1.0', 'extension reports version 6.1.0');

is(scalar_query(1,
    "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " .
    " WHERE n.nspname = 'spock' AND p.proname = 'quorum_status'"),
   '1', 'spock.quorum_status() exists');

is(scalar_query(1, "SELECT count(*) FROM spock.quorum_status()"),
   '1', 'quorum_status() returns exactly one row');

# VOLATILE, not STABLE: the function re-reads the provider, so the planner
# must not fold two calls in one statement into a single evaluation.
is(scalar_query(1,
    "SELECT provolatile FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace " .
    " WHERE n.nspname = 'spock' AND p.proname = 'quorum_status'"),
   'v', 'quorum_status() is declared VOLATILE');

# The function can influence nothing by itself, but it names the cluster and
# its provider, so it is not world-readable.
is(scalar_query(1,
    "SELECT has_function_privilege('public', 'spock.quorum_status()', 'EXECUTE')"),
   'f', 'quorum_status() is not executable by PUBLIC');

# Every GUC the layer defines must be present, or a deployment cannot be
# configured at all.
for my $guc (qw(spock.quorum_provider spock.quorum_timeout
                spock.quorum_cluster_id spock.quorum_etcd_endpoints)) {
    is(scalar_query(1, "SELECT count(*) FROM pg_settings WHERE name = '$guc'"),
       '1', "$guc is defined");
}

# --------------------------------------------------------------------------
# The default: nothing is consulted
#
# This is the regression that matters most. With no provider configured the
# layer must be inert, so enabling the feature is always a deliberate act.
# --------------------------------------------------------------------------
is(scalar_query(1, "SELECT setting FROM pg_settings WHERE name = 'spock.quorum_provider'"),
   'none', 'the default provider is none');

is(status_field('provider'), 'none', 'status reports the none provider');
is(status_field('has_quorum'), 'NULL', 'has_quorum is NULL, not false, with no provider');
is(status_field('is_leader'),  'NULL', 'is_leader is NULL with no provider');
is(status_field('leader'),     'NULL', 'leader is NULL with no provider');
is(status_field('last_error'), 'NULL', 'no error is reported when nothing was attempted');

# --------------------------------------------------------------------------
# A provider that is selected but not installed
#
# The layer must say so plainly rather than failing to start or pretending to
# have an answer.
# --------------------------------------------------------------------------
# A cluster id is now mandatory for every provider but 'none': the prefix is
# the only thing keeping two clusters' members apart, so there is no default.
set_guc_reload('spock.quorum_cluster_id', 'tap_cluster');

for my $prov (qw(pgraft pgbully)) {
    set_guc_reload('spock.quorum_provider', $prov);

    is(status_field('provider'), $prov, "status reports the $prov provider");
    is(status_field('has_quorum'), 'NULL',
       "has_quorum is NULL when $prov is not installed");
    like(status_field('last_error'), qr/\Q$prov\E/,
         "last_error names $prov as the missing extension");
}

# --------------------------------------------------------------------------
# A missing cluster id is refused, not defaulted
#
# Sharing one prefix between two clusters would make each count the other's
# nodes as its own, so the layer declines to start rather than guess.
# --------------------------------------------------------------------------
reset_guc_reload('spock.quorum_cluster_id');
is(status_field('has_quorum'), 'NULL', 'no answer while the cluster id is unset');
like(status_field('last_error'), qr/quorum_cluster_id/,
     'last_error names the missing cluster id');
set_guc_reload('spock.quorum_cluster_id', 'tap_cluster');

# --------------------------------------------------------------------------
# etcd with nothing to talk to
# --------------------------------------------------------------------------
set_guc_reload('spock.quorum_provider', 'etcd');

# No endpoints configured at all.
is(status_field('has_quorum'), 'NULL', 'has_quorum is NULL with no etcd endpoints');
like(status_field('last_error'), qr/endpoints/,
     'last_error points at the unset endpoint list');

# An endpoint that is syntactically fine but has nothing listening. Port 1 is
# used because it is reserved and will never have a real service on it.
set_guc_reload('spock.quorum_etcd_endpoints', 'http://127.0.0.1:1');
is(status_field('has_quorum'), 'NULL', 'has_quorum is NULL when etcd is unreachable');
like(status_field('last_error'), qr/127\.0\.0\.1:1/,
     'last_error names the endpoint that could not be reached');

# Asking again must not raise: a provider is forbidden from throwing, and the
# status view has to stay usable while the cluster is unhealthy.
my (undef, $again_rc) = psql_try("SELECT * FROM spock.quorum_status()");
is($again_rc, 0, 'the status view keeps working while the provider is unreachable');

# Malformed endpoint lists are a configuration error, not a crash.
set_guc_reload('spock.quorum_etcd_endpoints', ',,,');
is(status_field('has_quorum'), 'NULL', 'a malformed endpoint list yields no answer');
my (undef, $mal_rc) = psql_try("SELECT * FROM spock.quorum_status()");
is($mal_rc, 0, 'a malformed endpoint list does not raise');

reset_guc_reload('spock.quorum_etcd_endpoints');

# --------------------------------------------------------------------------
# A failing provider must not poison the caller's transaction
#
# Catching the error without an internal subtransaction leaves the surrounding
# transaction aborted, so the operator's next statement fails with "current
# transaction is aborted".  The status view is consulted from whatever
# transaction they happen to be in, so this has to hold.
# --------------------------------------------------------------------------
my ($txn, $txn_rc) = psql_try(
    "BEGIN; SELECT 1 AS before; SELECT has_quorum FROM spock.quorum_status(); " .
    "SELECT 2 AS after; COMMIT");
is($txn_rc, 0, 'a transaction survives consulting an unreachable provider');
like($txn, qr/\b2\b/, 'statements after the failed consult still run');

# --------------------------------------------------------------------------
# Runtime reconfiguration
#
# The provider is PGC_SIGHUP. A long-lived backend must notice a change rather
# than answering from whatever was configured when it first connected.
# --------------------------------------------------------------------------
set_guc_reload('spock.quorum_provider', 'none');
is(status_field('provider'), 'none', 'switching back to none is picked up');
is(status_field('last_error'), 'NULL', 'switching provider clears the stale error');

set_guc_reload('spock.quorum_provider', 'pgraft');
is(status_field('provider'), 'pgraft', 'switching away from none is picked up');

# Within a single session, too: the checks above each used a fresh backend,
# which would hide a provider cached for the life of a connection.  Statements
# go in on stdin rather than through -c, because ALTER SYSTEM cannot run inside
# a transaction block and -c wraps its whole string in one.
my $session = `$bin/psql -X -h $host -p $port -d $db -U $user -tA 2>&1 <<'EOSQL'
SELECT 'first=' || provider FROM spock.quorum_status();
ALTER SYSTEM SET spock.quorum_provider = 'none';
SELECT pg_reload_conf();
SELECT pg_sleep(1);
SELECT 'second=' || provider FROM spock.quorum_status();
EOSQL`;
like($session, qr/first=pgraft/, 'the session starts on the configured provider');
like($session, qr/second=none/,
     'the same backend reports the new provider after a reload');

reset_guc_reload('spock.quorum_provider');

# --------------------------------------------------------------------------
# GUC bounds
#
# The timeout is the deadline that keeps a wedged provider from stalling the
# caller, so its bounds are load-bearing rather than cosmetic.
# --------------------------------------------------------------------------
is(scalar_query(1,
    "SELECT min_val || '..' || max_val FROM pg_settings WHERE name = 'spock.quorum_timeout'"),
   '100..60000', 'the timeout is bounded to a sane millisecond range');

# PGC_SIGHUP: a session cannot change it at all, whatever the value.  That is
# deliberate -- the deadline protects a shared worker, not one backend.
my (undef, $set_rc) = psql_try("SET spock.quorum_timeout = '5s'");
isnt($set_rc, 0, 'the timeout cannot be changed by a single session');
my (undef, $set_prov_rc) = psql_try("SET spock.quorum_provider = 'etcd'");
isnt($set_prov_rc, 0, 'the provider cannot be changed by a single session');

# Values are still validated when set the supported way.
my (undef, $lo_rc) = psql_try("ALTER SYSTEM SET spock.quorum_timeout = '1ms'");
isnt($lo_rc, 0, 'a timeout below the minimum is rejected');
my (undef, $hi_rc) = psql_try("ALTER SYSTEM SET spock.quorum_timeout = '10min'");
isnt($hi_rc, 0, 'a timeout above the maximum is rejected');
my (undef, $ok_rc) = psql_try("ALTER SYSTEM SET spock.quorum_timeout = '5s'");
is($ok_rc, 0, 'a timeout inside the range is accepted');
reset_guc_reload('spock.quorum_timeout');

my (undef, $bad_prov_rc) = psql_try("ALTER SYSTEM SET spock.quorum_provider = 'wobble'");
isnt($bad_prov_rc, 0, 'an unknown provider name is rejected');

# --------------------------------------------------------------------------
# Nothing the layer does perturbs replication
#
# The layer is inert by design; this is the check that it stays that way.
# --------------------------------------------------------------------------
is(scalar_query(1,
    "SELECT count(*) FROM pg_replication_slots WHERE slot_name LIKE '%quorum%'"),
   '0', 'the quorum layer creates no replication slots');

is(scalar_query(1,
    "SELECT count(*) FROM pg_stat_activity WHERE application_name LIKE '%quorum%'"),
   '0', 'the quorum layer starts no background worker of its own');

destroy_cluster('Destroy quorum-layer test cluster');
done_testing();
