
/* spock--5.0.6--5.0.7.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.7'" to load this file. \quit

CREATE FUNCTION spock.pause_apply_workers()
RETURNS void VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_pause_apply_workers';

CREATE FUNCTION spock.resume_apply_workers()
RETURNS void VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_resume_apply_workers';

REVOKE EXECUTE ON FUNCTION spock.pause_apply_workers() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION spock.resume_apply_workers() FROM PUBLIC;

DROP PROCEDURE IF EXISTS spock.wait_for_sync_event(OUT bool, oid, pg_lsn, int);
DROP PROCEDURE IF EXISTS spock.wait_for_sync_event(OUT bool, oid, pg_lsn, int, bool);
DROP PROCEDURE IF EXISTS spock.wait_for_sync_event(OUT bool, name, pg_lsn, int);
DROP PROCEDURE IF EXISTS spock.wait_for_sync_event(OUT bool, name, pg_lsn, int, bool);
CREATE PROCEDURE spock.wait_for_sync_event(
	OUT result          bool,
	origin_id           oid,
	lsn                 pg_lsn,
	timeout             int  DEFAULT 0,
	wait_if_disabled    bool DEFAULT false
) AS $$
DECLARE
	target_id		oid;
	start_time		timestamptz := clock_timestamp();
	progress_lsn	pg_lsn;
	sub_is_enabled	bool;
	sub_slot		name;
BEGIN
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Invalid NULL origin_id';
	END IF;
	target_id := node_id FROM spock.node_info();

	-- Upfront existence check is skipped when wait_if_disabled is true because
	-- the subscription may not yet exist (e.g. a newly added node whose
	-- subscriptions are still initializing).  The loop below handles both the
	-- not-found and disabled cases gracefully in that mode.
	IF NOT wait_if_disabled THEN
		SELECT sub_enabled, sub_slot_name INTO sub_is_enabled, sub_slot
			FROM spock.subscription
			WHERE sub_origin = origin_id AND sub_target = target_id;

		IF NOT FOUND THEN
			RAISE EXCEPTION 'No subscription found for replication % => %',
							origin_id, target_id;
		END IF;
	END IF;

	WHILE true LOOP
		-- Re-check subscription state each iteration.  Also re-fetches
		-- sub_slot_name so the loop is self-contained when wait_if_disabled
		-- is true and the pre-loop check was skipped.
		SELECT sub_enabled, sub_slot_name INTO sub_is_enabled, sub_slot
			FROM spock.subscription
			WHERE sub_origin = origin_id AND sub_target = target_id;

		IF NOT FOUND THEN
			IF NOT wait_if_disabled THEN
				RAISE EXCEPTION 'No subscription found for replication % => %',
								origin_id, target_id;
			END IF;
			-- Subscription not yet created; fall through to sleep.
		ELSIF NOT sub_is_enabled THEN
			IF NOT wait_if_disabled THEN
				RAISE EXCEPTION 'Subscription % => % has been disabled',
								origin_id, target_id;
			END IF;
			-- Subscription still initializing; fall through to sleep.
		ELSE
			-- Subscription is enabled; check LSN progress.
			-- Uses PostgreSQL's native origin tracking rather than spock.progress
			SELECT remote_lsn INTO progress_lsn
				FROM pg_replication_origin_status
				WHERE external_id = sub_slot;

			IF progress_lsn IS NOT NULL AND progress_lsn >= lsn THEN
				result = true;
				RETURN;
			END IF;
		END IF;

		IF timeout <> 0 AND
		   EXTRACT(EPOCH FROM (clock_timestamp() - start_time)) >= timeout THEN
			result := false;
			RETURN;
		END IF;

		ROLLBACK;
		PERFORM pg_sleep(0.2);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE PROCEDURE spock.wait_for_sync_event(
	OUT result          bool,
	origin              name,
	lsn                 pg_lsn,
	timeout             int  DEFAULT 0,
	wait_if_disabled    bool DEFAULT false
) AS $$
DECLARE
	origin_id  oid;
BEGIN
	origin_id := node_id FROM spock.node WHERE node_name = origin;
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Origin node ''%'' not found', origin;
	END IF;
	CALL spock.wait_for_sync_event(result, origin_id, lsn, timeout, wait_if_disabled);
END;
$$ LANGUAGE plpgsql;

-- spock.sync_event() gained an optional 'transactional' boolean argument
-- (default false). Drop the old zero-arg signature first so the upgrade
-- doesn't leave behind two overloads with overlapping zero-arg resolution.
DROP FUNCTION IF EXISTS spock.sync_event();
CREATE FUNCTION spock.sync_event(transactional boolean DEFAULT false)
RETURNS pg_lsn RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_create_sync_event'
LANGUAGE C VOLATILE;

/*
 * Correct the declared type of spock.subscription.sub_skip_schema.
 *
 * The column was added as text in the 5.0.1--5.0.2 upgrade, but the C code
 * has always treated it as text[] on both read and write paths
 * (strlist_to_textarray on write, DatumGetArrayTypeP on read).  The bytes
 * already on disk are therefore a valid ArrayType; only the catalog's type
 * label is wrong.  ALTER TABLE ... ALTER COLUMN TYPE text[] USING ... is
 * not viable here: there is no SQL expression that converts "varlena bytes
 * the planner believes are text but are in fact ArrayType internal format"
 * back into an ArrayType Datum.  Relabel the column in place so SQL-level
 * access (SELECT, unnest, etc.) works as users expect, without rewriting
 * data.
 */
LOCK TABLE spock.subscription IN ACCESS EXCLUSIVE MODE;

UPDATE pg_catalog.pg_attribute
   SET atttypid  = 'text[]'::regtype,
       attndims  = 1
 WHERE attrelid  = 'spock.subscription'::regclass
   AND attname   = 'sub_skip_schema'
   AND atttypid  = 'text'::regtype;

/*
 * Drop any pg_statistic rows for the column.  Stats sampled when the
 * column was labelled text encode varlena bytes with text semantics;
 * after the relabel the planner would interpret the same stavalues
 * arrays as text[], producing nonsense selectivities (and possibly
 * crashing on operators that validate ArrayType structure).  ANALYZE
 * will repopulate as needed.
 */
DELETE FROM pg_catalog.pg_statistic
 WHERE starelid  = 'spock.subscription'::regclass
   AND staattnum = (
       SELECT attnum
       FROM   pg_catalog.pg_attribute
       WHERE  attrelid = 'spock.subscription'::regclass
         AND  attname  = 'sub_skip_schema');
