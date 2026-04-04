use strict;
use warnings;
use Test::More;
use File::Path qw(make_path remove_tree);
use Cwd qw(getcwd);

use lib '.';
use lib 't';
use SpockTest qw(system_or_bail system_maybe wait_for_pg_ready psql_or_bail scalar_query);

# =============================================================================
# Test: 018_upgrade_schema_match.pl
#
# Verify that upgrading Spock from 5.0.6 -> 5.1.0 produces a schema that is
# identical to a fresh 5.1.0 installation.
#
# Each Spock version requires PostgreSQL built with that branch's patches:
#   origin/v5_STABLE  needs  patches/18/ from v5_STABLE  (e.g. row-filter-check)
#   HEAD              needs  patches/18/ from current branch
#
# Fast path (local dev): set V5_PG_INSTALL and V51_PG_INSTALL env vars to
# point at pre-built PG installations that already include the right Spock.
# The test will skip all builds and go straight to the schema comparison.
#
# Full build path (CI): leave the env vars unset.  The test clones the spock
# repo at each branch, builds PG 18 from source with that branch's patches,
# then builds and installs Spock.  PG installs are preserved in TEMP_BASE
# for caching across runs (only datadirs and source trees are cleaned up).
#
# Environment variables:
#   V5_PG_INSTALL   pre-built PG+Spock 5.0.6 dir  (default: $TEMP_BASE/pg_v5)
#   V51_PG_INSTALL  pre-built PG+Spock 5.1.0 dir  (default: $TEMP_BASE/pg_v51)
#   PG_TAG          git tag for PG source          (default: REL_18_2)
#   PG_REPO         git URL for PG source          (default: github postgres mirror)
#
# NOTE: This test is intentionally excluded from the default schedule (slow).
# =============================================================================

# ─────────────────────────────────────────────────────────────────────────────
# SPOCK_REPO detection (same strategy as 014_rolling_upgrade.pl)
# ─────────────────────────────────────────────────────────────────────────────
my $SPOCK_REPO;
if (-d "/home/pgedge/spock" && -f "/home/pgedge/spock/Makefile") {
    $SPOCK_REPO = "/home/pgedge/spock";
} else {
    my $cwd = getcwd();
    if ($cwd =~ m{^(/.+)/tests/tap(?:/t)?$}) {
        $SPOCK_REPO = $1;
    } else {
        $SPOCK_REPO = $cwd;
    }
}
die "SPOCK_REPO not found or missing Makefile: $SPOCK_REPO\n"
    unless $SPOCK_REPO && -d $SPOCK_REPO && -f "$SPOCK_REPO/Makefile";

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
my $TEMP_BASE    = '/tmp/spock_upgrade_schema_test';

# Pre-built PG+Spock installs.  When set, the test skips all source builds.
# Local example:  V5_PG_INSTALL=/usr/local/pgsql/pg18-5.x
#                 V51_PG_INSTALL=/usr/local/pgsql/pg18
my $V5_PG_INSTALL  = $ENV{V5_PG_INSTALL}  // "$TEMP_BASE/pg_v5";
my $V51_PG_INSTALL = $ENV{V51_PG_INSTALL} // "$TEMP_BASE/pg_v51";

# PostgreSQL source for fresh builds
my $PG_TAG  = $ENV{PG_TAG}  // "REL_18_2";
my $PG_REPO = $ENV{PG_REPO} // "https://github.com/postgres/postgres.git";

my $V5_BRANCH  = "origin/v5_STABLE";
my $V51_BRANCH = "HEAD";

my $V5_BIN  = "$V5_PG_INSTALL/bin";
my $V51_BIN = "$V51_PG_INSTALL/bin";
my $PG_BIN  = $V51_BIN;   # client tools (psql, pg_ctl) use v51 binary

my $DATADIR_UPG = "$TEMP_BASE/datadir_upgraded";   # starts at 5.0.6, upgraded
my $DATADIR_NEW = "$TEMP_BASE/datadir_fresh";       # fresh 5.1.0 install
my $PORT_UPG    = 5441;
my $PORT_NEW    = 5442;

my $NODE_UPG    = 1;
my $NODE_NEW    = 2;
my $DB_NAME     = 'regression';
my $DB_USER     = 'regression';
my $HOST        = '127.0.0.1';

my $LOG_DIR  = $ENV{TESTLOGDIR} // 'logs';
my $LOG_FILE = $ENV{SPOCKTEST_LOG_FILE}
             // "$LOG_DIR/018_upgrade_schema_match.log";

make_path($LOG_DIR);
make_path($TEMP_BASE);

# Convert any uncaught die into BAIL_OUT so prove always sees a proper TAP result.
$SIG{__DIE__} = sub {
    return if $^S;   # inside eval — let it propagate normally
    my $msg = shift;
    $msg =~ s/\s+$//;
    BAIL_OUT("Fatal: $msg (see $LOG_FILE)");
};

diag("SPOCK_REPO    : $SPOCK_REPO");
diag("V5_PG_INSTALL : $V5_PG_INSTALL");
diag("V51_PG_INSTALL: $V51_PG_INSTALL");
diag("PG_TAG        : $PG_TAG");

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup on exit
# ─────────────────────────────────────────────────────────────────────────────
my @started_datadirs;
END {
    for my $dd (@started_datadirs) {
        system("$PG_BIN/pg_ctl stop -D '$dd' -m immediate -s 2>/dev/null");
    }
    # Remove datadirs; preserve pg installs (for caching) and pg_src (for debugging).
    remove_tree($DATADIR_UPG)              if -d $DATADIR_UPG;
    remove_tree($DATADIR_NEW)              if -d $DATADIR_NEW;
    remove_tree("$TEMP_BASE/build_v5")     if -d "$TEMP_BASE/build_v5";
    remove_tree("$TEMP_BASE/build_v51")    if -d "$TEMP_BASE/build_v51";
    $? = 0;  # Don't let pg_ctl exit codes propagate
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────

sub run_logged {
    my @cmd = @_;
    open my $log, '>>', $LOG_FILE or die "Cannot open $LOG_FILE: $!";
    my $pid = fork // die "fork failed: $!";
    if ($pid == 0) {
        open STDOUT, '>&', $log;
        open STDERR, '>&', $log;
        exec @cmd or exit 127;
    }
    waitpid($pid, 0);
    return $? >> 8;
}

sub run_or_bail {
    my @cmd = @_;
    my $rc = run_logged(@cmd);
    BAIL_OUT("Command failed (rc=$rc): @cmd\n  (see $LOG_FILE for details)") if $rc;
}

# Run a multi-line SQL query and return trimmed scalar value
# (SpockTest::psql_or_bail / scalar_query only support single-line -c queries)
sub psql_query {
    my ($port, $sql) = @_;
    my $tmpfile = "/tmp/spock_018_$$.sql";
    open my $fh, '>', $tmpfile or die "Cannot write $tmpfile: $!";
    print $fh $sql;
    close $fh;
    open $fh, '-|', "$PG_BIN/psql", '-X', '-t', '-A',
        '-p', $port, '-d', $DB_NAME, '-U', $DB_USER, '-f', $tmpfile
        or die "Cannot run psql: $!";
    my $out = join '', <$fh>;
    close $fh;
    unlink $tmpfile;
    chomp $out;
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

# Ensure a PG + Spock environment is ready at $pg_install_dir.
#
# Fast path: if $pg_install_dir/bin/postgres and spock library both exist,
# return immediately (handles pre-built installs via env vars).
#
# Build path: clone spock at $spock_branch, build PG from $PG_REPO at $PG_TAG
# applying that branch's patches/18/*.diff, then build and install Spock.
sub ensure_version_ready {
    my ($spock_branch, $pg_install_dir, $version_name) = @_;

    my $pg_config  = "$pg_install_dir/bin/pg_config";
    my $spock_build = "$TEMP_BASE/build_$version_name";
    my $pg_src      = "$TEMP_BASE/pg_src_$version_name";

    # ── Fast path: pre-built PG + Spock already present ──
    if (-x "$pg_install_dir/bin/postgres") {
        my $pkglibdir = `$pg_config --pkglibdir 2>/dev/null`; chomp $pkglibdir;
        if ($pkglibdir && (-f "$pkglibdir/spock.so" || -f "$pkglibdir/spock.dylib")) {
            diag("$version_name: pre-built PG+Spock found at $pg_install_dir — skipping builds");
            return 1;
        }
    }

    # ── Clone spock repo at the requested branch ──
    diag("$version_name: cloning spock ($spock_branch) to $spock_build");
    remove_tree($spock_build) if -d $spock_build;
    run_or_bail("git", "clone", "--quiet", $SPOCK_REPO, $spock_build);
    if ($spock_branch ne 'HEAD') {
        run_or_bail("bash", "-c", "cd $spock_build && git checkout --quiet $spock_branch");
    }

    # ── Build PG from source if not already installed ──
    if (!-x "$pg_install_dir/bin/postgres") {
        diag("$version_name: building PostgreSQL $PG_TAG from source...");
        remove_tree($pg_src) if -d $pg_src;
        make_path($pg_install_dir);

        run_or_bail("git", "clone", "--quiet", "--depth=1",
                    "--branch", $PG_TAG, $PG_REPO, $pg_src);

        my $patches_dir = "$spock_build/patches/18";
        for my $patch (sort glob("$patches_dir/*.diff")) {
            my $name = (split '/', $patch)[-1];
            diag("  applying $name");
            run_or_bail("bash", "-c", "cd $pg_src && patch -p1 < $patch");
        }

        diag("$version_name: configure (build log: $LOG_FILE)");
        run_or_bail("bash", "-c",
            "cd $pg_src && ./configure --prefix=$pg_install_dir "
            . "--without-icu --without-ldap --without-gssapi --without-readline");
        diag("$version_name: make (build log: $LOG_FILE)");
        # Unset MAKEFLAGS/MAKELEVEL inherited from the outer 'make check_prove'
        # to prevent them from interfering with PG's own build.
        run_or_bail("bash", "-c", "cd $pg_src && unset MAKEFLAGS MAKELEVEL MFLAGS && make");
        run_or_bail("bash", "-c", "cd $pg_src && unset MAKEFLAGS MAKELEVEL MFLAGS && make install");
        diag("$version_name: PostgreSQL installed to $pg_install_dir");
    }

    # ── Build and install Spock ──
    diag("$version_name: building Spock...");
    run_or_bail("bash", "-c", "cd $spock_build && unset MAKEFLAGS MAKELEVEL MFLAGS && make PG_CONFIG=$pg_config 2>&1");
    run_or_bail("bash", "-c", "cd $spock_build && unset MAKEFLAGS MAKELEVEL MFLAGS && make install PG_CONFIG=$pg_config 2>&1");
    diag("$version_name: Spock installed to $pg_install_dir");
    return 1;
}

# Append key=value lines to postgresql.conf
sub pg_conf_append {
    my ($datadir, %kv) = @_;
    open my $fh, '>>', "$datadir/postgresql.conf" or die $!;
    print $fh "$_=$kv{$_}\n" for keys %kv;
    close $fh;
}

sub _start_postgres {
    my ($pg_bin, $datadir) = @_;
    open my $log, '>>', $LOG_FILE or die $!;
    my $pid = fork // die "fork failed: $!";
    if ($pid == 0) {
        open STDOUT, '>&', $log;
        open STDERR, '>&', $log;
        exec "$pg_bin/postgres", '-D', $datadir;
        exit 127;
    }
    push @started_datadirs, $datadir;
}

# Initialise a data directory and start postgres from $pg_install_dir
sub init_and_start_node {
    my ($datadir, $port, $pg_install_dir) = @_;
    remove_tree($datadir) if -d $datadir;

    my $pg_bin = "$pg_install_dir/bin";
    run_or_bail("$pg_bin/initdb", '-A', 'trust', '-D', $datadir);

    pg_conf_append($datadir,
        port                     => $port,
        listen_addresses         => "'*'",
        wal_level                => 'logical',
        track_commit_timestamp   => 'on',
        shared_preload_libraries => "'spock'",
        log_min_messages         => 'warning',
    );

    _start_postgres($pg_bin, $datadir);
    return wait_for_pg_ready($HOST, $port, $PG_BIN, 30);
}

sub stop_pg {
    my ($datadir) = @_;
    run_logged("$PG_BIN/pg_ctl", 'stop', '-D', $datadir, '-m', 'fast', '-w');
    sleep 2;
}

# ─────────────────────────────────────────────────────────────────────────────
# Schema comparison queries
# ─────────────────────────────────────────────────────────────────────────────

my $Q_TABLES = <<'SQL';
SELECT string_agg(table_name, E'\n' ORDER BY table_name)
FROM information_schema.tables
WHERE table_schema = 'spock' AND table_type = 'BASE TABLE'
SQL

# udt_name catches text vs text[] mismatches (_text = text[])
my $Q_COLUMNS = <<'SQL';
SELECT string_agg(
    table_name || '.' || column_name || ' ' || udt_name
    || CASE WHEN is_nullable = 'NO' THEN ' NOT NULL' ELSE '' END,
    E'\n' ORDER BY table_name, ordinal_position)
FROM information_schema.columns
WHERE table_schema = 'spock'
SQL

my $Q_FUNCTIONS = <<'SQL';
SELECT string_agg(
    proname
    || '(' || pg_catalog.pg_get_function_arguments(oid) || ')'
    || ':' || prokind::text,
    E'\n' ORDER BY proname, pg_catalog.pg_get_function_arguments(oid))
FROM pg_catalog.pg_proc
WHERE pronamespace = 'spock'::regnamespace
SQL

my $Q_VIEWS = <<'SQL';
SELECT string_agg(viewname, E'\n' ORDER BY viewname)
FROM pg_catalog.pg_views
WHERE schemaname = 'spock'
SQL

my $Q_SEQUENCES = <<'SQL';
SELECT string_agg(sequence_name, E'\n' ORDER BY sequence_name)
FROM information_schema.sequences
WHERE sequence_schema = 'spock'
SQL

# View definitions (catches changes to view SQL)
my $Q_VIEW_DEFS = <<'SQL';
SELECT string_agg(viewname || ':' || regexp_replace(definition, '\s+', ' ', 'g'),
    E'\n' ORDER BY viewname)
FROM pg_catalog.pg_views
WHERE schemaname = 'spock'
SQL

# plpgsql/SQL function bodies (not C — those share the same symbol name)
my $Q_FUNC_BODIES = <<'SQL';
SELECT string_agg(
    proname || '(' || pg_catalog.pg_get_function_arguments(p.oid) || '):'
    || regexp_replace(pg_catalog.pg_get_functiondef(p.oid), '\s+', ' ', 'g'),
    E'\n' ORDER BY proname, pg_catalog.pg_get_function_arguments(p.oid))
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_language l ON l.oid = p.prolang
WHERE p.pronamespace = 'spock'::regnamespace
  AND l.lanname IN ('plpgsql', 'sql')
SQL

sub compare_category {
    my ($label, $upg, $new) = @_;
    if ($upg ne $new) {
        diag("$label MISMATCH");
        diag("  UPGRADED:\n$upg");
        diag("  FRESH:\n$new");
    }
    is($upg, $new, "$label match between upgraded and fresh install");
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1 – Ensure v5_STABLE environment (PG + Spock 5.0.6)
# ─────────────────────────────────────────────────────────────────────────────
diag("PHASE 1: Ensuring Spock 5.0.6 environment ($V5_BRANCH)");
ok(ensure_version_ready($V5_BRANCH, $V5_PG_INSTALL, 'v5'),
   "Spock 5.0.6 environment ready");

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2 – Ensure current environment (PG + Spock 5.1.0)
# ─────────────────────────────────────────────────────────────────────────────
diag("PHASE 2: Ensuring Spock 5.1.0 environment ($V51_BRANCH)");
ok(ensure_version_ready($V51_BRANCH, $V51_PG_INSTALL, 'v51'),
   "Spock 5.1.0 environment ready");

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3 – Start upgrade node (Spock 5.0.6)
# ─────────────────────────────────────────────────────────────────────────────
diag("PHASE 3: Initialising upgrade node (Spock 5.0.6)...");
ok(init_and_start_node($DATADIR_UPG, $PORT_UPG, $V5_PG_INSTALL),
   'Upgrade node started (5.0.6)');

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4 – Start fresh node (Spock 5.1.0)
# ─────────────────────────────────────────────────────────────────────────────
diag("PHASE 4: Initialising fresh node (Spock 5.1.0)...");
ok(init_and_start_node($DATADIR_NEW, $PORT_NEW, $V51_PG_INSTALL),
   'Fresh node started (5.1.0)');

# Create database and user on both nodes
for my $port ($PORT_UPG, $PORT_NEW) {
    system_maybe("$PG_BIN/psql", '-p', $port, '-d', 'postgres',
                 '-c', "CREATE DATABASE $DB_NAME");
    system_maybe("$PG_BIN/psql", '-p', $port, '-d', 'postgres',
                 '-c', "CREATE USER $DB_USER SUPERUSER");
}

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5 – Install extensions
# ─────────────────────────────────────────────────────────────────────────────
psql_or_bail($NODE_UPG, 'CREATE EXTENSION spock');
my $ver_upg = scalar_query($NODE_UPG,
    "SELECT extversion FROM pg_extension WHERE extname = 'spock'");
diag("Upgrade node extension version after CREATE: $ver_upg");
like($ver_upg, qr/^5\.0\.6/, 'Upgrade node starts at 5.0.6');

psql_or_bail($NODE_NEW, 'CREATE EXTENSION spock');
my $ver_new = scalar_query($NODE_NEW,
    "SELECT extversion FROM pg_extension WHERE extname = 'spock'");
diag("Fresh node extension version after CREATE: $ver_new");
like($ver_new, qr/^5\.1\.0/, 'Fresh node installs at 5.1.0');

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6 – Upgrade node 1: swap to 5.1.0 postgres binary, ALTER EXTENSION UPDATE
# ─────────────────────────────────────────────────────────────────────────────
diag("PHASE 6: Stopping upgrade node to swap to Spock 5.1.0 binary...");
stop_pg($DATADIR_UPG);

# Restart with the 5.1.0 postgres binary.  shared_preload_libraries='spock'
# (bare name) resolves against the new binary's own $libdir — no conf change needed.
_start_postgres($V51_BIN, $DATADIR_UPG);
ok(wait_for_pg_ready($HOST, $PORT_UPG, $PG_BIN, 30),
   'Upgrade node restarted with 5.1.0 binary');

psql_or_bail($NODE_UPG, 'ALTER EXTENSION spock UPDATE');

my $ver_upg2 = scalar_query($NODE_UPG,
    "SELECT extversion FROM pg_extension WHERE extname = 'spock'");
diag("Upgrade node extension version after ALTER EXTENSION UPDATE: $ver_upg2");
is($ver_upg2, '5.1.0', 'Upgrade node extension version is now 5.1.0');

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 7 – Schema comparison (catalog queries)
# ─────────────────────────────────────────────────────────────────────────────
diag("PHASE 7: Comparing schemas via catalog queries...");

compare_category('Tables',
    psql_query($PORT_UPG, $Q_TABLES),
    psql_query($PORT_NEW, $Q_TABLES));

compare_category('Columns (names and types)',
    psql_query($PORT_UPG, $Q_COLUMNS),
    psql_query($PORT_NEW, $Q_COLUMNS));

compare_category('Functions and procedures',
    psql_query($PORT_UPG, $Q_FUNCTIONS),
    psql_query($PORT_NEW, $Q_FUNCTIONS));

compare_category('Views',
    psql_query($PORT_UPG, $Q_VIEWS),
    psql_query($PORT_NEW, $Q_VIEWS));

compare_category('Sequences',
    psql_query($PORT_UPG, $Q_SEQUENCES),
    psql_query($PORT_NEW, $Q_SEQUENCES));

compare_category('View definitions',
    psql_query($PORT_UPG, $Q_VIEW_DEFS),
    psql_query($PORT_NEW, $Q_VIEW_DEFS));

compare_category('plpgsql/SQL function bodies',
    psql_query($PORT_UPG, $Q_FUNC_BODIES),
    psql_query($PORT_NEW, $Q_FUNC_BODIES));

done_testing();
