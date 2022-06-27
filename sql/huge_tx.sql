-- test huge transactions
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
-- lots of small rows replication with DDL outside transaction
SELECT spock.replicate_ddl_command($$
	CREATE TABLE public.a_huge (
		id integer primary key,
                id1 integer,
		data text default 'data',
		data1 text default 'data1'
	);
$$);
SELECT * FROM spock.replication_set_add_table('default', 'a_huge');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

BEGIN;

INSERT INTO public.a_huge VALUES (generate_series(1, 20000000), generate_series(1, 20000000));

COMMIT;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT count(*) FROM a_huge;
\dtS+ a_huge;

\c :provider_dsn
-- lots of small rows replication with DDL within transaction
BEGIN;
SELECT spock.replicate_ddl_command($$
	CREATE TABLE public.b_huge (
		id integer primary key,
                id1 integer,
		data text default 'data',
		data1 text default 'data1'
	);
$$);

SELECT * FROM spock.replication_set_add_table('default', 'b_huge');

INSERT INTO public.b_huge VALUES (generate_series(1,20000000), generate_series(1,20000000));

COMMIT;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT count(*) FROM b_huge;
\dtS+ b_huge;

\c :provider_dsn
\set VERBOSITY terse
SELECT spock.replicate_ddl_command($$
	DROP TABLE public.a_huge CASCADE;
	DROP TABLE public.b_huge CASCADE;
$$);


SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
