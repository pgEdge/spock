
/* spock--4.0.6--4.1.0.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '4.1.0'" to load this file. \quit

CREATE TABLE spock.progress (
	node_id oid NOT NULL,
	remote_node_id oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	remote_lsn pg_lsn NOT NULL,
	PRIMARY KEY(node_id, remote_node_id)
) WITH (fillfactor=50);

INSERT INTO spock.progress (node_id, remote_node_id, remote_commit_ts, remote_lsn)
	SELECT sub_target, sub_origin, 'epoch'::timestamptz, '0/0'
	FROM spock.subscription;
