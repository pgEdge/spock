/* First test whether a table's replication set can be properly manipulated */

SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

CREATE TABLE public.test_publicschema(id serial primary key, data text);

\c :subscriber_dsn

CREATE TABLE public.test_publicschema(data text, id serial primary key);

\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE SCHEMA "strange.schema-IS";
CREATE TABLE public.test_nosync(id serial primary key, data text);
CREATE TABLE "strange.schema-IS".test_strangeschema(id serial primary key, "S0m3th1ng" timestamptz DEFAULT '1993-01-01 00:00:00 CET');
CREATE TABLE "strange.schema-IS".test_diff_repset(id serial primary key, data text DEFAULT '');
$$);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- create some replication sets
SELECT * FROM spock.repset_create('repset_test');

-- move tables to replication set that is not subscribed
SELECT * FROM spock.repset_add_table('repset_test', 'test_publicschema');
SELECT * FROM spock.repset_add_table('repset_test', 'test_nosync');
SELECT * FROM spock.repset_add_table('repset_test', '"strange.schema-IS".test_strangeschema');
SELECT * FROM spock.repset_add_table('repset_test', '"strange.schema-IS".test_diff_repset');
SELECT * FROM spock.repset_add_all_seqs('repset_test', '{public}');
SELECT * FROM spock.repset_add_seq('repset_test', pg_get_serial_sequence('"strange.schema-IS".test_strangeschema', 'id'));
SELECT * FROM spock.repset_add_seq('repset_test', pg_get_serial_sequence('"strange.schema-IS".test_diff_repset', 'id'));
SELECT * FROM spock.repset_add_all_seqs('default', '{public}');
SELECT * FROM spock.repset_add_seq('default', pg_get_serial_sequence('"strange.schema-IS".test_strangeschema', 'id'));
SELECT * FROM spock.repset_add_seq('default', pg_get_serial_sequence('"strange.schema-IS".test_diff_repset', 'id'));

INSERT INTO public.test_publicschema(data) VALUES('a');
INSERT INTO public.test_publicschema(data) VALUES('b');
INSERT INTO public.test_nosync(data) VALUES('a');
INSERT INTO public.test_nosync(data) VALUES('b');
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(DEFAULT, DEFAULT);
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(DEFAuLT, DEFAULT);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM public.test_publicschema;
\c :provider_dsn

-- move tables back to the subscribed replication set
SELECT * FROM spock.repset_add_table('default', 'test_publicschema', true);
SELECT * FROM spock.repset_add_table('default', 'test_nosync', false);
SELECT * FROM spock.repset_add_table('default', '"strange.schema-IS".test_strangeschema', true);


\c :subscriber_dsn
SET statement_timeout = '20s';
SELECT spock.table_wait_for_sync('test_subscription', 'test_publicschema');
SELECT spock.table_wait_for_sync('test_subscription', '"strange.schema-IS".test_strangeschema');
RESET statement_timeout;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

\c :provider_dsn
DO $$
-- give it 10 seconds to synchronize the tables
BEGIN
	FOR i IN 1..100 LOOP
		IF (SELECT count(1) FROM pg_replication_slots) = 1 THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT count(1) FROM pg_replication_slots;

INSERT INTO public.test_publicschema VALUES(3, 'c');
INSERT INTO public.test_publicschema VALUES(4, 'd');
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(3, DEFAULT);
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(4, DEFAULT);

SELECT spock.sync_seq(c.oid)
  FROM pg_class c, pg_namespace n
 WHERE c.relkind = 'S' AND c.relnamespace = n.oid AND n.nspname IN ('public', 'strange.schema-IS');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM public.test_publicschema;
SELECT * FROM "strange.schema-IS".test_strangeschema;

SELECT * FROM spock.sub_alter_sync('test_subscription');

BEGIN;
SET statement_timeout = '20s';
SELECT spock.sub_resync_table('test_subscription', 'test_nosync');
COMMIT;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

SELECT * FROM public.test_nosync;

DELETE FROM public.test_publicschema WHERE id > 1;
SELECT * FROM public.test_publicschema;

SELECT * FROM spock.sub_resync_table('test_subscription', 'test_publicschema');

BEGIN;
SET statement_timeout = '20s';
SELECT spock.table_wait_for_sync('test_subscription', 'test_publicschema');
COMMIT;

SELECT sync_kind, sync_subid, sync_nspname, sync_relname, sync_status IN ('y', 'r') FROM spock.local_sync_status ORDER BY 2,3,4;

SELECT * FROM public.test_publicschema;

\x
SELECT nspname, relname, status IN ('synchronized', 'replicating') FROM spock.sub_show_table('test_subscription', 'test_publicschema');
\x

BEGIN;
SELECT * FROM spock.sub_add_repset('test_subscription', 'repset_test');
SELECT * FROM spock.sub_remove_repset('test_subscription', 'default');
COMMIT;

DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status = 'replicating') THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

\c :provider_dsn
SELECT * FROM spock.repset_remove_table('repset_test', '"strange.schema-IS".test_strangeschema');

INSERT INTO "strange.schema-IS".test_diff_repset VALUES(1);
INSERT INTO "strange.schema-IS".test_diff_repset VALUES(2);

INSERT INTO "strange.schema-IS".test_strangeschema VALUES(5, DEFAULT);
INSERT INTO "strange.schema-IS".test_strangeschema VALUES(6, DEFAULT);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM "strange.schema-IS".test_diff_repset;
SELECT * FROM "strange.schema-IS".test_strangeschema;

\c :provider_dsn

SELECT * FROM spock.repset_alter('repset_test', replicate_insert := false, replicate_update := false, replicate_delete := false, replicate_truncate := false);

INSERT INTO "strange.schema-IS".test_diff_repset VALUES(3);
INSERT INTO "strange.schema-IS".test_diff_repset VALUES(4);
UPDATE "strange.schema-IS".test_diff_repset SET data = 'data';
DELETE FROM "strange.schema-IS".test_diff_repset WHERE id < 3;
TRUNCATE "strange.schema-IS".test_diff_repset;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM "strange.schema-IS".test_diff_repset;

\c :provider_dsn

SELECT * FROM spock.repset_alter('repset_test', replicate_insert := true, replicate_truncate := true);

INSERT INTO "strange.schema-IS".test_diff_repset VALUES(5);
INSERT INTO "strange.schema-IS".test_diff_repset VALUES(6);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM "strange.schema-IS".test_diff_repset;

\c :provider_dsn

TRUNCATE "strange.schema-IS".test_diff_repset;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM "strange.schema-IS".test_diff_repset;

SELECT * FROM spock.sub_add_repset('test_subscription', 'default');

DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status = 'replicating') THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT N.nspname AS schemaname, C.relname AS tablename, (nextval(C.oid) > 1000) as synced
  FROM pg_class C JOIN pg_namespace N ON (N.oid = C.relnamespace)
 WHERE C.relkind = 'S' AND N.nspname IN ('public', 'strange.schema-IS')
 ORDER BY 1, 2;

\c :provider_dsn

DO $$
BEGIN
	FOR i IN 1..100 LOOP
		IF EXISTS (SELECT 1 FROM pg_stat_replication) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.test_publicschema CASCADE;
	DROP TABLE public.test_nosync CASCADE;
	DROP SCHEMA "strange.schema-IS" CASCADE;
$$);


SELECT spock.replicate_ddl($$
	CREATE TABLE public.synctest(a int primary key, b text);
$$);

SELECT * FROM spock.repset_add_table('repset_test', 'synctest', synchronize_data := false);

INSERT INTO synctest VALUES (1, '1');

-- no way to see if this worked currently, but if one can manually check
-- if there is conflict in log or not (conflict = bad here)
SELECT spock.replicate_ddl($$
	SELECT pg_sleep(5);
	UPDATE public.synctest SET b = md5(a::text);
$$);

INSERT INTO synctest VALUES (2, '2');

\c :subscriber_dsn

SELECT * FROM spock.sub_resync_table('test_subscription', 'synctest');

BEGIN;
SET statement_timeout = '20s';
SELECT spock.sub_resync_table('test_subscription', 'synctest');
COMMIT;

\c :provider_dsn

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

SELECT * FROM synctest;

\c :subscriber_dsn

SELECT * FROM synctest;

\c :provider_dsn

\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.synctest CASCADE;
$$);

\c :subscriber_dsn

-- this is to reorder repsets to default order
BEGIN;
SELECT * FROM spock.sub_remove_repset('test_subscription', 'default');
SELECT * FROM spock.sub_remove_repset('test_subscription', 'ddl_sql');
SELECT * FROM spock.sub_remove_repset('test_subscription', 'default_insert_only');
SELECT * FROM spock.sub_remove_repset('test_subscription', 'repset_test');
SELECT * FROM spock.sub_add_repset('test_subscription', 'default');
SELECT * FROM spock.sub_add_repset('test_subscription', 'default_insert_only');
SELECT * FROM spock.sub_add_repset('test_subscription', 'ddl_sql');
COMMIT;
