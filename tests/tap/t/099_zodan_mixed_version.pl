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
# Test: mixed-version add_node with zodan, old Spock (default 5.0.11, built
# from v5_STABLE) and new Spock (HEAD).  Two layouts, chosen by ZODAN_SCENARIO:
#
#   chain (default)  n1 runs the old version alone.  n2 (new version) joins it
#                    with add_node, making the cluster mixed.  n3 (new version)
#                    then joins the mixed cluster, from n2 by default.  This is
#                    the sequence QA reported.
#   pair             n1 and n2 run the old version, cross-wired.  n3 (new
#                    version) joins from n1.  Covers an old source with an old
#                    peer.
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
#   ZODAN_SCENARIO chain (default) or pair, see above
#   ZODAN_N3_SRC   chain only: node n3 joins from, n2 (default) or n1
#   ZODAN_N12_VER  name of the old build: v5 (default, built from
#                  origin/v5_STABLE), v6 (HEAD, gives an all-new-version
#                  control run), or any other name together with ZODAN_N12_REF
#   ZODAN_N12_REF  git ref to build for ZODAN_N12_VER (e.g. v5.0.9); defaults
#                  exist for v5 and v6 only
#   ZODAN_LOAD     1 = run pgbench load on the existing nodes while n3 joins
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
my $SCENARIO   = $ENV{ZODAN_SCENARIO} // 'chain';
my $N3_SRC     = $ENV{ZODAN_N3_SRC} // 'n2';
die "ZODAN_SCENARIO must be chain or pair" unless $SCENARIO =~ /^(chain|pair)$/;
die "ZODAN_N3_SRC must be n1 or n2" unless $N3_SRC =~ /^n[12]$/;

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

# Run $sql on a node and check that it fails with an error matching $re.
sub psql_expect_error {
    my ($node, $sql, $re, $label) = @_;
    my $c = get_test_config();
    my $port = $c->{node_ports}->[$node-1];
    my $out = `$c->{pg_bin}/psql -X -p $port -d $c->{db_name} -v ON_ERROR_STOP=1 -c "$sql" 2>&1`;
    my $rc = $? >> 8;
    ok($rc != 0 && $out =~ $re, $label) or diag("exit $rc, output:\n$out");
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
my @dsn = map { "host=$host dbname=$dbname port=$_ user=$db_user" } @$ports;

my $ver12 = install_version($N12_VER);   # old version
my $ver3  = install_version('v6');       # new version
my $mixed = $ver12 ne $ver3;
my @tree  = ($N12_VER, $SCENARIO eq 'pair' ? $N12_VER : 'v6', 'v6');
diag("Scenario $SCENARIO: n1 -> $ver12 ($tree[0]), n2 -> " . install_version($tree[1]) . " ($tree[1]), n3 -> $ver3 (v6)");

psql_or_bail($_, "DROP EXTENSION IF EXISTS spock CASCADE") for 1..3;
stop_node($_) for 1..3;
start_node($_, $tree[$_-1]) for 1..3;
psql_or_bail($_, "CREATE EXTENSION spock") for 1..3;

my @v = map { scalar_query($_, "SELECT spock.spock_version()") } 1..3;
diag("Versions: n1=$v[0] n2=$v[1] n3=$v[2]");
is($v[$_-1], install_version($tree[$_-1]), "n$_ runs Spock " . install_version($tree[$_-1]) . " ($tree[$_-1] build)") for 1..3;

# zodan lives on each node that is added (its objects are in the spock
# schema).  The wait_subscription() helper is a plain public function used
# only for the lag checks on n3; it must not be on a node whose schema is
# later dumped into n3, or the structure sync fails on the duplicate.
for my $n ($SCENARIO eq 'chain' ? (2, 3) : (3)) {
    psql_or_bail($n, "CREATE EXTENSION dblink");
    psql_or_bail($n, "\\i $ZODAN_SQL");
}
psql_or_bail(3, "\\i ../../samples/Z0DAN/wait_subscription.sql");

# Run add_node on node $new with source $src.  Output goes to a file whose
# name is returned; the test bails out if the call fails.
sub run_add_node {
    my ($new, $src) = @_;
    my $out_file = "$SCRATCH/add_node_${SCENARIO}_${N12_VER}_n${new}_from_n${src}" . ($LOAD ? '_load' : '') . ".out";
    my $sql = "CALL spock.add_node(src_node_name := 'n$src', src_dsn := '$dsn[$src-1]', "
            . "new_node_name := 'n$new', new_node_dsn := '$dsn[$new-1]', verb := true);";
    diag("Adding n$new (" . scalar_query($new, "SELECT spock.spock_version()") . ") from n$src ("
         . scalar_query($src, "SELECT spock.spock_version()") . ")");
    my $t0 = time();
    my $rc = system("timeout 1200 $config->{pg_bin}/psql -X -p $ports->[$new-1] -d $dbname -v ON_ERROR_STOP=1 -c \"$sql\" > '$out_file' 2>&1");
    my $elapsed = time() - $t0;
    diag("add_node n$new exit code " . ($rc >> 8) . " after ${elapsed}s; output in $out_file");
    is($rc, 0, "add_node n$new from n$src completed without error");
    if ($rc != 0) {
        open(my $fh, '<', $out_file); my @tail = <$fh>; close $fh;
        diag("--- add_node output tail ---"); diag($_) for @tail[-25..-1];
        dump_state("$SCRATCH/state_${SCENARIO}_${N12_VER}_failed_n${new}.txt");
        destroy_cluster('Destroy cluster');
        done_testing();
        exit 0;
    }
    return $out_file;
}

# Nodes first, then data: tables created on a node that exists are added to
# its replication sets (spock.include_ddl_repset), which is what the later
# syncs copy.
my ($out_n2, $out_n3);
psql_or_bail(1, "SELECT spock.node_create('n1', '$dsn[0]')");
if ($SCENARIO eq 'pair') {
    psql_or_bail(2, "SELECT spock.node_create('n2', '$dsn[1]')");
    cross_wire(2, ['n1', 'n2'], "Cross-wire n1 <-> n2 (both $ver12)");
}
system_or_bail("$config->{pg_bin}/pgbench", '-i', '-s', 1, '-h', $host, '-p', $ports->[0], '-U', $db_user, $dbname);
is(scalar_query(1, "SELECT count(*) FROM spock.tables WHERE set_name IS NOT NULL AND relname LIKE 'pgbench_%'"), '4',
    "pgbench tables are in replication sets on n1");
if ($SCENARIO eq 'pair') {
    psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
    wait_until(2, "SELECT count(*) FROM pgbench_accounts", '100000', 180, "pgbench data replicated n1 -> n2");
} else {
    $out_n2 = run_add_node(2, 1);
    wait_until(2, "SELECT count(*) FROM spock.sub_show_status() WHERE provider_node = 'n1' AND status = 'replicating'", '1', 120,
        "n2 replicates from n1");
    wait_until(1, "SELECT count(*) FROM spock.sub_show_status() WHERE provider_node = 'n2' AND status = 'replicating'", '1', 120,
        "n1 replicates from n2");
    wait_until(2, "SELECT count(*) FROM pgbench_accounts", '100000', 180, "pgbench data present on n2 after add");
}

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
my $n3_src = $SCENARIO eq 'pair' ? 1 : substr($N3_SRC, 1);
$out_n3 = run_add_node(3, $n3_src);
dump_state("$SCRATCH/state_${SCENARIO}_${N12_VER}" . ($LOAD ? '_load' : '_noload') . ".txt");
if ($LOAD) {
    for my $i (0, 1) { $pgb[$i]->kill_kill; $pgb[$i]->finish; }
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

# Three-way traffic after the add, including DDL from the old node.
psql_or_bail(1, "CREATE TABLE mixed_test (id int PRIMARY KEY, src text)");
wait_until(3, "SELECT count(*) FROM pg_tables WHERE tablename = 'mixed_test'", '1', 60, "DDL from n1 ($v[0]) reached n3 ($v[2])");
wait_until(2, "SELECT count(*) FROM pg_tables WHERE tablename = 'mixed_test'", '1', 60, "DDL from n1 reached n2");
psql_or_bail(1, "INSERT INTO mixed_test VALUES (1, 'n1')");
psql_or_bail(2, "INSERT INTO mixed_test VALUES (2, 'n2')");
psql_or_bail(3, "INSERT INTO mixed_test VALUES (3, 'n3')");
wait_until($_, "SELECT count(*) FROM mixed_test", '3', 90, "n$_ sees rows from all three nodes") for 1..3;
psql_or_bail(3, "UPDATE mixed_test SET src = 'n3-upd' WHERE id = 1");
wait_until(1, "SELECT src FROM mixed_test WHERE id = 1", 'n3-upd', 60, "UPDATE from n3 ($v[2]) applied on n1 ($v[0])");

# The version rule in check_spock_version_compatibility.  The accepting path
# is the add_node calls above; here are the notices they must have produced
# and the rejection, exercised by calling the procedure directly with an old
# node in the "new node" role.  Only meaningful when the versions differ.
if ($mixed) {
    if ($out_n2) {
        my $n = `grep -c 'Mixed-version add: new node runs Spock $ver3, existing nodes run: n1 $ver12' '$out_n2'`; chomp $n;
        is($n, '1', "add_node n2 reported the mixed-version add ($ver12 node, $ver3 new node)");
    }
    my $n = `grep -Ec 'Mixed-version add: new node runs Spock $ver3, existing nodes run: .*n1 $ver12' '$out_n3'`; chomp $n;
    is($n, '1', "add_node n3 reported the mixed-version add (existing nodes include n1 $ver12)");
    psql_expect_error(3,
        "CALL spock.check_spock_version_compatibility('$dsn[2]', '$dsn[0]')",
        qr/new node has version \Q$ver12\E, but source node has version \Q$ver3\E\. The new node must run the same or a newer major\.minor version than every existing node/,
        "version rule rejects an older new node ($ver12) via a $ver3 source");
    psql_expect_error(3,
        "CALL spock.check_spock_version_compatibility('$dsn[0]', '$dsn[0]')",
        qr/new node has version \Q$ver12\E, but node n[23] has version \Q$ver3\E\. The new node must run the same or a newer major\.minor version than every existing node/,
        "version rule rejects an older new node ($ver12) via a $ver12 source when a $ver3 node exists");
}

# Resync one table on n3 from n1.  This goes through copy_tables_data() and
# read_provider_progress(), which read the provider's spock.progress directly,
# so it covers the other place the sync worker must understand an older
# provider's catalog.  read_provider_progress() logs one "read provider
# progress" line per peer; that text is unique to it.
my $n3_log = "$ENV{TESTLOGDIR}/00$ports->[2].log";
sub count_progress_adjustments {
    my $n = `grep -c 'SPOCK: read provider progress' '$n3_log' 2>/dev/null`; chomp $n;
    return $n || 0;
}
my $adjusted_before = count_progress_adjustments();
psql_or_bail(1, "UPDATE pgbench_branches SET bbalance = bbalance + 1");
psql_or_bail(1, 'SELECT spock.wait_slot_confirm_lsn(NULL, NULL)');
psql_or_bail(3, "SELECT spock.sub_resync_table('sub_n1_n3', 'pgbench_branches')");
wait_until(3, "SELECT status FROM spock.sub_show_table('sub_n1_n3', 'pgbench_branches')", 'replicating', 120,
    "single-table resync of pgbench_branches on n3 from n1 ($v[0]) completed");
cmp_ok(count_progress_adjustments(), '>', $adjusted_before,
    "resync read the provider's progress entries (read_provider_progress ran; $adjusted_before log lines before)");
my @br = map { scalar_query($_, "SELECT sum(bbalance), count(*) FROM pgbench_branches") } 1, 3;
is($br[1], $br[0], "pgbench_branches equal on n1 and n3 after resync");

my @subs = map { scalar_query($_, "SELECT string_agg(subscription_name || ':' || status, ',' ORDER BY subscription_name) FROM spock.sub_show_status()") } 1..3;
diag("Final subs: n1=[$subs[0]] n2=[$subs[1]] n3=[$subs[2]]");

destroy_cluster('Destroy cluster');
done_testing();
