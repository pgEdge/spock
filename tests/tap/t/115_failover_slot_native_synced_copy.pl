use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(
    create_cluster destroy_cluster get_test_config
    system_or_bail psql_or_bail scalar_query
);
use Time::HiRes qw(time);

# =============================================================================
# Test: 115_failover_slot_native_synced_copy.pl
#
# On PG17 a copy created by native slot sync keeps synced = true until
# promotion, even after sync_replication_slots is turned off and the
# spock_failover_slots worker takes over.  PostgreSQL refuses to decode
# such a slot on a standby from any process but its own slot sync, so the
# worker must not try: with spock.failover_slots_database set it used to
# fail on every pass and stop synchronizing every slot.  It must keep
# synchronizing the copy by copying positions, and say why once.
# =============================================================================

my $pg_bin = get_test_config()->{pg_bin};
my ($pg_major) = `$pg_bin/pg_config --version` =~ /\b(\d+)/;
plan skip_all => "native slot sync with the spock worker exists only on PG17"
    unless defined $pg_major && $pg_major == 17;

sub qport {
    my ($port, $sql) = @_;
    my $config = get_test_config();
    my $out = `PGCONNECT_TIMEOUT=10 $config->{pg_bin}/psql -X -h $config->{host} -p $port -d $config->{db_name} -U $config->{db_user} -t -A -c "$sql" 2>/dev/null`;
    $out //= '';
    $out =~ s/^\s+|\s+$//g;
    return $out;
}

sub wait_until {
    my ($timeout, $poll, $cond) = @_;
    my $deadline = time() + $timeout;
    while (time() < $deadline) {
        return 1 if $cond->();
        sleep($poll);
    }
    return 0;
}

create_cluster(2, 'Create 2-node Spock cluster');

my $config       = get_test_config();
my $host         = $config->{host};
my $dbname       = $config->{db_name};
my $db_user      = $config->{db_user};
my $db_password  = $config->{db_password};
my $primary_port = $config->{node_ports}[0];

psql_or_bail(2, "SELECT spock.sub_create(
    'sub_n2_n1',
    'host=$host dbname=$dbname port=$primary_port user=$db_user password=$db_password',
    ARRAY['default','default_insert_only','ddl_sql'],
    true, true
)");

my $slot_name = '';
ok(wait_until(60, 2, sub {
    $slot_name = scalar_query(1,
        "SELECT slot_name FROM pg_replication_slots
         WHERE slot_type = 'logical' AND failover LIMIT 1");
    $slot_name =~ s/\s+//g;
    return length($slot_name) > 0;
}), "failover logical slot created on n1");

psql_or_bail(1, "CREATE TABLE synced_test (id serial primary key, pad text)");
psql_or_bail(1, "SELECT pg_create_physical_replication_slot('standby_slot')");

# ---------- physical standby with native slot sync ----------

my $standby_port    = $primary_port + 16;
my $standby_datadir = '/tmp/tmp_spock_synced_standby';
my $standby_logdir  = "$standby_datadir/pg_log";
my $standby_logpath = "$standby_logdir/standby.log";

system("rm -rf $standby_datadir 2>/dev/null");
system_or_bail("$pg_bin/pg_basebackup",
    '-D', $standby_datadir,
    '-h', $host, '-p', $primary_port, '-U', $db_user,
    '-X', 'stream', '-R');

system_or_bail('mkdir', '-p', $standby_logdir);
{
    open(my $conf, '>>', "$standby_datadir/postgresql.conf")
        or die "Cannot open standby postgresql.conf: $!";
    print $conf "\n# ---- standby overrides ----\n";
    print $conf "port = $standby_port\n";
    print $conf "hot_standby = on\n";
    print $conf "hot_standby_feedback = on\n";
    print $conf "primary_slot_name = 'standby_slot'\n";
    print $conf "sync_replication_slots = on\n";
    print $conf "spock.failover_slots_database = '$dbname'\n";
    print $conf "log_directory = '$standby_logdir'\n";
    print $conf "log_filename = 'standby.log'\n";
    close($conf);
}
{
    open(my $aconf, '>>', "$standby_datadir/postgresql.auto.conf")
        or die "Cannot open standby postgresql.auto.conf: $!";
    print $aconf "primary_conninfo = 'host=$host port=$primary_port "
               . "user=$db_user dbname=$dbname'\n";
    close($aconf);
}

system_or_bail("$pg_bin/pg_ctl", 'start', '-D', $standby_datadir,
    '-l', "$standby_datadir/startup.log", '-w');

my $synced = wait_until(120, 3, sub {
    psql_or_bail(1, "INSERT INTO synced_test (pad) VALUES ('x')");
    psql_or_bail(1, "CHECKPOINT");
    return qport($standby_port,
        "SELECT synced AND NOT temporary FROM pg_replication_slots
         WHERE slot_name = '$slot_name'") eq 't';
});
ok($synced, "native slot sync created a synced copy of '$slot_name'");

# ---------- hand over to the spock worker ----------

qport($standby_port, "ALTER SYSTEM SET sync_replication_slots = off");
qport($standby_port, "SELECT pg_reload_conf()");

# Two rounds, so the worker has to move the copy on more than one pass.
for my $round (1 .. 2)
{
    psql_or_bail(1,
        "INSERT INTO synced_test (pad) SELECT 'x' FROM generate_series(1, 100)");
    my $target = scalar_query(1, "SELECT pg_current_wal_lsn()");
    $target =~ s/\s+//g;
    ok(wait_until(60, 2, sub {
        psql_or_bail(1, "CHECKPOINT");
        return scalar_query(1,
            "SELECT confirmed_flush_lsn >= '$target'::pg_lsn
             FROM pg_replication_slots WHERE slot_name = '$slot_name'") =~ /t/;
    }), "round $round: n1's slot confirmed the new rows");
    ok(wait_until(60, 2, sub {
        return qport($standby_port,
            "SELECT confirmed_flush_lsn >= '$target'::pg_lsn
             FROM pg_replication_slots WHERE slot_name = '$slot_name'") eq 't';
    }), "round $round: the spock worker moved the synced copy");
}

my ($refused, $explained) = (0, 0);
if (open(my $fh, '<', $standby_logpath))
{
    while (<$fh>)
    {
        $refused++ if /cannot use replication slot "\Q$slot_name\E" for logical decoding/;
        $explained++ if /replication slot "\Q$slot_name\E" is synchronized without a consistent snapshot/;
    }
    close($fh);
}
is($refused, 0, 'the worker did not try to decode the synced copy');
is($explained, 1, 'the worker said once why the copy is not decoded');

# ---------- cleanup ----------

system("$pg_bin/pg_ctl stop -D $standby_datadir -m immediate >/dev/null 2>&1");
system("rm -rf $standby_datadir 2>/dev/null");

destroy_cluster('Destroy test cluster');
done_testing();
