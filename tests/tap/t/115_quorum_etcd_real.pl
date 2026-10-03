use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Copy qw(copy);
use POSIX ();
use MIME::Base64 qw(encode_base64);
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail
    run_capture find_in_path
);

# =============================================================================
# Test: 115_quorum_etcd_real.pl
#
# The etcd quorum provider against a real etcd.
#
# etcd is taken from PATH, from $SPOCK_ETCD, or downloaded once from its
# release page into $SPOCK_TAP_CACHE (default ~/.cache/spock-tap).  The test
# is skipped when none of that works.  A single-member etcd is started on
# free ports and torn down at the end.
#
# What the mock in 111 cannot do and this test does: a real linearizable
# read, a real lease that expires on its own, and etcd's own reply shapes.
# =============================================================================

my $ETCD_VERSION = 'v3.7.2';

create_cluster(2, 'Create 2-node cluster for the real etcd test');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $cfg  = get_test_config();
my $bin  = $cfg->{pg_bin};
my $host = $cfg->{host};
my $port = $cfg->{node_ports}[0];
my $db   = $cfg->{db_name};
my $user = $cfg->{db_user};
my $log_dir = $cfg->{log_dir};

sub psql_try {
    my ($sql) = @_;
    local $ENV{PGOPTIONS} = '-c client_min_messages=error';
    return run_capture("$bin/psql", '-X', '-h', $host, '-p', $port, '-d', $db, '-U', $user,
                       '-v', 'ON_ERROR_STOP=1', '-tA', '-c', $sql);
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

sub finish_skipped {
    my ($why) = @_;
    diag($why);
    reset_guc_reload('spock.quorum_provider');
    reset_guc_reload('spock.quorum_cluster_id');
    destroy_cluster('Destroy cluster after skipping the real etcd test');
    done_testing();
    exit 0;
}

# --------------------------------------------------------------------------
# Find or fetch etcd
# --------------------------------------------------------------------------
my $curl = find_in_path('curl');

set_guc_reload('spock.quorum_cluster_id', 'tap_cluster');
set_guc_reload('spock.quorum_provider', 'etcd');
finish_skipped('this build has no libcurl, so the etcd provider is unavailable')
    if status_field('last_error') =~ /no HTTP client/;
finish_skipped('curl is needed to drive etcd') unless $curl;

sub find_etcd {
    return $ENV{SPOCK_ETCD} if $ENV{SPOCK_ETCD} && -x $ENV{SPOCK_ETCD};
    my $on_path = find_in_path('etcd');
    return $on_path if $on_path;

    my $cache = $ENV{SPOCK_TAP_CACHE} || "$ENV{HOME}/.cache/spock-tap";
    my $cached = "$cache/etcd-$ETCD_VERSION/etcd";
    return $cached if -x $cached;

    my $os = $^O;
    my $arch = (POSIX::uname())[4];
    $arch = 'amd64' if $arch eq 'x86_64';
    $arch = 'arm64' if $arch eq 'aarch64';
    my $ext = $os eq 'darwin' ? 'zip' : 'tar.gz';
    my $asset = "etcd-$ETCD_VERSION-$os-$arch.$ext";
    my $url = "https://github.com/etcd-io/etcd/releases/download/$ETCD_VERSION/$asset";

    make_path($cache);
    diag("downloading $url");
    system($curl, '-fsSL', '-o', "$cache/$asset", $url) == 0 or return undef;
    my @unpack = $ext eq 'zip'
        ? ('unzip', '-q', '-o', "$cache/$asset", '-d', $cache)
        : ('tar', '-xzf', "$cache/$asset", '-C', $cache);
    system(@unpack) == 0 or return undef;
    my $dir = "$cache/etcd-$ETCD_VERSION-$os-$arch";
    return undef unless -x "$dir/etcd";
    make_path("$cache/etcd-$ETCD_VERSION");
    copy("$dir/etcd", $cached) or return undef;
    chmod 0755, $cached;
    return $cached;
}

my $etcd = find_etcd();
finish_skipped('etcd is not available and could not be downloaded') unless $etcd;
pass("using etcd at $etcd");

# --------------------------------------------------------------------------
# Start a single-member etcd
# --------------------------------------------------------------------------
my $client_port = 32379 + ($$ % 1000);
my $peer_port   = $client_port + 1;
my $client_url  = "http://127.0.0.1:$client_port";
my $peer_url    = "http://127.0.0.1:$peer_port";
my $data_dir    = tempdir(CLEANUP => 1);

my $etcd_pid = fork();
if ($etcd_pid == 0) {
    open(STDOUT, '>', "$log_dir/etcd.log");
    open(STDERR, '>&', \*STDOUT);
    exec($etcd, '--name', 'tap', '--data-dir', $data_dir,
         '--listen-client-urls', $client_url, '--advertise-client-urls', $client_url,
         '--listen-peer-urls', $peer_url, '--initial-advertise-peer-urls', $peer_url,
         '--initial-cluster', "tap=$peer_url") or exit(1);
}
END { kill 'TERM', $etcd_pid if $etcd_pid; }

my $up = 0;
for (1 .. 100) {
    if (system($curl, '-s', '-o', '/dev/null', "$client_url/version") == 0) { $up = 1; last; }
    select(undef, undef, undef, 0.2);
}
ok($up, 'etcd is up');

sub etcd_post {
    my ($path, $json) = @_;
    my ($out, $rc) = run_capture($curl, '-s', '-X', 'POST', "$client_url$path", '-d', $json);
    return $out;
}

sub etcd_put {
    my ($key, $value, $lease) = @_;
    my $k = encode_base64($key, '');
    my $v = encode_base64($value, '');
    my $l = $lease ? ",\"lease\":\"$lease\"" : '';
    etcd_post('/v3/kv/put', "{\"key\":\"$k\",\"value\":\"$v\"$l}");
}

sub etcd_del {
    my ($key) = @_;
    my $k = encode_base64($key, '');
    etcd_post('/v3/kv/deleterange', "{\"key\":\"$k\"}");
}

set_guc_reload('spock.quorum_etcd_endpoints', $client_url);

# --------------------------------------------------------------------------
# A real linearizable read
# --------------------------------------------------------------------------
is(status_field('has_quorum'), 'true', 'a linearizable read against a healthy etcd is quorum');
is(status_field('is_leader'), 'false', 'nobody leads yet');
is(status_field('last_error'), 'NULL', 'no error');
is(members(), '', 'nobody is registered yet');

# --------------------------------------------------------------------------
# Registration and leadership, in etcd's own reply shapes
# --------------------------------------------------------------------------
etcd_put('tap_cluster/nodes/n1', 'n1');
etcd_put('tap_cluster/nodes/n2', 'n2');
etcd_put('tap_cluster/nodes/ghost', 'ghost');
etcd_put('other_cluster/nodes/n9', 'n9');
is(members(), 'n1:true,n2:true',
   'registered nodes known to spock.node are members; a stranger and another cluster are not');

etcd_put('tap_cluster/leader', 'n1');
is(status_field('is_leader'), 'true', 'this node leads while it holds the leader key');
is(status_field('leader'), 'n1', 'the leader name is read from the leader key');
etcd_put('tap_cluster/leader', 'n2');
is(status_field('is_leader'), 'false', 'a peer holding the key means this node does not lead');
is(status_field('leader'), 'n2', 'the leader name follows the key');
etcd_put('tap_cluster/leader', 'ghost');
is(status_field('leader'), 'NULL', 'a leader Spock does not know is not named');
etcd_del('tap_cluster/leader');
is(status_field('leader'), 'NULL', 'no leader once the key is gone');

# --------------------------------------------------------------------------
# A lease that really expires
#
# etcd enforces a minimum TTL of five seconds; a key written under the lease
# disappears on its own once nobody keeps it alive.
# --------------------------------------------------------------------------
my $grant = etcd_post('/v3/lease/grant', '{"TTL":"5"}');
my ($lease) = $grant =~ /"ID":\s*"(\d+)"/;
ok($lease, 'etcd grants a lease');
etcd_del('tap_cluster/nodes/n2');
etcd_put('tap_cluster/nodes/n2', 'n2', $lease);
is(members(), 'n1:true,n2:true', 'a leased registration counts like any other');

my $gone = 0;
for (1 .. 40) {
    if (members() eq 'n1:true') { $gone = 1; last; }
    select(undef, undef, undef, 0.5);
}
ok($gone, 'a registration whose lease expired is gone from the reading');

# --------------------------------------------------------------------------
# Removing a node from Spock
# --------------------------------------------------------------------------
etcd_put('tap_cluster/nodes/n2', 'n2');
is(members(), 'n1:true,n2:true', 'n2 is registered again');
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");
psql_or_bail(2, "SELECT spock.sub_drop('sub_n2_n1')");
# Dropping the last subscription from a node drops the node record with it;
# node_drop() is the explicit form and is a no-op here.
psql_or_bail(1, "SELECT spock.node_drop('n2', true)");
is(scalar_query(1, "SELECT count(*) FROM spock.node WHERE node_name = 'n2'"),
   '0', 'n2 is gone from spock.node');
is(members(), 'n1:true',
   'a node dropped from spock.node stops counting while still registered in etcd');

# --------------------------------------------------------------------------
# etcd goes away
# --------------------------------------------------------------------------
kill 'TERM', $etcd_pid;
waitpid($etcd_pid, 0);
$etcd_pid = undef;

is(status_field('has_quorum'), 'NULL', 'an etcd that is gone yields no answer');
like(status_field('last_error'), qr/127\.0\.0\.1:$client_port/,
     'last_error names the endpoint that could not be reached');

reset_guc_reload('spock.quorum_etcd_endpoints');
reset_guc_reload('spock.quorum_provider');
reset_guc_reload('spock.quorum_cluster_id');

destroy_cluster('Destroy the real etcd test cluster');
done_testing();
