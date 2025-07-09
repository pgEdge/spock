
/* spock--4.0.10--5.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0'" to load this file. \quit

CREATE TABLE spock.progress (
	node_id oid NOT NULL,
	remote_node_id oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	remote_lsn pg_lsn NOT NULL,
	remote_insert_lsn pg_lsn NOT NULL,
	last_updated_ts timestamptz NOT NULL,
	updated_by_decode bool NOT NULL,
	PRIMARY KEY(node_id, remote_node_id)
) WITH (fillfactor=50);

INSERT INTO spock.progress (node_id, remote_node_id, remote_commit_ts, remote_lsn, remote_insert_lsn, last_updated_ts, updated_by_decode)
	SELECT sub_target, sub_origin, 'epoch'::timestamptz, '0/0', '0/0', 'epoch'::timestamptz, 'f'
	FROM spock.subscription;

DROP VIEW IF EXISTS spock.lag_tracker;
DROP FUNCTION spock.lag_tracker();
CREATE OR REPLACE VIEW spock.lag_tracker AS
	SELECT
		origin.node_name AS origin_name,
		MAX(p.remote_commit_ts) AS commit_timestamp,
		MAX(p.remote_lsn) AS last_received_lsn,
		MAX(p.remote_insert_lsn) AS remote_insert_lsn,
		CASE
			WHEN CAST(MAX(CAST(p.updated_by_decode as int)) as bool) THEN pg_wal_lsn_diff(MAX(p.remote_insert_lsn), MAX(p.remote_lsn))
			ELSE 0
		END AS replication_lag_bytes,
		CASE
			WHEN CAST(MAX(CAST(p.updated_by_decode as int)) as bool) THEN now() - MAX(p.remote_commit_ts)
			ELSE now() - MAX(p.last_updated_ts)
		END AS replication_lag
	FROM spock.progress p
	LEFT JOIN spock.subscription sub ON (p.node_id = sub.sub_target and p.remote_node_id = sub.sub_origin)
	LEFT JOIN spock.node origin ON sub.sub_origin = origin.node_id
	GROUP BY origin.node_name;

CREATE FUNCTION spock.sync_event()
RETURNS pg_lsn RETURNS NULL ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_sync_event';

CREATE PROCEDURE spock.wait_for_sync_event(OUT result bool, origin_id oid, lsn pg_lsn, timeout int DEFAULT 0)
AS $$
DECLARE
	target_id		oid;
	elapsed_time	numeric := 0;
	progress_lsn	pg_lsn;
BEGIN
	IF origin_id IS NULL THEN
		RAISE EXCEPTION 'Origin node ''%'' not found', origin;
	END IF;
	target_id := node_id FROM spock.node_info();

	WHILE true LOOP
		SELECT INTO progress_lsn remote_lsn
			FROM spock.progress
			WHERE node_id = target_id AND remote_node_id = origin_id;
		IF progress_lsn >= lsn THEN
			result = true;
			RETURN;
		END IF;
		elapsed_time := elapsed_time + .2;
		IF timeout <> 0 AND elapsed_time >= timeout THEN
			result := false;
			RETURN;
		END IF;

		ROLLBACK;
		PERFORM pg_sleep(0.2);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

CREATE PROCEDURE spock.wait_for_sync_event(OUT result bool, origin name, lsn pg_lsn, timeout int DEFAULT 0)
AS $$
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
		SELECT INTO progress_lsn remote_lsn
			FROM spock.progress
			WHERE node_id = target_id AND remote_node_id = origin_id;
		IF progress_lsn >= lsn THEN
			result = true;
			RETURN;
		END IF;
		elapsed_time := elapsed_time + .2;
		IF timeout <> 0 AND elapsed_time >= timeout THEN
			result := false;
			RETURN;
		END IF;

		ROLLBACK;
		PERFORM pg_sleep(0.2);
	END LOOP;
END;
$$ LANGUAGE plpgsql;

--
-- Function definition updated to include new 'enabled' parameter.
--
DROP FUNCTION spock.sub_create(name, text, text[], boolean, boolean, text[], interval, boolean);
CREATE FUNCTION spock.sub_create(subscription_name name, provider_dsn text,
    replication_sets text[] = '{default,default_insert_only,ddl_sql}', synchronize_structure boolean = false,
    synchronize_data boolean = false, forward_origins text[] = '{}', apply_delay interval DEFAULT '0',
    force_text_transfer boolean = false,
	enabled boolean = true)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_subscription';

-- ----
-- Function to determine LSN from commit timestamp
-- ----
CREATE FUNCTION spock.get_lsn_from_commit_ts(slot_name name, commit_ts timestamptz)
RETURNS pg_lsn STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_lsn_from_commit_ts';

CREATE OR REPLACE FUNCTION spock.get_apply_worker_status(
    OUT worker_pid bigint, -- Changed from int to bigint
    OUT worker_dboid int,
    OUT worker_subid bigint,
    OUT worker_status text
)
RETURNS SETOF record STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'get_apply_worker_status';

CREATE FUNCTION spock.wait_for_apply_worker(p_subbid bigint, timeout int DEFAULT 0)
RETURNS boolean
AS $$
DECLARE
    start_time timestamptz := clock_timestamp();
    elapsed_time int := 0;
    current_status text;
BEGIN
    -- Loop until the timeout is reached or the worker is no longer running
    WHILE true LOOP
        -- Call spock.get_apply_worker_status to check the worker's status
        SELECT worker_status
        INTO current_status
        FROM spock.get_apply_worker_status()
        WHERE worker_subid = p_subbid;

        -- If no row is found, return -1
        IF NOT FOUND THEN
            RETURN false;
        END IF;

        -- If the worker is no longer running, return 0
        IF current_status IS DISTINCT FROM 'running' THEN
            RETURN false;
        END IF;

        -- Check if the timeout has been reached
        elapsed_time := EXTRACT(EPOCH FROM clock_timestamp() - start_time) * 1000;
        IF timeout > 0 AND elapsed_time >= timeout THEN
            RETURN true;
        END IF;

        -- Sleep for a short interval before checking again
        PERFORM pg_sleep(0.2);
    END LOOP;
END;
$$ LANGUAGE plpgsql;
