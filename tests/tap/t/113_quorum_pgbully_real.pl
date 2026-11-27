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
# Test: 113_quorum_pgbully_real.pl
#
# The pgBully quorum provider against the real pgBully extension.
#
# pgBully is built from source when it is not already installed: from
# $PGBULLY_SRC if set, otherwise from a fresh clone of its repository.  The
# test is skipped when neither works, so it costs nothing on a machine that
# has no network and no checkout.
#
# Three Spock nodes run pgBully with the same membership list.  The test
# checks the provider's reading against what pgBully itself reports, then
# stops one node (quorum holds, the node reads as not live), then a second
# (quorum lost), brings them back, and finally drops a node from Spock while
# pgBully still lists it.
# =============================================================================

my $NODES = 3;

create_cluster($NODES, 'Create 3-node cluster for the real pgBully test');

my $cfg      = get_test_config();
my $bin      = $cfg->{pg_bin};
my $host     = $cfg->{host};
my @ports    = @{$cfg->{node_ports}};
my @datadirs = @{$cfg->{node_datadirs}};
my $db       = $cfg->{db_name};
my $user     = $cfg->{db_user};
my $password = $cfg->{db_password};
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

# Poll a status field on node $i until it reads $want.
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
    destroy_cluster('Destroy cluster after skipping the real pgBully test');
    done_testing();
    exit 0;
}

# --------------------------------------------------------------------------
# pgBully: already installed, or built from source
# --------------------------------------------------------------------------
my ($avail) = psql_on(0, "SELECT count(*) FROM pg_available_extensions WHERE name = 'pgbully'");
if ($avail ne '1') {
    my $src = $ENV{PGBULLY_SRC};
    if (!$src) {
        my $tmp = tempdir(CLEANUP => 1);
        $src = "$tmp/pgbully";
        if (system('git', 'clone', '--quiet', '--depth', '1',
                   'https://github.com/pgElephant/pgbully', $src) != 0) {
            finish_skipped('pgbully is not installed and could not be cloned');
        }
    }
    if (!system_maybe('make', '-C', $src, "PG_CONFIG=$bin/pg_config", 'install')) {
        finish_skipped("pgbully could not be built from $src; see the test log");
    }
    ($avail) = psql_on(0, "SELECT count(*) FROM pg_available_extensions WHERE name = 'pgbully'");
    finish_skipped('pgbully was built but is still not available') unless $avail eq '1';
}
pass('pgbully is available');

# --------------------------------------------------------------------------
# Preload pgBully on every node and restart
#
# The membership list uses the same host and port as Spock's own node
# interfaces, which is how the provider matches a pgBully peer to a Spock
# node.
# --------------------------------------------------------------------------
my $membership = join(', ', map {
    ($_ + 1) . ": host=$host port=$ports[$_] dbname=$db user=$user password=$password"
} (0 .. $NODES - 1));

for my $i (0 .. $NODES - 1) {
    my $id = $i + 1;
    open(my $conf, '>>', "$datadirs[$i]/postgresql.conf") or die "cannot open postgresql.conf: $!";
    print $conf "shared_preload_libraries = 'spock,pgbully'\n";
    print $conf "pgbully.node_id = $id\n";
    print $conf "pgbully.nodes = '$membership'\n";
    print $conf "pgbully.heartbeat_interval = '300ms'\n";
    print $conf "pgbully.election_timeout = '1500ms'\n";
    print $conf "pgbully.connect_timeout = '1s'\n";
    close($conf);
    system_or_bail("$bin/pg_ctl", 'restart', '-w', '-D', $datadirs[$i],
                   '-l', "$log_dir/pgctl_pgbully_$id.log");
}

cross_wire($NODES, ['n1', 'n2', 'n3'], 'Cross-wire the three nodes');
# Installing the extension is a per-node act, like loading the library, so
# it is kept out of DDL replication: the replicated CREATE would race the
# local one on the other nodes.
psql_or_bail($_ + 1, "SET spock.enable_ddl_replication = off; CREATE EXTENSION pgbully")
    for (0 .. $NODES - 1);

# The bully rule: the highest reachable id leads.
my $leader_ok = 0;
for (1 .. 60) {
    my ($l) = psql_on(2, 'SELECT pgbully.is_leader()');
    if ($l eq 't') { $leader_ok = 1; last; }
    select(undef, undef, undef, 0.5);
}
ok($leader_ok, 'pgBully elected node 3');

# --------------------------------------------------------------------------
# The provider agrees with pgBully
# --------------------------------------------------------------------------
set_guc_reload($_, 'spock.quorum_provider', 'pgbully') for (0 .. $NODES - 1);

is(status_field(0, 'provider'), 'pgbully', 'the pgbully provider is selected');
is(status_field(0, 'last_error'), 'NULL', 'the real pgBully API is accepted');
is(status_field(0, 'has_quorum'), 'true', 'n1 is in a quorum');
is(status_field(0, 'is_leader'), 'false', 'n1 does not lead');
is(status_field(0, 'leader'), 'n3', 'n1 names n3 as leader, resolved through its connection string');
is(status_field(2, 'is_leader'), 'true', 'n3 knows it leads');
ok(wait_members(0, 'n1:true,n2:true,n3:true', 20), 'every peer is a live member');
is(scalar_query(1, "SELECT count(*) FROM spock.quorum_members() WHERE last_seen IS NOT NULL"),
   '3', 'every member, this node included, carries a last contact time');

my ($pgb_leader) = psql_on(0, 'SELECT pgbully.get_leader()');
is($pgb_leader, '3', 'pgBully itself reports node 3 as leader');

# --------------------------------------------------------------------------
# One node down: quorum holds, the node reads as not live, a new leader
# --------------------------------------------------------------------------
system_or_bail("$bin/pg_ctl", 'stop', '-m', 'fast', '-w', '-D', $datadirs[2]);

ok(wait_status(0, 'leader', 'n2', 30), 'n2 takes over once n3 is gone');
ok(wait_members(0, 'n1:true,n2:true,n3:false', 20), 'n3 reads as a member that is not live');
is(status_field(0, 'has_quorum'), 'true', 'two of three is still a majority');
is(status_field(1, 'is_leader'), 'true', 'n2 knows it leads');

# --------------------------------------------------------------------------
# Two nodes down: no majority, so no quorum and no members
# --------------------------------------------------------------------------
system_or_bail("$bin/pg_ctl", 'stop', '-m', 'fast', '-w', '-D', $datadirs[1]);

ok(wait_status(0, 'has_quorum', 'false', 30), 'n1 alone is not a majority');
is(members(0), '', 'no members without quorum');
is(status_field(0, 'last_error'), 'NULL', 'a lost majority is not an error');

# --------------------------------------------------------------------------
# Recovery
# --------------------------------------------------------------------------
system_or_bail("$bin/pg_ctl", 'start', '-w', '-D', $datadirs[1], '-l', "$log_dir/pgctl_pgbully_2b.log");
system_or_bail("$bin/pg_ctl", 'start', '-w', '-D', $datadirs[2], '-l', "$log_dir/pgctl_pgbully_3b.log");

ok(wait_status(0, 'has_quorum', 'true', 30), 'quorum returns with the nodes');
ok(wait_members(0, 'n1:true,n2:true,n3:true', 30), 'every member is live again');
ok(wait_status(0, 'leader', 'n3', 30), 'n3 leads again');

# --------------------------------------------------------------------------
# Removing a node from Spock
#
# n3 stays in pgbully.nodes on every node and keeps answering pgBully.
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

is(members(0), 'n1:true,n2:true',
   'a node dropped from spock.node stops counting while pgBully still lists it');
is(status_field(0, 'leader'), 'NULL',
   'a leader Spock no longer knows is not named');
is(status_field(0, 'has_quorum'), 'true', 'quorum itself is pgBully\'s call and is unaffected');

destroy_cluster('Destroy the real pgBully test cluster');
done_testing();
