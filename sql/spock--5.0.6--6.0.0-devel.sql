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

-- spock.create_slot_with_progress(slot_name, provider_node_id, subscriber_node_id)
--
-- Atomically creates a replication slot and reads spock.progress for all peers
-- in one server-side call, eliminating the slot+progress race.  Called in an
-- open REPEATABLE READ transaction; caller must ROLLBACK after the COPY.
-- Row 0: lsn + snapshot header.  Rows 1+: one progress entry each.
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
BEGIN
    RAISE NOTICE 'SPOCK cswp[enter] slot=% provider_node=% subscriber_node=%',
        p_slot_name, p_provider_node_id, p_subscriber_node_id;

    -- -----------------------------------------------------------------------
    -- Step 0: Capture pre-slot ros.remote_lsn for every peer.
    --
    -- This provides a fallback value for the Case B P_snap derivation
    -- (Step 3 below).  If the apply worker commits a new transaction
    -- between this capture and the slot creation, the post-slot ros will
    -- have advanced past v_lsn; in that case, the pre-slot value captured
    -- here is a safe conservative lower bound for P_snap.
    -- -----------------------------------------------------------------------
    SELECT array_agg(sub.sub_origin ORDER BY sub.sub_origin),
           array_agg(COALESCE(ros.remote_lsn, '0/0'::pg_lsn) ORDER BY sub.sub_origin)
    INTO   v_pre_peer_ids, v_pre_ros_lsns
    FROM   spock.subscription sub
    JOIN   pg_replication_origin o ON o.roname = sub.sub_slot_name
    LEFT JOIN pg_replication_origin_status ros ON ros.local_id = o.roident
    WHERE  sub.sub_target = p_provider_node_id
      AND  sub.sub_origin <> p_subscriber_node_id;

    RAISE NOTICE 'SPOCK cswp[pre-slot-ros] slot=% pre_peer_ids=% pre_ros_lsns=% -- captured before slot creation',
        p_slot_name, v_pre_peer_ids, v_pre_ros_lsns;

    -- -----------------------------------------------------------------------
    -- Step 1: Create the replication slot.
    --
    -- This MUST be the first data-accessing statement in the REPEATABLE READ
    -- transaction.  In REPEATABLE READ, PostgreSQL establishes the transaction
    -- snapshot at exactly this point, so the slot's consistent point (v_lsn)
    -- and the COPY snapshot share the same WAL boundary.
    --
    -- Any N2 commit whose WAL record landed on N1 before v_lsn is therefore
    -- visible in the COPY.  Any commit whose WAL record landed after v_lsn is
    -- not in the COPY and also not visible to pg_replication_origin_status
    -- reads performed in this same statement evaluation, because its
    -- ros.local_lsn will be > v_lsn (detectable in Step 3 below).
    -- -----------------------------------------------------------------------
    RAISE NOTICE 'SPOCK cswp[pre-slot] slot=% -- calling pg_create_logical_replication_slot', p_slot_name;

    SELECT s.lsn INTO v_lsn
    FROM pg_create_logical_replication_slot(p_slot_name, 'spock_output') s;

    RAISE NOTICE 'SPOCK cswp[slot] slot=% v_lsn=% -- slot created; REPEATABLE READ snapshot boundary established',
        p_slot_name, v_lsn;

    -- -----------------------------------------------------------------------
    -- Step 2: Export the snapshot for the COPY worker.
    -- -----------------------------------------------------------------------
    v_snap := pg_export_snapshot();

    RAISE NOTICE 'SPOCK cswp[snap] slot=% v_lsn=% snapshot=% -- snapshot exported for COPY worker',
        p_slot_name, v_lsn, v_snap;

    -- Header row: lsn + snapshot only; progress fields all NULL.
    lsn      := v_lsn;
    snapshot := v_snap;
    RETURN NEXT;

    RAISE NOTICE 'SPOCK cswp[header-row] slot=% v_lsn=% snapshot=% -- header row emitted',
        p_slot_name, v_lsn, v_snap;

    -- -----------------------------------------------------------------------
    -- Step 3: Emit one progress row per peer node (P_snap derivation).
    --
    -- Peer enumeration uses PostgreSQL catalog tables (spock.subscription,
    -- pg_replication_origin) which are MVCC-stable heap tables, so the list
    -- of peers is snapshot-consistent.
    --
    -- P_snap (remote_commit_lsn) for each peer is determined by:
    --
    --   Case A  ros.local_lsn <= v_lsn
    --     The peer's last applied commit on N1 landed before the slot's
    --     consistent point.  That commit IS in the COPY snapshot.  Use
    --     ros.remote_lsn as the exact P_snap to feed Phase 7.
    --
    --   Case B  ros.local_lsn > v_lsn  (or ros row absent)
    --     The apply worker advanced past the consistent point just after
    --     slot creation.  That latest commit is NOT in the COPY.  Fall back
    --     to spock.progress.remote_commit_lsn (SpockGroupHash), which lags
    --     ros by one transaction and therefore reflects the commit immediately
    --     before the race -- a pre-snapshot value that is safe to use as a
    --     conservative lower bound for P_snap.
    -- -----------------------------------------------------------------------
    RAISE NOTICE 'SPOCK cswp[peer-enum-start] slot=% v_lsn=% -- querying peers for provider=% excluding subscriber=%',
        p_slot_name, v_lsn, p_provider_node_id, p_subscriber_node_id;

    FOR rec IN (
        SELECT p.dbid, p.node_id, p.remote_node_id,
               p.remote_commit_ts, p.prev_remote_ts,
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

        -- Look up the pre-slot ros value captured in Step 0 for this peer
        v_pre_idx     := array_position(v_pre_peer_ids, rec.remote_node_id);
        v_pre_ros_lsn := CASE WHEN v_pre_idx IS NOT NULL
                         THEN v_pre_ros_lsns[v_pre_idx]
                         ELSE '0/0'::pg_lsn END;

        RAISE NOTICE 'SPOCK cswp[peer-row] slot=% peer=% (#%) sub_slot=% roident=% '
                     'ros_local=% ros_remote=% pre_ros=% v_lsn=% '
                     'ros_present=% ros_local_le_vlsn=%',
            p_slot_name, rec.remote_node_id, v_n_peers,
            rec.sub_slot_name, rec.roident,
            rec.ros_local_lsn, rec.ros_remote_lsn, v_pre_ros_lsn, v_lsn,
            (rec.ros_local_lsn IS NOT NULL),
            (rec.ros_local_lsn IS NOT NULL AND rec.ros_local_lsn <= v_lsn);

        lsn               := v_lsn;
        snapshot          := v_snap;
        dbid              := rec.dbid;
        node_id           := rec.node_id;
        remote_node_id    := rec.remote_node_id;
        remote_commit_ts  := rec.remote_commit_ts;
        prev_remote_ts    := rec.prev_remote_ts;

        -- Case A: ros was last updated before the slot's consistent point,
        --         so ros.remote_lsn is the exact pre-snapshot P_snap.
        -- Case B: ros advanced past v_lsn after slot creation (or is absent);
        --         use the pre-slot ros captured in Step 0 as P_snap.
        --         SpockGroupHash (spock.progress) is NOT used here because it
        --         is updated at the same time as ros (after CommitTransactionCommand)
        --         and may already reflect R_new (post-snapshot), not R_last.
        IF rec.ros_local_lsn IS NOT NULL AND rec.ros_local_lsn <= v_lsn THEN
            remote_commit_lsn := COALESCE(rec.ros_remote_lsn, '0/0'::pg_lsn);
            RAISE NOTICE 'SPOCK cswp[case-A] slot=% peer=% ros_local=% <= v_lsn=% -- using ros_remote=% as P_snap',
                p_slot_name, rec.remote_node_id,
                rec.ros_local_lsn, v_lsn, remote_commit_lsn;
        ELSE
            remote_commit_lsn := v_pre_ros_lsn;
            RAISE NOTICE 'SPOCK cswp[case-B] slot=% peer=% ros_local=% > v_lsn=% (or NULL) -- using pre_ros=% as P_snap',
                p_slot_name, rec.remote_node_id,
                rec.ros_local_lsn, v_lsn, remote_commit_lsn;
        END IF;

        remote_insert_lsn := rec.remote_insert_lsn;
        received_lsn      := rec.received_lsn;
        last_updated_ts   := rec.last_updated_ts;
        updated_by_decode := rec.updated_by_decode;

        RAISE NOTICE 'SPOCK cswp[progress-row] slot=% peer=% P_snap=% remote_insert_lsn=% received_lsn=% remote_commit_ts=% -- emitting progress row',
            p_slot_name, rec.remote_node_id,
            remote_commit_lsn, remote_insert_lsn, received_lsn, remote_commit_ts;

        RETURN NEXT;
    END LOOP;

    IF v_n_peers = 0 THEN
        RAISE NOTICE 'SPOCK cswp[no-peers] slot=% v_lsn=% -- no peer nodes found for provider=% (subscriber=% excluded)',
            p_slot_name, v_lsn, p_provider_node_id, p_subscriber_node_id;
    END IF;

    RAISE NOTICE 'SPOCK cswp[done] slot=% v_lsn=% -- emitted % progress rows (+ 1 header)',
        p_slot_name, v_lsn, v_n_peers;
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
