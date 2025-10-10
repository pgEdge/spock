--Immutable, volatile functions and nextval in DEFAULT clause
SELECT * FROM spock_regress_variables()
\gset


\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE FUNCTION public.add(integer, integer) RETURNS integer
    AS 'select $1 + $2;'
    LANGUAGE SQL
    IMMUTABLE
    RETURNS NULL ON NULL INPUT;

CREATE TABLE public.funct2(
	a integer,
	b integer,
	c integer DEFAULT public.add(10,12 )
) ;
$$);

SELECT * FROM spock.repset_add_table('default_insert_only', 'public.funct2');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO public.funct2(a,b) VALUES (1,2);--c should be 22
INSERT INTO public.funct2(a,b,c) VALUES (3,4,5);-- c should be 5

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * from public.funct2;


\c :provider_dsn

SELECT spock.replicate_ddl($$
create or replace function public.get_curr_century() returns double precision as
 'SELECT EXTRACT(CENTURY FROM NOW());'
language sql volatile;

CREATE TABLE public.funct5(
	a integer,
	b integer,
	c double precision DEFAULT public.get_curr_century()
);
$$);

SELECT * FROM spock.repset_add_all_tables('default_insert_only', '{public}');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO public.funct5(a,b) VALUES (1,2);--c should be e.g. 21 for 2015
INSERT INTO public.funct5(a,b,c) VALUES (3,4,20);-- c should be 20

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * from public.funct5;

--nextval check
\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE SEQUENCE public.INSERT_SEQ;

CREATE TABLE public.funct (
	a integer,
	b INT DEFAULT nextval('public.insert_seq')
);
$$);

SELECT * FROM spock.repset_add_all_tables('default_insert_only', '{public}');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO public.funct (a) VALUES (1);
INSERT INTO public.funct (a) VALUES (2);
INSERT INTO public.funct (a) VALUES (3);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM public.funct;


\c :provider_dsn
BEGIN;
COMMIT;--empty transaction

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM public.funct;

-- test replication where the destination table has extra (nullable) columns that are not in the origin table
\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE TABLE public.nullcheck_tbl(
	id integer PRIMARY KEY,
	id1 integer,
	name text
) ;
$$);

SELECT * FROM spock.repset_add_table('default', 'nullcheck_tbl');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

INSERT INTO public.nullcheck_tbl(id,id1,name) VALUES (1,1,'name1');
INSERT INTO public.nullcheck_tbl(id,id1,name) VALUES (2,2,'name2');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM public.nullcheck_tbl;

ALTER TABLE public.nullcheck_tbl ADD COLUMN name1 text;

SELECT * FROM public.nullcheck_tbl;

\c :provider_dsn

INSERT INTO public.nullcheck_tbl(id,id1,name) VALUES (3,3,'name3');
INSERT INTO public.nullcheck_tbl(id,id1,name) VALUES (4,4,'name4');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM public.nullcheck_tbl;

\c :provider_dsn

UPDATE public.nullcheck_tbl SET name='name31' where id = 3;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

INSERT INTO public.nullcheck_tbl(id,id1,name) VALUES (6,6,'name6');
SELECT * FROM public.nullcheck_tbl;

\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE TABLE public.not_nullcheck_tbl(
	id integer PRIMARY KEY,
	id1 integer,
	name text
) ;
$$);

SELECT * FROM spock.repset_add_table('default', 'not_nullcheck_tbl');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

ALTER TABLE public.not_nullcheck_tbl ADD COLUMN id2 integer not null;

-- disable now to use pg_logical_slot_get_changes() later
SELECT spock.sub_disable('test_subscription', true);
-- Wait for the end of this operation
DO $$
BEGIN
    WHILE EXISTS (SELECT 1 FROM pg_replication_slots WHERE active = 'true')
	LOOP
    END LOOP;
END;$$;

\c :provider_dsn

SELECT quote_literal(pg_current_xlog_location()) as curr_lsn
\gset

INSERT INTO public.not_nullcheck_tbl(id,id1,name) VALUES (1,1,'name1');
INSERT INTO public.not_nullcheck_tbl(id,id1,name) VALUES (2,2,'name2');

\c :subscriber_dsn

SELECT * FROM public.not_nullcheck_tbl;
INSERT INTO public.not_nullcheck_tbl(id,id1,name) VALUES (3,3,'name3');
SELECT * FROM public.not_nullcheck_tbl;


\c :provider_dsn

DO $$
BEGIN
	FOR i IN 1..300 LOOP
		IF (SELECT count(1) FROM pg_replication_slots WHERE active = false) THEN
			RETURN;
		END IF;
		PERFORM pg_sleep(0.1);
	END LOOP;
END;
$$;

SELECT data::json->'action' as action, CASE WHEN data::json->>'action' IN ('I', 'D', 'U') THEN data END as data FROM pg_logical_slot_get_changes((SELECT slot_name FROM pg_replication_slots), NULL, 1, 'min_proto_version', '3', 'max_proto_version', '4', 'startup_params_format', '1', 'proto_format', 'json', 'spock.replication_set_names', 'default') WHERE LENGTH(data) > 0;
SELECT data::json->'action' as action, CASE WHEN data::json->>'action' IN ('I', 'D', 'U') THEN data END as data FROM pg_logical_slot_get_changes((SELECT slot_name FROM pg_replication_slots), NULL, 1, 'min_proto_version', '3', 'max_proto_version', '4', 'startup_params_format', '1', 'proto_format', 'json', 'spock.replication_set_names', 'default') WHERE LENGTH(data) > 0;

\c :subscriber_dsn

SELECT spock.sub_enable('test_subscription', true);
ALTER TABLE public.not_nullcheck_tbl ALTER COLUMN id2 SET default 99;

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

INSERT INTO public.not_nullcheck_tbl(id,id1,name) VALUES (4,4,'name4'); -- id2 will be 99 on subscriber
ALTER TABLE public.not_nullcheck_tbl ADD COLUMN id2 integer not null default 0;
INSERT INTO public.not_nullcheck_tbl(id,id1,name) VALUES (5,5,'name5'); -- id2 will be 0 on both
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM public.not_nullcheck_tbl;

\c :provider_dsn

SELECT spock.replicate_ddl($$
CREATE FUNCTION public.some_prime_numbers() RETURNS SETOF integer
	LANGUAGE sql IMMUTABLE STRICT LEAKPROOF
	AS $_$
  VALUES (2), (3), (5), (7), (11), (13), (17), (19), (23), (29), (31), (37), (41), (43), (47), (53), (59), (61), (67), (71), (73), (79), (83), (89), (97)
$_$;

CREATE FUNCTION public.is_prime_lt_100(integer) RETURNS boolean
    LANGUAGE sql IMMUTABLE STRICT LEAKPROOF
	AS $_$
  SELECT EXISTS (SELECT FROM public.some_prime_numbers() s(p) WHERE p = $1)
$_$;

CREATE DOMAIN public.prime AS integer
CONSTRAINT prime_check CHECK(public.is_prime_lt_100(VALUE));

CREATE TABLE public.prime_tbl (
	num public.prime NOT NULL,
	PRIMARY KEY(num)
);
$$);

SELECT * FROM spock.repset_add_table('default', 'public.prime_tbl');

INSERT INTO public.prime_tbl (num) VALUES(17), (31), (79);

DELETE FROM public.prime_tbl WHERE num = 31;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT num FROM public.prime_tbl;

\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl($$
	DROP TABLE public.funct CASCADE;
	DROP SEQUENCE public.INSERT_SEQ;
	DROP TABLE public.funct2 CASCADE;
	DROP TABLE public.funct5 CASCADE;
	DROP FUNCTION public.get_curr_century();
	DROP FUNCTION public.add(integer, integer);
	DROP TABLE public.nullcheck_tbl CASCADE;
	DROP TABLE public.not_nullcheck_tbl CASCADE;
	DROP TABLE public.prime_tbl CASCADE;
	DROP DOMAIN public.prime;
	DROP FUNCTION public.is_prime_lt_100(integer);
	DROP FUNCTION public.some_prime_numbers();
$$);

--
-- REPAIR mode tests
-- Here, we may check correctness of REPAIR mode for a single backend only
--

SET spock.enable_ddl_replication = 'on';
SET spock.include_ddl_repset = 'on';

CREATE TABLE spoc152_1(x integer PRIMARY KEY);
BEGIN;
  SELECT spock.repair_mode(true) \gset
  CREATE TABLE spoc152_2(x integer PRIMARY KEY); -- doesn't replicate DDL
  SELECT spock.repair_mode(false) \gset
  CREATE TABLE spoc152_3(x integer PRIMARY KEY); -- replicate DDL
  SELECT spock.repair_mode(true) \gset
  CREATE TABLE spoc152_4(x integer PRIMARY KEY); -- doesn't replicate DDL

  -- Check subtransations: nothing here should be replicated.
  SAVEPOINT s1;
	CREATE TABLE spoc152_6(x integer PRIMARY KEY);
  RELEASE SAVEPOINT s1;
    CREATE TABLE spoc152_7(x integer PRIMARY KEY);
  SAVEPOINT s2;
    CREATE TABLE spoc152_8(x integer PRIMARY KEY);
  ROLLBACK TO SAVEPOINT s2;
  CREATE TABLE spoc152_9(x integer PRIMARY KEY);
END;
CREATE TABLE spoc152_5(x integer PRIMARY KEY); -- replicate DDL

-- Should not see 'not replicated' DDL in this table
SELECT message FROM spock.queue WHERE message::text LIKE '%spoc152_%'
ORDER BY queued_at;

-- Wait for remote receiver
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT relname FROM pg_class WHERE relname LIKE '%spoc152_%'
ORDER BY relname COLLATE "C";
SELECT message FROM spock.queue WHERE message::text LIKE '%spoc152_%'
ORDER BY queued_at;

\c :provider_dsn
-- Cleanup and DROP messages check
DROP TABLE spoc152_1, spoc152_2, spoc152_3, spoc152_4, spoc152_5 CASCADE;

RESET spock.enable_ddl_replication;
RESET spock.include_ddl_repset;
