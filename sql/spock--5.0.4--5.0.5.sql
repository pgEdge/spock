/* spock--5.0.4--5.0.5.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '5.0.5'" to load this file. \quit
\echo Use "CREATE EXTENSION spock" to load this file. \quit

DROP PROCEDURE IF EXISTS spock.wait_for_sync_event(oid, pg_lsn, int);

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
		RAISE EXCEPTION 'Origin node ''%'' not found', origin;
	END IF;
	target_id := node_id FROM spock.node_info();

	WHILE true LOOP
		-- If an unresolvable issue occurs with the apply worker, the LR
		-- progress gets stuck, and we need to check the subscription's state
		-- carefully.
		IF NOT EXISTS (SELECT * FROM spock.subscription
					  WHERE sub_origin = origin_id AND
							sub_target = target_id AND
							sub_enabled = true) THEN
			RAISE EXCEPTION 'Replication % => % does not have any enabled subscription yet',
							origin_id, target_id;
		END IF;

		SELECT INTO progress_lsn remote_commit_lsn
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

DROP PROCEDURE IF EXISTS spock.wait_for_sync_event(name, pg_lsn, int);

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
		-- If an unresolvable issue occurs with the apply worker, the LR
		-- progress gets stuck, and we need to check the subscription's state
		-- carefully.
		IF NOT EXISTS (SELECT * FROM spock.subscription
					  WHERE sub_origin = origin_id AND
							sub_target = target_id AND
							sub_enabled = true) THEN
			RAISE EXCEPTION 'Replication % => % does not have any enabled subscription yet',
							origin_id, target_id;
		END IF;

		SELECT INTO progress_lsn remote_commit_lsn
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

