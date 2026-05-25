use strict;
use warnings;
use Test::More;
use POSIX ();
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster
    get_test_config system_or_bail
);

# =============================================================================
# Test 103: manager-worker dboid race during tenant-DB churn
#
# Reproduces the DROP DATABASE race condition:
#
#   The spock supervisor scans pg_database and registers a manager
#   worker per database.  Between the seq-scan tuple read and the
#   manager worker actually attaching, another backend can DROP
#   DATABASE or set datconnlimit = -2 (the invalid-database marker).
#   When that race fires, the manager worker FATALs during attach
#   with:
#       FATAL:  cannot connect to invalid database <oid>
#       FATAL:  database <oid> does not exist
#   The supervisor then respawns (because spock_worker_detach for a
#   manager re-arms SpockCtx->subscriptions_changed) and the loop
#   sustains itself, hammering SpockCtx->lock and pg_database.
#
# Fix: in start_manager_workers(), revalidate the dboid via
# SearchSysCache1(DATABASEOID, ...) immediately before
# spock_worker_register() and skip registration if the live tuple is
# gone or has datconnlimit = -2.
#
# Test method:
#   - 1-node cluster with spock loaded.
#   - 6 parallel children loop CREATE DATABASE / DROP DATABASE for a
#     fixed window — this is the CipherTrust tenant-DB churn pattern.
#   - A fast shutdown + restart of the postmaster lands in the middle
#     of the churn window to widen the race the supervisor sees.
#   - Snapshot the postgres log BEFORE the churn starts; after the
#     window, grep only the new log content for the FATAL signatures.
#   - Assert the FATAL counts are zero and that no manager worker
#     exited with error.  Without the fix this test reproducibly
#     shows several FATALs on PG16; with the fix it shows zero.
# =============================================================================

create_cluster(1, 'Create 1-node cluster for manager-drop-dboid-race test');

my $config = get_test_config();
my $pg_bin = $config->{pg_bin};
my $host   = $config->{host};
my $dbname = $config->{db_name};
my $user   = $config->{db_user};
my $log_dir = $config->{log_dir};

my $port    = $config->{node_ports}->[0];
my $datadir = $config->{node_datadirs}->[0];
my $log     = "$log_dir/00${port}.log";

# Snapshot log offset before churn so we only scan the new content.
my $log_offset_before = -s $log // 0;

# Spawn parallel CREATE/DROP DATABASE churn workers.
my $CHURN_PARALLEL = 6;
my $CHURN_SECONDS  = 20;

my @kids;
for my $w (1 .. $CHURN_PARALLEL) {
    my $pid = fork();
    die "fork failed: $!" unless defined $pid;
    if ($pid == 0) {
        my $deadline = time() + $CHURN_SECONDS;
        my $i = 0;
        while (time() < $deadline) {
            $i++;
            my $name = "kylo_w${w}_${i}_$$";
            # No sleep between create and drop — widen the race window
            # by giving the supervisor less time to spawn its manager.
            system("$pg_bin/psql -X -q -h $host -p $port -U $user -d $dbname "
                 . "-c 'CREATE DATABASE \"$name\"' >/dev/null 2>&1");
            system("$pg_bin/psql -X -q -h $host -p $port -U $user -d $dbname "
                 . "-c 'DROP DATABASE \"$name\" WITH (FORCE)' >/dev/null 2>&1");
        }
        # POSIX::_exit() bypasses Test::More's END handler — otherwise
        # each forked child would try to finalise the TAP plan on exit
        # and produce duplicate "ok" lines in the parent's output.
        POSIX::_exit(0);
    }
    push @kids, $pid;
}

# Mid-churn: fast shutdown + restart of the postmaster.  This is what
# turns the steady-state race into the DROP DATABASE FATAL burst on PG16 —
# the supervisor's last pre-shutdown pg_database scan registers
# managers for dboids the application is concurrently dropping.
sleep(int($CHURN_SECONDS / 2));
system_or_bail("$pg_bin/pg_ctl", '-D', $datadir, '-m', 'fast', '-w', 'stop');
sleep(1);
system_or_bail("$pg_bin/pg_ctl", '-D', $datadir, '-l', $log, '-w', 'start');

# Wait for all churn children.  They will see connection errors during
# the brief shutdown window — that's expected and irrelevant; we only
# care about what the spock supervisor and manager workers logged.
waitpid($_, 0) for @kids;

# Read only the log content produced since we snapshotted.
my $new_log = '';
if (open(my $lf, '<', $log)) {
    seek($lf, $log_offset_before, 0);
    local $/;
    $new_log = <$lf> // '';
    close($lf);
}

# (1) No "FATAL: cannot connect to invalid database <oid>"
# error's exact log signature
my @fatal_invalid =
    ($new_log =~ /FATAL:\s+cannot connect to invalid database/g);
is(scalar @fatal_invalid, 0,
   'no "FATAL: cannot connect to invalid database" during tenant churn');

# (2) No "FATAL: database <oid> does not exist" — the other shape of
# the same race when DROP DATABASE has fully completed by attach time.
my @fatal_missing =
    ($new_log =~ /FATAL:\s+database \d+ does not exist/g);
is(scalar @fatal_missing, 0,
   'no "FATAL: database <oid> does not exist" during tenant churn');

# (3) No manager-worker error-exits.  With the fix the supervisor
# skips registration entirely for invalidated dboids, so the only
# manager-worker exit lines should be "detaching cleanly".
my @err_exits =
    ($new_log =~ /manager worker \[\d+\][^\n]*exiting with error/g);
is(scalar @err_exits, 0,
   'no manager-worker "exiting with error" during tenant churn');

destroy_cluster('Destroy test cluster');
done_testing();
