use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use File::Basename qw(dirname);
use Cwd qw(getcwd);
use IPC::Run;

use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster system_or_bail system_maybe
    get_test_config cross_wire psql_or_bail scalar_query
);

# =============================================================================
# Test: mixed-version add_node.  Two Spock 5.0.11 nodes (n1, n2, built from
# v5_STABLE) plus a Spock 6.0.0 node (n3, current branch) added with zodan
# add_node() running on n3.
#
# Each Spock build lives in its own PostgreSQL install tree under
# /tmp/spock_rolling_upgrade_test/pg<major>_<name>: a copy of the install
# whose binaries are in PATH, with that Spock version built from a clone of
# this repository and installed into it (as 014_rolling_upgrade.pl does).
# PostgreSQL finds lib/ and share/ relative to its own binary, so a node
# started from such a tree has its own spock.so and extension scripts, exactly
# like separate installs on separate hosts.  Nothing outside those trees is
# modified, and no per-node path settings are needed.  Works on any
# PostgreSQL version the two Spock builds support.  Trees are kept between
# runs; remove /tmp/spock_rolling_upgrade_test to force a rebuild.
#
# Env knobs:
#   ZODAN_N12_VER  name of the build n1/n2 run: v5 (default, built from
#                  origin/v5_STABLE), v6 (HEAD, gives the all-6.0.0 control
#                  run), or any other name together with ZODAN_N12_REF
#   ZODAN_N12_REF  git ref to build for ZODAN_N12_VER (e.g. v5.0.9); defaults
#                  exist for v5 and v6 only
#   ZODAN_LOAD     1 = run pgbench load on n1/n2 while adding n3 (default 0)
#   ZODAN_SQL      path to the zodan.sql to use (default: ../../samples/Z0DAN/zodan.sql)
#   ZODAN_SCRATCH  where add_node output and state dumps go (default: TESTLOGDIR or logs)
# =============================================================================
my $TEMP_BASE = "/tmp/spock_rolling_upgrade_test";
my $PG_CONFIG = `which pg_config`; chomp $PG_CONFIG;
my ($PG_MAJOR) = (`$PG_CONFIG --version` =~ /(\d+)/);

# Install tree holding a given Spock build for this PostgreSQL major version.
sub install_dir { my ($name) = @_; return "$TEMP_BASE/pg${PG_MAJOR}_${name}"; }

# Spock version a tree will report, from its extension control file.
sub install_version {
    my ($name) = @_;
    my $sharedir = `${\ install_dir($name)}/bin/pg_config --sharedir`; chomp $sharedir;
    my $ctl = "$sharedir/extension/spock.control";
    open(my $fh, '<', $ctl) or die "cannot read $ctl: $!";
    my ($v) = map { /default_version\s*=\s*'([^']+)'/ ? $1 : () } <$fh>;
    close $fh;
    return $v;
}
my $SCRATCH    = $ENV{ZODAN_SCRATCH} // $ENV{TESTLOGDIR} // 'logs';
make_path($SCRATCH) unless -d $SCRATCH;
my $ZODAN_SQL  = $ENV{ZODAN_SQL} // '../../samples/Z0DAN/zodan.sql';
my $LOAD       = $ENV{ZODAN_LOAD} // 0;
my $N12_VER    = $ENV{ZODAN_N12_VER} // 'v5';

my %BUILD_REF = (v5 => 'origin/v5_STABLE', v6 => 'HEAD');
my $N12_REF = $ENV{ZODAN_N12_REF} // $BUILD_REF{$N12_VER}
    // die "no default git ref for build '$N12_VER'; set ZODAN_N12_REF";

# Repository to build from: the CI checkout if present, else derive from cwd
# (tests run from tests/tap).  Same rule as 014_rolling_upgrade.pl.
my $SPOCK_REPO;
if (-d "/home/pgedge/spock" && -f "/home/pgedge/spock/Makefile") {
    $SPOCK_REPO = "/home/pgedge/spock";
} else {
    my $cwd = getcwd();
    $SPOCK_REPO = ($cwd =~ m{^(/.+)/tests/tap(?:/t)?$}) ? $1 : $cwd;
}
die "SPOCK_REPO not found or missing Makefile: $SPOCK_REPO"
    unless -d $SPOCK_REPO && -f "$SPOCK_REPO/Makefile";

# Build Spock at $git_ref into its own copy of the PostgreSQL install.
# The commit that was built is recorded in the tree; an existing tree is
# reused only when it holds the commit $git_ref resolves to now.
sub build_spock_tree {
    my ($git_ref, $name) = @_;
    my $tree = install_dir($name);
    my $pg_bin = "$tree/bin";
    my $stamp = "$tree/.spock_commit";

    my $commit = `git -C $SPOCK_REPO rev-parse --verify --quiet $git_ref`;
    chomp $commit;
    die "cannot resolve git ref '$git_ref' in $SPOCK_REPO" unless $commit;

    if (-f $stamp) {
        open(my $fh, '<', $stamp) or die "cannot read $stamp: $!";
        my $built = <$fh>; close $fh; chomp $built;
        if ($built eq $commit) {
            diag("Spock $name already built from $git_ref ($commit) in $tree, skipping");
            return 1;
        }
        diag("Tree $tree holds $built, but $git_ref is now $commit; rebuilding");
    }

    if ($git_ref eq 'HEAD') {
        my $dirty = `git -C $SPOCK_REPO status --porcelain -- src sql include`;
        diag("NOTE: uncommitted changes under src/, sql/ or include/ are not part of this build (it clones HEAD):\n$dirty")
            if $dirty;
    }

    my $pghome    = dirname(dirname($PG_CONFIG));
    my $build_dir = "$TEMP_BASE/build_pg${PG_MAJOR}_${name}";
    diag("Building Spock $name from $git_ref into $tree (PostgreSQL install copied from $pghome)");
    remove_tree($tree);
    remove_tree($build_dir);
    make_path($TEMP_BASE);

    # A full copy: PostgreSQL resolves lib/ and share/ relative to bin/, so
    # the copy is an independent install.  Drop the system Spock from it so
    # the tree holds only the version built here.
    system_or_bail('cp', '-a', $pghome, $tree);
    my $libdir   = `$pg_bin/pg_config --pkglibdir`; chomp $libdir;
    my $sharedir = `$pg_bin/pg_config --sharedir`;  chomp $sharedir;
    unlink glob("$libdir/spock*.so"), glob("$sharedir/extension/spock*");

    system_or_bail("git clone --quiet $SPOCK_REPO $build_dir");
    system_or_bail("cd $build_dir && git checkout --quiet $git_ref") if $git_ref ne 'HEAD';
    system_or_bail("cd $build_dir && make PG_CONFIG=$pg_bin/pg_config");
    system_or_bail("cd $build_dir && make install PG_CONFIG=$pg_bin/pg_config");

    open(my $fh, '>', $stamp) or die "cannot write $stamp: $!";
    print $fh "$commit\n";
    close $fh;
    return 1;
}

ok(build_spock_tree($N12_REF, $N12_VER), "Built Spock $N12_VER ($N12_REF) into " . install_dir($N12_VER));
ok(build_spock_tree('HEAD', 'v6'), "Built Spock v6 (HEAD) into " . install_dir('v6'));

sub stop_node {
    my ($n) = @_;
    my $c = get_test_config();
    system("$c->{pg_bin}/pg_ctl stop -D $c->{node_datadirs}->[$n-1] -m fast -w >/dev/null 2>&1");
    sleep(1);
}
# Start node $n from the install tree holding Spock build $name.
sub start_node {
    my ($n, $name) = @_;
    my $c = get_test_config();
    my $bin = install_dir($name) . "/bin";
    system("$bin/pg_ctl start -D $c->{node_datadirs}->[$n-1] -l $c->{log_file} -w >/dev/null 2>&1");
    sleep(2);
}

# Poll a scalar query on a node until it equals $want or timeout (seconds).
sub wait_until {
    my ($node, $sql, $want, $timeout, $label) = @_;
    $timeout //= 120;
    my $got;
    for (1 .. $timeout) {
        $got = scalar_query($node, $sql);
        last if defined $got && $got eq $want;
        sleep 1;
    }
    is($got, $want, $label);
}

# Dump replication state of all nodes plus node log tails into $file.
sub dump_state {
    my ($file) = @_;
    my $c = get_test_config();
    open(my $fh, '>', $file) or die $!;
    for my $n (1..3) {
        my $port = $c->{node_ports}->[$n-1];
        print $fh "\n===== node n$n (port $port) =====\n";
        for my $q (
            "SELECT spock.spock_version()",
            "SELECT subscription_name, status, provider_node, slot_name FROM spock.sub_show_status()",
            "SELECT sub_name, sub_enabled, sub_slot_name, sub_sync_structure, sub_sync_data FROM spock.subscription",
            "SELECT * FROM spock.local_sync_status",
            "SELECT external_id, remote_lsn, local_lsn FROM pg_replication_origin_status",
            "SELECT slot_name, active, confirmed_flush_lsn, restart_lsn FROM pg_replication_slots",
            "SELECT application_name, state, sent_lsn, write_lsn, flush_lsn, replay_lsn FROM pg_stat_replication",
            "SELECT pid, backend_type, state, wait_event_type, wait_event, left(query,120) FROM pg_stat_activity WHERE backend_type LIKE '%spock%' OR application_name LIKE '%spock%' OR query LIKE '%spock%'",
            "SELECT * FROM spock.lag_tracker",
        ) {
            print $fh "-- $q\n";
            print $fh `$c->{pg_bin}/psql -X -p $port -d $c->{db_name} -c "$q" 2>&1`;
        }
        my $log = "$ENV{TESTLOGDIR}/00$port.log";
        print $fh "-- tail of $log (non-DEBUG)\n";
        print $fh `grep -v DEBUG '$log' 2>/dev/null | grep -v 'log_statement\|duration:\|STATEMENT:' | tail -120`;
    }
    close $fh;
    diag("state dump written to $file");
}

# ---------------------------------------------------------------------------
create_cluster(3, 'Create 3-node cluster (temporary, will be re-versioned)');
my $config = get_test_config();
my ($host, $dbname, $db_user, $ports) = ($config->{host}, $config->{db_name}, $config->{db_user}, $config->{node_ports});

my $ver12 = install_version($N12_VER);
my $ver3  = install_version('v6');
diag("Re-versioning: n1,n2 -> Spock $ver12 ($N12_VER tree), n3 -> Spock $ver3 (v6 tree)");
psql_or_bail($_, "DROP EXTENSION IF EXISTS spock CASCADE") for 1..3;
stop_node($_) for 1..3;
start_node(1, $N12_VER);
start_node(2, $N12_VER);
start_node(3, 'v6');
psql_or_bail($_, "CREATE EXTENSION spock") for 1..3;
psql_or_bail(1, "SELECT spock.node_create('n1', 'host=$host dbname=$dbname port=$ports->[0] user=$db_user')");
psql_or_bail(2, "SELECT spock.node_create('n2', 'host=$host dbname=$dbname port=$ports->[1] user=$db_user')");

my @v = map { scalar_query($_, "SELECT spock.spock_version()") } 1..3;
diag("Versions: n1=$v[0] n2=$v[1] n3=$v[2]");
is($v[0], $ver12, "n1 runs Spock $ver12 ($N12_VER build)");
is($v[1], $ver12, "n2 runs Spock $ver12 ($N12_VER build)");
is($v[2], $ver3, "n3 runs Spock $ver3 (v6 build)");

cross_wire(2, ['n1', 'n2'], "Cross-wire n1 <-> n2 (both $N12_VER)");

# zodan lives on the new node only.
psql_or_bail(3, "CREATE EXTENSION dblink");
psql_or_bail(3, "\\i $ZODAN_SQL");
psql_or_bail(3, "\\i ../../samples/Z0DAN/wait_subscription.sql");

# Seed data on n1, wait for n2.
system_or_bail("$config->{pg_bin}/pgbench", '-i', '-s', 1, '-h', $host, '-p', $ports->[0], '-U', $db_user, $dbname);
psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
wait_until(2, "SELECT count(*) FROM pgbench_accounts", '100000', 180, "pgbench data replicated n1 -> n2");

my (@pgb, @pgb_out, @pgb_err);
if ($LOAD) {
    diag("Starting non-intersecting pgbench load on n1 and n2");
    psql_or_bail(3, "ALTER SYSTEM SET spock.exception_behaviour = 'transdiscard'");
    psql_or_bail(3, "SELECT pg_reload_conf()");
    for my $i (0, 1) {
        my $f = '../../samples/Z0DAN/n' . ($i+1) . '.pgb';
        $pgb_out[$i] = ''; $pgb_err[$i] = '';
        $pgb[$i] = IPC::Run::start(
            [ "$config->{pg_bin}/pgbench", '-n', '-f', $f, '-T', 600, '-j', 2, '-c', 2,
              '-h', $host, '-p', $ports->[$i], '-U', $db_user, $dbname ],
            '>', \$pgb_out[$i], '2>', \$pgb_err[$i]);
    }
    sleep(20);
    psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
    psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
}

# ---------------------------------------------------------------------------
diag("Calling spock.add_node() on n3 (6.0.0) with source n1 (5.0.11)");
my $out_file = "$SCRATCH/add_node_" . $N12_VER . '_' . ($LOAD ? 'load' : 'noload') . ".out";
my $add_sql = "CALL spock.add_node(src_node_name := 'n1',
    src_dsn := 'host=$host dbname=$dbname port=$ports->[0] user=$db_user',
    new_node_name := 'n3',
    new_node_dsn := 'host=$host dbname=$dbname port=$ports->[2] user=$db_user',
    verb := true);";
my $t0 = time();
my $rc = system("timeout 1200 $config->{pg_bin}/psql -X -p $ports->[2] -d $dbname -v ON_ERROR_STOP=1 -c \"$add_sql\" > '$out_file' 2>&1");
my $elapsed = time() - $t0;
diag("add_node exit code " . ($rc >> 8) . " after ${elapsed}s; output in $out_file");
is($rc, 0, "add_node completed without error");
if ($rc != 0) {
    open(my $fh, '<', $out_file); my @tail = <$fh>; close $fh;
    diag("--- add_node output tail ---"); diag($_) for @tail[-25..-1];
}

dump_state("$SCRATCH/state_" . $N12_VER . '_' . ($LOAD ? 'load' : 'noload') . ".txt");
if ($LOAD) {
    for my $i (0, 1) { $pgb[$i]->kill_kill; $pgb[$i]->finish; }
}

if ($rc != 0) {
    diag("add_node failed; skipping data verification");
    destroy_cluster('Destroy cluster');
    done_testing();
    exit 0;
}

# ---------------------------------------------------------------------------
diag("Verifying subscriptions and data");
wait_until(3, "SELECT count(*) FROM spock.sub_show_status() WHERE status = 'replicating'", '2', 120,
    "n3 has 2 replicating subscriptions (from n1, n2)");
wait_until(1, "SELECT count(*) FROM spock.sub_show_status() WHERE provider_node = 'n3' AND status = 'replicating'", '1', 120,
    "n1 replicates from n3");
wait_until(2, "SELECT count(*) FROM spock.sub_show_status() WHERE provider_node = 'n3' AND status = 'replicating'", '1', 120,
    "n2 replicates from n3");

psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(2, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
for my $src ('n1', 'n2') {
    my $lag = scalar_query(3, "SELECT * FROM wait_subscription(remote_node_name := '$src', report_it := true, timeout := '5 minutes', delay := 1.)");
    ok(defined $lag && $lag <= 0, "n3 caught up with $src (lag=$lag)");
}
my @agg = map { scalar_query($_, "SELECT sum(abalance), sum(aid), count(*) FROM pgbench_accounts") } 1..3;
diag("pgbench_accounts aggregates: n1=$agg[0] n2=$agg[1] n3=$agg[2]");
is($agg[2], $agg[0], "n3 data equals n1");
is($agg[2], $agg[1], "n3 data equals n2");

# Three-way traffic after the add, including DDL from a 5.0.11 node.
psql_or_bail(1, "CREATE TABLE mixed_test (id int PRIMARY KEY, src text)");
wait_until(3, "SELECT count(*) FROM pg_tables WHERE tablename = 'mixed_test'", '1', 60, "DDL from n1 ($v[0]) reached n3 ($v[2])");
wait_until(2, "SELECT count(*) FROM pg_tables WHERE tablename = 'mixed_test'", '1', 60, "DDL from n1 reached n2");
psql_or_bail(1, "INSERT INTO mixed_test VALUES (1, 'n1')");
psql_or_bail(2, "INSERT INTO mixed_test VALUES (2, 'n2')");
psql_or_bail(3, "INSERT INTO mixed_test VALUES (3, 'n3')");
wait_until($_, "SELECT count(*) FROM mixed_test", '3', 90, "n$_ sees rows from all three nodes") for 1..3;
psql_or_bail(3, "UPDATE mixed_test SET src = 'n3-upd' WHERE id = 1");
wait_until(1, "SELECT src FROM mixed_test WHERE id = 1", 'n3-upd', 60, "UPDATE from n3 ($v[2]) applied on n1 ($v[0])");

my @subs = map { scalar_query($_, "SELECT string_agg(subscription_name || ':' || status, ',' ORDER BY subscription_name) FROM spock.sub_show_status()") } 1..3;
diag("Final subs: n1=[$subs[0]] n2=[$subs[1]] n3=[$subs[2]]");

destroy_cluster('Destroy cluster');
done_testing();
