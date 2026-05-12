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
	sub_skip_schema text[],
	sub_created_at timestamptz
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

-- Read peer progress (ros.remote_lsn) for all peer subscriptions.
-- Called while apply workers are paused and the slot's snapshot is imported.
-- Row 0: header (lsn + snapshot placeholder).  Rows 1+: one progress entry per peer.
CREATE FUNCTION spock.read_peer_progress(
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
BEGIN
    /*
     * The slot and snapshot are created by the C caller via the replication
     * protocol.  The slot's snapshot is imported into this transaction.
     * This function just reads peer progress (ros.remote_lsn) while apply
     * workers are paused.
     */

    -- Get the slot's LSN and the imported snapshot for the header row.
    SELECT restart_lsn INTO v_lsn
    FROM pg_replication_slots WHERE slot_name = p_slot_name;
    v_snap := '';  -- snapshot managed by C caller

    RAISE NOTICE 'SPOCK cswp slot=% v_lsn=%', p_slot_name, v_lsn;

    -- Header row: lsn only (snapshot managed by C caller).
    lsn      := v_lsn;
    snapshot := v_snap;
    RETURN NEXT;

    /*
     * Emit one progress row per peer.  With apply workers paused,
     * ros.remote_lsn is exact: it reflects only committed transactions
     * whose effects are visible in the slot snapshot.
     */
    FOR rec IN (
        SELECT p.dbid, p.node_id, p.remote_node_id,
               p.remote_commit_ts, p.prev_remote_ts,
               p.remote_commit_lsn      AS grp_remote_commit_lsn,
               p.remote_insert_lsn,
               p.received_lsn, p.last_updated_ts, p.updated_by_decode,
               ros.remote_lsn           AS ros_remote_lsn,
               sub.sub_slot_name        AS sub_slot_name
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

        lsn               := v_lsn;
        snapshot          := v_snap;
        dbid              := rec.dbid;
        node_id           := rec.node_id;
        remote_node_id    := rec.remote_node_id;
        remote_commit_ts  := rec.remote_commit_ts;
        prev_remote_ts    := rec.prev_remote_ts;
        remote_commit_lsn := COALESCE(rec.ros_remote_lsn, '0/0'::pg_lsn);
        remote_insert_lsn := rec.remote_insert_lsn;
        received_lsn      := rec.received_lsn;
        last_updated_ts   := rec.last_updated_ts;
        updated_by_decode := rec.updated_by_decode;

        RAISE NOTICE 'SPOCK cswp peer=% resume_lsn=%',
            rec.remote_node_id, remote_commit_lsn;

        RETURN NEXT;
    END LOOP;

    RAISE NOTICE 'SPOCK cswp slot=% done peers=%', p_slot_name, v_n_peers;
END;
$$;

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

CREATE FUNCTION spock.sub_create(
  subscription_name     name,
  provider_dsn          text,
  replication_sets      text[] = '{default,default_insert_only,ddl_sql}',
  synchronize_structure boolean = false,
  synchronize_data      boolean = false,
  forward_origins       text[] = '{}',
  apply_delay           interval DEFAULT '0',
  force_text_transfer   boolean = false,
  enabled               boolean = true,
  skip_schema           text[] = '{}'
)
RETURNS oid
AS 'MODULE_PATHNAME', 'spock_create_subscription'
LANGUAGE C STRICT VOLATILE;

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

CREATE FUNCTION spock.sub_alter_options(
  subscription_name name,
  options           jsonb
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_alter_subscription_options'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION spock.sub_show_status(
  subscription_name     name DEFAULT NULL,
  OUT subscription_name text,
  OUT status            text,
  OUT provider_node     text,
  OUT provider_dsn      text,
  OUT slot_name         text,
  OUT replication_sets  text[],
  OUT forward_origins   text[]
)
RETURNS SETOF record
AS 'MODULE_PATHNAME', 'spock_show_subscription_status'
LANGUAGE C STABLE;

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

-- Distributed sequence access method registry.
--
-- Maps a sequence (schema, name) to a "kind" identifying which generation
-- method nextval() should use.  Sequences without a row use the
-- spock.default_sequence_kind GUC (defaults to 'local').
--
-- Keyed on (nspname, relname) rather than seqoid.  Names round-trip cleanly
-- through pg_dump / pg_restore; OIDs do not.  seqoid is carried as a
-- non-key cache column so the OAT_POST_ALTER hook can find a row by the
-- (rename-stable) OID when ALTER SEQUENCE ... RENAME fires.  After a
-- logical restore the seqoid values reference the source cluster and are
-- stale; the next spock.alter_sequence_set_kind() or
-- spock.convert_all_sequences() call on a given sequence refreshes them.
--
-- Not marked user_catalog_table: this is a node-local registry, by
-- design.  Cluster-wide propagation is NOT automatic in Spock 6.0:
-- spock_autoddl_process only replicates LOGSTMT_DDL utility statements
-- (CREATE/ALTER/DROP), not SQL function invocations, so a call to
-- spock.alter_sequence_set_kind() or spock.convert_all_sequences()
-- affects only the local node.  Operators must run the same call on
-- every node in the cluster.  Running it on only some nodes is
-- supported but inconsistent: the unconverted nodes continue to emit
-- stock sequence values while the converted ones emit snowflakes, so
-- cluster-wide uniqueness is no longer guaranteed.  Autoddl-driven
-- propagation is a planned follow-up (see docs/specs/distributed_sequences.md
-- §14 "Known gaps and follow-up work").
CREATE TABLE spock.sequence_kind (
	nspname  name NOT NULL,
	relname  name NOT NULL,
	kind     text NOT NULL
		CHECK (kind IN ('local','snowflake')),
	seqoid   oid  NOT NULL,
	PRIMARY KEY (nspname, relname)
);
CREATE INDEX spock_sequence_kind_seqoid_idx
	ON spock.sequence_kind (seqoid);

SELECT pg_catalog.pg_extension_config_dump('spock.sequence_kind', '');

CREATE FUNCTION spock.alter_sequence_set_kind(seqname regclass, kind text)
RETURNS void
AS 'MODULE_PATHNAME', 'spock_alter_sequence_set_kind'
LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION spock.alter_sequence_set_kind(regclass, text) FROM PUBLIC;

CREATE FUNCTION spock.convert_all_sequences(
	method text DEFAULT 'snowflake',
	force  bool DEFAULT false
) RETURNS integer
AS 'MODULE_PATHNAME', 'spock_convert_all_sequences'
LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION spock.convert_all_sequences(text, bool) FROM PUBLIC;

CREATE FUNCTION spock.sequence_hook_available()
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_sequence_hook_available'
LANGUAGE C STABLE STRICT;

REVOKE ALL ON FUNCTION spock.sequence_hook_available() FROM PUBLIC;

-- Per-sequence summary.
--
-- hook_status is 'active' iff Spock's dispatcher is the *root* of the
-- nextval_hook chain.  An extension loaded after Spock that chains on
-- top will read as 'inactive' even though Spock is still reachable via
-- the chain; the column is therefore best read as "is Spock the
-- outermost hook?", not "is Spock managing my sequences?".
--
-- On unpatched PostgreSQL the spock shared library fails to load, so
-- this view doesn't exist there at all -- the column never reads
-- 'inactive' for the patch-absent reason in practice.
CREATE VIEW spock.sequence_info AS
SELECT
	sk.seqoid::regclass AS sequence_name,
	sk.kind,
	CASE WHEN spock.sequence_hook_available() THEN 'active'
	     ELSE 'inactive' END AS hook_status
FROM spock.sequence_kind sk;

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
CREATE INDEX ON spock.resolutions (log_time);

CREATE FUNCTION spock.cleanup_resolutions(days integer DEFAULT NULL)
RETURNS bigint VOLATILE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_cleanup_resolutions_sql';
REVOKE ALL ON FUNCTION spock.cleanup_resolutions(integer) FROM PUBLIC;

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

CREATE FUNCTION spock.repset_create(
  set_name           name,
  replicate_insert   boolean = true,
  replicate_update   boolean = true,
  replicate_delete   boolean = true,
  replicate_truncate boolean = true
)
RETURNS oid
AS 'MODULE_PATHNAME', 'spock_create_replication_set'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION spock.repset_alter(set_name name,
    replicate_insert boolean DEFAULT NULL, replicate_update boolean DEFAULT NULL,
    replicate_delete boolean DEFAULT NULL, replicate_truncate boolean DEFAULT NULL)
RETURNS oid CALLED ON NULL INPUT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_alter_replication_set';

CREATE FUNCTION spock.repset_drop(
  set_name name,
  ifexists boolean DEFAULT false
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_drop_replication_set'
LANGUAGE C STRICT VOLATILE;

CREATE FUNCTION spock.repset_add_table(
  set_name           name,
  relation           regclass,
  synchronize_data   boolean DEFAULT false,
  columns            text[] DEFAULT NULL,
  row_filter         text DEFAULT NULL,
  include_partitions boolean default true
)
RETURNS boolean
AS 'MODULE_PATHNAME', 'spock_replication_set_add_table'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;

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

CREATE FUNCTION spock.spock_gen_slot_name(
  dbname        name,
  provider_node name,
  subscription  name
) RETURNS name
AS 'MODULE_PATHNAME'
LANGUAGE C IMMUTABLE STRICT PARALLEL SAFE;

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

CREATE FUNCTION spock.sync_event(transactional boolean DEFAULT false)
RETURNS pg_lsn RETURNS NULL ON NULL INPUT
AS 'MODULE_PATHNAME', 'spock_create_sync_event'
LANGUAGE C VOLATILE;

CREATE FUNCTION spock.pause_apply_workers()
RETURNS void
AS 'MODULE_PATHNAME', 'spock_pause_apply_workers'
LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION spock.pause_apply_workers() FROM PUBLIC;

CREATE FUNCTION spock.resume_apply_workers()
RETURNS void
AS 'MODULE_PATHNAME', 'spock_resume_apply_workers'
LANGUAGE C VOLATILE;

REVOKE ALL ON FUNCTION spock.resume_apply_workers() FROM PUBLIC;

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
AS $$ SELECT md5($1 || $2::text) $$
LANGUAGE sql IMMUTABLE PARALLEL SAFE;
CREATE  AGGREGATE spock.md5_agg (ORDER BY anyelement)
(
	STYPE = text,
	SFUNC = spock.md5_agg_sfunc,
	INITCOND = '',
	PARALLEL = SAFE
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

-- ----
-- Subscription conflict statistics
-- ----
CREATE FUNCTION spock.get_subscription_stats(
	subid                           oid,
	OUT subid                       oid,
	OUT confl_insert_exists         bigint,
	OUT confl_update_origin_differs bigint,
	OUT confl_update_exists         bigint,
	OUT confl_update_missing        bigint,
	OUT confl_delete_origin_differs bigint,
	OUT confl_delete_missing        bigint,
	OUT confl_delete_exists         bigint,
	OUT stats_reset                 timestamptz
)
RETURNS record
AS 'MODULE_PATHNAME', 'spock_get_subscription_stats'
LANGUAGE C STABLE;

CREATE FUNCTION spock.reset_subscription_stats(subid oid DEFAULT NULL)
RETURNS void
AS 'MODULE_PATHNAME', 'spock_reset_subscription_stats'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;
