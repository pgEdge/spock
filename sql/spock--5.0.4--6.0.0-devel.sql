/* spock--5.0.4--6.0.0.devel.sql */

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

DROP PROCEDURE spock.wait_for_sync_event(OUT bool, oid, pg_lsn, int);
CREATE PROCEDURE spock.wait_for_sync_event(
	OUT result bool,
	origin_id  oid,
	lsn        pg_lsn,
	timeout    int DEFAULT 0
) AS $$
DECLARE
	target_id		oid;
	elapsed_time	numeric := 0;
	progress_lsn	pg_lsn;
BEGIN
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Origin node ''%'' not found', origin_id;
	END IF;
	target_id := node_id FROM spock.node_info();

	WHILE true LOOP
		SELECT	INTO progress_lsn ros.remote_lsn
		FROM	spock.subscription s
				INNER JOIN pg_replication_origin_status ros
				ON ros.external_id = s.sub_slot_name
		WHERE	s.sub_origin = origin_id
		AND  	s.sub_target = target_id;

		IF progress_lsn IS NULL THEN
			RAISE EXCEPTION 'Could not fetch progress for origin_id ''%''', origin_id;
		END IF;

		IF progress_lsn >= lsn THEN
			result := true;
			RETURN;
		END IF;
		elapsed_time := elapsed_time + .2;
		IF timeout <> 0 AND elapsed_time >= timeout THEN
			result := false;
			RETURN;
		END IF;

		PERFORM pg_sleep(0.2);
	END LOOP;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

DROP PROCEDURE spock.wait_for_sync_event(OUT bool, name, pg_lsn, int);
CREATE PROCEDURE spock.wait_for_sync_event(
	OUT result bool,
	origin     name,
	lsn        pg_lsn,
	timeout    int DEFAULT 0
) AS $$
DECLARE
	origin_id		oid;
	target_id		oid;
	elapsed_time	numeric := 0;
	progress_lsn	pg_lsn;
BEGIN
	origin_id := node_id FROM spock.node WHERE node_name = origin;
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Origin node ''%'' not found', origin;
	END IF;
	target_id := node_id FROM spock.node_info();

	WHILE true LOOP
		SELECT	INTO progress_lsn ros.remote_lsn
		FROM	spock.subscription s
				INNER JOIN pg_replication_origin_status ros
				ON ros.external_id = s.sub_slot_name
		WHERE	s.sub_origin = origin_id
		AND  	s.sub_target = target_id;

		IF progress_lsn IS NULL THEN
			RAISE EXCEPTION 'Could not fetch progress for origin ''%''', origin;
		END IF;

		IF progress_lsn >= lsn THEN
			result := true;
			RETURN;
		END IF;

		elapsed_time := elapsed_time + .2;
		IF timeout <> 0 AND elapsed_time >= timeout THEN
			result := false;
			RETURN;
		END IF;

		PERFORM pg_sleep(0.2);
	END LOOP;

END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
