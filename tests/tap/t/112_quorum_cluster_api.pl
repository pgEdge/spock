use strict;
use warnings;
use Test::More;
use Time::HiRes qw(time);
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster cross_wire destroy_cluster
    get_test_config scalar_query psql_or_bail
    run_capture find_in_path
);

# =============================================================================
# Test: 112_quorum_cluster_api.pl
#
# The pgraft and pgBully quorum providers, driven against stand-in schemas.
#
# Both providers consult the in-database cluster-manager API through SPI:
# <schema>.get_cluster_status(), is_leader(), and either
# pgraft.get_nodes_from_raft() or pgbully.peers().  The test defines those
# functions itself, backed by ordinary tables, so every answer the real
# extensions could give is reproducible here without a Raft cluster: a
# leader, no leader, a failing call, a call slower than spock.quorum_timeout,
# a reachable or unreachable majority.  The real extensions are exercised in
# 113_quorum_pgbully_real.pl and 114_quorum_pgraft_real.pl.
#
# Positive: quorum, leadership, member identity (pgraft by name, pgBully by
# connection host and port), membership filtered to spock.node, liveness
# and last contact, pgBully's majority rule, pgraft's leader-only activity.
#
# Negative: no leader is a definite false, not NULL; a raising backend and a
# slow backend yield NULL with the cause named; the caller's transaction
# survives both; the deadline really interrupts; a stranger and a dropped
# node do not count.
# =============================================================================

create_cluster(2, 'Create 2-node cluster for cluster-API quorum tests');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

my $cfg   = get_test_config();
my $bin   = $cfg->{pg_bin};
my $host  = $cfg->{host};
my @ports = @{$cfg->{node_ports}};
my $port  = $ports[0];
my $db    = $cfg->{db_name};
my $user  = $cfg->{db_user};

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

# --------------------------------------------------------------------------
# A stand-in for the cluster-manager API, in plain SQL
#
# One set of tables drives both schemas.  The state row holds what
# get_cluster_status() and is_leader() report, plus two fault switches: a
# delay in seconds and whether to raise.  The nodes table holds the members
# as the manager sees them: pgraft publishes them with their names, pgBully
# as connection strings, and both carry a reachability verdict.  Node 3 is a
# stranger: it is not in spock.node and listens on nothing.
# --------------------------------------------------------------------------
sub define_fake_api {
    my ($schema) = @_;

    psql_or_bail(1, <<"SQL");
CREATE SCHEMA $schema;
CREATE TABLE $schema.fake_state (
    node_id   integer, leader_id bigint, is_leader boolean,
    delay     float8 DEFAULT 0, fail boolean DEFAULT false);
INSERT INTO $schema.fake_state VALUES (1, 1, true);
CREATE TABLE $schema.fake_nodes (
    node_id integer PRIMARY KEY, name text, host text, port integer,
    reachable boolean, last_seen timestamptz);
INSERT INTO $schema.fake_nodes VALUES
    (1, 'n1',    '$host', $ports[0], true, now()),
    (2, 'n2',    '$host', $ports[1], true, now()),
    (3, 'ghost', '$host', 1,         true, now());

CREATE FUNCTION $schema.get_cluster_status()
RETURNS TABLE(node_id integer, current_term bigint, leader_id bigint, state text,
              num_nodes integer, messages_processed bigint, heartbeats_sent bigint,
              elections_triggered bigint)
LANGUAGE plpgsql AS \$\$
DECLARE s $schema.fake_state;
BEGIN
    SELECT * INTO s FROM $schema.fake_state;
    IF s.delay > 0 THEN PERFORM pg_sleep(s.delay); END IF;
    IF s.fail THEN RAISE EXCEPTION 'injected $schema failure'; END IF;
    RETURN QUERY SELECT s.node_id, 7::bigint, s.leader_id,
                        CASE WHEN s.is_leader THEN 'leader' ELSE 'follower' END,
                        (SELECT count(*)::integer FROM $schema.fake_nodes),
                        0::bigint, 0::bigint, 0::bigint;
END
\$\$;
CREATE FUNCTION $schema.is_leader() RETURNS boolean
LANGUAGE sql AS \$\$ SELECT is_leader FROM $schema.fake_state \$\$;
CREATE FUNCTION $schema.get_nodes_from_raft() RETURNS text
LANGUAGE sql AS \$\$
    SELECT coalesce(jsonb_agg(jsonb_build_object(
               'id', node_id, 'name', name,
               'address', host || ':' || port,
               'active', coalesce(reachable, true)) ORDER BY node_id), '[]')::text
      FROM $schema.fake_nodes \$\$;
CREATE FUNCTION $schema.peers(
    OUT node_id integer, OUT conninfo text, OUT is_self boolean,
    OUT is_leader boolean, OUT reachable boolean, OUT last_seen timestamptz)
RETURNS SETOF record
LANGUAGE sql AS \$\$
    SELECT n.node_id, 'host=' || n.host || ' port=' || n.port || ' dbname=postgres',
           n.node_id = s.node_id, n.node_id = s.leader_id, n.reachable, n.last_seen
      FROM $schema.fake_nodes n, $schema.fake_state s \$\$;
SQL
}

sub fake_set {
    my ($schema, $assignments) = @_;
    psql_or_bail(1, "UPDATE $schema.fake_state SET $assignments");
}

sub fake_node {
    my ($schema, $id, $assignments) = @_;
    psql_or_bail(1, "UPDATE $schema.fake_nodes SET $assignments WHERE node_id = $id");
}

# --------------------------------------------------------------------------
# pgraft
# --------------------------------------------------------------------------
define_fake_api('pgraft');
set_guc_reload('spock.quorum_provider', 'pgraft');

is(status_field('provider'), 'pgraft', 'the pgraft provider is selected');
is(status_field('last_error'), 'NULL', 'the stand-in API is accepted as pgraft');
is(status_field('has_quorum'), 'true', 'a leader id is quorum for pgraft');
is(status_field('is_leader'), 'true', 'this node leads when is_leader() says so');
is(status_field('leader'), 'n1', 'the leader is named through the member list');
is(members(), 'n1:true,n2:true',
   'members named like spock.node rows count; the stranger does not');
is(scalar_query(1, "SELECT count(*) FROM spock.quorum_members() WHERE last_seen IS NULL"),
   '2', 'pgraft tracks no last contact, so last_seen is NULL');
is(scalar_query(1, "SELECT bool_and(voting) FROM spock.quorum_members()"),
   't', 'every member votes');

# Raft tracks follower activity on the leader only.  There the flag is the
# member's liveness; on a follower every member reads as live.
fake_node('pgraft', 2, 'reachable = false');
is(members(), 'n1:true,n2:false', 'the leader reports an inactive follower as not live');
fake_set('pgraft', 'leader_id = 2, is_leader = false');
is(status_field('has_quorum'), 'true', 'quorum with a peer leading');
is(status_field('is_leader'), 'false', 'this node does not lead');
is(status_field('leader'), 'n2', 'the peer is named as leader');
fake_set('pgraft', 'leader_id = 3');
is(status_field('leader'), 'NULL', 'a leader Spock does not know is not named');
fake_set('pgraft', 'leader_id = 2');
is(members(), 'n1:true,n2:true', 'a follower has no activity signal and reports every member live');
fake_node('pgraft', 2, 'reachable = true');

# A definite no.  pgraft reports 0 for "nobody leads"; pgBully reports NULL,
# which the provider coalesces, so both read as false rather than unknown.
fake_set('pgraft', 'leader_id = 0');
is(status_field('has_quorum'), 'false', 'no leader is a definite false, not NULL');
is(status_field('is_leader'), 'NULL', 'leadership is not reported outside a quorum');
is(status_field('leader'), 'NULL', 'nor a leader name');
is(members(), '', 'nor members');
is(status_field('last_error'), 'NULL', 'and it is not an error');
fake_set('pgraft', 'leader_id = 1, is_leader = true');

# A member list that is not a list.
psql_or_bail(1, "CREATE OR REPLACE FUNCTION pgraft.get_nodes_from_raft() RETURNS text " .
                "LANGUAGE sql AS \$\$ SELECT '{\"error\": \"raft not ready\"}' \$\$");
is(status_field('has_quorum'), 'true', 'quorum does not depend on the member list');
is(members(), '', 'an error object instead of a member list yields no members');
psql_or_bail(1, "CREATE OR REPLACE FUNCTION pgraft.get_nodes_from_raft() RETURNS text " .
                "LANGUAGE sql AS \$\$ SELECT 'not json at all' \$\$");
is(status_field('has_quorum'), 'NULL', 'a member list that is not JSON yields no reading');
like(status_field('last_error'), qr/json/i, 'last_error carries the parse error');
psql_or_bail(1, "DROP FUNCTION pgraft.get_nodes_from_raft()");
is(status_field('has_quorum'), 'NULL', 'a member function that vanished yields no reading');
like(status_field('last_error'), qr/pgraft/,
     'the next startup finds the API incomplete and names the backend');
psql_or_bail(1, "CREATE FUNCTION pgraft.get_nodes_from_raft() RETURNS text LANGUAGE sql AS \$\$ " .
                "SELECT coalesce(jsonb_agg(jsonb_build_object('id', node_id, 'name', name, " .
                "'address', host || ':' || port, 'active', coalesce(reachable, true)) " .
                "ORDER BY node_id), '[]')::text FROM pgraft.fake_nodes \$\$");
is(status_field('has_quorum'), 'true', 'service resumes once the function is back');

# A raising backend.
fake_set('pgraft', 'fail = true');
is(status_field('has_quorum'), 'NULL', 'a raising backend yields no answer');
like(status_field('last_error'), qr/injected pgraft failure/,
     'last_error carries the backend\'s own message');
my ($txn, $txn_rc) = psql_try(
    "BEGIN; SELECT has_quorum FROM spock.quorum_status(); SELECT 42 AS after; COMMIT");
is($txn_rc, 0, 'a raising backend does not poison the transaction');
like($txn, qr/\b42\b/, 'statements after the failed consult still run');
fake_set('pgraft', 'fail = false');
is(status_field('has_quorum'), 'true', 'service resumes once the backend recovers');
is(status_field('last_error'), 'NULL', 'the error is cleared by a good reading');

# A slow backend.  The deadline is armed around the query and interrupts
# it, so the caller waits for the timeout, not for the backend.
set_guc_reload('spock.quorum_timeout', '500ms');
fake_set('pgraft', 'delay = 5');
my $t0 = time();
my $slow = status_field('has_quorum');
my $elapsed = time() - $t0;
is($slow, 'NULL', 'a backend slower than the timeout yields no answer');
ok($elapsed < 4, sprintf('the caller waited %.1fs, not the full delay', $elapsed));
like(status_field('last_error'), qr/did not answer within 500 ms/,
     'last_error names the deadline');
my ($after, $after_rc) = psql_try(
    "BEGIN; SELECT has_quorum FROM spock.quorum_status(); SELECT 43 AS after; COMMIT");
is($after_rc, 0, 'the interrupted consult does not poison the transaction');
like($after, qr/\b43\b/, 'and the cancel it raised does not leak to the next statement');
fake_set('pgraft', 'delay = 0');
reset_guc_reload('spock.quorum_timeout');
is(status_field('has_quorum'), 'true', 'service resumes once the backend is fast again');

# --------------------------------------------------------------------------
# pgBully: members are connection strings, matched to spock.node_interface
# --------------------------------------------------------------------------
define_fake_api('pgbully');
set_guc_reload('spock.quorum_provider', 'pgbully');

is(status_field('provider'), 'pgbully', 'the pgbully provider is selected');
is(status_field('last_error'), 'NULL', 'the stand-in API is accepted as pgbully');
is(status_field('has_quorum'), 'true', 'a leader id with a reachable majority is quorum');
is(status_field('is_leader'), 'true', 'this node leads');
is(status_field('leader'), 'n1', 'the leader is named through its connection string');
is(members(), 'n1:true,n2:true',
   'peers whose host and port match a node interface count; the stranger does not');
is(scalar_query(1, "SELECT count(*) FROM spock.quorum_members() WHERE last_seen IS NOT NULL"),
   '2', 'pgBully\'s last contact time is carried into last_seen');

# The match is by what libpq makes of the string, not by its spelling.
psql_or_bail(1, "CREATE OR REPLACE FUNCTION pgbully.peers(" .
    "OUT node_id integer, OUT conninfo text, OUT is_self boolean, OUT is_leader boolean, " .
    "OUT reachable boolean, OUT last_seen timestamptz) RETURNS SETOF record LANGUAGE sql AS \$\$ " .
    "SELECT n.node_id, 'postgresql://someone\@' || n.host || ':' || n.port || '/postgres?connect_timeout=3', " .
    "n.node_id = s.node_id, n.node_id = s.leader_id, n.reachable, n.last_seen " .
    "FROM pgbully.fake_nodes n, pgbully.fake_state s \$\$");
is(members(), 'n1:true,n2:true', 'a URI connection string matches the same nodes');

fake_set('pgbully', 'leader_id = 2, is_leader = false');
is(status_field('leader'), 'n2', 'a peer leader is named through its connection string');
is(status_field('is_leader'), 'false', 'this node does not lead');
fake_set('pgbully', 'leader_id = 1, is_leader = true');

# One peer unreachable: still a majority (2 of 3), and the peer is reported
# as not live, which is what a consumer would act on.
fake_node('pgbully', 2, 'reachable = false');
is(status_field('has_quorum'), 'true', 'two of three reachable is still a majority');
is(members(), 'n1:true,n2:false', 'an unreachable peer is a member that is not live');

# Two peers unreachable: a leader id alone is not enough for pgBully, because
# it can say whether a majority is reachable, and it is not.
fake_node('pgbully', 3, 'reachable = false');
is(status_field('has_quorum'), 'false',
   'a leader id without a reachable majority is not quorum for pgBully');
is(members(), '', 'no members without quorum');
is(status_field('last_error'), 'NULL', 'a lost majority is not an error');
fake_node('pgbully', 2, 'reachable = true');
fake_node('pgbully', 3, 'reachable = true');
is(status_field('has_quorum'), 'true', 'quorum returns with the peers');

# No opinion is not evidence of failure: a peer pgBully has not judged yet
# must not read as dead.
fake_node('pgbully', 2, 'reachable = NULL');
is(members(), 'n1:true,n2:true', 'a peer with no reachability verdict is treated as live');
fake_node('pgbully', 2, 'reachable = true');

# pgBully says "nobody" with NULL rather than 0.
fake_set('pgbully', 'leader_id = NULL, is_leader = false');
is(status_field('has_quorum'), 'false', 'a NULL leader id is a definite false');
fake_set('pgbully', 'leader_id = 1, is_leader = true');

# --------------------------------------------------------------------------
# Removing a node
#
# n2 stays in the cluster manager's view.  Dropping it from Spock must stop
# it counting, under either identity scheme.
# --------------------------------------------------------------------------
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");
psql_or_bail(2, "SELECT spock.sub_drop('sub_n2_n1')");
# Dropping the last subscription from a node drops the node record with it;
# node_drop() is the explicit form and is a no-op here.
psql_or_bail(1, "SELECT spock.node_drop('n2', true)");
is(scalar_query(1, "SELECT count(*) FROM spock.node WHERE node_name = 'n2'"),
   '0', 'n2 is gone from spock.node');
is(members(), 'n1:true',
   'a node dropped from spock.node stops counting while pgBully still lists its connection');
set_guc_reload('spock.quorum_provider', 'pgraft');
is(members(), 'n1:true',
   'a node dropped from spock.node stops counting while pgraft still lists its name');
set_guc_reload('spock.quorum_provider', 'pgbully');

# --------------------------------------------------------------------------
# The extension going away underneath a running provider
# --------------------------------------------------------------------------
psql_or_bail(1, "DROP SCHEMA pgbully CASCADE");
is(status_field('has_quorum'), 'NULL', 'a backend that vanished yields no answer');
like(status_field('last_error'), qr/pgbully/, 'last_error names the backend');

reset_guc_reload('spock.quorum_provider');
is(status_field('provider'), 'none', 'back to none, nothing is consulted');

destroy_cluster('Destroy cluster-API quorum test cluster');
done_testing();
