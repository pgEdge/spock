use strict;
use warnings;
use Test::More;
use lib '.';
use lib 't';
use SpockTest qw(create_cluster destroy_cluster cross_wire
                 scalar_query psql_or_bail wait_for_exception_log);

# =============================================================================
# 040_missing_update_to_insert.pl - spock.missing_update_to_insert
#
# An UPDATE message carries every replicated column of the new row, not just
# the ones the statement touched.  The single exception is a column whose value
# is an unchanged TOAST pointer: logical decoding sends 'u' for it, because the
# toast chunks were never written to WAL for this update and may already have
# been vacuumed away.
#
# So when the row to be updated is missing locally, the whole row can usually
# be rebuilt and inserted instead of failing.  spock.missing_update_to_insert
# turns that on.  When the tuple does carry a 'u' column it must still fail:
# inserting would silently store NULL where a large value belongs.
#
# Covered here:
#   a  GUC off               -> UPDATE of a missing row still fails
#   b  GUC on                -> row is reinserted with every column intact
#   c  GUC on, row present   -> ordinary UPDATE path, unaffected
#   d  GUC on, key moved onto an existing local row
#                            -> resolved as an insert conflict, not a
#                               duplicate-key error
#   e  GUC on, unchanged TOAST column
#                            -> refused; no row with a NULL in its place
#   f  GUC on, subscriber-only column with a DEFAULT
#                            -> DEFAULT applied, not NULL
#   g  spock.resolutions records update_missing / apply_remote
#   h  GUC on, subscriber-only NOT NULL column with no default
#                            -> fails, same as a plain INSERT would
#   j  GUC on, unchanged TOAST column marked LOG_OLD_VALUE
#                            -> converts anyway: the old value is in the
#                               UPDATE's old tuple, and unchanged means the
#                               old value is the new value
#   k  GUC on, two unchanged TOAST columns, only one logged
#                            -> still refuses; partial recovery is not enough
#   i  GUC on, a newer local DELETE races the UPDATE
#                            -> the row comes back.  Known gap: spock does not
#                               yet track tombstones, so the conversion cannot
#                               tell a newer DELETE from a reordered INSERT.
# =============================================================================

# The cases we expect to fail cost an apply-worker restart each: the first
# attempt raises the error and the worker exits, and only the retry runs under
# the exception handler that writes spock.exception_log.  Allow for that.
my $TIMEOUT = $ENV{SPOCK_MUI_TIMEOUT} // 90;

# Poll until $query on $node returns $want, or give up.  Returns the last value
# seen so a failing test can report it.
sub wait_for_value {
    my ($node, $query, $want) = @_;
    my $got;
    for (1 .. $TIMEOUT) {
        $got = scalar_query($node, $query);
        $got = '' unless defined $got;
        return $got if $got eq $want;
        sleep(1);
    }
    return $got;
}

# Push a marker row through and wait for it.  Proves the apply worker is still
# making progress after a transaction we expect to fail.
my $marker = 0;
sub replication_still_flowing {
    my ($label) = @_;
    $marker++;
    psql_or_bail(1, "INSERT INTO public.mui_marker (id) VALUES ($marker)");
    my $got = wait_for_value(2,
        "SELECT count(*) FROM public.mui_marker WHERE id = $marker", '1');
    is($got, '1', "replication still flowing after $label");
}

create_cluster(2, 'Create 2-node Spock cluster');
cross_wire(2, ['n1', 'n2'], 'Cross-wire nodes n1 and n2');

# Make replication one-directional, n1 -> n2, so the local deletes we make on
# n2 to manufacture "missing row" are not replicated back to n1.
psql_or_bail(1, "SELECT spock.sub_drop('sub_n1_n2')");
sleep(3);

# discard, not sub_disable: the cases we expect to fail should log an exception
# and let replication carry on, so the rest of the test can run.  Also turn on
# the resolutions log for case (g).
psql_or_bail(2, "ALTER SYSTEM SET spock.exception_behaviour = 'discard'");
psql_or_bail(2, "ALTER SYSTEM SET spock.save_resolutions = on");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(2);
is(scalar_query(2, "SHOW spock.exception_behaviour"), 'discard',
   "n2 exception_behaviour is discard");
is(scalar_query(2, "SHOW spock.missing_update_to_insert"), 'on',
   "n2 spock.missing_update_to_insert defaults to on");

# Case (a) needs it off, so turn it off explicitly rather than leaning on the
# default.
psql_or_bail(2, "ALTER SYSTEM SET spock.missing_update_to_insert = off");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(2);
is(scalar_query(2, "SHOW spock.missing_update_to_insert"), 'off',
   "n2 spock.missing_update_to_insert turned off for case (a)");

psql_or_bail(1, "CREATE TABLE public.mui_marker (id int PRIMARY KEY)");
psql_or_bail(1, "CREATE TABLE public.mui_basic (id int PRIMARY KEY, a text, b int)");
psql_or_bail(1, "CREATE TABLE public.mui_toast (id int PRIMARY KEY, small text, big text)");
psql_or_bail(1, "ALTER TABLE public.mui_toast ALTER COLUMN big SET STORAGE EXTERNAL");
psql_or_bail(1, "CREATE TABLE public.mui_extra (id int PRIMARY KEY, a text)");
psql_or_bail(1, "CREATE TABLE public.mui_req (id int PRIMARY KEY, a text)");
psql_or_bail(1, "CREATE TABLE public.mui_race (id int PRIMARY KEY, a text)");
psql_or_bail(1, "CREATE TABLE public.mui_lov (id int PRIMARY KEY, small text, big text)");
psql_or_bail(1, "ALTER TABLE public.mui_lov ALTER COLUMN big SET STORAGE EXTERNAL");
psql_or_bail(1, "ALTER TABLE public.mui_lov ALTER COLUMN big SET (log_old_value = true)");
psql_or_bail(1, "CREATE TABLE public.mui_lov2 (id int PRIMARY KEY, small text, big1 text, big2 text)");
psql_or_bail(1, "ALTER TABLE public.mui_lov2 ALTER COLUMN big1 SET STORAGE EXTERNAL");
psql_or_bail(1, "ALTER TABLE public.mui_lov2 ALTER COLUMN big2 SET STORAGE EXTERNAL");
psql_or_bail(1, "ALTER TABLE public.mui_lov2 ALTER COLUMN big1 SET (log_old_value = true)");

is(wait_for_value(2,
     "SELECT count(*) FROM pg_class WHERE relkind = 'r' AND relname IN "
   . "('mui_marker', 'mui_basic', 'mui_toast', 'mui_extra', 'mui_req', "
   . "'mui_race', 'mui_lov', 'mui_lov2')", '8'),
   '8', "all test tables replicated to n2");

# n2 gains two columns that n1 does not have, so n1 never sends them.
# DDL replication is disabled for these statements so they stay local to n2.
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.mui_extra ADD COLUMN note text DEFAULT 'defaulted'");
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.mui_req ADD COLUMN req text NOT NULL DEFAULT 'seed'");
psql_or_bail(2, "SET spock.enable_ddl_replication = off; "
              . "ALTER TABLE public.mui_req ALTER COLUMN req DROP DEFAULT");

# -----------------------------------------------------------------------------
# (a) GUC off: an UPDATE whose row is missing still fails.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_basic VALUES (1, 'one', 1)");
is(wait_for_value(2, "SELECT count(*) FROM public.mui_basic WHERE id = 1", '1'),
   '1', "(a) row 1 replicated to n2");

psql_or_bail(2, "DELETE FROM public.mui_basic WHERE id = 1");
psql_or_bail(1, "UPDATE public.mui_basic SET b = 99 WHERE id = 1");

ok(wait_for_exception_log(2,
     "table_name = 'mui_basic' AND operation = 'UPDATE'", $TIMEOUT),
   "(a) GUC off: missing-row UPDATE logged an exception");
is(scalar_query(2, "SELECT count(*) FROM public.mui_basic WHERE id = 1"), '0',
   "(a) GUC off: row 1 was not inserted on n2");
replication_still_flowing("(a)");

# -----------------------------------------------------------------------------
# Turn the feature on for everything below.
# -----------------------------------------------------------------------------
psql_or_bail(2, "ALTER SYSTEM RESET spock.missing_update_to_insert");
psql_or_bail(2, "SELECT pg_reload_conf()");
sleep(2);
is(scalar_query(2, "SHOW spock.missing_update_to_insert"), 'on',
   "n2 spock.missing_update_to_insert back on");

# -----------------------------------------------------------------------------
# (b) GUC on: the row is rebuilt in full and inserted.
#     'a' is not touched by the UPDATE, so this also proves untouched columns
#     really do arrive on the wire.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_basic VALUES (2, 'two', 2)");
is(wait_for_value(2, "SELECT count(*) FROM public.mui_basic WHERE id = 2", '1'),
   '1', "(b) row 2 replicated to n2");

psql_or_bail(2, "DELETE FROM public.mui_basic WHERE id = 2");
psql_or_bail(1, "UPDATE public.mui_basic SET b = 22 WHERE id = 2");

is(wait_for_value(2, "SELECT a || '/' || b FROM public.mui_basic WHERE id = 2",
                  'two/22'),
   'two/22', "(b) GUC on: missing row reinserted with all columns intact");

# -----------------------------------------------------------------------------
# (g) the conversion is recorded in spock.resolutions.
# -----------------------------------------------------------------------------
is(wait_for_value(2,
     "SELECT count(*) FROM spock.resolutions "
   . "WHERE relname LIKE '%mui_basic%' AND conflict_type = 'update_missing' "
   . "AND conflict_resolution = 'apply_remote'", '1'),
   '1', "(g) resolution logged as update_missing / apply_remote");

# -----------------------------------------------------------------------------
# (c) GUC on, row present: the ordinary UPDATE path is untouched.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_basic VALUES (3, 'three', 3)");
is(wait_for_value(2, "SELECT count(*) FROM public.mui_basic WHERE id = 3", '1'),
   '1', "(c) row 3 replicated to n2");
psql_or_bail(1, "UPDATE public.mui_basic SET b = 33 WHERE id = 3");
is(wait_for_value(2, "SELECT a || '/' || b FROM public.mui_basic WHERE id = 3",
                  'three/33'),
   'three/33', "(c) GUC on: existing row still updated normally");

# -----------------------------------------------------------------------------
# (d) GUC on, the UPDATE moves the key onto a row that exists locally.
#     The search that failed used the OLD key; the conversion must search again
#     with the new one, or this is a duplicate-key error.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_basic VALUES (10, 'ten', 10)");
is(wait_for_value(2, "SELECT count(*) FROM public.mui_basic WHERE id = 10", '1'),
   '1', "(d) row 10 replicated to n2");

psql_or_bail(2, "DELETE FROM public.mui_basic WHERE id = 10");
psql_or_bail(2, "INSERT INTO public.mui_basic VALUES (20, 'local-20', 999)");
sleep(1);
psql_or_bail(1, "UPDATE public.mui_basic SET id = 20 WHERE id = 10");

is(wait_for_value(2, "SELECT a || '/' || b FROM public.mui_basic WHERE id = 20",
                  'ten/10'),
   'ten/10', "(d) key moved onto an existing local row: remote tuple won");
is(scalar_query(2, "SELECT count(*) FROM public.mui_basic WHERE id = 20"), '1',
   "(d) exactly one row with the new key");
replication_still_flowing("(d)");

# -----------------------------------------------------------------------------
# (f) GUC on, subscriber-only column with a DEFAULT.
#     No local row to copy it from, so the DEFAULT must be evaluated.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_extra VALUES (1, 'x')");
is(wait_for_value(2, "SELECT note FROM public.mui_extra WHERE id = 1",
                  'defaulted'),
   'defaulted', "(f) subscriber-only column defaulted on the initial INSERT");

psql_or_bail(2, "DELETE FROM public.mui_extra WHERE id = 1");
psql_or_bail(1, "UPDATE public.mui_extra SET a = 'y' WHERE id = 1");

is(wait_for_value(2, "SELECT a || '/' || note FROM public.mui_extra WHERE id = 1",
                  'y/defaulted'),
   'y/defaulted', "(f) converted INSERT applied the local DEFAULT, not NULL");

# -----------------------------------------------------------------------------
# (e) GUC on, unchanged TOAST column: must refuse rather than store NULL.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_toast "
              . "VALUES (1, 'small', repeat('x', 200000))");
is(wait_for_value(2, "SELECT length(big) FROM public.mui_toast WHERE id = 1",
                  '200000'),
   '200000', "(e) toasted row replicated to n2");

psql_or_bail(2, "DELETE FROM public.mui_toast WHERE id = 1");
# 'big' is not touched, so it arrives as an unchanged TOAST pointer ('u').
psql_or_bail(1, "UPDATE public.mui_toast SET small = 'changed' WHERE id = 1");

ok(wait_for_exception_log(2,
     "table_name = 'mui_toast' AND operation = 'UPDATE'", $TIMEOUT),
   "(e) unchanged TOAST column: conversion refused, exception logged");
is(scalar_query(2, "SELECT count(*) FROM public.mui_toast WHERE id = 1"), '0',
   "(e) no row inserted with a NULL where the TOAST value belongs");
is(scalar_query(2, "SELECT count(*) FROM public.mui_toast WHERE big IS NULL"), '0',
   "(e) no row anywhere has a NULL big column");
replication_still_flowing("(e)");

# -----------------------------------------------------------------------------
# (j) Same as (e), but 'big' is marked LOG_OLD_VALUE, so its old value is
#     WAL-logged (flattened) with every UPDATE and travels in the old tuple.
#     Unchanged means old value == new value, so the conversion recovers it
#     and proceeds.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_lov "
              . "VALUES (1, 'small', repeat('y', 200000))");
is(wait_for_value(2, "SELECT length(big) FROM public.mui_lov WHERE id = 1",
                  '200000'),
   '200000', "(j) toasted row replicated to n2");

psql_or_bail(2, "DELETE FROM public.mui_lov WHERE id = 1");
psql_or_bail(1, "UPDATE public.mui_lov SET small = 'changed' WHERE id = 1");

is(wait_for_value(2,
     "SELECT small || '/' || length(big) FROM public.mui_lov WHERE id = 1",
     'changed/200000'),
   'changed/200000',
   "(j) LOG_OLD_VALUE column recovered, missing row reinserted in full");
is(scalar_query(2,
     "SELECT count(*) FROM public.mui_lov "
   . "WHERE big <> repeat('y', 200000)"), '0',
   "(j) recovered TOAST value is byte-identical");

# -----------------------------------------------------------------------------
# (k) Two unchanged TOAST columns, only big1 logged.  big2 stays
#     unrecoverable, so the conversion must refuse -- partially rebuilt rows
#     are worse than a loud failure.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_lov2 "
              . "VALUES (1, 'small', repeat('a', 200000), repeat('b', 200000))");
is(wait_for_value(2, "SELECT length(big2) FROM public.mui_lov2 WHERE id = 1",
                  '200000'),
   '200000', "(k) two-TOAST row replicated to n2");

psql_or_bail(2, "DELETE FROM public.mui_lov2 WHERE id = 1");
psql_or_bail(1, "UPDATE public.mui_lov2 SET small = 'changed' WHERE id = 1");

ok(wait_for_exception_log(2,
     "table_name = 'mui_lov2' AND operation = 'UPDATE'", $TIMEOUT),
   "(k) partially recoverable tuple refused, exception logged");
is(scalar_query(2, "SELECT count(*) FROM public.mui_lov2 WHERE id = 1"), '0',
   "(k) no partially rebuilt row inserted");
replication_still_flowing("(k)");

# -----------------------------------------------------------------------------
# (h) GUC on, subscriber-only NOT NULL column with no default.  Nothing can
#     supply a value, so this fails exactly as a plain INSERT would.  Documents
#     the limit rather than pretending the conversion can work around it.
# -----------------------------------------------------------------------------
psql_or_bail(2, "INSERT INTO public.mui_req VALUES (1, 'seeded', 'r')");
psql_or_bail(1, "INSERT INTO public.mui_req VALUES (1, 'a')");   # insert_exists
sleep(2);
psql_or_bail(2, "DELETE FROM public.mui_req WHERE id = 1");
psql_or_bail(1, "UPDATE public.mui_req SET a = 'b' WHERE id = 1");

ok(wait_for_exception_log(2,
     "table_name = 'mui_req' AND operation = 'UPDATE'", $TIMEOUT),
   "(h) NOT NULL subscriber-only column with no default: conversion fails");
is(scalar_query(2, "SELECT count(*) FROM public.mui_req WHERE id = 1"), '0',
   "(h) no row inserted on n2");
replication_still_flowing("(h)");

# -----------------------------------------------------------------------------
# (i) A DELETE newer than the UPDATE it races.  Spock does not yet track
#     tombstones, so the apply worker sees only "no local row" and rebuilds
#     it: the newer DELETE is undone.  Pinned here as a known gap, not as
#     desired behaviour.
#     Disabling the subscription is how we hold the UPDATE back so the DELETE
#     is provably the later of the two.
# -----------------------------------------------------------------------------
psql_or_bail(1, "INSERT INTO public.mui_race VALUES (1, 'seed')");
is(wait_for_value(2, "SELECT a FROM public.mui_race WHERE id = 1", 'seed'),
   'seed', "(i) row replicated to n2");

psql_or_bail(2, "SELECT spock.sub_disable('sub_n2_n1', true)");
sleep(2);
psql_or_bail(1, "UPDATE public.mui_race SET a = 'updated' WHERE id = 1");
sleep(2);
psql_or_bail(2, "DELETE FROM public.mui_race WHERE id = 1");   # strictly later
psql_or_bail(2, "SELECT spock.sub_enable('sub_n2_n1', true)");

is(wait_for_value(2, "SELECT a FROM public.mui_race WHERE id = 1", 'updated'),
   'updated', "(i) known gap: a newer local DELETE is undone by the conversion");
replication_still_flowing("(i)");

destroy_cluster('Destroy cluster');
done_testing();
