\echo Use "CREATE EXTENSION spock" to load this file. \quit

CREATE TABLE spock.node (
    node_id oid NOT NULL PRIMARY KEY,
    node_name name NOT NULL UNIQUE,
    location text,
    country text,
    info jsonb
) WITH (user_catalog_table=true);

CREATE TABLE spock.node_interface (
    if_id oid NOT NULL PRIMARY KEY,
    if_name name NOT NULL, -- default same as node name
    if_nodeid oid REFERENCES node(node_id) ON UPDATE CASCADE,
    if_dsn text NOT NULL,
    UNIQUE (if_nodeid, if_name)
);

CREATE TABLE spock.local_node (
    node_id oid PRIMARY KEY REFERENCES node(node_id),
    node_local_interface oid NOT NULL REFERENCES node_interface(if_id)
);

CREATE TABLE spock.subscription (
    sub_id oid NOT NULL PRIMARY KEY,
    sub_name name NOT NULL UNIQUE,
    sub_origin oid NOT NULL REFERENCES node(node_id) ON UPDATE CASCADE,
    sub_target oid NOT NULL REFERENCES node(node_id) ON UPDATE CASCADE,
    sub_origin_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_target_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_enabled boolean NOT NULL DEFAULT true,
    sub_slot_name name NOT NULL,
    sub_replication_sets text[],
    sub_forward_origins text[],
    sub_apply_delay interval NOT NULL DEFAULT '0',
    sub_force_text_transfer boolean NOT NULL DEFAULT 'f',
	sub_skip_lsn pg_lsn NOT NULL DEFAULT '0/0',
	sub_skip_schema text[]
);
-- Source for sub_id values.
CREATE SEQUENCE spock.sub_id_generator AS integer MINVALUE 1 CYCLE START WITH 1 OWNED BY spock.subscription.sub_id;

CREATE TABLE spock.local_sync_status (
    sync_kind "char" NOT NULL CHECK (sync_kind IN ('i', 's', 'd', 'f')),
    sync_subid oid NOT NULL REFERENCES spock.subscription(sub_id),
    sync_nspname name,
    sync_relname name,
    sync_status "char" NOT NULL,
	sync_statuslsn pg_lsn NOT NULL,
    UNIQUE (sync_subid, sync_nspname, sync_relname)
);

CREATE TABLE spock.exception_log (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	command_counter integer NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	local_origin oid,
	local_commit_ts timestamptz,
	table_schema text,
	table_name text,
	operation text,
	local_tup jsonb,
	remote_old_tup jsonb,
	remote_new_tup jsonb,
	ddl_statement text,
	ddl_user text,
	error_message text NOT NULL,
	PRIMARY KEY(remote_origin, remote_commit_ts,
				command_counter, retry_errored_at)
) WITH (user_catalog_table=true);

CREATE TABLE spock.exception_status (
	remote_origin oid NOT NULL,
	remote_commit_ts timestamptz NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts, retry_errored_at)
) WITH (user_catalog_table=true);

CREATE TABLE spock.exception_status_detail (
	remote_origin oid NOT NULL,
    remote_commit_ts timestamptz NOT NULL,
	command_counter integer NOT NULL,
	retry_errored_at timestamptz NOT NULL,
	remote_xid bigint NOT NULL,
	status text NOT NULL,
	resolved_at timestamptz,
	resolution_details jsonb,
	PRIMARY KEY(remote_origin, remote_commit_ts,
				command_counter, retry_errored_at),
	FOREIGN KEY(remote_origin, remote_commit_ts, retry_errored_at)
		REFERENCES spock.exception_status
) WITH (user_catalog_table=true);

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

CREATE FUNCTION spock.node_create(node_name name, dsn text,
    location text DEFAULT NULL, country text DEFAULT NULL,
    info jsonb DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_node';
CREATE FUNCTION spock.node_drop(node_name name, ifexists boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_node';

CREATE FUNCTION spock.node_add_interface(node_name name, interface_name name, dsn text)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_node_add_interface';
CREATE FUNCTION spock.node_drop_interface(node_name name, interface_name name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_node_drop_interface';

CREATE FUNCTION spock.sub_create(subscription_name name, provider_dsn text,
    replication_sets text[] = '{default,default_insert_only,ddl_sql}', synchronize_structure boolean = false,
    synchronize_data boolean = false, forward_origins text[] = '{}', apply_delay interval DEFAULT '0',
    force_text_transfer boolean = false,
	enabled boolean = true, skip_schema text[] = '{}')
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_subscription';
CREATE FUNCTION spock.sub_drop(subscription_name name, ifexists boolean DEFAULT false)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_subscription';

CREATE FUNCTION spock.sub_alter_interface(subscription_name name, interface_name name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_interface';

CREATE FUNCTION spock.sub_disable(subscription_name name, immediate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_disable';
CREATE FUNCTION spock.sub_enable(subscription_name name, immediate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_enable';

CREATE FUNCTION spock.sub_add_repset(subscription_name name, replication_set name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_add_replication_set';
CREATE FUNCTION spock.sub_remove_repset(subscription_name name, replication_set name)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_remove_replication_set';
CREATE FUNCTION spock.sub_alter_skiplsn(subscription_name name, lsn pg_lsn)
	RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_skip_lsn';

CREATE FUNCTION spock.sub_show_status(subscription_name name DEFAULT NULL,
    OUT subscription_name text, OUT status text, OUT provider_node text,
    OUT provider_dsn text, OUT slot_name text, OUT replication_sets text[],
    OUT forward_origins text[])
RETURNS SETOF record STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_subscription_status';

CREATE TABLE spock.replication_set (
    set_id oid NOT NULL PRIMARY KEY,
    set_nodeid oid NOT NULL REFERENCES node(node_id) ON UPDATE CASCADE,
    set_name name NOT NULL,
    replicate_insert boolean NOT NULL DEFAULT true,
    replicate_update boolean NOT NULL DEFAULT true,
    replicate_delete boolean NOT NULL DEFAULT true,
    replicate_truncate boolean NOT NULL DEFAULT true,
    UNIQUE (set_nodeid, set_name)
) WITH (user_catalog_table=true);

CREATE TABLE spock.replication_set_table (
    set_id oid NOT NULL,
    set_reloid regclass NOT NULL,
    set_att_list text[],
    set_row_filter pg_node_tree,
    PRIMARY KEY(set_id, set_reloid)
) WITH (user_catalog_table=true);

CREATE TABLE spock.replication_set_seq (
    set_id oid NOT NULL,
    set_seqoid regclass NOT NULL,
    PRIMARY KEY(set_id, set_seqoid)
) WITH (user_catalog_table=true);

CREATE TABLE spock.sequence_state (
	seqoid oid NOT NULL PRIMARY KEY,
	cache_size integer NOT NULL,
	last_value bigint NOT NULL
) WITH (user_catalog_table=true);

CREATE TABLE spock.depend (
    classid oid NOT NULL,
    objid oid NOT NULL,
    objsubid integer NOT NULL,

    refclassid oid NOT NULL,
    refobjid oid NOT NULL,
    refobjsubid integer NOT NULL,

	deptype "char" NOT NULL
) WITH (user_catalog_table=true);

CREATE TABLE spock.pii (
    id int generated always as identity,
    pii_schema text NOT NULL,
    pii_table text NOT NULL,
    pii_column text NOT NULL,
    PRIMARY KEY(id)
) WITH (user_catalog_table=true);

CREATE TABLE spock.resolutions (
    id int generated always as identity,
    node_name name NOT NULL,
    log_time timestamptz NOT NULL,
    relname text,
    idxname text,
    conflict_type text,
    conflict_resolution text,

    -- columns for local changes
    local_origin int,
    local_tuple text,
    local_xid xid,
    local_timestamp timestamptz,

    -- columns for remote changes
    remote_origin int,
    remote_tuple text,
    remote_xid xid,
    remote_timestamp timestamptz,
    remote_lsn pg_lsn,

    PRIMARY KEY(id, node_name)
) WITH (user_catalog_table=true);

CREATE VIEW spock.TABLES AS
    WITH set_relations AS (
        SELECT s.set_name, r.set_reloid
          FROM spock.replication_set_table r,
               spock.replication_set s,
               spock.local_node n
         WHERE s.set_nodeid = n.node_id
           AND s.set_id = r.set_id
    ),
    user_tables AS (
        SELECT r.oid, n.nspname, r.relname, r.relreplident
          FROM pg_catalog.pg_class r,
               pg_catalog.pg_namespace n
         WHERE r.relkind IN ('r', 'p')
           AND r.relpersistence = 'p'
           AND n.oid = r.relnamespace
           AND n.nspname !~ '^pg_'
           AND n.nspname != 'information_schema'
           AND n.nspname != 'spock'
    )
    SELECT r.oid AS relid, n.nspname, r.relname, s.set_name
      FROM pg_catalog.pg_namespace n,
           pg_catalog.pg_class r,
           set_relations s
     WHERE r.relkind IN ('r', 'p')
       AND n.oid = r.relnamespace
       AND r.oid = s.set_reloid
     UNION
    SELECT t.oid AS relid, t.nspname, t.relname, NULL
      FROM user_tables t
     WHERE t.oid NOT IN (SELECT set_reloid FROM set_relations);

CREATE FUNCTION spock.repset_create(set_name name,
    replicate_insert boolean = true, replicate_update boolean = true,
    replicate_delete boolean = true, replicate_truncate boolean = true)
RETURNS oid STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_replication_set';
CREATE FUNCTION spock.repset_alter(set_name name,
    replicate_insert boolean DEFAULT NULL, replicate_update boolean DEFAULT NULL,
    replicate_delete boolean DEFAULT NULL, replicate_truncate boolean DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_replication_set';
CREATE FUNCTION spock.repset_drop(set_name name, ifexists boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_replication_set';

CREATE FUNCTION spock.repset_add_table(set_name name, relation regclass, synchronize_data boolean DEFAULT false,
	columns text[] DEFAULT NULL, row_filter text DEFAULT NULL, include_partitions boolean default true)
RETURNS boolean CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_table';
CREATE FUNCTION spock.repset_add_all_tables(set_name name, schema_names text[], synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_all_tables';
CREATE FUNCTION spock.repset_remove_table(set_name name, relation regclass, include_partitions boolean default true)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_table';

CREATE FUNCTION spock.repset_add_seq(set_name name, relation regclass, synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_sequence';
CREATE FUNCTION spock.repset_add_all_seqs(set_name name, schema_names text[], synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_all_sequences';
CREATE FUNCTION spock.repset_remove_seq(set_name name, relation regclass)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_sequence';

CREATE FUNCTION spock.repset_add_partition(parent regclass, partition regclass default NULL,
    row_filter text default NULL)
RETURNS int CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_partition';

CREATE FUNCTION spock.repset_remove_partition(parent regclass, partition regclass default NULL)
RETURNS int CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_partition';

CREATE FUNCTION spock.sub_alter_sync(subscription_name name, truncate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_synchronize';

CREATE FUNCTION spock.sub_resync_table(
	subscription_name name,
	relation          regclass,
	truncate          boolean DEFAULT true
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_alter_subscription_resynchronize_table'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION spock.sync_seq(relation regclass)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_synchronize_sequence';

CREATE FUNCTION spock.table_data_filtered(reltyp anyelement, relation regclass, repsets text[])
RETURNS SETOF anyelement CALLED ON NULL INPUT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_table_data_filtered';

CREATE FUNCTION spock.repset_show_table(relation regclass, repsets text[], OUT relid oid, OUT nspname text,
	OUT relname text, OUT att_list text[], OUT has_row_filter boolean, OUT relkind "char", OUT relispartition boolean)
RETURNS record STRICT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_repset_table_info';

CREATE FUNCTION spock.sub_show_table(subscription_name name, relation regclass, OUT nspname text, OUT relname text, OUT status text)
RETURNS record STRICT STABLE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_subscription_table';

CREATE TABLE spock.queue (
    queued_at timestamp with time zone NOT NULL,
    role name NOT NULL,
    replication_sets text[],
    message_type "char" NOT NULL,
    message json NOT NULL
);

CREATE FUNCTION spock.replicate_ddl(command text,
									replication_sets text[] DEFAULT '{ddl_sql}',
									search_path text DEFAULT current_setting('search_path'),
									role text DEFAULT CURRENT_USER)
RETURNS boolean STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replicate_ddl_command';

CREATE FUNCTION spock.replicate_ddl(command text[],
									replication_sets text[] DEFAULT '{ddl_sql}',
									search_path text DEFAULT current_setting('search_path'),
									role text DEFAULT CURRENT_USER)
RETURNS SETOF boolean STRICT VOLATILE LANGUAGE sql AS
    'SELECT spock.replicate_ddl(cmd, $2, $3, $4) FROM (SELECT unnest(command) cmd)';

CREATE FUNCTION spock.node_info(OUT node_id oid, OUT node_name text,
    OUT sysid text, OUT dbname text, OUT replication_sets text,
    OUT location text, OUT country text, OUT info jsonb)
RETURNS record
STABLE STRICT LANGUAGE c AS 'MODULE_PATHNAME', 'spock_node_info';

CREATE FUNCTION spock.spock_gen_slot_name(name, name, name)
RETURNS name
IMMUTABLE STRICT LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_version() RETURNS text
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_version_num() RETURNS integer
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_max_proto_version() RETURNS integer
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock_min_proto_version() RETURNS integer
LANGUAGE c AS 'MODULE_PATHNAME';

CREATE FUNCTION spock.get_country() RETURNS text
LANGUAGE sql AS
$$ SELECT current_setting('spock.country') $$;

CREATE FUNCTION spock.wait_slot_confirm_lsn(slotname name, target pg_lsn)
RETURNS void
AS 'spock','spock_wait_slot_confirm_lsn'
LANGUAGE C;

CREATE FUNCTION spock.sub_wait_for_sync(subscription_name name)
RETURNS void RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_wait_for_subscription_sync_complete'
LANGUAGE C VOLATILE;

CREATE FUNCTION spock.table_wait_for_sync(
	subscription_name name,
	relation          regclass
) RETURNS void RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_wait_for_table_sync_complete'
LANGUAGE C VOLATILE;

CREATE FUNCTION spock.sync_event()
RETURNS pg_lsn RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_create_sync_event'
LANGUAGE C VOLATILE;

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

CREATE FUNCTION spock.xact_commit_timestamp_origin("xid" xid, OUT "timestamp" timestamptz, OUT "roident" oid)
RETURNS record RETURNS NULL ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_xact_commit_timestamp_origin';

CREATE FUNCTION spock.get_channel_stats(
    OUT subid oid,
	OUT relid oid,
    OUT n_tup_ins bigint,
    OUT n_tup_upd bigint,
    OUT n_tup_del bigint,
	OUT n_conflict bigint,
	OUT n_dca bigint)
RETURNS SETOF record
LANGUAGE c AS 'MODULE_PATHNAME', 'get_channel_stats';

CREATE FUNCTION spock.reset_channel_stats() RETURNS void
LANGUAGE c AS 'MODULE_PATHNAME', 'reset_channel_stats';

CREATE VIEW spock.channel_table_stats AS
  SELECT H.subid, H.relid,
	 CASE H.subid
	 	WHEN 0 THEN '<output>'
		ELSE S.sub_name
	 END AS sub_name,
	 pg_catalog.quote_ident(N.nspname) || '.' || pg_catalog.quote_ident(C.relname) AS table_name,
	 H.n_tup_ins, H.n_tup_upd, H.n_tup_del,
	 H.n_conflict, H.n_dca
  FROM spock.get_channel_stats() AS H
  LEFT JOIN spock.subscription AS S ON S.sub_id = H.subid
  LEFT JOIN pg_catalog.pg_class AS C ON C.oid = H.relid
  LEFT JOIN pg_catalog.pg_namespace AS N ON N.oid = C.relnamespace;

CREATE VIEW spock.channel_summary_stats AS
  SELECT subid, sub_name,
     sum(n_tup_ins) AS n_tup_ins,
     sum(n_tup_upd) AS n_tup_upd,
     sum(n_tup_del) AS n_tup_del,
     sum(n_conflict) AS n_conflict,
     sum(n_dca) AS n_dca
  FROM spock.channel_table_stats
  GROUP BY subid, sub_name;

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

CREATE FUNCTION spock.md5_agg_sfunc(text, anyelement)
	RETURNS text
	LANGUAGE sql
AS
$$
	SELECT md5($1 || $2::text)
$$;
CREATE  AGGREGATE spock.md5_agg (ORDER BY anyelement)
(
	STYPE = text,
	SFUNC = spock.md5_agg_sfunc,
	INITCOND = ''
);

-- ----------------------------------------------------------------------
-- Spock Read Only
-- ----------------------------------------------------------------------
CREATE FUNCTION spock.terminate_active_transactions() RETURNS bool
 AS 'MODULE_PATHNAME', 'spockro_terminate_active_transactions'
 LANGUAGE C STRICT;

-- ----
-- Generic delta apply functions for all numeric data types
-- ----
CREATE FUNCTION spock.delta_apply(int2, int2, int2)
RETURNS int2 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_int2';
CREATE FUNCTION spock.delta_apply(int4, int4, int4)
RETURNS int4 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_int4';
CREATE FUNCTION spock.delta_apply(int8, int8, int8)
RETURNS int8 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_int8';
CREATE FUNCTION spock.delta_apply(float4, float4, float4)
RETURNS float4 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_float4';
CREATE FUNCTION spock.delta_apply(float8, float8, float8)
RETURNS float8 LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_float8';
CREATE FUNCTION spock.delta_apply(numeric, numeric, numeric)
RETURNS numeric LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_numeric';
CREATE FUNCTION spock.delta_apply(money, money, money)
RETURNS money LANGUAGE c AS 'MODULE_PATHNAME', 'delta_apply_money';

-- ----
-- Function to control REPAIR mode
-- ----
CREATE FUNCTION spock.repair_mode(enabled bool)
RETURNS pg_catalog.pg_lsn LANGUAGE c
AS 'MODULE_PATHNAME', 'spock_repair_mode';

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

-- ============================================================================
-- TABLE CONSISTENCY CHECK AND REPAIR - TYPES
-- ============================================================================

-- Table row with metadata
CREATE TYPE spock.table_row AS (
    pk_values text[],
    all_values text[],
    commit_ts timestamptz,
    node_origin text
);

-- Diff result row
CREATE TYPE spock.diff_row AS (
    diff_type text,              -- 'only_local', 'only_remote', 'modified'
    pk_values text[],
    local_values text[],
    remote_values text[],
    local_commit_ts timestamptz,
    remote_commit_ts timestamptz,
    columns_changed text[]
);

-- Repair operation result
CREATE TYPE spock.repair_operation AS (
    operation text,              -- 'DELETE', 'INSERT', 'UPDATE'
    table_name regclass,
    pk_values text[],
    sql_statement text,
    rows_affected bigint,
    success boolean,
    error_msg text,
    execution_time_ms numeric
);

-- Subscription health status
CREATE TYPE spock.subscription_health AS (
    subscription_name name,
    status text,                 -- 'healthy', 'lagging', 'down', 'error'
    provider_dsn text,
    slot_name name,
    replication_lag_bytes bigint,
    replication_lag_seconds numeric,
    last_received_lsn pg_lsn,
    worker_pid int,
    error_count bigint,
    last_error text,
    last_error_time timestamptz
);

-- Node health status
CREATE TYPE spock.node_health AS (
    node_name name,
    node_id oid,
    is_local boolean,
    connection_status text,      -- 'ok', 'timeout', 'failed'
    response_time_ms numeric,
    database_size bigint,
    active_connections int,
    replication_slots int,
    subscriptions int,
    status_detail jsonb
);

-- Table health information
CREATE TYPE spock.table_health AS (
    schema_name name,
    table_name name,
    has_primary_key boolean,
    row_count_estimate bigint,
    table_size bigint,
    last_vacuum timestamptz,
    last_analyze timestamptz,
    n_dead_tup bigint,
    in_replication_set boolean,
    issues text[]
);

-- ============================================================================
-- TABLE CONSISTENCY CHECK AND REPAIR - HELPER FUNCTIONS
-- ============================================================================

-- Get table metadata (schema, table, PK columns, all columns)
CREATE FUNCTION spock.get_table_info(
    p_relation regclass,
    OUT schema_name name,
    OUT table_name name,
    OUT primary_key_cols name[],
    OUT all_cols name[],
    OUT col_types text[]
)
RETURNS record
LANGUAGE c
STRICT
STABLE
AS 'MODULE_PATHNAME', 'spock_get_table_info';

-- Get primary key columns only
CREATE FUNCTION spock.get_primary_key_columns(p_relation regclass)
RETURNS text[]
LANGUAGE c
STRICT
STABLE
AS 'MODULE_PATHNAME', 'spock_get_primary_key_columns';

-- Get all columns
CREATE FUNCTION spock.get_all_columns(p_relation regclass)
RETURNS text[]
LANGUAGE c
STRICT
STABLE
AS 'MODULE_PATHNAME', 'spock_get_all_columns';

-- Fetch local table rows with metadata (PL/pgSQL implementation)
CREATE FUNCTION spock.fetch_table_rows(
    p_relation regclass,
    p_filter text DEFAULT NULL
)
RETURNS SETOF spock.table_row
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_pk_cols text[];
    v_all_cols text[];
    v_sql text;
    v_pk_list text;
    v_all_list text;
BEGIN
    -- Get column arrays and cast to text[]
    v_pk_cols := (SELECT spock.get_primary_key_columns(p_relation))::text[];
    v_all_cols := (SELECT spock.get_all_columns(p_relation))::text[];
    
    IF v_all_cols IS NULL OR array_length(v_all_cols, 1) IS NULL THEN
        RAISE EXCEPTION 'Table % not found or has no columns', p_relation;
    END IF;
    
    -- Handle empty PK case
    IF v_pk_cols IS NULL OR array_length(v_pk_cols, 1) IS NULL THEN
        v_pk_list := 'NULL::text';
    ELSE
        v_pk_list := (
            SELECT string_agg(quote_ident(col) || '::text', ', ')
            FROM unnest(v_pk_cols) AS col
        );
    END IF;
    
    -- Build all columns list
    v_all_list := (
        SELECT string_agg(quote_ident(col) || '::text', ', ')
        FROM unnest(v_all_cols) AS col
    );
    
    -- Build and execute query
    v_sql := format(
        'SELECT ARRAY[%s]::text[] as pk_values, ARRAY[%s]::text[] as all_values, NULL::timestamptz as commit_ts, ''local''::text as node_origin FROM %s',
        COALESCE(v_pk_list, 'NULL::text'),
        v_all_list,
        p_relation::text
    );
    
    IF p_filter IS NOT NULL THEN
        v_sql := v_sql || ' WHERE ' || p_filter;
    END IF;
    
    RETURN QUERY EXECUTE v_sql;
END;
$$;

-- Fetch rows in batches (PL/pgSQL implementation)
CREATE FUNCTION spock.fetch_table_rows_batch(
    p_relation regclass,
    p_filter text DEFAULT NULL,
    p_batch_size int DEFAULT NULL
)
RETURNS SETOF spock.table_row
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    -- For now, just call fetch_table_rows
    -- In future, could implement cursor-based batching
    RETURN QUERY SELECT * FROM spock.fetch_table_rows(p_relation, p_filter);
END;
$$;

-- Get changed column names between two value arrays
CREATE FUNCTION spock.get_changed_columns(
    p_local_values text[],
    p_remote_values text[],
    p_all_cols text[]
)
RETURNS text[]
LANGUAGE c
STRICT
IMMUTABLE
AS 'MODULE_PATHNAME', 'spock_get_changed_columns';

-- Generate DELETE SQL statement
CREATE FUNCTION spock.generate_delete_sql(
    p_relation regclass,
    p_pk_values text[]
)
RETURNS text
LANGUAGE c
STRICT
IMMUTABLE
AS 'MODULE_PATHNAME', 'spock_generate_delete_sql';

-- Generate INSERT...ON CONFLICT (UPSERT) SQL statement
CREATE FUNCTION spock.generate_upsert_sql(
    p_relation regclass,
    p_pk_values text[],
    p_all_values text[],
    p_insert_only boolean DEFAULT false
)
RETURNS text
LANGUAGE c
STRICT
IMMUTABLE
AS 'MODULE_PATHNAME', 'spock_generate_upsert_sql';

-- Check subscription health
CREATE FUNCTION spock.check_subscription_health(p_subscription_name name DEFAULT NULL)
RETURNS SETOF spock.subscription_health
LANGUAGE c
CALLED ON NULL INPUT
STABLE
AS 'MODULE_PATHNAME', 'spock_check_subscription_health';

-- Check table health
CREATE FUNCTION spock.check_table_health(p_relation regclass DEFAULT NULL)
RETURNS SETOF spock.table_health
LANGUAGE c
CALLED ON NULL INPUT
STABLE
AS 'MODULE_PATHNAME', 'spock_check_table_health';

-- ============================================================================
-- ADDITIONAL CONSISTENCY CHECK FUNCTIONS
-- ============================================================================

-- Compare spock configuration across multiple DSNs
CREATE FUNCTION spock.compare_spock_config(p_dsn_list text[])
RETURNS TABLE(
    comparison_key text,
    node_values jsonb
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_dsn text;
    v_conn_name text;
    v_node_name text;
    v_result record;
    v_all_configs jsonb := '{}'::jsonb;
BEGIN
    -- Collect config from each node
    FOREACH v_dsn IN ARRAY p_dsn_list
    LOOP
        v_conn_name := 'config_check_' || pg_backend_pid();
        
        BEGIN
            PERFORM dblink_connect(v_conn_name, v_dsn);
            
            -- Get node name
            SELECT node_name INTO v_node_name
            FROM dblink(v_conn_name, 'SELECT node_name FROM spock.node LIMIT 1')
            AS t(node_name name);
            
            IF v_node_name IS NULL THEN
                v_node_name := v_dsn;
            END IF;
            
            -- Collect subscriptions
            v_all_configs := jsonb_set(
                v_all_configs,
                ARRAY[v_node_name, 'subscriptions'],
                (SELECT jsonb_agg(sub_info)
                 FROM dblink(v_conn_name,
                     'SELECT sub_name, sub_enabled, sub_replication_sets 
                      FROM spock.subscription'
                 ) AS t(sub_name name, sub_enabled boolean, sub_replication_sets text[])
                 sub_info),
                true
            );
            
            -- Collect replication sets
            v_all_configs := jsonb_set(
                v_all_configs,
                ARRAY[v_node_name, 'replication_sets'],
                (SELECT jsonb_agg(rs_info)
                 FROM dblink(v_conn_name,
                     'SELECT set_name, COUNT(*) as table_count
                      FROM spock.replication_set rs
                      LEFT JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
                      GROUP BY set_name'
                 ) AS t(set_name name, table_count bigint)
                 rs_info),
                true
            );
            
            PERFORM dblink_disconnect(v_conn_name);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                PERFORM dblink_disconnect(v_conn_name);
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            RAISE WARNING 'Failed to collect config from %: %', v_dsn, SQLERRM;
        END;
    END LOOP;
    
    -- Return comparison results
    RETURN QUERY
    SELECT 
        'node_config'::text as comparison_key,
        v_all_configs as node_values;
END;
$$;

COMMENT ON FUNCTION spock.compare_spock_config IS
'Compare spock configuration (nodes, subscriptions, replication sets) across multiple database instances.';

-- List all tables in a replication set
CREATE FUNCTION spock.get_repset_tables(p_repset_name name)
RETURNS TABLE(
    schema_name name,
    table_name name,
    reloid oid
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        n.nspname,
        c.relname,
        c.oid
    FROM spock.replication_set rs
    JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
    JOIN pg_class c ON c.oid = rst.set_reloid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE rs.set_name = p_repset_name
    ORDER BY n.nspname, c.relname;
$$;

COMMENT ON FUNCTION spock.get_repset_tables IS
'Get all tables in a replication set with their schema and OID.';

-- List all tables in a schema
CREATE FUNCTION spock.get_schema_tables(p_schema_name name)
RETURNS TABLE(
    table_name name,
    reloid oid,
    has_primary_key boolean,
    row_count_estimate bigint
)
LANGUAGE sql
STABLE
AS $$
    SELECT 
        c.relname,
        c.oid,
        (SELECT COUNT(*) > 0 FROM pg_constraint 
         WHERE conrelid = c.oid AND contype = 'p'),
        pg_stat_get_live_tuples(c.oid)
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = p_schema_name
      AND c.relkind = 'r'
    ORDER BY c.relname;
$$;

COMMENT ON FUNCTION spock.get_schema_tables IS
'Get all tables in a schema with metadata (PK status, estimated row count).';

-- Compare schema objects between nodes
CREATE FUNCTION spock.compare_schema_objects(
    p_dsn_list text[],
    p_schema_name name
)
RETURNS TABLE(
    node_name text,
    tables text[],
    views text[],
    functions text[],
    indexes text[]
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_dsn text;
    v_conn_name text;
    v_node text;
BEGIN
    FOREACH v_dsn IN ARRAY p_dsn_list
    LOOP
        v_conn_name := 'schema_compare_' || pg_backend_pid();
        
        BEGIN
            PERFORM dblink_connect(v_conn_name, v_dsn);
            
            -- Get node identifier
            SELECT COALESCE(
                (SELECT node_name FROM dblink(v_conn_name, 
                 'SELECT node_name FROM spock.node LIMIT 1') 
                 AS t(node_name name)),
                v_dsn
            ) INTO v_node;
            
            -- Get tables
            RETURN QUERY
            SELECT 
                v_node,
                ARRAY(SELECT table_name FROM dblink(v_conn_name,
                    format('SELECT relname FROM pg_class c 
                            JOIN pg_namespace n ON n.oid = c.relnamespace 
                            WHERE n.nspname = %L AND c.relkind = ''r'' 
                            ORDER BY relname', p_schema_name)
                ) AS t(table_name text)),
                ARRAY(SELECT view_name FROM dblink(v_conn_name,
                    format('SELECT relname FROM pg_class c 
                            JOIN pg_namespace n ON n.oid = c.relnamespace 
                            WHERE n.nspname = %L AND c.relkind = ''v'' 
                            ORDER BY relname', p_schema_name)
                ) AS t(view_name text)),
                ARRAY(SELECT func_name FROM dblink(v_conn_name,
                    format('SELECT p.proname FROM pg_proc p 
                            JOIN pg_namespace n ON n.oid = p.pronamespace 
                            WHERE n.nspname = %L 
                            ORDER BY proname', p_schema_name)
                ) AS t(func_name text)),
                ARRAY(SELECT idx_name FROM dblink(v_conn_name,
                    format('SELECT i.relname FROM pg_class i 
                            JOIN pg_namespace n ON n.oid = i.relnamespace 
                            WHERE n.nspname = %L AND i.relkind = ''i'' 
                            ORDER BY relname', p_schema_name)
                ) AS t(idx_name text));
            
            PERFORM dblink_disconnect(v_conn_name);
        EXCEPTION WHEN OTHERS THEN
            BEGIN
                PERFORM dblink_disconnect(v_conn_name);
            EXCEPTION WHEN OTHERS THEN
                NULL;
            END;
            RAISE WARNING 'Failed to compare schema on %: %', v_dsn, SQLERRM;
        END;
    END LOOP;
END;
$$;

COMMENT ON FUNCTION spock.compare_schema_objects IS
'Compare database objects (tables, views, functions, indexes) in a schema across multiple nodes.';

-- ============================================================================
-- SYSTEM VIEWS
-- ============================================================================

-- View all Spock GUC configuration
CREATE VIEW spock.v_config AS
SELECT 
    name,
    setting,
    unit,
    category,
    short_desc,
    extra_desc,
    context,
    vartype,
    source,
    min_val,
    max_val,
    enumvals,
    boot_val,
    reset_val
FROM pg_settings
WHERE name LIKE 'spock.%'
ORDER BY name;

-- View all subscriptions with status
CREATE VIEW spock.v_subscription_status AS
SELECT 
    s.sub_name,
    s.sub_enabled,
    n.node_name as provider_node,
    s.sub_slot_name,
    s.sub_replication_sets,
    w.worker_pid,
    w.worker_status
FROM spock.subscription s
LEFT JOIN spock.node n ON n.node_id = s.sub_origin
LEFT JOIN LATERAL (
    SELECT * FROM spock.get_apply_worker_status() 
    WHERE worker_subid = s.sub_id
) w ON true;

-- View all tables in replication sets
CREATE VIEW spock.v_replicated_tables AS
SELECT 
    n.nspname as schema_name,
    c.relname as table_name,
    rs.set_name as replication_set,
    rst.set_reloid as reloid
FROM spock.replication_set rs
JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
JOIN pg_class c ON c.oid = rst.set_reloid
JOIN pg_namespace n ON n.oid = c.relnamespace
ORDER BY n.nspname, c.relname, rs.set_name;

-- View replication health summary
CREATE VIEW spock.v_replication_health AS
SELECT 
    sub_name,
    CASE 
        WHEN NOT sub_enabled THEN 'disabled'
        WHEN worker_pid IS NULL THEN 'down'
        WHEN worker_status = 'running' THEN 'healthy'
        ELSE worker_status
    END as health_status,
    worker_pid
FROM spock.v_subscription_status;

-- View table health (tables without PK, large tables, bloat, etc)
CREATE VIEW spock.v_table_health AS
SELECT 
    n.nspname as schema_name,
    c.relname as table_name,
    pg_size_pretty(pg_relation_size(c.oid)) as table_size,
    (SELECT COUNT(*) FROM pg_constraint 
     WHERE conrelid = c.oid AND contype = 'p') > 0 as has_primary_key,
    pg_stat_get_live_tuples(c.oid) as live_tuples,
    pg_stat_get_dead_tuples(c.oid) as dead_tuples,
    (SELECT vrt.replication_set FROM spock.v_replicated_tables vrt 
     WHERE vrt.schema_name = n.nspname AND vrt.table_name = c.relname 
     LIMIT 1) as in_replication_set,
    ARRAY(
        SELECT issue FROM (
            SELECT 'no_primary_key' as issue 
            WHERE (SELECT COUNT(*) FROM pg_constraint 
                   WHERE conrelid = c.oid AND contype = 'p') = 0
            UNION ALL
            SELECT 'large_table'
            WHERE pg_relation_size(c.oid) > 10737418240  -- 10GB
            UNION ALL
            SELECT 'high_dead_tuples'
            WHERE pg_stat_get_dead_tuples(c.oid) > pg_stat_get_live_tuples(c.oid) * 0.2
        ) issues
    ) as issues
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind = 'r'
  AND n.nspname NOT IN ('pg_catalog', 'information_schema', 'spock')
ORDER BY pg_relation_size(c.oid) DESC;
