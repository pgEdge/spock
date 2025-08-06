-- basic builtin datatypes
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SELECT spock.replicate_ddl($$
	CREATE TABLE public.basic_conflict (
		id int primary key,
		data text);
$$);

SELECT * FROM spock.repset_add_table('default', 'basic_conflict');

INSERT INTO basic_conflict VALUES (1, 'A'), (2, 'B');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM basic_conflict ORDER BY id;

\c :provider_dsn

TRUNCATE spock.resolutions;

UPDATE basic_conflict SET data = 'AAA' WHERE id = 1;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

SELECT * FROM basic_conflict ORDER BY id;

--- should return nothing
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- now update row locally to set up an origin difference
UPDATE basic_conflict SET data = 'sub-A' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :provider_dsn

-- Update on provider again so subscriber will see
-- an origin different from its local one
UPDATE basic_conflict SET data = 'pub-A' WHERE id = 1;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);


\c :subscriber_dsn
SELECT * FROM basic_conflict ORDER BY id;

-- We should now see a conflict
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

-- Clean
TRUNCATE spock.resolutions;

\c :provider_dsn
-- Do update in same transaction as INSERT
BEGIN;
INSERT INTO basic_conflict VALUES (3, 'C');
UPDATE basic_conflict SET data = 'pub-C' WHERE id = 3;
COMMIT;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);


\c :subscriber_dsn
SELECT * FROM basic_conflict ORDER BY id;

-- We should not see a conflict
SELECT relname, conflict_type FROM spock.resolutions WHERE relname = 'public.basic_conflict';

DROP table basic_conflict;
