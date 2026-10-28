use strict;
use warnings;
use Test::More;
use File::Temp qw(tempfile);
use IPC::Run;
use lib '.';
use SpockTest qw(create_cluster cross_wire destroy_cluster psql_or_bail
                 scalar_query get_test_config sync_nodes);

# =============================================================================
# Test: 302_delta_apply.pl - Delta-apply columns converge, or are unavailable
# =============================================================================
# On PostgreSQL with the Spock core patches, two nodes run concurrent
# "bal = bal + 1" updates against a few hot rows of a delta-apply column.
# Delta apply turns each conflicting update into an increment, so no update
# may be lost: every node must end with the full total and identical rows.
# Plain last-update-wins would drop increments here.
#
# On unpatched PostgreSQL, delta apply cannot be configured at all: core
# rejects the delta_apply_function column option.
#
# Whether the server is patched is decided from the postgres binary's
# exported symbols, not by asking spock.
# =============================================================================

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};
my $postgres = "$pg_bin/postgres";
my $nm_cmd = $^O eq 'darwin' ? "nm -gU '$postgres'" : "nm -D --defined-only '$postgres'";
my $symbols = `$nm_cmd 2>/dev/null`;
BAIL_OUT("'$nm_cmd' failed; cannot tell whether the server is patched") if $? != 0;
my $patched = $symbols =~ /\b_?SubTransactionIdSetCommitTsData\b/;

my $alter_opts = "ALTER TABLE delta_t ALTER COLUMN bal " .
                 "SET (log_old_value=true, delta_apply_function=spock.delta_apply)";

if (!$patched)
{
    note('server lacks the Spock core patches; checking delta apply is unavailable');
    create_cluster(1, 'Create 1-node cluster on unpatched PostgreSQL');

    psql_or_bail(1, "CREATE TABLE delta_t (id int PRIMARY KEY, bal bigint NOT NULL)");

    my $port = $config->{node_ports}->[0];
    my $out = `"$pg_bin/psql" -X -p $port -d $config->{db_name} -c "$alter_opts" 2>&1`;
    isnt($?, 0, 'setting a delta-apply column option fails');
    like($out, qr/unrecognized parameter/, 'core rejects the delta-apply column option');

    destroy_cluster();
    done_testing();
    exit 0;
}

my $nrows = 5;
my $clients = 4;
my $txns = 200;
my $expected = 2 * $clients * $txns;

create_cluster(2, 'Create 2-node cluster');
cross_wire(2, ['n1', 'n2'], 'Cross-wire n1 and n2');

# Create the table on each node directly, with DDL replication off, so the
# test does not depend on how the column options replicate.
for my $n (1, 2)
{
    psql_or_bail($n,
        "SET spock.enable_ddl_replication = off; " .
        "CREATE TABLE delta_t (id int PRIMARY KEY, bal bigint NOT NULL); " .
        "$alter_opts; " .
        "SELECT spock.repset_add_table('default', 'delta_t')");
}

psql_or_bail(1, "INSERT INTO delta_t SELECT g, 0 FROM generate_series(1, $nrows) g");
ok(sync_nodes(1, 2, 'n1', 60), 'initial rows reach n2');
is(scalar_query(2, "SELECT count(*) FROM delta_t"), $nrows, "n2 has $nrows rows");

# Concurrent increments on both nodes, on few rows so they conflict.
my ($fh, $script) = tempfile('delta_XXXX', SUFFIX => '.sql', TMPDIR => 1, UNLINK => 1);
print $fh "\\set id random(1, $nrows)\n" .
          "UPDATE delta_t SET bal = bal + 1 WHERE id = :id;\n";
close($fh);

my @runs;
for my $n (1, 2)
{
    my $port = $config->{node_ports}->[$n - 1];
    my ($o, $e) = ('', '');
    push @runs, [$n, \$o, \$e, IPC::Run::start(
        ["$pg_bin/pgbench", '-n', '-f', $script, '-t', $txns,
         '-c', $clients, '-j', $clients, '-h', $config->{host}, '-p', $port,
         '-U', $config->{db_user}, $config->{db_name}],
        '>' => \$o, '2>' => \$e)];
}
for my $r (@runs)
{
    my ($n, $o, $e, $h) = @$r;
    ok($h->finish, "pgbench on n$n completed") or diag($$e);
}

ok(sync_nodes(1, 2, 'n1', 120), 'n1 changes reach n2');
ok(sync_nodes(2, 1, 'n2', 120), 'n2 changes reach n1');

my $rowq = "SELECT string_agg(id || ':' || bal, ',' ORDER BY id) FROM delta_t";
for my $n (1, 2)
{
    is(scalar_query($n, "SELECT sum(bal) FROM delta_t"), $expected,
       "n$n kept every increment (sum = $expected)");
}
is(scalar_query(1, $rowq), scalar_query(2, $rowq), 'n1 and n2 have identical rows');

destroy_cluster();
done_testing();
