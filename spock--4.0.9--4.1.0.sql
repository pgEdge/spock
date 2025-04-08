
/* spock--4.0.9--4.1.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '4.1.0'" to load this file. \quit

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

-- Recreate function spock.sub_create() to add enabled=true argument
DROP FUNCTION spock.sub_create(name, text, text[], boolean, boolean,
    text[], interval, boolean, boolean);
CREATE FUNCTION spock.sub_create(subscription_name name, provider_dsn text,
    replication_sets text[] = '{default,default_insert_only,ddl_sql}', synchronize_structure boolean = false,
    synchronize_data boolean = false, forward_origins text[] = '{}', apply_delay interval DEFAULT '0',
    force_text_transfer boolean = false,
    enabled boolean = true)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_subscription';
