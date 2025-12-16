-- Generated columns replication tests
-- Tests for ensuring generated columns are properly handled during replication

SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

-- Test 1: Basic table with generated column
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_basic (
    id integer PRIMARY KEY,
    base_val integer NOT NULL,
    doubled integer GENERATED ALWAYS AS (base_val * 2) STORED
);
$$);

SELECT * FROM spock.repset_add_table('default', 'gen_basic');
INSERT INTO gen_basic (id, base_val) VALUES (1, 10), (2, 20), (3, 30);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_basic ORDER BY id;

-- Test 2: INSERT, UPDATE, DELETE operations with generated columns
\c :provider_dsn
INSERT INTO gen_basic (id, base_val) VALUES (4, 40);
UPDATE gen_basic SET base_val = 15 WHERE id = 1;
DELETE FROM gen_basic WHERE id = 3;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_basic ORDER BY id;

-- Test 3: Multiple generated columns in different positions
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE gen_multiple (
    gen1 integer GENERATED ALWAYS AS (id + 100) STORED,
    id integer PRIMARY KEY,
    val1 integer NOT NULL,
    gen2 integer GENERATED ALWAYS AS (val1 * 10) STORED,
    val2 text,
    gen3 text GENERATED ALWAYS AS (val2 || '_suffix') STORED
);
$$);

SELECT * FROM spock.repset_add_table('default', 'gen_multiple');
INSERT INTO gen_multiple (id, val1, val2) VALUES (1, 5, 'test'), (2, 10, 'data');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_multiple ORDER BY id;

-- Test 5: Row filter with generated columns
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_filtered (
    id integer PRIMARY KEY,
    amount integer NOT NULL,
    category text NOT NULL,
    doubled_amount integer GENERATED ALWAYS AS (amount * 2) STORED
);
$$);

-- Filter to only replicate category 'A'
SELECT * FROM spock.repset_add_table('default', 'gen_filtered', false,
    row_filter := 'category = ''A''');
INSERT INTO gen_filtered (id, amount, category) VALUES
    (1, 100, 'A'),
    (2, 200, 'B'),
    (3, 300, 'A'),
    (4, 400, 'B');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Should only see category 'A' rows
SELECT * FROM gen_filtered ORDER BY id;

\c :provider_dsn
-- Insert more rows, only category 'A' should replicate
INSERT INTO gen_filtered (id, amount, category) VALUES
    (5, 500, 'A'),
    (6, 600, 'B');

UPDATE gen_filtered SET amount = 150 WHERE id = 1;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_filtered ORDER BY id;

-- Test 6: Table resync with generated columns
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_resync (
    id integer PRIMARY KEY,
    data integer NOT NULL,
    computed integer GENERATED ALWAYS AS (data + 1000) STORED
);
$$);

INSERT INTO gen_resync (id, data) VALUES (1, 1), (2, 2);
SELECT * FROM spock.repset_add_table('default', 'gen_resync');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- Add more data before resync
INSERT INTO gen_resync (id, data) VALUES (3, 3), (4, 4);

\c :subscriber_dsn
SELECT spock.sub_resync_table('test_subscription', 'gen_resync', true);
SELECT spock.table_wait_for_sync('test_subscription', 'gen_resync');
SELECT * FROM gen_resync ORDER BY id;

-- Test 7: Generated column referencing multiple base columns
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_multi_ref (
    id integer PRIMARY KEY,
    x integer NOT NULL,
    y integer NOT NULL,
    z integer NOT NULL,
    sum_xy integer GENERATED ALWAYS AS (x + y) STORED,
    product_xyz integer GENERATED ALWAYS AS (x * y * z) STORED
);
$$);

SELECT * FROM spock.repset_add_table('default', 'gen_multi_ref');
INSERT INTO gen_multi_ref (id, x, y, z) VALUES
    (1, 2, 3, 4),
    (2, 5, 6, 7);

UPDATE gen_multi_ref SET x = 10, y = 20 WHERE id = 1;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_multi_ref ORDER BY id;

-- Test 8: Generated column with NULL handling
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_nulls (
    id integer PRIMARY KEY,
    val integer,
    doubled integer GENERATED ALWAYS AS (val * 2) STORED
);
$$);

SELECT * FROM spock.repset_add_table('default', 'gen_nulls');
INSERT INTO gen_nulls (id, val) VALUES (1, 10), (2, NULL), (3, 30);

UPDATE gen_nulls SET val = NULL WHERE id = 1;
UPDATE gen_nulls SET val = 25 WHERE id = 2;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_nulls ORDER BY id;

-- Test 9: Column list with generated columns
-- (Generated columns should be automatically excluded)
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_collist (
    id integer PRIMARY KEY,
    col1 integer NOT NULL,
    gen1 integer GENERATED ALWAYS AS (col1 * 2) STORED,
    col2 text NOT NULL,
    gen2 text GENERATED ALWAYS AS (col2 || '_gen') STORED
);
$$);

-- Add table with explicit column list (including generated column)
SELECT * FROM spock.repset_add_table('default', 'gen_collist', false,
    columns := '{id, col1, col2, gen2}'); -- ERROR
SELECT * FROM spock.repset_add_table('default', 'gen_collist', false,
    columns := '{id, col1, col2}');
INSERT INTO gen_collist (id, col1, col2) VALUES (1, 10, 'test'), (2, 20, 'data');
INSERT INTO gen_collist (id, col1, col2) VALUES (3, 30, 'more');

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT * FROM gen_collist ORDER BY id;

-- Test 10: Mixed dropped and generated columns
\c :provider_dsn
SELECT spock.replicate_ddl($$
CREATE TABLE public.gen_mixed (
    id integer PRIMARY KEY,
    col1 integer NOT NULL,
    col2 integer,
    gen1 integer GENERATED ALWAYS AS (col1 + 10) STORED
);
$$);

SELECT * FROM spock.repset_add_table('default', 'gen_mixed');
INSERT INTO gen_mixed (id, col1, col2) VALUES (1, 5, 50);

-- Now drop col2 on provider
ALTER TABLE gen_mixed DROP COLUMN col2;

INSERT INTO gen_mixed (id, col1) VALUES (2, 10);

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
-- Drop col2 on subscriber too
ALTER TABLE gen_mixed DROP COLUMN col2;

SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

SELECT * FROM gen_mixed ORDER BY id;

-- Cleanup
\c :provider_dsn
DROP TABLE gen_basic CASCADE;
DROP TABLE gen_multiple CASCADE;
DROP TABLE gen_filtered CASCADE;
DROP TABLE gen_resync CASCADE;
DROP TABLE gen_multi_ref CASCADE;
DROP TABLE gen_nulls CASCADE;
DROP TABLE gen_collist CASCADE;
DROP TABLE gen_mixed CASCADE;
