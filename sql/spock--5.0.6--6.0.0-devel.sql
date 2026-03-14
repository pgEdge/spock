/* spock--5.0.6--6.0.0-devel.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0-devel'" to load this file. \quit

DROP VIEW IF EXISTS spock.lag_tracker;
DROP TABLE IF EXISTS spock.progress;

DROP FUNCTION IF EXISTS spock.apply_group_progress;
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

-- Atomically create a replication slot and read spock.progress for all peers.
-- Row 0: lsn + snapshot header.  Rows 1+: one progress entry per peer.
CREATE FUNCTION spock.create_slot_with_progress(
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
    v_pre_peer_ids  oid[];
    v_pre_ros_lsns  pg_lsn[];
    v_pre_idx       int;
    v_pre_ros_lsn   pg_lsn;
    v_ros2_remote_lsn pg_lsn;
    v_ros2_local_lsn  pg_lsn;
    v_attempt      int;
    v_max_retries  int := 50;
    v_all_case_a   boolean;
    v_prev_local_lsns pg_lsn[];
    v_curr_local_lsns pg_lsn[];
    v_idle         boolean;
BEGIN
    -- Capture pre-slot ros.remote_lsn as Case B fallback.
    SELECT array_agg(sub.sub_origin ORDER BY sub.sub_origin),
           array_agg(COALESCE(ros.remote_lsn, '0/0'::pg_lsn) ORDER BY sub.sub_origin)
    INTO   v_pre_peer_ids, v_pre_ros_lsns
    FROM   spock.subscription sub
    JOIN   pg_replication_origin o ON o.roname = sub.sub_slot_name
    LEFT JOIN pg_replication_origin_status ros ON ros.local_id = o.roident
    WHERE  sub.sub_target = p_provider_node_id
      AND  sub.sub_origin <> p_subscriber_node_id;

    RAISE NOTICE 'SPOCK cswp slot=% pre_ros=%', p_slot_name, v_pre_ros_lsns;

    -- Try to create slot during an idle window (Case A).
    FOR v_attempt IN 1..v_max_retries LOOP
        -- Probe ros.local_lsn twice with a short gap to detect idle workers.
        SELECT array_agg(COALESCE(ros.local_lsn, '0/0'::pg_lsn) ORDER BY sub.sub_origin)
        INTO   v_prev_local_lsns
        FROM   spock.subscription sub
        JOIN   pg_replication_origin o ON o.roname = sub.sub_slot_name
        LEFT JOIN pg_replication_origin_status ros ON ros.local_id = o.roident
        WHERE  sub.sub_target = p_provider_node_id
          AND  sub.sub_origin <> p_subscriber_node_id;

        PERFORM pg_sleep(0.003);

        SELECT array_agg(COALESCE(ros.local_lsn, '0/0'::pg_lsn) ORDER BY sub.sub_origin)
        INTO   v_curr_local_lsns
        FROM   spock.subscription sub
        JOIN   pg_replication_origin o ON o.roname = sub.sub_slot_name
        LEFT JOIN pg_replication_origin_status ros ON ros.local_id = o.roident
        WHERE  sub.sub_target = p_provider_node_id
          AND  sub.sub_origin <> p_subscriber_node_id;

        v_idle := (v_prev_local_lsns IS NOT DISTINCT FROM v_curr_local_lsns);

        -- Re-capture pre_ros each iteration to keep it fresh.
        SELECT array_agg(sub.sub_origin ORDER BY sub.sub_origin),
               array_agg(COALESCE(ros.remote_lsn, '0/0'::pg_lsn) ORDER BY sub.sub_origin)
        INTO   v_pre_peer_ids, v_pre_ros_lsns
        FROM   spock.subscription sub
        JOIN   pg_replication_origin o ON o.roname = sub.sub_slot_name
        LEFT JOIN pg_replication_origin_status ros ON ros.local_id = o.roident
        WHERE  sub.sub_target = p_provider_node_id
          AND  sub.sub_origin <> p_subscriber_node_id;

        SELECT s.lsn INTO v_lsn
        FROM pg_create_logical_replication_slot(p_slot_name, 'spock_output') s;

        RAISE NOTICE 'SPOCK cswp slot=% v_lsn=% attempt=%/% idle=%',
            p_slot_name, v_lsn, v_attempt, v_max_retries, v_idle;

        -- Check if all peers have ros.local_lsn <= v_lsn (Case A).
        SELECT bool_and(COALESCE(ros.local_lsn <= v_lsn, false))
        INTO   v_all_case_a
        FROM   spock.subscription sub
        JOIN   pg_replication_origin o ON o.roname = sub.sub_slot_name
        LEFT JOIN pg_replication_origin_status ros ON ros.local_id = o.roident
        WHERE  sub.sub_target = p_provider_node_id
          AND  sub.sub_origin <> p_subscriber_node_id;

        EXIT WHEN v_all_case_a IS NOT FALSE OR v_attempt = v_max_retries;

        PERFORM pg_drop_replication_slot(p_slot_name);
        PERFORM pg_sleep(CASE WHEN v_idle THEN 0.005 ELSE 0.02 + 0.002 * v_attempt END);
    END LOOP;

    -- Export snapshot for the COPY worker.
    v_snap := pg_export_snapshot();

    -- Header row: lsn + snapshot only.
    lsn      := v_lsn;
    snapshot := v_snap;
    RETURN NEXT;

    -- Emit one progress row per peer with P_snap derivation.
    -- Case A (ros.local_lsn <= v_lsn): use ros.remote_lsn (exact).
    -- Case B (ros.local_lsn > v_lsn): use ros.remote_lsn (slightly high but safe).
    FOR rec IN (
        SELECT p.dbid, p.node_id, p.remote_node_id,
               p.remote_commit_ts, p.prev_remote_ts,
           p.remote_commit_lsn      AS grp_remote_commit_lsn,
               p.remote_insert_lsn,
               p.received_lsn, p.last_updated_ts, p.updated_by_decode,
               ros.remote_lsn             AS ros_remote_lsn,
               ros.local_lsn              AS ros_local_lsn,
               sub.sub_slot_name          AS sub_slot_name,
               o.roident                  AS roident
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

        v_pre_idx     := array_position(v_pre_peer_ids, rec.remote_node_id);
        v_pre_ros_lsn := CASE WHEN v_pre_idx IS NOT NULL
                         THEN v_pre_ros_lsns[v_pre_idx]
                         ELSE '0/0'::pg_lsn END;

        lsn               := v_lsn;
        snapshot          := v_snap;
        dbid              := rec.dbid;
        node_id           := rec.node_id;
        remote_node_id    := rec.remote_node_id;
        remote_commit_ts  := rec.remote_commit_ts;
        prev_remote_ts    := rec.prev_remote_ts;

        IF rec.ros_local_lsn IS NOT NULL AND rec.ros_local_lsn <= v_lsn THEN
          -- Case A: double-sample ros to reduce stale-read window.
          SELECT ros.remote_lsn, ros.local_lsn
          INTO   v_ros2_remote_lsn, v_ros2_local_lsn
          FROM   pg_replication_origin_status ros
          WHERE  ros.local_id = rec.roident;

          IF v_ros2_local_lsn IS NOT NULL AND v_ros2_local_lsn <= v_lsn THEN
            remote_commit_lsn := GREATEST(
              COALESCE(rec.ros_remote_lsn, '0/0'::pg_lsn),
              COALESCE(v_ros2_remote_lsn, '0/0'::pg_lsn)
            );
          ELSE
            remote_commit_lsn := COALESCE(rec.ros_remote_lsn, '0/0'::pg_lsn);
          END IF;
        ELSE
          -- Case B: use ros.remote_lsn with grp/pre_ros fallbacks.
          remote_commit_lsn := COALESCE(rec.ros_remote_lsn,
                          rec.grp_remote_commit_lsn,
                          v_pre_ros_lsn,
                          '0/0'::pg_lsn);
        END IF;

        remote_insert_lsn := rec.remote_insert_lsn;
        received_lsn      := rec.received_lsn;
        last_updated_ts   := rec.last_updated_ts;
        updated_by_decode := rec.updated_by_decode;

        RAISE NOTICE 'SPOCK cswp peer=% case=% P_snap=%',
            rec.remote_node_id,
            CASE WHEN rec.ros_local_lsn IS NOT NULL AND rec.ros_local_lsn <= v_lsn THEN 'A' ELSE 'B' END,
            remote_commit_lsn;

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

 SELECT t.typname,t.typinput,t.typoutput, a.attnotnull
  FROM pg_catalog.pg_attribute a, pg_type t
  WHERE a.attrelid = rel AND a.attname = att_name AND (a.atttypid = t.oid)
  INTO attdata;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'column % does not exist in the table %', att_name, rel;
  END IF;

  IF (attdata.attnotnull = false) THEN
    /*
	 * TODO: Here is a case where the table has different constraints on nodes.
	 * Using prepared transactions, we might be sure this operation will finish
	 * if only each node satisfies the rule. But we need to add support for 2PC
	 * commit beforehand.
	 */
    RAISE NOTICE USING
	  MESSAGE = format('delta_apply feature can not be applied to nullable column %L of the table %I',
						att_name, rel),
	  HINT = 'Set NOT NULL constraint on the column',
	  ERRCODE = 'object_not_in_prerequisite_state';
	RETURN false;
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
