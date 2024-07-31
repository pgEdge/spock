/* spock--4.0.0--4.0.1.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '4.0.1'" to load this file. \quit

CREATE TABLE spock.exception_status (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts)
) WITH (user_catalog_table=true);

CREATE TABLE spock.exception_status_detail (
	remote_origin oid NOT NULL,
    remote_commit_ts timestamptz NOT NULL,
	command_counter integer NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts, command_counter),
	FOREIGN KEY(remote_origin, remote_commit_ts)
		REFERENCES spock.exception_status
) WITH (user_catalog_table=true);
