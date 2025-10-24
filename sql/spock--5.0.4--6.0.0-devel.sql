/* spock--5.0.4--6.0.0.devel.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0-devel'" to load this file. \quit

DROP VIEW IF EXISTS spock.lag_tracker;
DROP TABLE IF EXISTS spock.progress;

CREATE FUNCTION spock.apply_group_progress (
	OUT dbid oid,
	OUT node_id oid,
	OUT remote_node_id oid,
	OUT remote_commit_ts timestamptz,
	OUT prev_remote_ts timestamptz,
	OUT remote_commit_lsn pg_lsn,
	OUT remote_insert_lsn pg_lsn,
	OUT last_updated_ts timestamptz,
	OUT updated_by_decode bool
) RETURNS SETOF record
LANGUAGE c AS 'MODULE_PATHNAME', 'get_apply_group_progress';

CREATE VIEW spock.progress AS
	SELECT node_id, remote_node_id, remote_commit_ts,
		   remote_commit_lsn, remote_insert_lsn,
		   last_updated_ts, updated_by_decode
	FROM spock.apply_group_progress();

CREATE VIEW spock.lag_tracker AS
	SELECT
		origin.node_name AS origin_name,
		n.node_name AS receiver_name,
		MAX(p.remote_commit_ts) AS commit_timestamp,
		MAX(p.remote_commit_lsn) AS commit_lsn,
		MAX(p.remote_insert_lsn) AS remote_insert_lsn,
		CASE
			WHEN CAST(MAX(CAST(p.updated_by_decode as int)) as bool) THEN pg_wal_lsn_diff(MAX(p.remote_insert_lsn), MAX(p.remote_commit_lsn))
			ELSE 0
		END AS replication_lag_bytes,
		CASE
			WHEN CAST(MAX(CAST(p.updated_by_decode as int)) as bool) THEN now() - MAX(p.remote_commit_ts)
			ELSE now() - MAX(p.last_updated_ts)
		END AS replication_lag
	FROM spock.progress p
	LEFT JOIN spock.subscription sub ON (p.node_id = sub.sub_target and p.remote_node_id = sub.sub_origin)
	LEFT JOIN spock.node origin ON sub.sub_origin = origin.node_id
	LEFT JOIN spock.node n ON n.node_id = p.node_id
	GROUP BY origin.node_name, n.node_name;

-- Source for sub_id values.
CREATE SEQUENCE spock.sub_id_generator AS integer MINVALUE 1 CYCLE START WITH 1
OWNED BY spock.subscription.sub_id;
