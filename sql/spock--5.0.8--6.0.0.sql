/* spock--5.0.8--6.0.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0'" to load this file. \quit

-- Drop functions removed from the 6.0.0 fresh install (present since 5.0.0 but no longer needed)
DROP FUNCTION IF EXISTS spock.convert_column_to_int8(regclass, smallint);
DROP FUNCTION IF EXISTS spock.convert_sequence_to_snowflake(regclass);

-- Add IMMUTABLE PARALLEL SAFE to md5_agg_sfunc (was missing in earlier definitions)
CREATE OR REPLACE FUNCTION spock.md5_agg_sfunc(text, anyelement)
	RETURNS text
AS $$ SELECT md5($1 || $2::text) $$
LANGUAGE sql IMMUTABLE PARALLEL SAFE;

-- Add named parameters to spock_gen_slot_name (originally created without names in 5.0.0)
CREATE OR REPLACE FUNCTION spock.spock_gen_slot_name(
  dbname        name,
  provider_node name,
  subscription  name
) RETURNS name
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

DROP VIEW IF EXISTS spock.lag_tracker;
DROP TABLE IF EXISTS spock.progress;

CREATE FUNCTION spock.apply_group_progress (
	OUT dbid              oid,
	OUT node_id           oid,
	OUT remote_node_id    oid,
	OUT remote_commit_ts  timestamptz,
	OUT prev_remote_ts    timestamptz,
	OUT remote_commit_lsn pg_lsn,
	OUT remote_insert_lsn pg_lsn,
	OUT received_lsn      pg_lsn,
	OUT last_updated_ts   timestamptz,
	OUT updated_by_decode bool
) RETURNS SETOF record
LANGUAGE c AS 'MODULE_PATHNAME', 'get_apply_group_progress';

-- Show the Spock apply progress for the current database
-- Columns prev_remote_ts, last_updated_ts, and updated_by_decode is dedicated
-- for internal use only.
CREATE VIEW spock.progress AS
	SELECT * FROM spock.apply_group_progress()
      WHERE dbid = (
        SELECT oid FROM pg_database WHERE datname = current_database()
      );


-- Read peer progress (ros.remote_lsn) for all peer subscriptions.
-- Called while apply workers are paused and the slot's snapshot is imported.
-- Row 0: header (lsn + snapshot placeholder).  Rows 1+: one progress entry per peer.
CREATE FUNCTION spock.read_peer_progress(
    p_slot_name text,
    p_provider_node_id oid,
    p_subscriber_node_id oid
) RETURNS TABLE(
    lsn pg_lsn,
    snapshot text,
    dbid oid,
    node_id oid,
    remote_node_id oid,
    remote_commit_ts timestamptz,
    prev_remote_ts timestamptz,
    remote_commit_lsn pg_lsn,
    remote_insert_lsn pg_lsn,
    received_lsn pg_lsn,
    last_updated_ts timestamptz,
    updated_by_decode boolean
) VOLATILE STRICT LANGUAGE plpgsql AS $$
DECLARE
    v_lsn          pg_lsn;
    v_snap         text;
    rec            record;
    v_n_peers      int := 0;
BEGIN
    /*
     * The slot and snapshot are created by the C caller via the replication
     * protocol.  The slot's snapshot is imported into this transaction.
     * This function just reads peer progress (ros.remote_lsn) while apply
     * workers are paused.
     */

    -- Get the slot's LSN and the imported snapshot for the header row.
    SELECT restart_lsn INTO v_lsn
    FROM pg_replication_slots WHERE slot_name = p_slot_name;
    v_snap := '';  -- snapshot managed by C caller

    RAISE NOTICE 'SPOCK cswp slot=% v_lsn=%', p_slot_name, v_lsn;

    -- Header row: lsn only (snapshot managed by C caller).
    lsn      := v_lsn;
    snapshot := v_snap;
    RETURN NEXT;

    /*
     * Emit one progress row per peer.  With apply workers paused,
     * ros.remote_lsn is exact: it reflects only committed transactions
     * whose effects are visible in the slot snapshot.
     */
    FOR rec IN (
        SELECT p.dbid, p.node_id, p.remote_node_id,
               p.remote_commit_ts, p.prev_remote_ts,
               p.remote_commit_lsn      AS grp_remote_commit_lsn,
               p.remote_insert_lsn,
               p.received_lsn, p.last_updated_ts, p.updated_by_decode,
               ros.remote_lsn           AS ros_remote_lsn,
               sub.sub_slot_name        AS sub_slot_name
        FROM   spock.subscription sub
        JOIN   spock.progress p
               ON  p.remote_node_id = sub.sub_origin
               AND p.node_id        = sub.sub_target
        JOIN   pg_replication_origin o
               ON  o.roname = sub.sub_slot_name
        LEFT JOIN pg_replication_origin_status ros
               ON  ros.local_id = o.roident
        WHERE  sub.sub_target = p_provider_node_id
          AND  sub.sub_origin <> p_subscriber_node_id
    ) LOOP
        v_n_peers := v_n_peers + 1;

        lsn               := v_lsn;
        snapshot          := v_snap;
        dbid              := rec.dbid;
        node_id           := rec.node_id;
        remote_node_id    := rec.remote_node_id;
        remote_commit_ts  := rec.remote_commit_ts;
        prev_remote_ts    := rec.prev_remote_ts;
        remote_commit_lsn := COALESCE(rec.ros_remote_lsn, '0/0'::pg_lsn);
        remote_insert_lsn := rec.remote_insert_lsn;
        received_lsn      := rec.received_lsn;
        last_updated_ts   := rec.last_updated_ts;
        updated_by_decode := rec.updated_by_decode;

        RAISE NOTICE 'SPOCK cswp peer=% resume_lsn=%',
            rec.remote_node_id, remote_commit_lsn;

        RETURN NEXT;
    END LOOP;

    RAISE NOTICE 'SPOCK cswp slot=% done peers=%', p_slot_name, v_n_peers;
END;
$$;

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

-- Migrate spock.resolutions to the new conflict types
-- insert_exists stays the same
UPDATE spock.resolutions
SET conflict_type = CASE conflict_type
    WHEN 'update_update' THEN 'update_exists'
    WHEN 'update_delete' THEN 'update_missing'
    WHEN 'delete_delete' THEN 'delete_missing'
    ELSE conflict_type
END;

-- Add index on log_time to support efficient TTL-based cleanup
CREATE INDEX ON spock.resolutions (log_time);

-- Manual cleanup function for the resolutions table
CREATE FUNCTION spock.cleanup_resolutions(days integer DEFAULT NULL)
RETURNS bigint VOLATILE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_cleanup_resolutions_sql';
REVOKE ALL ON FUNCTION spock.cleanup_resolutions(integer) FROM PUBLIC;

-- ----
-- Subscription conflict statistics
-- ----
CREATE FUNCTION spock.get_subscription_stats(
	subid                           oid,
	OUT subid                       oid,
	OUT confl_insert_exists         bigint,
	OUT confl_update_origin_differs bigint,
	OUT confl_update_exists         bigint,
	OUT confl_update_missing        bigint,
	OUT confl_delete_origin_differs bigint,
	OUT confl_delete_missing        bigint,
	OUT confl_delete_exists         bigint,
	OUT stats_reset                 timestamptz
)
RETURNS record
AS 'MODULE_PATHNAME', 'spock_get_subscription_stats'
LANGUAGE C STABLE;

CREATE FUNCTION spock.reset_subscription_stats(subid oid DEFAULT NULL)
RETURNS void
AS 'MODULE_PATHNAME', 'spock_reset_subscription_stats'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

-- Set delta_apply security label on specific column
CREATE FUNCTION spock.delta_apply(
  rel regclass,
  att_name name,
  to_drop boolean DEFAULT false
) RETURNS boolean AS $$
DECLARE
  label     text;
  atttype   name;
  attdata   record;
  sqlstring text;
  status    boolean;
  relreplident char (1);
  ctypname  name;
BEGIN

  /*
   * regclass input type guarantees we see this table, no 'not found' check
   * is needed.
   */
  SELECT c.relreplident FROM pg_class c WHERE oid = rel INTO relreplident;
  /*
   * Allow only DEFAULT type of replica identity. FULL type means we have
   * already requested delta_apply feature on this table.
   * Avoid INDEX type because indexes may have different names on the nodes and
   * it would be better to stay paranoid than afraid of consequences.
   */
  IF (relreplident <> 'd' AND relreplident <> 'f')
  THEN
    RAISE EXCEPTION 'spock can apply delta_apply feature to the DEFAULT replica identity type only. This table holds "%" idenity', relreplident;
  END IF;

  /*
   * Find proper delta_apply function for the column type or ERROR
   */

  SELECT t.typname,t.typinput,t.typoutput
  FROM pg_catalog.pg_attribute a, pg_type t
  WHERE a.attrelid = rel AND a.attname = att_name AND (a.atttypid = t.oid)
  INTO attdata;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'column % does not exist in the table %', att_name, rel;
  END IF;

  SELECT typname FROM pg_type WHERE
    typname IN ('int2','int4','int8','float4','float8','numeric','money') AND
    typinput = attdata.typinput AND typoutput = attdata.typoutput
  INTO ctypname;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'type "%" can not be used in delta_apply conflict resolution',
          attdata.typname;
  END IF;

  --
  -- Create security label on the column
  --
  IF (to_drop = true) THEN
    sqlstring := format('SECURITY LABEL FOR spock ON COLUMN %I.%I IS NULL;' ,
                        rel, att_name);
  ELSE
    sqlstring := format('SECURITY LABEL FOR spock ON COLUMN %I.%I IS %L;' ,
                        rel, att_name, 'spock.delta_apply');
  END IF;

  EXECUTE sqlstring;

  /*
   * Auto replication will propagate security label if needed. Just warn if it's
   * not - the structure sync pg_dump call would copy security labels, isn't it?
   */
  SELECT pg_catalog.current_setting('spock.enable_ddl_replication') INTO status;
  IF EXISTS (SELECT 1 FROM spock.local_node) AND status = false THEN
    raise WARNING 'delta_apply setting has not been propagated to other spock nodes';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_catalog.pg_seclabel
			 WHERE objoid = rel AND classoid = 'pg_class'::regclass AND
			       provider = 'spock') THEN
    /*
     * Call it each time to trigger relcache invalidation callback that causes
     * refresh of the SpockRelation entry and guarantees actual state of the
     * delta_apply columns.
     */
    EXECUTE format('ALTER TABLE %I REPLICA IDENTITY FULL', rel);
  ELSIF EXISTS (SELECT 1 FROM pg_catalog.pg_class c
			 WHERE c.oid = rel AND c.relreplident = 'f') THEN
    /*
	 * Have removed he last security label. Revert this spock hack change,
	 * if needed.
	 */
	EXECUTE format('ALTER TABLE %I REPLICA IDENTITY DEFAULT', rel);
  END IF;

  RETURN true;
END;
$$ LANGUAGE plpgsql STRICT VOLATILE;


CREATE FUNCTION spock.sub_alter_options(
  subscription_name name,
  options           jsonb
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_alter_subscription_options'
LANGUAGE C STRICT VOLATILE;

