--
-- Test: tuple data that does not match the local column definition
--
-- Spock does not replicate DDL by default, so the two nodes can end up
-- disagreeing about a column's type.  Here the provider sends a uuid
-- that the subscriber reads as a bytea.  The apply worker must reject
-- the tuple, leave existing rows untouched, and resume on its own once
-- the two schemas agree again.
--
-- On 64-bit builds of this branch the values travel as send/recv ('b'),
-- not in the internal binary representation ('i'): the provider turns
-- 'i' down for every subscriber, because the float8_byval startup
-- parameter is recorded as float4_byval (spock_output_config.c) and the
-- two then disagree.  On 32-bit builds both are false, so they agree and
-- 'i' is used, and this test would take that path.  So what stops the
-- worker here is the type check that the 'b' branch already had, and
-- the 'i' checks in spock_read_tuple() and check_varlena_attribute()
-- are not reached.  This test guards the behaviour around them: valid
-- rows still apply, a mismatched one is refused without touching
-- existing data, and replication resumes once the schemas agree.
--
-- TODO: 't' (text) is only chosen when the subscription was created
-- with force_text_transfer := true, so it needs a subscription of its
-- own -- see spock.sub_create() in init.sql for the shape.
--
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
SELECT spock.replicate_ddl($$
  CREATE TABLE public.wire_sanity (
    id      integer PRIMARY KEY,
    payload bytea,
    marker  uuid
  );
$$);
SELECT spock.repset_add_table('default', 'wire_sanity');

-- ============================================================
-- A well formed row first, a varlena (bytea) and a fixed-length
-- pass-by-reference type (uuid), to show the checks leave valid
-- data alone.
-- ============================================================
INSERT INTO wire_sanity
VALUES (1, '\x0011223344'::bytea,
        '11111111-1111-1111-1111-111111111111');

-- A second valid row, sent while the two definitions still agree.
-- Waiting for it is what pins the worker's position: once it has been
-- applied, the only thing left between the worker and the mismatched
-- row is the mismatched row itself, so what follows can be read as
-- "refused" rather than "not reached yet".
INSERT INTO wire_sanity
VALUES (99, '\x99'::bytea,
        '33333333-3333-3333-3333-333333333333');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT id, encode(payload, 'hex') AS payload, marker
FROM wire_sanity ORDER BY id;

-- Note which process is applying changes right now.  An apply worker
-- that hits an error exits, and the manager starts a new one a few
-- seconds later, so a different pid (or none) is how a refused tuple
-- shows up here.
SELECT pid AS apply_pid
FROM pg_stat_activity a, spock.subscription s
WHERE s.sub_name = 'test_subscription'
  AND a.backend_type = 'spock apply ' || a.datid || ':' || s.sub_id
\gset

-- ============================================================
-- Diverge the schema on the provider only, then send a value
-- that does not match the subscriber's definition of the column.
-- ============================================================
\c :provider_dsn
ALTER TABLE wire_sanity
  ALTER COLUMN payload TYPE uuid
  USING '00000000-0000-0000-0000-000000000000'::uuid;

INSERT INTO wire_sanity
VALUES (100, '00040000-aaaa-bbbb-cccc-dddddddddddd'::uuid,
        '22222222-2222-2222-2222-222222222222');
SELECT pg_current_wal_lsn() AS sync_lsn \gset

\c :subscriber_dsn
-- psql does not substitute variables inside a DO body, so hand them in
-- as settings.
SELECT set_config('wire_sanity.apply_pid', :'apply_pid', false) IS NOT NULL AS ok;
DO $$
DECLARE
	deadline timestamptz := clock_timestamp() + interval '30 seconds';
BEGIN
	LOOP
		IF NOT EXISTS (SELECT 1 FROM pg_stat_activity
					   WHERE pid = current_setting('wire_sanity.apply_pid')::int) THEN
			EXIT;
		END IF;

		IF clock_timestamp() > deadline THEN
			RAISE EXCEPTION 'apply worker kept running past the mismatched tuple';
		END IF;

		PERFORM pg_sleep(0.2);
	END LOOP;
END $$;

-- The mismatched row must be absent, and the rows that were already
-- there must be untouched.
SELECT count(*) AS mismatched_rows FROM wire_sanity WHERE id = 100;
SELECT id, octet_length(payload) AS payload_len,
       encode(payload, 'hex') AS payload, marker
FROM wire_sanity ORDER BY id;

-- Nor was the transaction acknowledged to the provider.
\c :provider_dsn
SELECT confirmed_flush_lsn < :'sync_lsn' AS still_behind
FROM pg_replication_slots
WHERE slot_type = 'logical' AND database = current_database();

-- ============================================================
-- Repair the divergence.  The tuple is valid for the local
-- definition now, so the worker gets past it and replication
-- catches up by itself.
-- ============================================================
\c :subscriber_dsn
-- Bounded, so that a lock this is not expected to have to wait for
-- fails the test quickly and audibly rather than hanging it.
SET lock_timeout = '30s';
ALTER TABLE wire_sanity
  ALTER COLUMN payload TYPE uuid
  USING '00000000-0000-0000-0000-000000000000'::uuid;
RESET lock_timeout;

-- Bounded for the same reason; wait_slot_confirm_lsn() would wait
-- forever if the worker never got past the row.
\c :provider_dsn
SELECT set_config('wire_sanity.sync_lsn', :'sync_lsn', false) IS NOT NULL AS ok;
DO $$
DECLARE
	deadline timestamptz := clock_timestamp() + interval '60 seconds';
BEGIN
	WHILE EXISTS (SELECT 1 FROM pg_replication_slots
				  WHERE slot_type = 'logical'
					AND database = current_database()
					AND confirmed_flush_lsn < current_setting('wire_sanity.sync_lsn')::pg_lsn) LOOP
		IF clock_timestamp() > deadline THEN
			RAISE EXCEPTION 'replication did not resume after the schema was repaired';
		END IF;

		PERFORM pg_sleep(0.2);
	END LOOP;
END $$;

\c :subscriber_dsn
SELECT id, payload, marker FROM wire_sanity ORDER BY id;

-- ============================================================
-- Cleanup
-- ============================================================
\c :provider_dsn
SELECT spock.replicate_ddl($$
  DROP TABLE IF EXISTS public.wire_sanity CASCADE;
$$);
