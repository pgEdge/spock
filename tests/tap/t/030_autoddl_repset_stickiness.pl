use strict;
use warnings;
use Test::More tests => 25;
use lib '.';
use SpockTest qw(create_cluster destroy_cluster system_or_bail psql_or_bail
                 scalar_query get_test_config);

# =============================================================================
# Test: 030_autoddl_repset_stickiness.pl
# =============================================================================
# With autoDDL + spock.include_ddl_repset, verify that:
#   - ALTER TABLE that does not touch PK/RI leaves repset membership alone
#   - tables placed in a user-defined repset are not yanked back into the
#     default repsets on unrelated ALTERs
#   - PK is only auto-managed when the ALTER actually adds or drops it
#   - dropping a PK from a custom UPDATE/DELETE repset emits a WARNING
#     and falls back to default_insert_only (replication safety net)
#   - adding a PK to a table in a custom repset emits a NOTICE and
#     leaves the membership unchanged

# A single provider node is enough to exercise the local repset logic.
create_cluster(1, 'Create single-node cluster for repset stickiness tests');

my $config = get_test_config();
my $node_port = $config->{node_ports}->[0];
my $pg_bin    = $config->{pg_bin};
my $dbname    = $config->{db_name};

# Helper: comma-joined sorted list of repsets the table belongs to.
sub repsets_for {
    my ($relname) = @_;
    return scalar_query(1,
        "SELECT coalesce(string_agg(set_name, ',' ORDER BY set_name), '')" .
        " FROM spock.tables WHERE relname = '$relname'" .
        " AND set_name IS NOT NULL");
}

# Custom repsets.
psql_or_bail(1, "SELECT spock.repset_create('spoc539_full')");
psql_or_bail(1, "SELECT spock.repset_create('spoc539_insonly'," .
                " replicate_update := false, replicate_delete := false)");

# -----------------------------------------------------------------------------
# T1: ALTER ADD COLUMN on a table in a custom repset -> sticky.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t1 (id int primary key, a text)");
psql_or_bail(1, "SELECT spock.repset_remove_table('default', 'spoc539_t1')");
psql_or_bail(1, "SELECT spock.repset_add_table('spoc539_full', 'spoc539_t1')");
is(repsets_for('spoc539_t1'), 'spoc539_full',
   'T1: table starts in custom repset only');
psql_or_bail(1, "ALTER TABLE spoc539_t1 ADD COLUMN b int");
is(repsets_for('spoc539_t1'), 'spoc539_full',
   'T1: ALTER ADD COLUMN leaves custom-repset membership alone');

# -----------------------------------------------------------------------------
# T2: ALTER ADD COLUMN on a table in default -> still in default only.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t2 (id int primary key, a text)");
is(repsets_for('spoc539_t2'), 'default',
   'T2: table with PK auto-placed in default');
psql_or_bail(1, "ALTER TABLE spoc539_t2 ADD COLUMN b int");
is(repsets_for('spoc539_t2'), 'default',
   'T2: ALTER ADD COLUMN does not churn default membership');

# -----------------------------------------------------------------------------
# T3: drop PK on a table in default -> default_insert_only.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t3 (id int primary key, a text)");
is(repsets_for('spoc539_t3'), 'default',
   'T3: table starts in default');
psql_or_bail(1, "ALTER TABLE spoc539_t3 DROP CONSTRAINT spoc539_t3_pkey");
is(repsets_for('spoc539_t3'), 'default_insert_only',
   'T3: dropping PK moves table from default to default_insert_only');

# -----------------------------------------------------------------------------
# T4: drop PK on a table in a custom UPDATE/DELETE repset -> WARNING + move
# to default_insert_only (custom membership would break replication).
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t4 (id int primary key, a text)");
psql_or_bail(1, "SELECT spock.repset_remove_table('default', 'spoc539_t4')");
psql_or_bail(1, "SELECT spock.repset_add_table('spoc539_full', 'spoc539_t4')");
is(repsets_for('spoc539_t4'), 'spoc539_full',
   'T4: table starts in custom UPDATE/DELETE repset');

# Capture stderr for the DROP CONSTRAINT to assert the WARNING fired.
my $t4_cmd = qq{$pg_bin/psql -X -p $node_port -d $dbname }
           . qq{-c "ALTER TABLE spoc539_t4 DROP CONSTRAINT spoc539_t4_pkey" 2>&1};
my $output = `$t4_cmd`;
like($output, qr/WARNING:.*lost its primary key.*moving to/i,
     'T4: WARNING emitted on PK drop from UPDATE/DELETE custom repset');
is(repsets_for('spoc539_t4'), 'default_insert_only',
   'T4: table moved to default_insert_only by safety net');

# -----------------------------------------------------------------------------
# T5: drop PK on a table in a custom insert-only repset -> sticky.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t5 (id int primary key, a text)");
psql_or_bail(1, "SELECT spock.repset_remove_table('default', 'spoc539_t5')");
psql_or_bail(1, "SELECT spock.repset_add_table('spoc539_insonly', 'spoc539_t5')");
is(repsets_for('spoc539_t5'), 'spoc539_insonly',
   'T5: table starts in custom insert-only repset');
psql_or_bail(1, "ALTER TABLE spoc539_t5 DROP CONSTRAINT spoc539_t5_pkey");
is(repsets_for('spoc539_t5'), 'spoc539_insonly',
   'T5: dropping PK leaves table in custom insert-only repset');

# -----------------------------------------------------------------------------
# T6: add PK on a no-PK table that already lives in a custom insert-only repset
# -> sticky (NOTICE emitted but membership unchanged). spoc539_full replicates
# UPDATE/DELETE and would reject a no-PK table, so use the insert-only repset.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t6 (id int, a text)");
psql_or_bail(1, "SELECT spock.repset_remove_table('default_insert_only', 'spoc539_t6')");
psql_or_bail(1, "SELECT spock.repset_add_table('spoc539_insonly', 'spoc539_t6')");
is(repsets_for('spoc539_t6'), 'spoc539_insonly',
   'T6: no-PK table starts in custom insert-only repset');
my $t6_cmd = qq{$pg_bin/psql -X -p $node_port -d $dbname }
           . qq{-c "ALTER TABLE spoc539_t6 ADD PRIMARY KEY (id)" 2>&1};
my $t6_output = `$t6_cmd`;
like($t6_output, qr/NOTICE:.*gained a primary key.*leaving membership unchanged/i,
     'T6: NOTICE emitted on PK add to custom repset');
is(repsets_for('spoc539_t6'), 'spoc539_insonly',
   'T6: adding PK leaves custom-repset membership alone');

# -----------------------------------------------------------------------------
# T7 (regression for the upstream behavior): ensure CREATE TABLE still adds
# to default_insert_only when there is no PK.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t7 (id int)");
is(repsets_for('spoc539_t7'), 'default_insert_only',
   'T7: CREATE TABLE without PK still lands in default_insert_only');
psql_or_bail(1, "ALTER TABLE spoc539_t7 ADD COLUMN b int");
is(repsets_for('spoc539_t7'), 'default_insert_only',
   'T7: unrelated ALTER on no-PK table does not churn membership');

# -----------------------------------------------------------------------------
# T8: mixed membership (default + custom insert-only), PK dropped.
# The 'default' repset replicates UPDATE/DELETE and would break without a PK,
# so the safety net must evict the table from 'default' and place it in
# 'default_insert_only'. The custom insert-only membership must be preserved.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t8 (id int primary key, a text)");
psql_or_bail(1, "SELECT spock.repset_add_table('spoc539_insonly', 'spoc539_t8')");
is(repsets_for('spoc539_t8'), 'default,spoc539_insonly',
   'T8: table starts in default + custom insert-only');
my $t8_cmd = qq{$pg_bin/psql -X -p $node_port -d $dbname }
           . qq{-c "ALTER TABLE spoc539_t8 DROP CONSTRAINT spoc539_t8_pkey" 2>&1};
my $t8_output = `$t8_cmd`;
like($t8_output, qr/WARNING:.*lost its primary key.*moving to/i,
     'T8: WARNING emitted when PK drop affects a UPDATE/DELETE repset');
is(repsets_for('spoc539_t8'), 'default_insert_only,spoc539_insonly',
   'T8: evicted from default, preserved in custom insert-only');

# -----------------------------------------------------------------------------
# T9: mixed membership (default_insert_only + custom insert-only), PK dropped.
# Nothing replicates UPDATE/DELETE; the missing PK is harmless. Sticky.
# -----------------------------------------------------------------------------
psql_or_bail(1, "CREATE TABLE spoc539_t9 (id int)");
psql_or_bail(1, "SELECT spock.repset_add_table('spoc539_insonly', 'spoc539_t9')");
psql_or_bail(1, "ALTER TABLE spoc539_t9 ADD PRIMARY KEY (id)");
# Sticky path on the ADD PRIMARY KEY leaves it in both repsets; we now drop.
is(repsets_for('spoc539_t9'), 'default_insert_only,spoc539_insonly',
   'T9: table starts in default_insert_only + custom insert-only with PK');
psql_or_bail(1, "ALTER TABLE spoc539_t9 DROP CONSTRAINT spoc539_t9_pkey");
is(repsets_for('spoc539_t9'), 'default_insert_only,spoc539_insonly',
   'T9: PK drop on insert-only-only membership leaves placement alone');

destroy_cluster();
