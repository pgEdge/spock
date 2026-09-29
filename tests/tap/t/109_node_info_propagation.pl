#!/usr/bin/perl
# Test direct node-metadata propagation, node_alter validation, identity
# mismatches, and SQL NULL handling. Forwarding and mixed-version gating are
# outside this test's scope.

use strict;
use warnings;
use Test::More;
use Cwd qw(getcwd);
use lib '.';
use SpockTest qw(create_cluster destroy_cluster get_test_config scalar_query
                 psql_or_bail wait_for_sub_status poll_query_until
                 log_offset wait_for_log);

# Ensure fresh-install and upgrade scripts declare the new objects.
{
    my $cwd = getcwd();
    my $spock_repo = ($cwd =~ m{^(/.+)/tests/tap(?:/t)?$}) ? $1 : $cwd;

    my $fresh_sql = do {
        local $/;
        open(my $fh, '<', "$spock_repo/sql/spock--6.0.0.sql")
            or die "cannot open $spock_repo/sql/spock--6.0.0.sql: $!";
        <$fh>;
    };
    my $upgrade_sql = do {
        local $/;
        open(my $fh, '<', "$spock_repo/sql/spock--5.0.12--6.0.0.sql")
            or die "cannot open $spock_repo/sql/spock--5.0.12--6.0.0.sql: $!";
        <$fh>;
    };

    for my $sig (
        'CREATE FUNCTION spock\.node_info_emit\(',
        'CREATE FUNCTION spock\.node_info_apply\(',
        'CREATE FUNCTION spock\.node_info_broadcast\(\) RETURNS trigger',
        'CREATE TRIGGER node_info_broadcast_trigger',
        'CREATE FUNCTION spock\.node_alter\(',
    ) {
        my ($fresh_matches) = ($fresh_sql =~ /($sig)/s);
        my ($upgrade_matches) = ($upgrade_sql =~ /($sig)/s);
        ok(defined $fresh_matches, "fresh-install script declares: $sig");
        ok(defined $upgrade_matches, "upgrade script declares: $sig");
    }
}

# Two-node direct subscription; forwarding is intentionally out of scope.
create_cluster(2, 'Create 2-node cluster');

my $config     = get_test_config();
my $node_ports = $config->{node_ports};
my $dbname     = $config->{db_name};
my $host       = $config->{host};

my $conn_n1 = "host=$host port=$node_ports->[0] dbname=$dbname";

psql_or_bail(2, "SELECT spock.sub_create('sub_n1_n2', '$conn_n1', ARRAY['default'], false, false)");
ok(wait_for_sub_status(2, 'sub_n1_n2', 'replicating', 60), 'n2 subscribed to n1');

my $n1_id = scalar_query(1, "SELECT node_id FROM spock.node_info()");

# Run SQL without shell re-parsing and return its status and output.
sub psql_capture_err {
    my ($node_num, $sql) = @_;
    my $port = $node_ports->[$node_num - 1];

    my $pid = open(my $fh, '-|');
    defined $pid or die "fork failed: $!";
    if ($pid == 0) {
        open(STDERR, '>&STDOUT') or die "cannot dup STDOUT to STDERR: $!";
        exec($config->{pg_bin} . '/psql', '-X', '-p', $port, '-d', $dbname,
             '-t', '-c', $sql) or exit(127);
    }
    local $/;
    my $out = <$fh> // '';
    close($fh);
    my $rc = $? >> 8;
    return ($rc, $out);
}

# Scalar query variant safe for JSON literals containing double quotes.
sub scalar_query_safe {
    my ($node_num, $sql) = @_;
    my (undef, $out) = psql_capture_err($node_num, $sql);
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

# A raw local-node UPDATE propagates without a manual refresh.
psql_or_bail(1,
    "UPDATE spock.node SET location = 'loc-n1', country = 'US', " .
    "info = '{\"tiebreaker\": 555}'::jsonb " .
    "WHERE node_id = (SELECT node_id FROM spock.node_info())");

ok(poll_query_until(2, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_name = 'n1'",
                    '555', 30),
   'n2 converged on n1\'s new tiebreaker via automatic propagation');
is(scalar_query(2, "SELECT location FROM spock.node WHERE node_name = 'n1'"), 'loc-n1',
   'n2 also picked up location in the same message');

# Incoming metadata never changes the subscriber's own row.
is(scalar_query(2,
    "SELECT node_name FROM spock.node WHERE node_id = (SELECT node_id FROM spock.local_node)"),
   'n2',
   'n2\'s own row is untouched -- still describes n2, not clobbered by n1\'s propagated row');

# node_alter() uses the same propagation path.
psql_or_bail(1, "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": 777}'::jsonb)");

ok(poll_query_until(2, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_name = 'n1'",
                    '777', 30),
   'node_alter() on n1 propagates to n2 exactly like a raw UPDATE');

# node_alter() merges info and updates scalar fields independently.
psql_or_bail(1, "SELECT spock.node_alter(p_info_patch => '{\"region\": \"us-east\"}'::jsonb)");
is(scalar_query(1, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_id = $n1_id"),
   '777', 'merging an unrelated info key preserves the existing tiebreaker');
is(scalar_query(1, "SELECT info->>'region' FROM spock.node WHERE node_id = $n1_id"),
   'us-east', 'the new info key was actually merged in');

psql_or_bail(1, "SELECT spock.node_alter(p_location => 'loc-n1-v2')");
is(scalar_query(1, "SELECT location FROM spock.node WHERE node_id = $n1_id"),
   'loc-n1-v2', 'node_alter() updated location...');
is(scalar_query(1, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_id = $n1_id"),
   '777', '...without touching info, which was omitted from that call');

# Reject invalid tiebreakers without changing the row.
my ($str_rc, $str_out) = psql_capture_err(1,
    "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": \"42\"}'::jsonb)");
isnt($str_rc, 0, 'node_alter() rejects a JSON string tiebreaker, not just a non-numeric one');
like($str_out, qr/must be a JSON number/, 'the error explains a JSON number is required');

my ($null_rc, $null_out) = psql_capture_err(1,
    "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": null}'::jsonb)");
isnt($null_rc, 0, 'node_alter() rejects a JSON null tiebreaker rather than silently accepting it');
like($null_out, qr/must be a JSON number/, 'the error names the null-is-not-a-number problem');

my ($bad_rc, $bad_out) = psql_capture_err(1,
    "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": \"abc\"}'::jsonb)");
isnt($bad_rc, 0, 'node_alter() rejects a non-numeric tiebreaker');

my ($range_rc, $range_out) = psql_capture_err(1,
    "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": 99999999999}'::jsonb)");
isnt($range_rc, 0, 'node_alter() rejects an out-of-32-bit-range tiebreaker');
like($range_out, qr/must fit a 32-bit integer/, 'the error names the range problem');

is(scalar_query(1, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_id = $n1_id"),
   '777', 'the row is unchanged after all four rejected calls');

# Whole numbers written in a non-canonical form are stored as plain integers,
# which is the only form node_fromtuple() can parse.
psql_or_bail(1, "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": 5.0}'::jsonb)");
is(scalar_query(1, "SELECT info->'tiebreaker' FROM spock.node WHERE node_id = $n1_id"),
   '5', 'node_alter() stores tiebreaker 5.0 as the integer 5');
psql_or_bail(1, "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": 1e2}'::jsonb)");
is(scalar_query(1, "SELECT info->'tiebreaker' FROM spock.node WHERE node_id = $n1_id"),
   '100', 'node_alter() stores tiebreaker 1e2 as the integer 100');
ok(poll_query_until(2, "SELECT info->'tiebreaker' FROM spock.node WHERE node_name = 'n1'",
                    '100', 60),
   'n2 receives the normalized integer');

psql_or_bail(1, "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": 777}'::jsonb)");
ok(poll_query_until(2, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_name = 'n1'",
                    '777', 60),
   'n2 converges back to tiebreaker 777');

# Quarantine the same node_id under a different name.
psql_or_bail(2, "UPDATE spock.node SET node_name = 'impostor' WHERE node_id = $n1_id");

my $n2_log_offset = log_offset(2);
psql_or_bail(1, "SELECT spock.node_alter(p_info_patch => '{\"tiebreaker\": 888}'::jsonb)");

ok(wait_for_log(2, qr/identity conflict applying node-info update for node $n1_id/,
                $n2_log_offset, 90),
   'n2 logs the identity mismatch (same id, different name) instead of silently applying it');
ok(wait_for_log(2, qr/Node $n1_id is known locally as \"impostor\"/, $n2_log_offset, 90),
   'the log names the name the node id is known under locally');
is(scalar_query(2, "SELECT node_name FROM spock.node WHERE node_id = $n1_id"), 'impostor',
   'the mismatched row\'s name is untouched');
is(scalar_query(2, "SELECT info->>'tiebreaker' FROM spock.node WHERE node_id = $n1_id"),
   '777', 'the mismatched row\'s info was never overwritten with the incoming update');

# Restore n2's cached row for n1.
psql_or_bail(2, "UPDATE spock.node SET node_name = 'n1' WHERE node_id = $n1_id");

# node_info_apply() updates an existing row by name and never creates one.
psql_or_bail(2, "INSERT INTO spock.node (node_id, node_name) VALUES (888888, 'ghost')");

is(scalar_query_safe(2,
    "SELECT spock.node_info_apply('ghost'::name, 'loc', 'CA', '{\"tiebreaker\": 3}'::jsonb)"),
   't', 'node_info_apply() reports that it updated an existing row');
is(scalar_query(2, "SELECT location FROM spock.node WHERE node_name = 'ghost'"),
   'loc', 'the existing row carries the snapshot passed to it');

is(scalar_query_safe(2,
    "SELECT spock.node_info_apply('newcomer'::name, 'loc', 'CA', NULL)"),
   'f', 'node_info_apply() reports false for a name with no row');
is(scalar_query(2, "SELECT count(*) FROM spock.node WHERE node_name = 'newcomer'"),
   '0', 'no row is created for an unknown name');

psql_or_bail(2, "DELETE FROM spock.node WHERE node_id = 888888");

# Preserve SQL NULL rather than converting it to JSONB null.
psql_or_bail(1, "UPDATE spock.node SET info = NULL " .
                "WHERE node_id = (SELECT node_id FROM spock.node_info())");

ok(poll_query_until(2, "SELECT (info IS NULL)::text FROM spock.node WHERE node_id = $n1_id",
                    'true', 30),
   'n2\'s cached info becomes a true SQL NULL, not \'null\'::jsonb, when n1 sets info to NULL');

destroy_cluster('Destroy 2-node cluster');

done_testing();
