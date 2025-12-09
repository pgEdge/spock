-- basic builtin datatypes
SELECT * FROM spock_regress_variables()
\gset

-- Check any progress interface changes
\df spock.apply_group_progress
\d spock.progress
\d spock.lag_tracker

\c :provider_dsn
SELECT spock.replicate_ddl($$
	CREATE TABLE public.test_progress (
		id serial primary key,
		value integer
	);
$$);

SELECT * FROM spock.repset_add_table('default', 'test_progress');
INSERT INTO test_progress (value) VALUES (42);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

SELECT count(*) FROM spock.progress; -- Should be zero

\c :subscriber_dsn
SELECT
  remote_commit_ts > 'epoch', prev_remote_ts > 'epoch',
  remote_commit_lsn > '0/0'::pg_lsn, remote_insert_lsn > '0/0'::pg_lsn,
  received_lsn > '0/0'::pg_lsn, last_updated_ts > 'epoch',
  updated_by_decode = 't', local_lsn > '0/0'::pg_lsn
FROM spock.progress;

SELECT * FROM test_progress;

UPDATE test_progress SET value = 43;
\c :provider_dsn
INSERT INTO test_progress (value) VALUES (44);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
\c :subscriber_dsn

-- Check that nothing changes in the progress table after a resync
CREATE TEMP TABLE cmp (x1 pg_lsn, x2 pg_lsn, x3 pg_lsn);
INSERT INTO cmp SELECT remote_commit_lsn, remote_insert_lsn, local_lsn
  FROM spock.progress;
SELECT spock.sub_resync_table('test_subscription', 'test_progress', false);
INSERT INTO cmp SELECT remote_commit_lsn, remote_insert_lsn, local_lsn
  FROM spock.progress;
SELECT count(*) FROM (SELECT * FROM cmp GROUP BY (x1,x2,x3)); -- Should be 1
DROP TABLE cmp;

-- Check subscription and the table state
SELECT sub_name,sub_enabled FROM spock.subscription;
SELECT * FROM test_progress;

\c :provider_dsn
-- Just to fix that resync doesn't actually sunchronize the data unless we
-- truncate the subscriber's table.
SELECT * FROM test_progress;

SELECT spock.replicate_ddl($$DROP TABLE test_progress CASCADE;$$);
