use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use Time::HiRes qw(time);
use MIME::Base64 qw(encode_base64);
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail
    run_capture find_in_path
);

# =============================================================================
# Test: 111_quorum_etcd.pl
#
# The etcd quorum provider, driven against t/mock_etcd.py: a stand-in for the
# v3 HTTP/JSON gateway that speaks the same request and reply shapes and can
# be told to misbehave.
#
# Positive: a completed linearizable read is quorum; membership is whatever
# is registered under <cluster_id>/nodes/, filtered to nodes in spock.node;
# the leader is whoever holds <cluster_id>/leader; a node removed from Spock
# stops counting even while still registered; endpoints rotate past a dead
# one.
#
# Negative: HTTP errors, replies that are not JSON, a gateway slower than
# spock.quorum_timeout, and a registration that expires.  Every one of them
# yields NULL answers with a named cause, never an error to the caller, and
# never a poisoned transaction.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for etcd quorum tests');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $cfg  = get_test_config();
my $bin  = $cfg->{pg_bin};
my $host = $cfg->{host};
my $port = $cfg->{node_ports}[0];
my $db   = $cfg->{db_name};
my $user = $cfg->{db_user};

sub psql_try {
    my ($sql) = @_;
    local $ENV{PGOPTIONS} = '-c client_min_messages=error';
    return run_capture("$bin/psql", '-X', '-h', $host, '-p', $port, '-d', $db, '-U', $user,
                       '-v', 'ON_ERROR_STOP=1', '-tA', '-c', $sql);
}

# Run a script of statements in one session, like psql on stdin, returning
# its output.  Used where ALTER SYSTEM has to run between statements, which
# -c cannot do because it wraps its whole string in one transaction.
sub psql_session {
    my ($script) = @_;
    my ($fh, $file) = tempfile(UNLINK => 1);
    print $fh $script;
    close($fh);
    my ($out, $rc) = run_capture("$bin/psql", '-X', '-h', $host, '-p', $port, '-d', $db, '-U', $user,
                                 '-tA', '-f', $file);
    return $out;
}

sub status_field {
    my ($field) = @_;
    my ($out, $rc) = psql_try(
        "SELECT coalesce($field\::text, 'NULL') FROM spock.quorum_status()");
    return $rc == 0 ? $out : "ERROR:$out";
}

sub members {
    return scalar_query(1,
        "SELECT coalesce(string_agg(member_name || ':' || live::text, ',' ORDER BY member_name), '') " .
        "  FROM spock.quorum_members()");
}

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
# The mock gateway
# --------------------------------------------------------------------------
my $python = find_in_path('python3');
my $curl = find_in_path('curl');
my $mock_port = 24790 + ($$ % 1000);
my $mock_url  = "http://127.0.0.1:$mock_port";

set_guc_reload('spock.quorum_cluster_id', 'tap_cluster');
set_guc_reload('spock.quorum_provider', 'etcd');
my $have_curl = status_field('last_error') !~ /no HTTP client/;

my $mock_pid;
if ($have_curl && $python && $curl) {
    $mock_pid = fork();
    if ($mock_pid == 0) {
        # The child must not inherit the TAP stream: prove reads it until
        # EOF, and a mock that outlived the test would hold it open.
        open(STDOUT, '>', '/dev/null');
        open(STDERR, '>', '/dev/null');
        exec($python, 't/mock_etcd.py', $mock_port) or exit(1);
    }
    for (1 .. 50) {
        last if system($curl, '-s', '-o', '/dev/null', "$mock_url/") == 0;
        select(undef, undef, undef, 0.2);
    }
}

sub mock_post {
    my ($path, $json) = @_;
    my ($out, $rc) = run_capture($curl, '-s', '-X', 'POST', "$mock_url$path", '-d', $json);
    return $out;
}

sub etcd_put {
    my ($key, $value, $lease) = @_;
    my $k = encode_base64($key, '');
    my $v = encode_base64($value, '');
    my $l = $lease ? ",\"lease\":\"$lease\"" : '';
    mock_post('/v3/kv/put', "{\"key\":\"$k\",\"value\":\"$v\"$l}");
}

sub etcd_del {
    my ($key) = @_;
    my $k = encode_base64($key, '');
    mock_post('/v3/kv/deleterange', "{\"key\":\"$k\"}");
}

sub mock_mode {
    my ($mode, $delay) = @_;
    $delay //= 0;
    mock_post('/mock/mode', "{\"mode\":\"$mode\",\"delay\":$delay}");
}

# Whatever happens below, the mock must not outlive the test.
END { kill 'TERM', $mock_pid if $mock_pid; }

if (!$mock_pid) {
    diag('etcd tests need libcurl in the build, python3 and curl');
    reset_guc_reload('spock.quorum_provider');
    reset_guc_reload('spock.quorum_cluster_id');
    destroy_cluster('Destroy etcd quorum test cluster');
    done_testing();
    exit 0;
}

set_guc_reload('spock.quorum_etcd_endpoints', $mock_url);

# --------------------------------------------------------------------------
# Positive: an empty registry
# --------------------------------------------------------------------------
is(status_field('provider'), 'etcd', 'the etcd provider is selected');
is(status_field('has_quorum'), 'true', 'a completed linearizable read proves quorum');
is(status_field('is_leader'), 'false', 'nobody leads while the leader key is absent');
is(status_field('leader'), 'NULL', 'no leader name while the leader key is absent');
is(status_field('last_error'), 'NULL', 'no error against a healthy gateway');
isnt(status_field('last_consulted'), 'NULL', 'a successful reading is timestamped');
is(members(), '', 'no members while nothing is registered');

# --------------------------------------------------------------------------
# Positive: registration, filtering, leadership
# --------------------------------------------------------------------------
etcd_put('tap_cluster/nodes/n1', 'n1');
etcd_put('tap_cluster/nodes/n2', 'n2');
etcd_put('tap_cluster/nodes/ghost', 'ghost');
etcd_put('other_cluster/nodes/n9', 'n9');

is(members(), 'n1:true,n2:true',
   'registered nodes known to spock.node are members; a stranger is not');
is(scalar_query(1, "SELECT count(*) FROM spock.quorum_members() WHERE last_seen IS NULL"),
   '2', 'etcd does not track last contact, so last_seen is NULL');
is(scalar_query(1, "SELECT bool_and(voting) FROM spock.quorum_members()"),
   't', 'every registered member votes');

etcd_put('tap_cluster/leader', 'n1');
is(status_field('is_leader'), 'true', 'this node leads while it holds the leader key');
is(status_field('leader'), 'n1', 'the leader name is read from the leader key');

etcd_put('tap_cluster/leader', 'n2');
is(status_field('is_leader'), 'false', 'this node does not lead when a peer holds the key');
is(status_field('leader'), 'n2', 'the leader name follows the key');

etcd_put('tap_cluster/leader', 'ghost');
is(status_field('is_leader'), 'false', 'a stranger holding the key means this node does not lead');
is(status_field('leader'), 'NULL', 'a leader Spock does not know is not named');

etcd_del('tap_cluster/leader');
is(status_field('is_leader'), 'false', 'no leader once the key is gone');
is(status_field('leader'), 'NULL', 'and no leader name either');

# A reading is one transaction: members and leader come from one revision,
# and asking twice in one statement is two readings, not one folded answer.
my ($two, $two_rc) = psql_try(
    "SELECT (SELECT has_quorum FROM spock.quorum_status()) AND " .
    "       (SELECT has_quorum FROM spock.quorum_status())");
is($two, 't', 'two readings in one statement both succeed');

# --------------------------------------------------------------------------
# Positive: a registration that lapses
#
# A node that stops renewing its lease has its key expired by etcd.  The mock
# never expires anything by itself, so the lease is revoked by hand, which
# is what etcd does when the TTL runs out.
# --------------------------------------------------------------------------
my $grant = mock_post('/v3/lease/grant', '{"TTL":"30"}');
my ($lease) = $grant =~ /"ID":\s*"(\d+)"/;
ok($lease, 'the mock grants a lease');
etcd_del('tap_cluster/nodes/n2');
etcd_put('tap_cluster/nodes/n2', 'n2', $lease);
is(members(), 'n1:true,n2:true', 'a leased registration counts like any other');
mock_post('/v3/lease/revoke', "{\"ID\":\"$lease\"}");
is(members(), 'n1:true', 'a member whose lease lapsed is gone from the reading');

# --------------------------------------------------------------------------
# Positive: removing a node from Spock
#
# n2 is registered again and alive as far as etcd is concerned.  Dropping it
# from Spock must stop it counting at once: a consumer that still waited for
# n2 would pin WAL for a node that no longer exists.
# --------------------------------------------------------------------------
etcd_put('tap_cluster/nodes/n2', 'n2');
is(members(), 'n1:true,n2:true', 'n2 is back before it is dropped');

psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");
psql_or_bail(2, "SELECT spock.sub_drop('sub_n2_n1')");
# Dropping the last subscription from a node drops the node record with it;
# node_drop() is the explicit form and is a no-op here.
psql_or_bail(1, "SELECT spock.node_drop('n2', true)");
is(scalar_query(1, "SELECT count(*) FROM spock.node WHERE node_name = 'n2'"),
   '0', 'n2 is gone from spock.node');

is(members(), 'n1:true',
   'a node dropped from spock.node stops counting while still registered in etcd');
is(status_field('has_quorum'), 'true', 'quorum itself is unaffected by the drop');

# --------------------------------------------------------------------------
# Positive: endpoint rotation
#
# One dead endpoint costs one call, not every call.
# --------------------------------------------------------------------------
set_guc_reload('spock.quorum_etcd_endpoints', "http://127.0.0.1:1,$mock_url");
is(status_field('has_quorum'), 'true',
   'a live endpoint is reached despite a dead one listed before it');
is(status_field('last_error'), 'NULL', 'the dead endpoint leaves no error once a live one answered');
set_guc_reload('spock.quorum_etcd_endpoints', $mock_url);

# --------------------------------------------------------------------------
# Negative: the gateway fails
# --------------------------------------------------------------------------
mock_mode('http500');
is(status_field('has_quorum'), 'NULL', 'an HTTP error yields no answer, not false');
is(status_field('is_leader'), 'NULL', 'and no leadership');
like(status_field('last_error'), qr/HTTP 500/, 'last_error names the HTTP status');
is(members(), '', 'no members without a reading');

# last_consulted and last_error describe this session's own consults, so a
# good reading followed by a failed one in the same session keeps the time
# of the good one.  The mock is switched between the two statements from
# inside the session, with psql's \! escape.
mock_mode('ok');
my $kept = psql_session(<<EOSQL);
SELECT 'good=' || coalesce(last_consulted::text, 'NULL') FROM spock.quorum_status();
\\! $curl -s -o /dev/null -X POST $mock_url/mock/mode -d '{"mode":"http500","delay":0}'
SELECT 'bad=' || coalesce(last_consulted::text, 'NULL') || ' err=' || coalesce(last_error, 'NULL') FROM spock.quorum_status();
EOSQL
my ($good_ts) = $kept =~ /good=(\S+ \S+)/;
ok($good_ts, 'a good reading is timestamped');
like($kept, qr/bad=\Q$good_ts\E err=.*HTTP 500/,
     'a failed consult keeps the time of the last good reading and names the failure');
mock_mode('http500');

my ($txn, $txn_rc) = psql_try(
    "BEGIN; SELECT has_quorum FROM spock.quorum_status(); SELECT 42 AS after; COMMIT");
is($txn_rc, 0, 'a failing gateway does not poison the transaction');
like($txn, qr/\b42\b/, 'statements after the failed consult still run');

mock_mode('garbage');
is(status_field('has_quorum'), 'NULL', 'a reply that is not JSON yields no answer');
like(status_field('last_error'), qr/unexpected shape|unparseable/,
     'last_error says the reply was not understood');

# --------------------------------------------------------------------------
# Negative: the gateway is too slow
#
# spock.quorum_timeout is the contract.  A gateway that takes longer than
# that yields no answer and, more to the point, does not keep the caller
# waiting for the full delay.
# --------------------------------------------------------------------------
set_guc_reload('spock.quorum_timeout', '500ms');
mock_mode('slow', 4);
my $t0 = time();
my $slow = status_field('has_quorum');
my $elapsed = time() - $t0;
is($slow, 'NULL', 'a gateway slower than the timeout yields no answer');
ok($elapsed < 3, sprintf('the caller waited %.1fs, not the full delay', $elapsed));
like(status_field('last_error'), qr/[Tt]ime/, 'last_error says the call timed out');
mock_mode('ok');
reset_guc_reload('spock.quorum_timeout');

# --------------------------------------------------------------------------
# Positive: recovery
# --------------------------------------------------------------------------
is(status_field('has_quorum'), 'true', 'service resumes once the gateway recovers');
is(status_field('last_error'), 'NULL', 'the error is cleared by a good reading');
is(members(), 'n1:true', 'membership is back');

# --------------------------------------------------------------------------
# Negative: the gateway goes away entirely
# --------------------------------------------------------------------------
kill 'TERM', $mock_pid;
waitpid($mock_pid, 0);
$mock_pid = undef;

is(status_field('has_quorum'), 'NULL', 'a gateway that is gone yields no answer');
like(status_field('last_error'), qr/127\.0\.0\.1:$mock_port/,
     'last_error names the endpoint that could not be reached');

reset_guc_reload('spock.quorum_etcd_endpoints');
reset_guc_reload('spock.quorum_provider');
reset_guc_reload('spock.quorum_cluster_id');
is(status_field('provider'), 'none', 'back to none, nothing is consulted');

destroy_cluster('Destroy etcd quorum test cluster');
done_testing();
