--PRIMARY KEY
SELECT * FROM spock_regress_variables()
\gset

-- This is to ensure that the test runs with the correct configuration
\c :provider_dsn
ALTER SYSTEM SET spock.check_all_uc_indexes = true;
ALTER SYSTEM SET spock.exception_behaviour = sub_disable;
SELECT pg_reload_conf();

\c :subscriber_dsn
ALTER SYSTEM SET spock.check_all_uc_indexes = true;
ALTER SYSTEM SET spock.exception_behaviour = sub_disable;
SELECT pg_reload_conf();

\c :provider_dsn

-- testing update of primary key
-- create  table with primary key and 3 other tables referencing it
SELECT spock.replicate_ddl($$
CREATE TABLE public.pk_users (
    id integer PRIMARY KEY,
    another_id integer unique not null,
    a_id integer,
    name text,
    address text
);

--pass
$$);

SELECT * FROM spock.repset_add_table('default', 'pk_users');

INSERT INTO pk_users VALUES(1,11,1,'User1', 'Address1');
INSERT INTO pk_users VALUES(2,12,1,'User2', 'Address2');
INSERT INTO pk_users VALUES(3,13,2,'User3', 'Address3');
INSERT INTO pk_users VALUES(4,14,2,'User4', 'Address4');

SELECT * FROM pk_users ORDER BY id;

SELECT attname, attnotnull, attisdropped from pg_attribute where attrelid = 'pk_users'::regclass and attnum > 0 order by attnum;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM pk_users ORDER BY id;

\c :provider_dsn

UPDATE pk_users SET address='UpdatedAddress1' WHERE id=1;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM pk_users ORDER BY id;

-- Set up for secondary unique index and two-index
-- conflict handling cases.
INSERT INTO pk_users VALUES (5000,5000,0,'sub1',NULL);
INSERT INTO pk_users VALUES (6000,6000,0,'sub2',NULL);
\c :provider_dsn
-- Resolve a conflict on the secondary unique constraint
INSERT INTO pk_users VALUES (5001,5000,1,'pub1',NULL);
-- And a conflict that violates two constraints
INSERT INTO pk_users VALUES (6000,6000,1,'pub2',NULL);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM pk_users WHERE id IN (5000,5001,6000) ORDER BY id;

\c :provider_dsn
DELETE FROM pk_users WHERE id IN (5000,5001,6000);

\set VERBOSITY terse

SELECT spock.replicate_ddl($$
CREATE UNIQUE INDEX another_id_temp_idx ON public.pk_users (another_id);
ALTER TABLE public.pk_users DROP CONSTRAINT pk_users_pkey,
    ADD CONSTRAINT pk_users_pkey PRIMARY KEY USING INDEX another_id_temp_idx;

ALTER TABLE public.pk_users DROP CONSTRAINT pk_users_another_id_key;
$$);

SELECT attname, attnotnull, attisdropped from pg_attribute where attrelid = 'pk_users'::regclass and attnum > 0 order by attnum;

UPDATE pk_users SET address='UpdatedAddress2' WHERE id=2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT attname, attnotnull, attisdropped from pg_attribute where attrelid = 'pk_users'::regclass and attnum > 0 order by attnum;

SELECT * FROM pk_users ORDER BY id;

\c :provider_dsn
UPDATE pk_users SET address='UpdatedAddress3' WHERE another_id=12;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM pk_users ORDER BY id;

\c :provider_dsn
UPDATE pk_users SET address='UpdatedAddress4' WHERE a_id=2;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

INSERT INTO pk_users VALUES(4,15,2,'User5', 'Address5');
-- subscriber now has duplicated value in id field while provider does not
SELECT * FROM pk_users ORDER BY id;

\c :provider_dsn
\set VERBOSITY terse

SELECT quote_literal(pg_current_wal_lsn()) as curr_lsn
\gset

SELECT spock.replicate_ddl($$
CREATE UNIQUE INDEX id_temp_idx ON public.pk_users (id);
ALTER TABLE public.pk_users DROP CONSTRAINT pk_users_pkey,
    ADD CONSTRAINT pk_users_pkey PRIMARY KEY USING INDEX id_temp_idx;
$$);

SELECT attname, attnotnull, attisdropped from pg_attribute where attrelid = 'pk_users'::regclass and attnum > 0 order by attnum;

SELECT spock.wait_slot_confirm_lsn(NULL, :curr_lsn);

\c :subscriber_dsn
SELECT attname, attnotnull, attisdropped from pg_attribute where attrelid = 'pk_users'::regclass and attnum > 0 order by attnum;

select status from spock.sub_show_status();

\c :provider_dsn

-- Wait for subscription to disconnect. It will have been bouncing already
-- due to apply worker restarts, but if it was retrying it'll stay down
-- this time.
DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF (SELECT count(1) FROM pg_replication_slots WHERE active = false) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT data::json->'action' as action, CASE WHEN data::json->>'action' IN ('I', 'D', 'U') THEN json_extract_path(data::json, 'relation') END as data FROM pg_logical_slot_get_changes((SELECT slot_name FROM pg_replication_slots), NULL, 1, 'min_proto_version', '3', 'max_proto_version', '4', 'startup_params_format', '1', 'proto_format', 'json', 'spock.replication_set_names', 'default,ddl_sql')
WHERE data IS NOT NULL AND data <> '';

SELECT data::json->'action' as action, CASE WHEN data::json->>'action' IN ('I', 'D', 'U') THEN data END as data FROM pg_logical_slot_get_changes((SELECT slot_name FROM pg_replication_slots), NULL, 1, 'min_proto_version', '3', 'max_proto_version', '4', 'startup_params_format', '1', 'proto_format', 'json', 'spock.replication_set_names', 'default,ddl_sql')
WHERE data IS NOT NULL AND data <> '';

\c :subscriber_dsn

DELETE FROM pk_users WHERE id = 4;-- remove the offending entries.
SELECT spock.sub_enable('test_subscription', true);

\c :provider_dsn

DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF (SELECT count(1) FROM pg_replication_slots WHERE active = true) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;
UPDATE pk_users SET address='UpdatedAddress2' WHERE id=2;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM pk_users ORDER BY id;

\c :provider_dsn

--
-- Test to show that we don't defend against alterations to tables
-- that will break replication once added to a repset, or prevent
-- dml that would break on apply.
--
-- See 2ndQuadrant/spock_internal#146
--

-- Show that the current PK is not marked 'indisreplident' because we use
-- REPLICA IDENTITY DEFAULT
SELECT indisreplident FROM pg_index WHERE indexrelid = 'pk_users_pkey'::regclass;
SELECT relreplident FROM pg_class WHERE oid = 'pk_users'::regclass;

SELECT spock.replicate_ddl($$
ALTER TABLE public.pk_users DROP CONSTRAINT pk_users_pkey;
$$);

INSERT INTO pk_users VALUES(90,0,0,'User90', 'Address90');

-- spock will stop us adding the table to a repset if we try to,
-- but didn't stop us altering it, and won't stop us updating it...
BEGIN;
SELECT * FROM spock.repset_remove_table('default', 'pk_users');
SELECT * FROM spock.repset_add_table('default', 'pk_users');
ROLLBACK;

--
-- Previously this would cause an error on the subscriber:
--      remote UPDATE on relation public.pk_users (tuple not found).
-- In Spock's, this will be caught and the subscription will be disabled when
-- spock.exception_behaviour = sub_disable is set.
--
UPDATE pk_users SET id = 91 WHERE id = 90;

-- feth xid of the last 'U' action
SELECT fetch_last_xid('U') AS remote_xid \gset

-- To carry on we'll need to make the index on the downstream
-- We need to skip the last 'U' action that caused the subscription to be disabled.
-- Its done by altering the subscription to skip the last 'U' action and the error
-- message from the exception log is used to find the skip_lsn.
\c :subscriber_dsn
SELECT skiplsn_and_enable_sub('test_subscription', :remote_xid);

ALTER TABLE public.pk_users
    ADD CONSTRAINT pk_users_pkey PRIMARY KEY (id) NOT DEFERRABLE;

\c :provider_dsn

ALTER TABLE public.pk_users
    ADD CONSTRAINT pk_users_pkey PRIMARY KEY (id) NOT DEFERRABLE;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);




-- Demonstrate that deferrable indexes aren't yet supported for updates on downstream
-- and will fail with an informative error.
SELECT spock.replicate_ddl($$
ALTER TABLE public.pk_users
    DROP CONSTRAINT pk_users_pkey,
    ADD CONSTRAINT pk_users_pkey PRIMARY KEY (id) DEFERRABLE INITIALLY DEFERRED;
$$);

-- Not allowed, deferrable
ALTER TABLE public.pk_users REPLICA IDENTITY USING INDEX pk_users_pkey;

-- New index isn't REPLICA IDENTITY either
SELECT indisreplident FROM pg_index WHERE indexrelid = 'pk_users_pkey'::regclass;

-- spock won't let us add the table to a repset, though
-- it doesn't stop us altering it; see 2ndQuadrant/spock_internal#146
BEGIN;
SELECT * FROM spock.repset_remove_table('default', 'pk_users');
SELECT * FROM spock.repset_add_table('default', 'pk_users');
ROLLBACK;

-- We can still INSERT (which is fine)
INSERT INTO pk_users VALUES(100,0,0,'User100', 'Address100');

-- FIXME spock shouldn't allow this, no valid replica identity exists
-- see 2ndQuadrant/spock_internal#146
UPDATE pk_users SET id = 101 WHERE id = 100;

-- Must time out, apply will fail on downstream due to no replident index
BEGIN;
SET LOCAL statement_timeout = '2s';
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
ROLLBACK;

\c :subscriber_dsn

-- entry 100 must be absent since we can't apply it without
-- a suitable pk
SELECT id FROM pk_users WHERE id IN (90, 91, 100, 101) ORDER BY id;

SELECT spock.sub_show_status();

-- we can recover by re-creating the pk as non-deferrable
ALTER TABLE public.pk_users DROP CONSTRAINT pk_users_pkey,
    ADD CONSTRAINT pk_users_pkey PRIMARY KEY (id) NOT DEFERRABLE;


-- then replay. Toggle the subscription's enabled state
-- to make it recover faster for a quicker test run.
-- sub is already disabled due to the previous
SELECT spock.sub_enable('test_subscription', true);
-- \c :provider_dsn
-- SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT id FROM pk_users WHERE id IN (90, 91, 100, 101) ORDER BY id;

\c :provider_dsn
-- Subscriber and provider have diverged due to inability to replicate
-- the UPDATEs
SELECT id FROM pk_users WHERE id IN (90, 91, 100, 101) ORDER BY id;

\c :provider_dsn
-- feth xid of the last 'U' action
SELECT fetch_last_xid('U') AS remote_xid \gset

-- To carry on we'll need to make the index on the downstream
-- We need to skip the last 'U' action that caused the subscription to be disabled.
-- Its done by altering the subscription to skip the last 'U' action and the error
-- message from the exception log is used to find the skip_lsn.
\c :subscriber_dsn
SELECT skiplsn_and_enable_sub('test_subscription', :remote_xid);

-- Demonstrate that we properly handle wide conflict rows
\c :subscriber_dsn

INSERT INTO pk_users (id, another_id, address)
VALUES (200,2000,repeat('waah daah sooo mooo', 1000));

\c :provider_dsn
INSERT INTO pk_users (id, another_id, address)
VALUES (200,2000,repeat('boop boop doop boop', 1000));

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- wait until subscription status updated.
DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF (SELECT count(1) FROM spock.subscription WHERE sub_enabled = true) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT id, another_id, left(address,30) AS address_abbrev
FROM pk_users WHERE another_id = 2000;

-- DELETE conflicts; the DELETE is discarded
\c :subscriber_dsn
DELETE FROM pk_users WHERE id = 1;
\c :provider_dsn
DELETE FROM pk_users WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- UPDATE conflicts violating multiple constraints.
-- For this one we need to put the secondary unique
-- constraint back.
TRUNCATE TABLE pk_users;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
SELECT spock.replicate_ddl($$
  CREATE UNIQUE INDEX pk_users_another_id_idx ON public.pk_users(another_id);
$$);
\c :subscriber_dsn
INSERT INTO pk_users VALUES
(1,10,0,'sub',NULL),
(2,20,0,'sub',NULL);
\c :provider_dsn
INSERT INTO pk_users VALUES
(3,11,1,'pub',NULL),
(4,22,1,'pub',NULL);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT * FROM pk_users ORDER BY id;
\c :provider_dsn
-- UPDATE one of our upstream tuples to violate both constraints on the
-- downstream. The constraints are independent but there's only one existing
-- downstream tuple that violates both constraints. We'll match it by replica
-- identity, replace it, and satisfy the other constraint in the process.
UPDATE pk_users SET id=1, another_id = 10, name='should_error' WHERE id = 3 AND another_id = 11;
SELECT * FROM pk_users ORDER BY id;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT spock.sub_show_status();
SELECT * FROM pk_users ORDER BY id;

-- UPDATEs to missing rows could either resurrect the row or conclude it
-- shouldn't exist and discard it. Currently spk unconditionally discards, so
-- this row's name is a misnomer.
\c :subscriber_dsn
SELECT spock.sub_show_status();
DELETE FROM pk_users WHERE id = 4 AND another_id = 22;
\c :provider_dsn
UPDATE pk_users SET name = 'jesus' WHERE id = 4;

-- fetch xid of the last 'U' action
SELECT fetch_last_xid('U') AS remote_xid \gset
--SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT spock.sub_show_status();     -- SUB is disabled due to the previous UPDATE
SELECT skiplsn_and_enable_sub('test_subscription', :remote_xid);

-- No resurrection here
SELECT * FROM pk_users ORDER BY id;

-- But if the UPDATE would create a row that violates
-- a secondary unique index (but doesn't match the replident)
-- we'll ERROR on the secondary index.
INSERT INTO pk_users VALUES (5,55,0,'sub',NULL);
\c :provider_dsn
INSERT INTO pk_users VALUES (6,66,0,'sub',NULL);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
-- The new row (6,55) will conflict with (5,55)
UPDATE pk_users SET another_id = 55, name = 'pub_should_error' WHERE id = 6;
SELECT * FROM pk_users ORDER BY id;
-- We'll time out due to apply errors
BEGIN;
SET LOCAL statement_timeout = '2s';
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
ROLLBACK;
-- This time we'll fix it by deleting the conflicting row
-- Since SUB is disabled, DELETE the row on the subscriber
-- and then re-enable the subscription.
\c :subscriber_dsn
SELECT spock.sub_show_status();
SELECT * FROM pk_users ORDER BY id;
DELETE FROM pk_users WHERE id = 5;
SELECT spock.sub_enable('test_subscription', true);
\c :provider_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn
SELECT * FROM pk_users ORDER BY id;



\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.pk_users CASCADE;
$$);

-- Reset the configuration to the default value
\c :provider_dsn
ALTER SYSTEM SET spock.check_all_uc_indexes = false;
ALTER SYSTEM SET spock.exception_behaviour = transdiscard;
SELECT pg_reload_conf();

\c :subscriber_dsn
ALTER SYSTEM SET spock.check_all_uc_indexes = false;
ALTER SYSTEM SET spock.exception_behaviour = transdiscard;
SELECT pg_reload_conf();
