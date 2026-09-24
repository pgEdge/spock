--
-- Test: tuple data that does not match the local column definition
--
-- Spock does not replicate DDL by default, so the two nodes can end up
-- disagreeing about a column's type.  Here the provider sends a uuid
-- that the subscriber reads as a bytea.  The apply worker must reject
-- the tuple, leave existing rows untouched, and resume on its own once
-- the two schemas agree again.
--
-- TODO: only the internal binary representation ('i') is covered here.
-- spock_read_tuple() has two more branches that were hardened by the
-- same change and have no test at all:
--
--   'b' (send/recv) is only chosen for types the internal format
--       declines, so exercising it needs a column type that
--       decide_datum_transfer() routes that way;
--   't' (text) is only chosen when the subscription was created with
--       force_text_transfer := true, so it needs a subscription of its
--       own -- see spock.sub_create() in init.sql for the shape.
--
SELECT * FROM spock_regress_variables()
\gset

-- Pin the exception policy so the outcome does not depend on the
-- cluster default.
\c :subscriber_dsn
ALTER SYSTEM SET spock.exception_behaviour = 'discard';
SELECT pg_reload_conf();

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
-- A well formed row first.  Both a varlena (bytea) and a
-- fixed-length pass-by-reference type (uuid) travel in the
-- internal binary format, which is the path being hardened, so
-- this also shows the check leaves valid data alone.
-- ============================================================
INSERT INTO wire_sanity
VALUES (1, '\x0011223344'::bytea,
        '11111111-1111-1111-1111-111111111111');
SELECT spock.sync_event() AS sync_lsn \gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);
SELECT id, encode(payload, 'hex') AS payload, marker
FROM wire_sanity ORDER BY id;

-- ============================================================
-- Diverge the schema on the provider only, then send a value
-- that does not match the subscriber's definition of the column.
-- ============================================================
\c :provider_dsn

-- A valid row first, while the two definitions still agree, and its own
-- sync event.  Waiting for this row to arrive is what pins the worker's
-- position: once it has been applied, the only thing left between the
-- worker and the mismatched row is the mismatched row itself, which
-- is what lets the wait below be read as "refused" rather than "not
-- reached yet".  The marker has to go in before the divergence -- sent
-- afterwards it would be a uuid read as a bytea, which is the very
-- thing being rejected.
INSERT INTO wire_sanity
VALUES (99, '\x99'::bytea,
        '33333333-3333-3333-3333-333333333333');
SELECT spock.sync_event() AS marker_lsn \gset

ALTER TABLE wire_sanity
  ALTER COLUMN payload TYPE uuid
  USING '00000000-0000-0000-0000-000000000000'::uuid;

INSERT INTO wire_sanity
VALUES (100, '00040000-aaaa-bbbb-cccc-dddddddddddd'::uuid,
        '22222222-2222-2222-2222-222222222222');
SELECT spock.sync_event() AS sync_lsn \gset

-- The worker is alive and has consumed everything up to the mismatched row.
\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'marker_lsn', 30);

DO $$
DECLARE
	deadline timestamptz := clock_timestamp() + interval '30 seconds';
BEGIN
	LOOP
		/* the marker row above already proved it was replicating */
		IF EXISTS (SELECT 1 FROM spock.sub_show_status()
				   WHERE subscription_name = 'test_subscription'
					 AND status = 'down') THEN
			EXIT;
		END IF;

		IF EXISTS (SELECT 1 FROM spock.exception_log
				   WHERE table_name = 'wire_sanity') THEN
			EXIT;
		END IF;

		IF clock_timestamp() > deadline THEN
			RAISE EXCEPTION 'apply worker kept replicating past the mismatched tuple';
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

-- ============================================================
-- Repair the divergence.  The tuple is valid for the local
-- definition now, so the worker gets past it and replication
-- catches up by itself.
-- ============================================================
-- Bounded, so that a lock this is not expected to have to wait for
-- fails the test quickly and audibly rather than hanging it.
SET lock_timeout = '30s';
ALTER TABLE wire_sanity
  ALTER COLUMN payload TYPE uuid
  USING '00000000-0000-0000-0000-000000000000'::uuid;
RESET lock_timeout;

CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 60);
SELECT id, payload, marker FROM wire_sanity ORDER BY id;

-- ============================================================
-- Cleanup
-- ============================================================
ALTER SYSTEM RESET spock.exception_behaviour;
SELECT pg_reload_conf();

\c :provider_dsn
SELECT spock.replicate_ddl($$
  DROP TABLE IF EXISTS public.wire_sanity CASCADE;
$$);
