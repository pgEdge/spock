/* spock--5.0.4--6.0.0.devel.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0-devel'" to load this file. \quit

DROP VIEW IF EXISTS spock.lag_tracker;
DROP TABLE IF EXISTS spock.progress;

ALTER TABLE spock.subscription
	ADD COLUMN IF NOT EXISTS sub_rescue_suspended boolean NOT NULL DEFAULT false;
ALTER TABLE spock.subscription
	ADD COLUMN IF NOT EXISTS sub_rescue_temporary boolean NOT NULL DEFAULT false;
ALTER TABLE spock.subscription
	ADD COLUMN IF NOT EXISTS sub_rescue_stop_lsn pg_lsn;
ALTER TABLE spock.subscription
	ADD COLUMN IF NOT EXISTS sub_rescue_stop_time timestamptz;
ALTER TABLE spock.subscription
	ADD COLUMN IF NOT EXISTS sub_rescue_cleanup_pending boolean NOT NULL DEFAULT false;
ALTER TABLE spock.subscription
	ADD COLUMN IF NOT EXISTS sub_rescue_failed boolean NOT NULL DEFAULT false;

DROP FUNCTION IF EXISTS spock.apply_group_progress;

CREATE FUNCTION spock.apply_group_progress (
	OUT dbid oid,
	OUT node_id oid,
	OUT remote_node_id oid,
	OUT remote_commit_ts timestamptz,
	OUT prev_remote_ts timestamptz,
	OUT remote_commit_lsn pg_lsn,
	OUT remote_insert_lsn pg_lsn,
	OUT received_lsn pg_lsn,
	OUT last_updated_ts timestamptz,
	OUT updated_by_decode bool
) RETURNS SETOF record
LANGUAGE c AS 'MODULE_PATHNAME', 'get_apply_group_progress';

CREATE VIEW spock.progress AS
	SELECT * FROM spock.apply_group_progress();

CREATE VIEW spock.lag_tracker AS
	SELECT
		origin.node_name AS origin_name,
		n.node_name AS receiver_name,
		MAX(p.remote_commit_ts) AS commit_timestamp,
		MAX(p.remote_commit_lsn) AS commit_lsn,
		MAX(p.remote_insert_lsn) AS remote_insert_lsn,
		MAX(p.received_lsn) AS received_lsn,
		CASE
			WHEN MAX(p.remote_insert_lsn) IS NOT NULL AND MAX(p.remote_commit_lsn) IS NOT NULL
			  THEN MAX(pg_wal_lsn_diff(p.remote_insert_lsn, p.remote_commit_lsn))
			ELSE NULL
		END AS replication_lag_bytes,
		CASE
			WHEN MAX(p.remote_commit_ts) IS NOT NULL AND MAX(p.last_updated_ts) IS NOT NULL
              THEN MAX(p.last_updated_ts - p.remote_commit_ts)
            ELSE NULL
		END AS replication_lag
	FROM spock.progress p
	LEFT JOIN spock.subscription sub ON (p.node_id = sub.sub_target and p.remote_node_id = sub.sub_origin)
	LEFT JOIN spock.node origin ON sub.sub_origin = origin.node_id
	LEFT JOIN spock.node n ON n.node_id = p.node_id
	GROUP BY origin.node_name, n.node_name;

-- Source for sub_id values.
CREATE SEQUENCE spock.sub_id_generator AS integer MINVALUE 1 CYCLE START WITH 1
OWNED BY spock.subscription.sub_id;

CREATE FUNCTION spock.get_recovery_slot_status()
RETURNS TABLE (
	slot_name text,
	restart_lsn pg_lsn,
	confirmed_flush_lsn pg_lsn,
	min_unacknowledged_ts timestamptz,
	active boolean,
	in_recovery boolean
)
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_recovery_slot_status_sql';

CREATE OR REPLACE FUNCTION spock.get_recovery_status()
RETURNS TABLE (
	component text,
	status text,
	details text
)
LANGUAGE plpgsql
AS $$
DECLARE
    recovery_slot_exists boolean := false;
    recovery_slot_name text;
    db_name text := current_database();
BEGIN
    -- Check if recovery slot exists
    SELECT EXISTS (
        SELECT 1 FROM spock.get_recovery_slot_status() WHERE active = true
    ) INTO recovery_slot_exists;
    
    IF recovery_slot_exists THEN
        RETURN QUERY SELECT 'Recovery Slot'::text, 'HEALTHY'::text, 'Recovery slot exists and is active'::text;
    ELSE
        -- Check if recovery slots are enabled via GUC
        IF current_setting('spock.enable_recovery_slots', true)::boolean THEN
            RETURN QUERY SELECT 'Recovery Slot'::text, 'MISSING'::text, 'Recovery slot is missing but should be created automatically by the manager process'::text;
        ELSE
            RETURN QUERY SELECT 'Recovery Slot'::text, 'DISABLED'::text, 'Recovery slot is disabled via spock.enable_recovery_slots = off'::text;
        END IF;
    END IF;
    
    RETURN;
END;
$$;

CREATE OR REPLACE FUNCTION spock.find_rescue_source(failed_node_name text)
RETURNS TABLE (
    origin_node_id oid,
    source_node_id oid,
    last_lsn pg_lsn,
    last_commit_timestamp timestamptz,
    confidence_level text
)
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_find_rescue_source';

CREATE OR REPLACE FUNCTION spock.clone_recovery_slot(
    target_restart_lsn pg_lsn DEFAULT NULL
)
RETURNS TABLE (
    cloned_slot_name text,
    original_slot_name text,
    restart_lsn pg_lsn,
    success boolean,
    message text
)
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_clone_recovery_slot';

CREATE FUNCTION spock.create_rescue_subscription(
    target_node name,
    source_node name,
    cloned_slot text,
    skip_lsn pg_lsn DEFAULT NULL,
    stop_lsn pg_lsn DEFAULT NULL,
    stop_timestamp timestamptz DEFAULT NULL
)
RETURNS oid
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_rescue_subscription';

CREATE FUNCTION spock.suspend_all_peer_subs_for_rescue(
    node_id oid,
    failed_node_id oid
)
RETURNS boolean
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_suspend_all_peer_subs_for_rescue_sql';

CREATE FUNCTION spock.resume_all_peer_subs_post_rescue(
    node_id oid
)
RETURNS boolean
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_resume_all_peer_subs_post_rescue_sql';
