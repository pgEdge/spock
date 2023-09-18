\echo Use "CREATE EXTENSION spock" to load this file. \quit

-- ----------------------------------------------------------------------
-- Create the Spock admin and monitor roles
-- ----------------------------------------------------------------------
DO $$
BEGIN
	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_authid WHERE rolname = 'spock_admin') THEN
		CREATE ROLE spock_admin WITH NOLOGIN;
	END IF;
	IF NOT EXISTS (SELECT 1 FROM pg_catalog.pg_authid WHERE rolname = 'spock_monitor') THEN
		CREATE ROLE spock_monitor WITH NOLOGIN;
	END IF;
END;
$$ LANGUAGE plpgsql;

GRANT USAGE ON SCHEMA spock TO spock_admin;
GRANT USAGE ON SCHEMA spock TO spock_monitor;

-- ----------------------------------------------------------------------
-- Create Spock tables
-- ----------------------------------------------------------------------
CREATE TABLE spock.node (
    node_id oid NOT NULL PRIMARY KEY,
    node_name name NOT NULL UNIQUE,
    location text,
    country text,
    info jsonb
) WITH (user_catalog_table=true);
GRANT SELECT ON spock.node TO spock_admin;
GRANT SELECT ON spock.node TO spock_monitor;

CREATE TABLE spock.node_interface (
    if_id oid NOT NULL PRIMARY KEY,
    if_name name NOT NULL, -- default same as node name
    if_nodeid oid REFERENCES node(node_id),
    if_dsn text NOT NULL,
    UNIQUE (if_nodeid, if_name)
);
GRANT SELECT ON spock.node_interface TO spock_admin;

CREATE TABLE spock.local_node (
    node_id oid PRIMARY KEY REFERENCES node(node_id),
    node_local_interface oid NOT NULL REFERENCES node_interface(if_id)
);
GRANT SELECT ON spock.node_interface TO spock_admin;

CREATE TABLE spock.subscription (
    sub_id oid NOT NULL PRIMARY KEY,
    sub_name name NOT NULL UNIQUE,
    sub_origin oid NOT NULL REFERENCES node(node_id),
    sub_target oid NOT NULL REFERENCES node(node_id),
    sub_origin_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_target_if oid NOT NULL REFERENCES node_interface(if_id),
    sub_enabled boolean NOT NULL DEFAULT true,
    sub_slot_name name NOT NULL,
    sub_replication_sets text[],
    sub_forward_origins text[],
    sub_apply_delay interval NOT NULL DEFAULT '0',
    sub_force_text_transfer boolean NOT NULL DEFAULT 'f'
);
GRANT SELECT ON spock.subscription TO spock_admin;

CREATE TABLE spock.local_sync_status (
    sync_kind "char" NOT NULL CHECK (sync_kind IN ('i', 's', 'd', 'f')),
    sync_subid oid NOT NULL REFERENCES spock.subscription(sub_id),
    sync_nspname name,
    sync_relname name,
    sync_status "char" NOT NULL,
	sync_statuslsn pg_lsn NOT NULL,
    UNIQUE (sync_subid, sync_nspname, sync_relname)
);
GRANT SELECT ON spock.local_sync_status TO spock_admin;


CREATE FUNCTION spock.node_create(node_name name, dsn text,
    location text DEFAULT NULL, country text DEFAULT NULL,
    info jsonb DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_node';
GRANT EXECUTE ON FUNCTION spock.node_create TO spock_admin;

CREATE FUNCTION spock.node_drop(node_name name, ifexists boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_node';
GRANT EXECUTE ON FUNCTION spock.node_drop TO spock_admin;

CREATE FUNCTION spock.node_add_interface(node_name name, interface_name name, dsn text)
RETURNS oid STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_node_add_interface';
GRANT EXECUTE ON FUNCTION spock.node_add_interface TO spock_admin;

CREATE FUNCTION spock.node_drop_interface(node_name name, interface_name name)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_node_drop_interface';
GRANT EXECUTE ON FUNCTION spock.node_drop_interface TO spock_admin;

CREATE FUNCTION spock.sub_create(subscription_name name, provider_dsn text,
    replication_sets text[] = '{default,default_insert_only,ddl_sql}', synchronize_structure boolean = false,
    synchronize_data boolean = false, forward_origins text[] = '{}', apply_delay interval DEFAULT '0',
    force_text_transfer boolean = false)
RETURNS oid STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_subscription';
GRANT EXECUTE ON FUNCTION spock.sub_create TO spock_admin;

CREATE FUNCTION spock.sub_drop(subscription_name name, ifexists boolean DEFAULT false)
RETURNS oid STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_subscription';
GRANT EXECUTE ON FUNCTION spock.sub_drop TO spock_admin;

CREATE FUNCTION spock.sub_alter_interface(subscription_name name, interface_name name)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_interface';
GRANT EXECUTE ON FUNCTION spock.sub_alter_interface TO spock_admin;

CREATE FUNCTION spock.sub_disable(subscription_name name, immediate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_disable';
GRANT EXECUTE ON FUNCTION spock.sub_disable TO spock_admin;

CREATE FUNCTION spock.sub_enable(subscription_name name, immediate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_enable';
GRANT EXECUTE ON FUNCTION spock.sub_enable TO spock_admin;

CREATE FUNCTION spock.sub_add_repset(subscription_name name, replication_set name)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_add_replication_set';
GRANT EXECUTE ON FUNCTION spock.sub_add_repset TO spock_admin;

CREATE FUNCTION spock.sub_remove_repset(subscription_name name, replication_set name)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_remove_replication_set';
GRANT EXECUTE ON FUNCTION spock.sub_remove_repset TO spock_admin;

CREATE FUNCTION spock.sub_show_status(subscription_name name DEFAULT NULL,
    OUT subscription_name text, OUT status text, OUT provider_node text,
    OUT provider_dsn text, OUT slot_name text, OUT replication_sets text[],
    OUT forward_origins text[])
RETURNS SETOF record STABLE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_subscription_status';
GRANT EXECUTE ON FUNCTION spock.sub_show_status TO spock_admin;

CREATE TABLE spock.replication_set (
    set_id oid NOT NULL PRIMARY KEY,
    set_nodeid oid NOT NULL,
    set_name name NOT NULL,
    replicate_insert boolean NOT NULL DEFAULT true,
    replicate_update boolean NOT NULL DEFAULT true,
    replicate_delete boolean NOT NULL DEFAULT true,
    replicate_truncate boolean NOT NULL DEFAULT true,
    UNIQUE (set_nodeid, set_name)
) WITH (user_catalog_table=true);
GRANT SELECT ON TABLE spock.replication_set TO spock_admin;

CREATE TABLE spock.replication_set_table (
    set_id oid NOT NULL,
    set_reloid regclass NOT NULL,
    set_att_list text[],
    set_row_filter pg_node_tree,
    PRIMARY KEY(set_id, set_reloid)
) WITH (user_catalog_table=true);
GRANT SELECT ON TABLE spock.replication_set_table TO spock_admin;

CREATE TABLE spock.replication_set_seq (
    set_id oid NOT NULL,
    set_seqoid regclass NOT NULL,
    PRIMARY KEY(set_id, set_seqoid)
) WITH (user_catalog_table=true);
GRANT SELECT ON TABLE spock.replication_set_seq TO spock_admin;

CREATE TABLE spock.sequence_state (
	seqoid oid NOT NULL PRIMARY KEY,
	cache_size integer NOT NULL,
	last_value bigint NOT NULL
) WITH (user_catalog_table=true);
GRANT SELECT ON TABLE spock.sequence_state TO spock_admin;

CREATE TABLE spock.depend (
    classid oid NOT NULL,
    objid oid NOT NULL,
    objsubid integer NOT NULL,

    refclassid oid NOT NULL,
    refobjid oid NOT NULL,
    refobjsubid integer NOT NULL,

	deptype "char" NOT NULL
) WITH (user_catalog_table=true);
GRANT SELECT ON TABLE spock.depend TO spock_admin;

CREATE TABLE spock.pii (
    id int generated always as identity,
    pii_schema text NOT NULL,
    pii_table text NOT NULL,
    pii_column text NOT NULL,
    PRIMARY KEY(id)
) WITH (user_catalog_table=true);
GRANT SELECT ON TABLE spock.pii TO spock_admin;

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
GRANT SELECT ON TABLE spock.resolutions TO spock_admin;
GRANT SELECT ON TABLE spock.resolutions TO spock_monitor;

CREATE VIEW spock.tables AS
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
GRANT SELECT ON TABLE spock.tables TO spock_admin;
GRANT SELECT ON TABLE spock.tables TO spock_monitor;

CREATE FUNCTION spock.repset_create(set_name name,
    replicate_insert boolean = true, replicate_update boolean = true,
    replicate_delete boolean = true, replicate_truncate boolean = true)
RETURNS oid STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_create_replication_set';
GRANT EXECUTE ON FUNCTION spock.repset_create TO spock_admin;

CREATE FUNCTION spock.repset_alter(set_name name,
    replicate_insert boolean DEFAULT NULL, replicate_update boolean DEFAULT NULL,
    replicate_delete boolean DEFAULT NULL, replicate_truncate boolean DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_replication_set';
GRANT EXECUTE ON FUNCTION spock.repset_alter TO spock_admin;

CREATE FUNCTION spock.repset_drop(set_name name, ifexists boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_drop_replication_set';
GRANT EXECUTE ON FUNCTION spock.repset_drop TO spock_admin;

CREATE FUNCTION spock.repset_add_table(set_name name, relation regclass, synchronize_data boolean DEFAULT false,
	columns text[] DEFAULT NULL, row_filter text DEFAULT NULL, include_partitions boolean default true)
RETURNS boolean CALLED ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_table';
GRANT EXECUTE ON FUNCTION spock.repset_add_table TO spock_admin;

CREATE FUNCTION spock.repset_add_all_tables(set_name name, schema_names text[], synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_all_tables';
GRANT EXECUTE ON FUNCTION spock.repset_add_all_tables TO spock_admin;

CREATE FUNCTION spock.repset_remove_table(set_name name, relation regclass, include_partitions boolean default true)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_table';
GRANT EXECUTE ON FUNCTION spock.repset_remove_table TO spock_admin;

CREATE FUNCTION spock.repset_add_seq(set_name name, relation regclass, synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_sequence';
GRANT EXECUTE ON FUNCTION spock.repset_add_seq TO spock_admin;

CREATE FUNCTION spock.repset_add_all_seqs(set_name name, schema_names text[], synchronize_data boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_all_sequences';
GRANT EXECUTE ON FUNCTION spock.repset_add_all_seqs TO spock_admin;

CREATE FUNCTION spock.repset_remove_seq(set_name name, relation regclass)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_sequence';
GRANT EXECUTE ON FUNCTION spock.repset_remove_seq TO spock_admin;

CREATE FUNCTION spock.repset_add_partition(parent regclass, partition regclass default NULL,
    row_filter text default NULL)
RETURNS int CALLED ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_add_partition';
GRANT EXECUTE ON FUNCTION spock.repset_add_partition TO spock_admin;

CREATE FUNCTION spock.repset_remove_partition(parent regclass, partition regclass default NULL)
RETURNS int CALLED ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replication_set_remove_partition';
GRANT EXECUTE ON FUNCTION spock.repset_remove_partition TO spock_admin;

CREATE FUNCTION spock.sub_alter_sync(subscription_name name, truncate boolean DEFAULT false)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_synchronize';
GRANT EXECUTE ON FUNCTION spock.sub_alter_sync TO spock_admin;

CREATE FUNCTION spock.sub_resync_table(subscription_name name, relation regclass,
	truncate boolean DEFAULT true)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_subscription_resynchronize_table';
GRANT EXECUTE ON FUNCTION spock.sub_resync_table TO spock_admin;

CREATE FUNCTION spock.sync_seq(relation regclass)
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_synchronize_sequence';
GRANT EXECUTE ON FUNCTION spock.sync_seq TO spock_admin;

CREATE FUNCTION spock.table_data_filtered(reltyp anyelement, relation regclass, repsets text[])
RETURNS SETOF anyelement CALLED ON NULL INPUT STABLE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_table_data_filtered';
GRANT EXECUTE ON FUNCTION spock.table_data_filtered TO spock_admin;

CREATE FUNCTION spock.repset_show_table(relation regclass, repsets text[], OUT relid oid, OUT nspname text,
	OUT relname text, OUT att_list text[], OUT has_row_filter boolean, OUT relkind "char", OUT relispartition boolean)
RETURNS record STRICT STABLE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_repset_table_info';
GRANT EXECUTE ON FUNCTION spock.repset_show_table TO spock_admin;

CREATE FUNCTION spock.sub_show_table(subscription_name name, relation regclass, OUT nspname text, OUT relname text, OUT status text)
RETURNS record STRICT STABLE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_show_subscription_table';
GRANT EXECUTE ON FUNCTION spock.sub_show_table TO spock_admin;

CREATE TABLE spock.queue (
    queued_at timestamp with time zone NOT NULL,
    role name NOT NULL,
    replication_sets text[],
    message_type "char" NOT NULL,
    message json NOT NULL
);
GRANT SELECT ON TABLE spock.queue TO spock_admin;

CREATE FUNCTION spock.replicate_ddl(command text, replication_sets text[] DEFAULT '{ddl_sql}')
RETURNS boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_replicate_ddl_command';
GRANT EXECUTE ON FUNCTION spock.replicate_ddl(text, text[]) TO spock_admin;
CREATE FUNCTION spock.replicate_ddl(command text[], replication_sets text[] DEFAULT '{ddl_sql}')
RETURNS SETOF boolean STRICT VOLATILE SECURITY DEFINER LANGUAGE sql AS
    'SELECT spock.replicate_ddl(cmd, $2) FROM (SELECT unnest(command) cmd)';
GRANT EXECUTE ON FUNCTION spock.replicate_ddl(text[], text[]) TO spock_admin;

CREATE FUNCTION spock.queue_truncate()
RETURNS trigger SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_queue_truncate';
GRANT EXECUTE ON FUNCTION spock.queue_truncate TO spock_admin;

CREATE FUNCTION spock.node_info(OUT node_id oid, OUT node_name text,
    OUT sysid text, OUT dbname text, OUT replication_sets text,
    OUT location text, OUT country text, OUT info jsonb)
RETURNS record
STABLE STRICT SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_node_info';
GRANT EXECUTE ON FUNCTION spock.node_info TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.node_info TO spock_monitor;

CREATE FUNCTION spock.spock_gen_slot_name(name, name, name)
RETURNS name
IMMUTABLE STRICT SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME';
GRANT EXECUTE ON FUNCTION spock.spock_gen_slot_name TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.spock_gen_slot_name TO spock_monitor;

CREATE FUNCTION spock.spock_version() RETURNS text
SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME';
GRANT EXECUTE ON FUNCTION spock.spock_version TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.spock_version TO spock_monitor;

CREATE FUNCTION spock.spock_version_num() RETURNS integer
SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME';
GRANT EXECUTE ON FUNCTION spock.spock_version_num TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.spock_version_num TO spock_monitor;

CREATE FUNCTION spock.spock_max_proto_version() RETURNS integer
SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME';
GRANT EXECUTE ON FUNCTION spock.spock_max_proto_version TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.spock_max_proto_version TO spock_monitor;

CREATE FUNCTION spock.spock_min_proto_version() RETURNS integer
SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME';
GRANT EXECUTE ON FUNCTION spock.spock_min_proto_version TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.spock_min_proto_version TO spock_monitor;

CREATE FUNCTION spock.get_country() RETURNS text
SECURITY DEFINER LANGUAGE sql AS
$$ SELECT current_setting('spock.country') $$;
GRANT EXECUTE ON FUNCTION spock.get_country TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.get_country TO spock_monitor;

CREATE FUNCTION spock.wait_slot_confirm_lsn(slotname name, target pg_lsn)
RETURNS void SECURITY DEFINER LANGUAGE c AS 'spock','spock_wait_slot_confirm_lsn';
GRANT EXECUTE ON FUNCTION spock.wait_slot_confirm_lsn TO spock_admin;

CREATE FUNCTION spock.sub_wait_for_sync(subscription_name name)
RETURNS void RETURNS NULL ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_wait_for_subscription_sync_complete';
GRANT EXECUTE ON FUNCTION spock.sub_wait_for_sync TO spock_admin;

CREATE FUNCTION spock.table_wait_for_sync(subscription_name name, relation regclass)
RETURNS void RETURNS NULL ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_wait_for_table_sync_complete';
GRANT EXECUTE ON FUNCTION spock.table_wait_for_sync TO spock_admin;

CREATE FUNCTION spock.xact_commit_timestamp_origin("xid" xid, OUT "timestamp" timestamptz, OUT "roident" oid)
RETURNS record RETURNS NULL ON NULL INPUT VOLATILE SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'spock_xact_commit_timestamp_origin';
GRANT EXECUTE ON FUNCTION spock.xact_commit_timestamp_origin TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.xact_commit_timestamp_origin TO spock_monitor;

CREATE FUNCTION spock.get_channel_stats(
    OUT subid oid,
	OUT relid oid,
    OUT n_tup_ins bigint,
    OUT n_tup_upd bigint,
    OUT n_tup_del bigint,
	OUT n_conflict bigint,
	OUT n_dca bigint)
RETURNS SETOF record
SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'get_channel_stats';
GRANT EXECUTE ON FUNCTION spock.get_channel_stats TO spock_admin;
GRANT EXECUTE ON FUNCTION spock.get_channel_stats TO spock_monitor;

CREATE FUNCTION spock.reset_channel_stats() RETURNS void
SECURITY DEFINER LANGUAGE c AS 'MODULE_PATHNAME', 'reset_channel_stats';
GRANT EXECUTE ON FUNCTION spock.reset_channel_stats TO spock_admin;

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
GRANT SELECT ON TABLE spock.channel_table_stats TO spock_admin;
GRANT SELECT ON TABLE spock.channel_table_stats TO spock_monitor;

CREATE VIEW spock.channel_summary_stats AS
  SELECT subid, sub_name,
     sum(n_tup_ins) AS n_tup_ins,
     sum(n_tup_upd) AS n_tup_upd,
     sum(n_tup_del) AS n_tup_del,
     sum(n_conflict) AS n_conflict,
     sum(n_dca) AS n_dca
  FROM spock.channel_table_stats
  GROUP BY subid, sub_name;
GRANT SELECT ON TABLE spock.channel_summary_stats TO spock_admin;
GRANT SELECT ON TABLE spock.channel_summary_stats TO spock_monitor;

CREATE FUNCTION spock.prune_conflict_tracking()
RETURNS int4
AS 'MODULE_PATHNAME', 'prune_conflict_tracking'
SECURITY DEFINER LANGUAGE C;
GRANT EXECUTE ON FUNCTION spock.prune_conflict_tracking TO spock_admin;

CREATE TABLE spock.conflict_tracker (
    relid oid,
    tid tid,

    last_origin int,
    last_xmin xid,
    last_ts timestamptz,

    PRIMARY KEY(relid, tid)
);
GRANT SELECT ON TABLE spock.conflict_tracker TO spock_admin;

CREATE FUNCTION spock.lag_tracker(
    OUT slot_name text,
    OUT commit_lsn pg_lsn,
    OUT commit_timestamp timestamptz
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'lag_tracker_info'
STRICT SECURITY DEFINER LANGUAGE C;
GRANT EXECUTE ON FUNCTION spock.lag_tracker TO spock_admin;

CREATE VIEW spock.lag_tracker AS
    SELECT L.slot_name, L.commit_lsn, L.commit_timestamp,
		CASE WHEN pg_wal_lsn_diff(pg_catalog.pg_current_wal_insert_lsn(), S.write_lsn) <= 0 
		THEN '0'::interval
		ELSE pg_catalog.timeofday()::timestamptz - L.commit_timestamp
		END AS replication_lag,
		pg_wal_lsn_diff(pg_catalog.pg_current_wal_insert_lsn(), S.write_lsn) AS replication_lag_bytes
    FROM spock.lag_tracker() L
	LEFT JOIN pg_catalog.pg_stat_replication S ON S.application_name = L.slot_name;
GRANT SELECT ON TABLE spock.lag_tracker TO spock_admin;
GRANT SELECT ON TABLE spock.lag_tracker TO spock_monitor;

CREATE FUNCTION spock.md5_agg_sfunc(text, anyelement) 
       RETURNS text
       LANGUAGE sql
AS
$$
  SELECT md5($1 || $2::text)
$$;
GRANT EXECUTE ON FUNCTION spock.md5_agg_sfunc TO public;

CREATE  AGGREGATE spock.md5_agg (ORDER BY anyelement)
(
  STYPE = text,
  SFUNC = spock.md5_agg_sfunc,
  INITCOND = ''
);
GRANT EXECUTE ON FUNCTION spock.md5_agg TO public;

-- ----------------------------------------------------------------------
-- Allow spock_admin to call pg_catalog.pg_replication_origin_session_setup()
-- ----------------------------------------------------------------------
GRANT EXECUTE ON FUNCTION pg_catalog.pg_replication_origin_session_setup TO spock_admin;

-- ----------------------------------------------------------------------
-- Create a wrapper function so that spock_sync can set the
-- session replication role in the remote connection for table sync.
-- ----------------------------------------------------------------------
CREATE FUNCTION spock.set_session_replication_role_replica()
	RETURNS void
	LANGUAGE sql
	SECURITY DEFINER
AS
$$
	SET session_replication_role TO 'replica';
$$;
GRANT EXECUTE ON FUNCTION spock.set_session_replication_role_replica TO spock_admin;
