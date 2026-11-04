use strict;
use warnings;
use Test::More;
use File::Temp qw(tempdir);
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail system_or_bail system_maybe
    run_capture find_in_path
);

# =============================================================================
# Test: 114_quorum_pgraft_real.pl
#
# The pgraft quorum provider against the real pgraft extension.
#
# pgraft is built from source when it is not already installed: from
# $PGRAFT_SRC if set, otherwise from a fresh clone of its repository.  It
# needs a Go toolchain.  The test is skipped when none of that works.
#
# Three Spock nodes run pgraft with the same initial_cluster, and each
# pgraft member carries the Spock node's name, which is how the provider
# matches them.  The test checks the provider's reading against what pgraft
# itself reports, stops a follower (the leader reports it inactive), stops
# a second node (the leader loses its majority and steps down, so quorum is
# gone), brings them back, and finally drops a node from Spock while pgraft
# still lists it.
# =============================================================================

my $NODES = 3;

create_cluster($NODES, 'Create 3-node cluster for the real pgraft test');

my $cfg      = get_test_config();
my $bin      = $cfg->{pg_bin};
my $host     = $cfg->{host};
my @ports    = @{$cfg->{node_ports}};
my @datadirs = @{$cfg->{node_datadirs}};
my $db       = $cfg->{db_name};
my $user     = $cfg->{db_user};
my $log_dir  = $cfg->{log_dir};

sub psql_on {
    my ($i, $sql) = @_;
    local $ENV{PGOPTIONS} = '-c client_min_messages=error';
    return run_capture("$bin/psql", '-X', '-h', $host, '-p', $ports[$i], '-d', $db, '-U', $user,
                       '-v', 'ON_ERROR_STOP=1', '-tA', '-c', $sql);
}

sub status_field {
    my ($i, $field) = @_;
    my ($out, $rc) = psql_on($i,
        "SELECT coalesce($field\::text, 'NULL') FROM spock.quorum_status()");
    return $rc == 0 ? $out : "ERROR:$out";
}

sub members {
    my ($i) = @_;
    my ($out, $rc) = psql_on($i,
        "SELECT coalesce(string_agg(member_name || ':' || live::text, ',' ORDER BY member_name), '') " .
        "  FROM spock.quorum_members()");
    return $rc == 0 ? $out : "ERROR:$out";
}

sub wait_status {
    my ($i, $field, $want, $secs) = @_;
    my $got = '';
    for (1 .. ($secs * 2)) {
        $got = status_field($i, $field);
        return 1 if $got eq $want;
        select(undef, undef, undef, 0.5);
    }
    diag("node " . ($i + 1) . " $field: wanted '$want', last saw '$got'");
    return 0;
}

sub wait_members {
    my ($i, $want, $secs) = @_;
    my $got = '';
    for (1 .. ($secs * 2)) {
        $got = members($i);
        return 1 if $got eq $want;
        select(undef, undef, undef, 0.5);
    }
    diag("node " . ($i + 1) . " members: wanted '$want', last saw '$got'");
    return 0;
}

sub set_guc_reload {
    my ($i, $name, $value) = @_;
    psql_or_bail($i + 1, "ALTER SYSTEM SET $name = '$value'");
    psql_or_bail($i + 1, "SELECT pg_reload_conf()");
    sleep(1);
}

sub finish_skipped {
    my ($why) = @_;
    diag($why);
    destroy_cluster('Destroy cluster after skipping the real pgraft test');
    done_testing();
    exit 0;
}

# --------------------------------------------------------------------------
# pgraft: already installed, or built from source
# --------------------------------------------------------------------------
my ($avail) = psql_on(0, "SELECT count(*) FROM pg_available_extensions WHERE name = 'pgraft'");
if ($avail ne '1') {
    my $go = find_in_path('go');
    finish_skipped('pgraft is not installed and there is no Go toolchain to build it') unless $go;
    my $src = $ENV{PGRAFT_SRC};
    if (!$src) {
        my $tmp = tempdir(CLEANUP => 1);
        $src = "$tmp/pgraft";
        if (system('git', 'clone', '--quiet', '--depth', '1',
                   'https://github.com/pgElephant/pgraft', $src) != 0) {
            finish_skipped('pgraft is not installed and could not be cloned');
        }
    }
    if (!system_maybe('make', '-C', $src, "PG_CONFIG=$bin/pg_config", 'install')) {
        finish_skipped("pgraft could not be built from $src; see the test log");
    }
    ($avail) = psql_on(0, "SELECT count(*) FROM pg_available_extensions WHERE name = 'pgraft'");
    finish_skipped('pgraft was built but is still not available') unless $avail eq '1';
}
pass('pgraft is available');

# --------------------------------------------------------------------------
# Preload pgraft on every node and restart
#
# Each pgraft member is named after its Spock node; that name is what the
# provider matches on.
# --------------------------------------------------------------------------
my @peer_ports = map { 27000 + ($$ % 1000) * 3 + $_ } (0 .. $NODES - 1);
my $initial_cluster = join(',', map {
    'n' . ($_ + 1) . "=http://127.0.0.1:$peer_ports[$_]"
} (0 .. $NODES - 1));

for my $i (0 .. $NODES - 1) {
    my $name = 'n' . ($i + 1);
    open(my $conf, '>>', "$datadirs[$i]/postgresql.conf") or die "cannot open postgresql.conf: $!";
    print $conf "shared_preload_libraries = 'spock,pgraft'\n";
    print $conf "pgraft.name = '$name'\n";
    print $conf "pgraft.initial_cluster = '$initial_cluster'\n";
    print $conf "pgraft.initial_cluster_state = 'new'\n";
    print $conf "pgraft.initial_cluster_token = 'spock-tap'\n";
    print $conf "pgraft.listen_peer_urls = 'http://127.0.0.1:$peer_ports[$i]'\n";
    print $conf "pgraft.initial_advertise_peer_urls = 'http://127.0.0.1:$peer_ports[$i]'\n";
    print $conf "pgraft.data_dir = '$datadirs[$i]/pgraft'\n";
    print $conf "pgraft.election_timeout = 1000\n";
    print $conf "pgraft.heartbeat_interval = 100\n";
    close($conf);
    system_or_bail("$bin/pg_ctl", 'restart', '-w', '-D', $datadirs[$i],
                   '-l', "$log_dir/pgctl_pgraft_" . ($i + 1) . ".log");
}

cross_wire($NODES, ['n1', 'n2', 'n3'], 'Cross-wire the three nodes');
# Installing the extension is a per-node act, like loading the library, so
# it is kept out of DDL replication: the replicated CREATE would race the
# local one on the other nodes.
psql_or_bail($_ + 1, "SET spock.enable_ddl_replication = off; CREATE EXTENSION pgraft")
    for (0 .. $NODES - 1);

# Wait for an election.  Node ids are positions in initial_cluster, so the
# leader's Spock name is simply "n<leader_id>".
my $leader_id = 0;
for (1 .. 120) {
    my ($l) = psql_on(0, 'SELECT coalesce(leader_id, 0) FROM pgraft.get_cluster_status()');
    if ($l =~ /^[1-9]\d*$/) { $leader_id = $l; last; }
    select(undef, undef, undef, 0.5);
}
ok($leader_id, "pgraft elected node $leader_id");
my $leader = $leader_id - 1;
my @followers = grep { $_ != $leader } (0 .. $NODES - 1);

# --------------------------------------------------------------------------
# The provider agrees with pgraft
# --------------------------------------------------------------------------
set_guc_reload($_, 'spock.quorum_provider', 'pgraft') for (0 .. $NODES - 1);

is(status_field(0, 'provider'), 'pgraft', 'the pgraft provider is selected');
is(status_field(0, 'last_error'), 'NULL', 'the real pgraft API is accepted');
ok(wait_status($_, 'has_quorum', 'true', 20), 'n' . ($_ + 1) . ' is in a quorum')
    for (0 .. $NODES - 1);
is(status_field($leader, 'is_leader'), 'true', "n$leader_id knows it leads");
is(status_field($followers[0], 'is_leader'), 'false', 'a follower knows it does not lead');
is(status_field($followers[0], 'leader'), "n$leader_id",
   'a follower names the leader through the member list');
ok(wait_members($leader, 'n1:true,n2:true,n3:true', 20),
   'the leader reports every member live');
is(members($followers[0]), 'n1:true,n2:true,n3:true',
   'a follower reports every member live');
is(scalar_query($leader + 1, "SELECT count(*) FROM spock.quorum_members() WHERE last_seen IS NULL"),
   '3', 'pgraft tracks no last contact, so last_seen is NULL');

# --------------------------------------------------------------------------
# One follower down: the leader sees it go inactive, quorum holds
# --------------------------------------------------------------------------
my $down = $followers[0];
my $up   = $followers[1];
system_or_bail("$bin/pg_ctl", 'stop', '-m', 'fast', '-w', '-D', $datadirs[$down]);

my $expect = join(',', map { 'n' . ($_ + 1) . ':' . ($_ == $down ? 'false' : 'true') }
                      (0 .. $NODES - 1));
ok(wait_members($leader, $expect, 30), 'the leader reports the stopped follower as not live');
is(status_field($leader, 'has_quorum'), 'true', 'two of three is still a majority');
is(members($up), 'n1:true,n2:true,n3:true',
   'the other follower has no activity signal and still reports every member live');

# --------------------------------------------------------------------------
# Two down: the leader cannot hear a majority and steps down
# --------------------------------------------------------------------------
system_or_bail("$bin/pg_ctl", 'stop', '-m', 'fast', '-w', '-D', $datadirs[$up]);

ok(wait_status($leader, 'has_quorum', 'false', 30),
   'a leader that lost its majority stops reporting quorum');
is(members($leader), '', 'no members without quorum');
is(status_field($leader, 'last_error'), 'NULL', 'a lost majority is not an error');

# --------------------------------------------------------------------------
# Recovery
# --------------------------------------------------------------------------
system_or_bail("$bin/pg_ctl", 'start', '-w', '-D', $datadirs[$down],
               '-l', "$log_dir/pgctl_pgraft_" . ($down + 1) . "b.log");
system_or_bail("$bin/pg_ctl", 'start', '-w', '-D', $datadirs[$up],
               '-l', "$log_dir/pgctl_pgraft_" . ($up + 1) . "b.log");

ok(wait_status(0, 'has_quorum', 'true', 60), 'quorum returns with the nodes');
ok(wait_members(0, 'n1:true,n2:true,n3:true', 60), 'every member is live again');

# --------------------------------------------------------------------------
# Removing a node from Spock
#
# n3 stays in initial_cluster everywhere and keeps taking part in raft.
# Dropping it from Spock must stop it counting.
# --------------------------------------------------------------------------
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n3')");
psql_or_bail(2, "SELECT spock.sub_drop('sub_n2_n3')");
psql_or_bail(3, "SELECT spock.sub_drop('sub_n3_n1')");
psql_or_bail(3, "SELECT spock.sub_drop('sub_n3_n2')");
# Dropping the last subscription from a node drops the node record with it;
# node_drop() is the explicit form and is a no-op here.
psql_or_bail(1, "SELECT spock.node_drop('n3', true)");
is(scalar_query(1, "SELECT count(*) FROM spock.node WHERE node_name = 'n3'"),
   '0', 'n3 is gone from spock.node');

ok(wait_members(0, 'n1:true,n2:true', 20),
   'a node dropped from spock.node stops counting while pgraft still lists it');
is(status_field(0, 'has_quorum'), 'true', 'quorum itself is pgraft\'s call and is unaffected');

destroy_cluster('Destroy the real pgraft test cluster');
done_testing();
