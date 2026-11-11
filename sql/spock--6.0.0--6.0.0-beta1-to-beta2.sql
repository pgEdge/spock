/* spock--6.0.0--6.0.0-beta1-to-beta2.sql */

-- complain if script is sourced in psql, rather than via ALTER EXTENSION
\echo Use "ALTER EXTENSION spock UPDATE TO '6.0.0-beta1-to-beta2'" to load this file. \quit

-- One-time catalog fix for nodes installed with 6.0.0-beta.1.
--
-- Beta 1 and beta 2 both call themselves 6.0.0, so a plain ALTER EXTENSION
-- UPDATE has nothing to do on a beta 1 node.  Run instead:
--
--   ALTER EXTENSION spock UPDATE TO '6.0.0-beta1-to-beta2';
--   ALTER EXTENSION spock UPDATE TO '6.0.0';
--
-- This script brings the beta 1 catalog to the beta 2 one; the second step
-- (an empty script) sets the version name back to 6.0.0.  Every statement is
-- written to be a no-op on a catalog that already has the beta 2 objects, so
-- running this on a beta 2 node changes nothing.  The definitions are the
-- same as in spock--6.0.0.sql and spock--5.0.14--6.0.0.sql.
--
-- Remove both files at general availability.

DROP FUNCTION IF EXISTS spock.wait_for_apply_worker(bigint, int);

CREATE OR REPLACE FUNCTION spock.slot_enable_failover()
RETURNS integer
AS 'MODULE_PATHNAME', 'spock_slot_enable_failover'
LANGUAGE C VOLATILE;
REVOKE ALL ON FUNCTION spock.slot_enable_failover() FROM PUBLIC;

-- Beta 1's upgrade from 5.x did not set the failover flag on existing slots.
SELECT spock.slot_enable_failover();

-- Beta 1's upgrade from 5.x did not mark md5_agg parallel safe.
CREATE OR REPLACE AGGREGATE spock.md5_agg (ORDER BY anyelement)
(
	STYPE = text,
	SFUNC = spock.md5_agg_sfunc,
	INITCOND = '',
	PARALLEL = SAFE
);

CREATE TABLE IF NOT EXISTS spock.reserved_object (
    name              name    NOT NULL,
    kind              text    NOT NULL CHECK (kind IN ('schema', 'extension')),
    exclude_from_dump boolean NOT NULL DEFAULT true,
    block_in_repset   boolean NOT NULL DEFAULT true,
    replicate_ddl     boolean,
    builtin           boolean NOT NULL DEFAULT false,
    PRIMARY KEY (name, kind),
    CONSTRAINT reserved_object_replicate_ddl_kind
        CHECK ((kind = 'schema') = (replicate_ddl IS NOT NULL))
) WITH (user_catalog_table=true);

SELECT pg_catalog.pg_extension_config_dump('spock.reserved_object', 'WHERE NOT builtin');

-- A user_catalog_table does not allow INSERT ... ON CONFLICT, so skip rows
-- that are already there instead.
INSERT INTO spock.reserved_object
    (name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin)
SELECT v.* FROM (VALUES
    ('spock'::name,      'schema',    true, true,  true,  true),
    ('spock',            'extension', true, true,  NULL,  true),
    ('snowflake',        'schema',    true, true,  true,  true),
    ('snowflake',        'extension', true, true,  NULL,  true),
    ('lolor',            'schema',    true, false, true,  true),
    ('lolor',            'extension', true, false, NULL,  true),
    ('coldfront',        'schema',    true, false, true,  true),
    ('coldfront',        'extension', true, false, NULL,  true),
    ('pgedge_ace',       'schema',    true, true,  false, true)
) AS v(name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin)
WHERE NOT EXISTS (SELECT 1 FROM spock.reserved_object r
                  WHERE r.name = v.name AND r.kind = v.kind);

CREATE OR REPLACE FUNCTION spock.reserved_object_guard()
RETURNS trigger AS $$
BEGIN
    IF OLD.builtin THEN
        RAISE EXCEPTION 'cannot % built-in reserved object "%" (%)',
            lower(TG_OP), OLD.name, OLD.kind;
    END IF;
    IF TG_OP = 'DELETE' THEN
        RETURN OLD;
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE TRIGGER reserved_object_guard
    BEFORE UPDATE OR DELETE ON spock.reserved_object
    FOR EACH ROW EXECUTE FUNCTION spock.reserved_object_guard();

CREATE OR REPLACE FUNCTION spock.reserved_object_add(
    p_name              name,
    p_kind              text,
    p_exclude_from_dump boolean DEFAULT true,
    p_block_in_repset   boolean DEFAULT true,
    p_replicate_ddl     boolean DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    -- replicate_ddl is schema-only.  For a schema, an unset (NULL) argument
    -- defaults to true; for an extension it is always NULL, so the
    -- reserved_object_replicate_ddl_kind CHECK holds without the caller
    -- having to pass NULL explicitly.  (The table is a user_catalog_table,
    -- which forbids INSERT ... ON CONFLICT, so this hand-rolled upsert stands.)
    v_replicate_ddl boolean := CASE WHEN p_kind = 'schema'
                                    THEN COALESCE(p_replicate_ddl, true) END;
BEGIN
    UPDATE spock.reserved_object
       SET exclude_from_dump = p_exclude_from_dump,
           block_in_repset   = p_block_in_repset,
           replicate_ddl     = v_replicate_ddl
     WHERE name = p_name AND kind = p_kind;
    IF NOT FOUND THEN
        BEGIN
            INSERT INTO spock.reserved_object
                (name, kind, exclude_from_dump, block_in_repset, replicate_ddl, builtin)
            VALUES (p_name, p_kind, p_exclude_from_dump, p_block_in_repset, v_replicate_ddl, false);
        EXCEPTION WHEN unique_violation THEN
            UPDATE spock.reserved_object
               SET exclude_from_dump = p_exclude_from_dump,
                   block_in_repset   = p_block_in_repset,
                   replicate_ddl     = v_replicate_ddl
             WHERE name = p_name AND kind = p_kind;
        END;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION spock.reserved_object_remove(p_name name, p_kind text)
RETURNS void
LANGUAGE sql AS $$
    DELETE FROM spock.reserved_object WHERE name = p_name AND kind = p_kind;
$$;

-- Node metadata refresh and propagation.  Without node_info_apply() an apply
-- worker that receives a peer's metadata change fails, and without the
-- trigger this node's own changes are not sent.

-- Emit a full node-metadata snapshot to direct subscribers only.
CREATE OR REPLACE FUNCTION spock.node_info_emit(
    node_name  name,
    location   text,
    country    text,
    info       jsonb
) RETURNS pg_lsn
AS 'MODULE_PATHNAME', 'spock_node_info_emit'
LANGUAGE C CALLED ON NULL INPUT VOLATILE;
REVOKE ALL ON FUNCTION spock.node_info_emit(name, text, text, jsonb) FROM PUBLIC;

-- Internal metadata update for a cached peer row. The C caller verifies
-- that node_name belongs to the node that originated the transaction.
-- Returns false when no row has that name. A missing row is not created.
CREATE OR REPLACE FUNCTION spock.node_info_apply(
    p_node_name name,
    p_location  text,
    p_country   text,
    p_info      jsonb
) RETURNS boolean
LANGUAGE plpgsql AS $$
BEGIN
    UPDATE spock.node
       SET location = p_location,
           country  = p_country,
           info     = p_info
     WHERE node_name = p_node_name;

    RETURN FOUND;
END;
$$;
REVOKE ALL ON FUNCTION spock.node_info_apply(name, text, text, jsonb) FROM PUBLIC;

-- Broadcast changes to this node's own row. Updates to cached peer rows return
-- without emitting, preventing recursion on receivers.
CREATE OR REPLACE FUNCTION spock.node_info_broadcast() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    IF NEW.node_id IS DISTINCT FROM (SELECT node_id FROM spock.local_node) THEN
        RETURN NULL;
    END IF;

    PERFORM spock.node_info_emit(NEW.node_name, NEW.location,
                                 NEW.country, NEW.info);

    RETURN NULL;
END;
$$;

CREATE OR REPLACE TRIGGER node_info_broadcast_trigger
    AFTER UPDATE ON spock.node
    FOR EACH ROW
    EXECUTE FUNCTION spock.node_info_broadcast();

-- Internal: fetch one already-known node's current info via the given
-- dsn. Not meant to be called directly; see spock.node_refresh_info(),
-- which is the one that writes the result into spock.node.
CREATE OR REPLACE FUNCTION spock.node_refresh_info_one(node_id oid, node_name name, dsn text,
    OUT location text, OUT country text, OUT info jsonb)
RETURNS record STRICT VOLATILE LANGUAGE c AS 'MODULE_PATHNAME', 'spock_node_refresh_info_one';
REVOKE ALL ON FUNCTION spock.node_refresh_info_one(oid, name, text) FROM PUBLIC;

CREATE OR REPLACE FUNCTION spock.node_refresh_info(p_node_name name DEFAULT NULL)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_local_id oid;
    v_rec      record;
    v_fresh    record;
    v_ok       boolean := true;
BEGIN
    SELECT ni.node_id INTO v_local_id FROM spock.node_info() ni;

    IF p_node_name IS NOT NULL THEN
        IF NOT EXISTS (SELECT 1 FROM spock.node n WHERE n.node_name = p_node_name) THEN
            RAISE EXCEPTION 'node "%" not found', p_node_name;
        END IF;
        IF EXISTS (SELECT 1 FROM spock.node n
                   WHERE n.node_name = p_node_name AND n.node_id = v_local_id) THEN
            RAISE EXCEPTION 'cannot refresh info for the local node "%" from itself', p_node_name;
        END IF;
    END IF;

    FOR v_rec IN
        /*
         * Prefer the interface named the same as the node (the default one
         * node_create()/sub_create() set up), but fall back to any other
         * interface the node has rather than silently skipping it -- the
         * default one may have been legally dropped after a subscription
         * was switched to use an alternate interface. Ordering guarantees
         * exactly one row per node (never zero, when at least one interface
         * exists), so a node is never dropped out of this loop -- and thus
         * out of the existence/error checks below -- just because its
         * default-named interface is gone.
         */
        SELECT n.node_id, n.node_name,
               (SELECT ni.if_dsn
                  FROM spock.node_interface ni
                 WHERE ni.if_nodeid = n.node_id
                 ORDER BY (ni.if_name = n.node_name) DESC, ni.if_id
                 LIMIT 1) AS dsn
        FROM spock.node n
        WHERE n.node_id != v_local_id
          AND (p_node_name IS NULL OR n.node_name = p_node_name)
    LOOP
        BEGIN
            IF v_rec.dsn IS NULL THEN
                RAISE EXCEPTION 'node "%" has no usable interface', v_rec.node_name;
            END IF;

            SELECT * INTO v_fresh
              FROM spock.node_refresh_info_one(v_rec.node_id, v_rec.node_name, v_rec.dsn);

            UPDATE spock.node
               SET location = v_fresh.location,
                   country  = v_fresh.country,
                   info     = v_fresh.info
             WHERE node_id = v_rec.node_id;
        EXCEPTION WHEN OTHERS THEN
            IF p_node_name IS NOT NULL THEN
                RAISE;   -- explicit single-node call: bubble the real error up
            END IF;
            RAISE WARNING 'could not refresh info for node "%": %', v_rec.node_name, SQLERRM;
            v_ok := false;
        END;
    END LOOP;

    RETURN v_ok;
END;
$$;

-- Update this node's metadata, merging info and validating tiebreaker.
-- The shared UPDATE trigger handles propagation.
CREATE OR REPLACE FUNCTION spock.node_alter(
    p_location   text  DEFAULT NULL,
    p_country    text  DEFAULT NULL,
    p_info_patch jsonb DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql AS $$
DECLARE
    v_local_id   oid;
    v_tiebreaker numeric;
    v_rows       int;
BEGIN
    SELECT ni.node_id INTO v_local_id FROM spock.node_info() ni;

    IF p_info_patch IS NOT NULL THEN
        IF jsonb_typeof(p_info_patch) != 'object' THEN
            RAISE EXCEPTION 'info patch must be a JSON object';
        END IF;

        -- Other info keys remain open-ended and unvalidated.
        IF p_info_patch ? 'tiebreaker' THEN
            IF jsonb_typeof(p_info_patch->'tiebreaker') != 'number' THEN
                RAISE EXCEPTION 'invalid "tiebreaker" value %: must be a JSON number, not a string or null',
                    p_info_patch->'tiebreaker';
            END IF;

            v_tiebreaker := (p_info_patch->>'tiebreaker')::numeric;
            IF v_tiebreaker != trunc(v_tiebreaker)
               OR v_tiebreaker NOT BETWEEN -2147483648 AND 2147483647 THEN
                RAISE EXCEPTION 'invalid "tiebreaker" value %: must fit a 32-bit integer',
                    p_info_patch->'tiebreaker';
            END IF;

            -- Store a canonical integer: node_fromtuple() parses the text
            -- form with pg_strtoint32(), which rejects "5.0" or "1e2".
            p_info_patch := jsonb_set(p_info_patch, '{tiebreaker}',
                                      to_jsonb(v_tiebreaker::int));
        END IF;
    END IF;

    UPDATE spock.node
       SET location = COALESCE(p_location, location),
           country  = COALESCE(p_country, country),
           info     = CASE WHEN p_info_patch IS NOT NULL
                            THEN COALESCE(info, '{}'::jsonb) || p_info_patch
                            ELSE info END
     WHERE node_id = v_local_id;

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    IF v_rows != 1 THEN
        RAISE EXCEPTION 'local node (id=%) not found in spock.node', v_local_id;
    END IF;

    RETURN true;
END;
$$;

-- Node monitoring views, event history and node_report().

-- ----------------------------------------------------------------------
-- Node monitoring
--
-- The functions read shared memory and return raw rows; the views join
-- them with the catalogs and are the interface meant for operators.
-- ----------------------------------------------------------------------
CREATE OR REPLACE FUNCTION spock.get_worker_status(
    OUT worker_slot           integer,
    OUT worker_type           text,
    OUT pid                   integer,
    OUT database_id           oid,
    OUT subscription_id       oid,
    OUT worker_status         text,
    OUT generation            integer,
    OUT terminated_at         timestamptz,
    OUT restart_delay         integer,
    OUT paused                boolean,
    OUT in_exception_handling boolean,
    OUT sync_pending          boolean,
    OUT replay_stop_lsn       pg_lsn,
    OUT remote_wal_insert_lsn pg_lsn,
    OUT sync_schema_name      name,
    OUT sync_table_name       name)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_worker_status';

-- The 5.x interface, kept for callers that still use it: running apply
-- workers only, in the old column layout.  Up to 5.x this was a C function.
CREATE OR REPLACE FUNCTION spock.get_apply_worker_status(
    OUT worker_pid    bigint,
    OUT worker_dboid  int,
    OUT worker_subid  bigint,
    OUT worker_status text)
RETURNS SETOF record STABLE
LANGUAGE sql AS $$
    SELECT w.pid::bigint,
           w.database_id::int,
           w.subscription_id::bigint,
           CASE w.worker_status WHEN 'starting' THEN 'none'
                ELSE w.worker_status END
      FROM spock.get_worker_status() AS w
     WHERE w.worker_type = 'apply'
       AND w.pid IS NOT NULL
$$;

CREATE OR REPLACE FUNCTION spock.get_events(
    OUT event_id        bigint,
    OUT event_time      timestamptz,
    OUT event_type      text,
    OUT severity        text,
    OUT sqlstate        text,
    OUT database_id     oid,
    OUT subscription_id oid,
    OUT pid             integer,
    OUT lsn             pg_lsn,
    OUT detail          text)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_events';

CREATE OR REPLACE FUNCTION spock.reset_events() RETURNS void
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_reset_events';

CREATE OR REPLACE FUNCTION spock.get_apply_stats(
    OUT database_id                 oid,
    OUT subscription_id             oid,
    OUT worker_starts               bigint,
    OUT worker_failures             bigint,
    OUT sync_worker_starts          bigint,
    OUT sync_worker_failures        bigint,
    OUT provider_connects           bigint,
    OUT provider_disconnects        bigint,
    OUT idle_timeouts               bigint,
    OUT messages_received           bigint,
    OUT bytes_received              bigint,
    OUT xacts_applied               bigint,
    OUT xacts_skipped               bigint,
    OUT xacts_discarded             bigint,
    OUT apply_errors                bigint,
    OUT sync_errors                 bigint,
    OUT deadlocks                   bigint,
    OUT lock_timeouts               bigint,
    OUT constraint_violations       bigint,
    OUT resource_errors             bigint,
    OUT tables_synced               bigint,
    OUT confl_insert_exists         bigint,
    OUT confl_update_origin_differs bigint,
    OUT confl_update_exists         bigint,
    OUT confl_update_missing        bigint,
    OUT confl_delete_origin_differs bigint,
    OUT confl_delete_missing        bigint,
    OUT confl_delete_exists         bigint,
    OUT last_worker_start           timestamptz,
    OUT last_worker_failure         timestamptz,
    OUT last_provider_connect       timestamptz,
    OUT last_provider_disconnect    timestamptz,
    OUT last_message_received       timestamptz,
    OUT last_xact_applied           timestamptz,
    OUT last_apply_error            timestamptz,
    OUT last_sync_error             timestamptz,
    OUT last_table_synced           timestamptz,
    OUT last_error_message          text,
    OUT last_error_lsn              pg_lsn,
    OUT last_error_sqlstate         text,
    OUT last_error_pid              integer,
    OUT stats_reset                 timestamptz)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_apply_stats';

CREATE OR REPLACE FUNCTION spock.get_slot_groups(
    OUT slot_group_name name,
    OUT members         integer,
    OUT last_lsn        pg_lsn,
    OUT last_commit_ts  timestamptz)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_slot_groups';

CREATE OR REPLACE FUNCTION spock.get_monitor_summary(
    OUT started_at                  timestamptz,
    OUT supervisor_pid              integer,
    OUT worker_slots                integer,
    OUT worker_slots_used           integer,
    OUT apply_paused                boolean,
    OUT events_capacity             integer,
    OUT events_retained             integer,
    OUT events_recorded             bigint,
    OUT subscription_stats_capacity integer,
    OUT subscription_stats_used     integer,
    OUT channel_stats_capacity      integer,
    OUT channel_stats_used          bigint,
    OUT channel_stats_full          boolean)
RETURNS record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_monitor_summary';

CREATE OR REPLACE FUNCTION spock.get_system_info(
    OUT hostname              text,
    OUT os_name               text,
    OUT os_release            text,
    OUT os_version            text,
    OUT architecture          text,
    OUT cpu_count             integer,
    OUT memory_bytes          bigint,
    OUT load_average_1min     float8,
    OUT load_average_5min     float8,
    OUT load_average_15min    float8,
    OUT data_directory        text,
    OUT data_disk_total_bytes bigint,
    OUT data_disk_free_bytes  bigint,
    OUT wal_disk_total_bytes  bigint,
    OUT wal_disk_free_bytes   bigint,
    OUT postmaster_pid        integer,
    OUT postmaster_start_time timestamptz,
    OUT postgres_version      text,
    OUT postgres_version_num  integer,
    OUT spock_version         text,
    OUT spock_version_num     integer,
    OUT protocol_version      integer,
    OUT min_protocol_version  integer)
RETURNS record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_system_info';

CREATE OR REPLACE FUNCTION spock.get_pending_exceptions(
    OUT subscription_name name,
    OUT commit_lsn        pg_lsn,
    OUT failed_action_number integer,   -- position of the failing change in the transaction, from 1
    OUT error_message     text)
RETURNS SETOF record STABLE
LANGUAGE c AS 'MODULE_PATHNAME', 'spock_get_pending_exceptions';

-- Hide the password of a connection string, in keyword and in URI form.
CREATE OR REPLACE FUNCTION spock.redact_dsn(dsn text) RETURNS text
LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT pg_catalog.regexp_replace(
               pg_catalog.regexp_replace(dsn,
                   '(password\s*=\s*)(''(?:[^''\\]|\\.)*''|\S+)', '\1********', 'gi'),
               '(://[^/@:]+:)[^@]+@', '\1********@', 'g')
$$;

-- The spock parameters and the core parameters replication depends on.
CREATE OR REPLACE VIEW spock.settings AS
    SELECT s.name,
           CASE WHEN s.name IN ('spock.primary_dsn',
                                'spock.extra_connection_options')
                THEN spock.redact_dsn(s.setting)
                ELSE s.setting
           END AS setting,
           s.unit,
           s.context,
           s.source,
           s.pending_restart
      FROM pg_catalog.pg_settings AS s
     WHERE s.name LIKE 'spock.%'
        OR s.name IN ('wal_level', 'max_worker_processes',
                      'max_replication_slots', 'max_wal_senders',
                      'max_slot_wal_keep_size', 'track_commit_timestamp',
                      'shared_preload_libraries', 'output_plugin_libraries',
                      'wal_sender_timeout', 'wal_receiver_timeout',
                      'synchronous_commit', 'synchronous_standby_names',
                      'logical_decoding_work_mem', 'hot_standby_feedback',
                      'sync_replication_slots')
     ORDER BY s.name;

-- Health of the host and of the PostgreSQL instance, for the checks that
-- come before any replication question: disk, load, connections, long
-- transactions, wraparound, archiving and WAL volume.
-- The origin progress behind the subscription views.  The core view
-- pg_replication_origin_status is superuser only; this reads the same
-- progress through the origin API.
CREATE OR REPLACE FUNCTION spock.replication_origin_status(
    OUT external_id text,
    OUT remote_lsn pg_lsn)
RETURNS SETOF record
LANGUAGE c STRICT
AS 'MODULE_PATHNAME', 'spock_replication_origin_status';
REVOKE ALL ON FUNCTION spock.replication_origin_status() FROM PUBLIC;

-- pg_ls_waldir() is restricted to pg_monitor.  The views only need the
-- total, so compute it in C and let a plain monitoring role see it without
-- the file list.
CREATE OR REPLACE FUNCTION spock.wal_size_bytes() RETURNS bigint
LANGUAGE c STRICT STABLE AS 'MODULE_PATHNAME', 'spock_wal_size_bytes';

CREATE OR REPLACE VIEW spock.system_status AS
    SELECT si.hostname,
           si.os_name,
           si.os_release,
           si.architecture,
           si.cpu_count,
           si.memory_bytes,
           si.load_average_1min,
           si.load_average_5min,
           si.load_average_15min,
           si.data_directory,
           si.data_disk_total_bytes,
           si.data_disk_free_bytes,
           si.wal_disk_total_bytes,
           si.wal_disk_free_bytes,
           spock.wal_size_bytes() AS wal_size_bytes,
           pg_catalog.pg_database_size(pg_catalog.current_database()) AS database_size_bytes,
           si.postgres_version,
           si.postmaster_pid,
           si.postmaster_start_time,
           pg_catalog.now() - si.postmaster_start_time AS uptime,
           pg_catalog.pg_is_in_recovery() AS in_recovery,
           pg_catalog.current_setting('max_connections')::integer AS max_connections,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE backend_type = 'client backend') AS connections,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE state = 'active' AND backend_type = 'client backend') AS active_connections,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE state LIKE 'idle in transaction%') AS idle_in_transaction,
           (SELECT max(pg_catalog.now() - xact_start) FROM pg_catalog.pg_stat_activity
             WHERE backend_type = 'client backend' AND xact_start IS NOT NULL)
               AS longest_transaction,
           (SELECT max(pg_catalog.now() - state_change) FROM pg_catalog.pg_stat_activity
             WHERE state LIKE 'idle in transaction%') AS longest_idle_in_transaction,
           (SELECT count(*) FROM pg_catalog.pg_stat_activity
             WHERE wait_event_type = 'Lock') AS waiting_on_locks,
           (SELECT count(*) FROM pg_catalog.pg_prepared_xacts) AS prepared_transactions,
           (SELECT count(*) FROM pg_catalog.pg_stat_replication
             WHERE pid NOT IN (SELECT active_pid FROM pg_catalog.pg_replication_slots
                                WHERE active_pid IS NOT NULL AND slot_type = 'logical'))
               AS physical_standbys,
           pg_catalog.age(d.datfrozenxid) AS oldest_xid_age,
           sd.xact_commit,
           sd.xact_rollback,
           sd.deadlocks,
           sd.conflicts AS recovery_conflicts,
           sd.temp_files,
           sd.temp_bytes,
           sd.checksum_failures,
           sd.stats_reset AS database_stats_reset,
           pg_catalog.current_setting('archive_mode') AS archive_mode,
           ar.archived_count,
           ar.last_archived_time,
           ar.failed_count AS archive_failed_count,
           ar.last_failed_time AS last_archive_failure
      FROM spock.get_system_info() AS si
      CROSS JOIN pg_catalog.pg_database AS d
      LEFT JOIN pg_catalog.pg_stat_database AS sd ON sd.datid = d.oid
      CROSS JOIN pg_catalog.pg_stat_archiver AS ar
     WHERE d.datname = pg_catalog.current_database();

-- Every spock process of this database, plus the cluster-wide supervisor.
CREATE OR REPLACE VIEW spock.worker_status AS
    SELECT w.worker_slot,
           w.worker_type,
           w.pid,
           w.worker_status,
           w.subscription_id,
           s.sub_name AS subscription_name,
           w.sync_schema_name,
           w.sync_table_name,
           a.backend_start AS started_at,
           a.xact_start,
           a.state AS backend_state,
           a.wait_event_type,
           a.wait_event,
           blk.blocked_by_pids,
           blk.blocking_pid,
           blk.blocking_xact_start,
           blk.blocking_query,
           w.paused,
           w.in_exception_handling,
           w.sync_pending,
           w.replay_stop_lsn,
           w.remote_wal_insert_lsn,
           w.generation,
           w.terminated_at,
           w.restart_delay
      FROM spock.get_worker_status() AS w
      LEFT JOIN spock.subscription AS s ON s.sub_id = w.subscription_id
      LEFT JOIN pg_catalog.pg_stat_activity AS a ON a.pid = w.pid
      LEFT JOIN LATERAL (
               SELECT bp.pids AS blocked_by_pids,
                      b.pid AS blocking_pid,
                      b.xact_start AS blocking_xact_start,
                      b.query AS blocking_query
                 FROM (SELECT pg_catalog.pg_blocking_pids(w.pid) AS pids) AS bp
                 LEFT JOIN pg_catalog.pg_stat_activity AS b ON b.pid = bp.pids[1]
                WHERE pg_catalog.cardinality(bp.pids) > 0) AS blk ON true
     WHERE w.database_id IS NULL
        OR w.database_id = (SELECT d.oid FROM pg_catalog.pg_database AS d
                             WHERE d.datname = pg_catalog.current_database())
     ORDER BY w.worker_slot;

-- Recent events of this database, oldest first.
CREATE OR REPLACE VIEW spock.events AS
    SELECT e.event_id,
           e.event_time,
           e.event_type,
           e.severity,
           e.sqlstate,
           e.subscription_id,
           s.sub_name AS subscription_name,
           o.node_name AS provider_node,
           e.pid,
           e.lsn,
           e.detail
      FROM spock.get_events() AS e
      LEFT JOIN spock.subscription AS s ON s.sub_id = e.subscription_id
      LEFT JOIN spock.node AS o ON o.node_id = s.sub_origin
     WHERE e.database_id IS NULL
        OR e.database_id = (SELECT d.oid FROM pg_catalog.pg_database AS d
                             WHERE d.datname = pg_catalog.current_database())
     ORDER BY e.event_id;

-- Activity, tuple and conflict counters of every subscription.
CREATE OR REPLACE VIEW spock.subscription_stats AS
    SELECT s.sub_id AS subscription_id,
           s.sub_name AS subscription_name,
           COALESCE(a.worker_starts, 0) AS worker_starts,
           COALESCE(a.worker_failures, 0) AS worker_failures,
           COALESCE(a.sync_worker_starts, 0) AS sync_worker_starts,
           COALESCE(a.sync_worker_failures, 0) AS sync_worker_failures,
           COALESCE(a.provider_connects, 0) AS provider_connects,
           COALESCE(a.provider_disconnects, 0) AS provider_disconnects,
           COALESCE(a.idle_timeouts, 0) AS idle_timeouts,
           COALESCE(a.messages_received, 0) AS messages_received,
           COALESCE(a.bytes_received, 0) AS bytes_received,
           COALESCE(a.xacts_applied, 0) AS xacts_applied,
           COALESCE(a.xacts_skipped, 0) AS xacts_skipped,
           COALESCE(a.xacts_discarded, 0) AS xacts_discarded,
           COALESCE(a.apply_errors, 0) AS apply_errors,
           COALESCE(a.sync_errors, 0) AS sync_errors,
           COALESCE(a.deadlocks, 0) AS deadlocks,
           COALESCE(a.lock_timeouts, 0) AS lock_timeouts,
           COALESCE(a.constraint_violations, 0) AS constraint_violations,
           COALESCE(a.resource_errors, 0) AS resource_errors,
           COALESCE(a.tables_synced, 0) AS tables_synced,
           COALESCE(c.n_tup_ins, 0)::bigint AS n_tup_ins,
           COALESCE(c.n_tup_upd, 0)::bigint AS n_tup_upd,
           COALESCE(c.n_tup_del, 0)::bigint AS n_tup_del,
           COALESCE(c.n_conflict, 0)::bigint AS n_conflict,
           COALESCE(c.n_dca, 0)::bigint AS n_dca,
           a.confl_insert_exists,
           a.confl_update_origin_differs,
           a.confl_update_exists,
           a.confl_update_missing,
           a.confl_delete_origin_differs,
           a.confl_delete_missing,
           a.confl_delete_exists,
           a.last_worker_start,
           a.last_worker_failure,
           a.last_provider_connect,
           a.last_provider_disconnect,
           a.last_message_received,
           a.last_xact_applied,
           a.last_apply_error,
           a.last_sync_error,
           a.last_table_synced,
           a.last_error_message,
           a.last_error_lsn,
           a.last_error_sqlstate,
           a.last_error_pid,
           a.stats_reset
      FROM spock.subscription AS s
      LEFT JOIN spock.get_apply_stats() AS a ON a.subscription_id = s.sub_id
      LEFT JOIN spock.channel_summary_stats AS c ON c.subid = s.sub_id;

-- Synchronization state of subscriptions and of their tables.  A row
-- without a table describes the subscription as a whole.
CREATE OR REPLACE VIEW spock.table_sync_status AS
    SELECT s.sub_name AS subscription_name,
           l.sync_nspname AS schema_name,
           l.sync_relname AS table_name,
           CASE l.sync_kind
               WHEN 'i' THEN 'none'
               WHEN 'f' THEN 'full'
               WHEN 's' THEN 'structure'
               WHEN 'd' THEN 'data'
           END AS sync_kind,
           CASE l.sync_status
               WHEN 'i' THEN 'requested'
               WHEN 's' THEN 'copying structure'
               WHEN 'd' THEN 'copying data'
               WHEN 'c' THEN 'copying constraints'
               WHEN 'w' THEN 'waiting for apply'
               WHEN 'p' THEN 'started'
               WHEN 'u' THEN 'catching up'
               WHEN 'y' THEN 'synchronized'
               WHEN 'r' THEN 'ready'
               WHEN 'f' THEN 'failed'
           END AS sync_status,
           l.sync_statuslsn AS status_lsn
      FROM spock.local_sync_status AS l
      JOIN spock.subscription AS s ON s.sub_id = l.sync_subid
     ORDER BY s.sub_name, l.sync_nspname, l.sync_relname;

-- Everything about a subscription on one row: configuration, the worker
-- serving it, replication position and lag, and the most recent error.
CREATE OR REPLACE VIEW spock.subscription_status AS
    SELECT s.sub_id AS subscription_id,
           s.sub_name AS subscription_name,
           s.sub_enabled AS enabled,
           -- The initial copy runs before the worker is 'running', so it is
           -- checked first; on a large database it can take hours.
           CASE
               WHEN w.pid IS NOT NULL AND t.sync_status IS NULL THEN 'unknown'
               WHEN w.pid IS NOT NULL AND t.sync_status <> 'ready' THEN 'initializing'
               WHEN w.pid IS NOT NULL AND w.worker_status = 'running' THEN 'replicating'
               WHEN w.pid IS NOT NULL THEN 'starting'
               WHEN NOT s.sub_enabled THEN 'disabled'
               ELSE 'down'
           END AS status,
           o.node_name AS provider_node,
           spock.redact_dsn(oi.if_dsn) AS provider_dsn,
           s.sub_slot_name AS slot_name,
           s.sub_replication_sets AS replication_sets,
           s.sub_forward_origins AS forward_origins,
           s.sub_apply_delay AS apply_delay,
           s.sub_skip_lsn AS skip_lsn,
           s.sub_skip_schema AS skip_schema,
           s.sub_force_text_transfer AS force_text_transfer,
           s.sub_created_at AS created_at,
           t.sync_status,
           w.pid AS worker_pid,
           w.worker_status,
           w.started_at AS worker_started_at,
           w.terminated_at AS worker_terminated_at,
           w.restart_delay AS worker_restart_delay,
           w.paused AS worker_paused,
           w.in_exception_handling,
           w.blocked_by_pids AS worker_blocked_by_pids,
           w.blocking_pid AS worker_blocking_pid,
           w.blocking_query AS worker_blocking_query,
           pe.commit_lsn AS pending_exception_lsn,
           pe.error_message AS pending_exception_error,
           ros.remote_lsn AS origin_lsn,
           p.remote_commit_lsn,
           p.remote_commit_ts,
           p.remote_insert_lsn,
           p.received_lsn,
           pg_catalog.pg_wal_lsn_diff(p.remote_insert_lsn, p.remote_commit_lsn)
               AS replication_lag_bytes,
           p.last_updated_ts - p.remote_commit_ts AS replication_lag,
           st.last_message_received,
           pg_catalog.now() - st.last_message_received AS time_since_last_message,
           st.last_xact_applied,
           st.worker_starts,
           st.worker_failures,
           st.xacts_applied,
           st.apply_errors,
           st.last_apply_error,
           st.last_error_sqlstate,
           st.last_error_pid,
           st.last_error_message
      FROM spock.subscription AS s
      JOIN spock.node AS o ON o.node_id = s.sub_origin
      JOIN spock.node_interface AS oi ON oi.if_id = s.sub_origin_if
      LEFT JOIN spock.table_sync_status AS t
             ON t.subscription_name = s.sub_name
            AND t.table_name IS NULL
      LEFT JOIN (
               SELECT DISTINCT ON (ws.subscription_id) ws.*
                 FROM spock.worker_status AS ws
                WHERE ws.worker_type = 'apply'
                ORDER BY ws.subscription_id, ws.pid IS NULL, ws.worker_slot) AS w
             ON w.subscription_id = s.sub_id
      LEFT JOIN spock.progress AS p
             ON p.node_id = s.sub_target
            AND p.remote_node_id = s.sub_origin
      LEFT JOIN spock.replication_origin_status() AS ros
             ON ros.external_id = s.sub_slot_name
      LEFT JOIN spock.get_pending_exceptions() AS pe
             ON pe.subscription_name = s.sub_name
      LEFT JOIN spock.subscription_stats AS st ON st.subscription_id = s.sub_id
     ORDER BY s.sub_name;

-- Every node this node knows about, with the subscription that brings its
-- changes here.  A node with several subscriptions has one row for each.
CREATE OR REPLACE VIEW spock.peer_status AS
    SELECT n.node_id,
           n.node_name,
           n.location,
           n.country,
           n.node_id = ln.node_id AS is_local,
           i.dsn,
           ss.subscription_name,
           ss.status AS subscription_status,
           ss.replication_lag,
           ss.replication_lag_bytes,
           ss.last_message_received
      FROM spock.node AS n
      LEFT JOIN spock.local_node AS ln ON true
      LEFT JOIN LATERAL (
               SELECT string_agg(spock.redact_dsn(ni.if_dsn), ', ' ORDER BY ni.if_name)
                 FROM spock.node_interface AS ni
                WHERE ni.if_nodeid = n.node_id) AS i(dsn) ON true
      LEFT JOIN spock.subscription AS s ON s.sub_origin = n.node_id
      LEFT JOIN spock.subscription_status AS ss ON ss.subscription_id = s.sub_id
     ORDER BY n.node_name, ss.subscription_name;

-- The replication sets of the local node with what they carry.
CREATE OR REPLACE VIEW spock.replication_set_status AS
    SELECT rs.set_id,
           rs.set_name,
           rs.replicate_insert,
           rs.replicate_update,
           rs.replicate_delete,
           rs.replicate_truncate,
           (SELECT count(*) FROM spock.replication_set_table AS t
             WHERE t.set_id = rs.set_id) AS table_count,
           (SELECT count(*) FROM spock.replication_set_seq AS q
             WHERE q.set_id = rs.set_id) AS sequence_count,
           (SELECT count(*) FROM spock.subscription AS s
             WHERE rs.set_name::text = ANY (s.sub_replication_sets)) AS subscription_count
      FROM spock.replication_set AS rs
      JOIN spock.local_node AS ln ON ln.node_id = rs.set_nodeid
     ORDER BY rs.set_name;

-- The provider side: every spock replication slot of this database with
-- the walsender serving it and the WAL it holds back.
CREATE OR REPLACE VIEW spock.slot_status AS
    SELECT rs.slot_name,
           rs.active,
           rs.active_pid,
           sr.application_name AS client_name,
           sr.client_addr,
           sr.backend_start AS connected_at,
           sr.state,
           rs.restart_lsn,
           rs.confirmed_flush_lsn,
           sr.sent_lsn,
           sr.write_lsn,
           sr.flush_lsn,
           sr.replay_lsn,
           pg_catalog.pg_wal_lsn_diff(cur.lsn, rs.restart_lsn) AS retained_wal_bytes,
           pg_catalog.pg_wal_lsn_diff(cur.lsn, rs.confirmed_flush_lsn) AS pending_wal_bytes,
           sr.write_lag,
           sr.flush_lag,
           sr.replay_lag,
           sr.reply_time AS last_reply_time,
           rs.wal_status,
           rs.safe_wal_size,
           rs.catalog_xmin,
           pg_catalog.age(rs.catalog_xmin) AS catalog_xmin_age,
           rs.temporary,
           rs.two_phase,
           srs.total_txns AS decoded_txns,
           srs.total_bytes AS decoded_bytes,
           srs.spill_txns,
           srs.spill_count,
           srs.spill_bytes,
           srs.stream_txns,
           srs.stream_count,
           srs.stream_bytes,
           srs.stats_reset AS decode_stats_reset,
           sg.slot_group_name,
           sg.members AS slot_group_members,
           sg.last_lsn AS slot_group_last_lsn,
           sg.last_commit_ts AS slot_group_last_commit_ts
      FROM pg_catalog.pg_replication_slots AS rs
      CROSS JOIN LATERAL (
               SELECT CASE WHEN pg_catalog.pg_is_in_recovery()
                           THEN pg_catalog.pg_last_wal_replay_lsn()
                           ELSE pg_catalog.pg_current_wal_lsn()
                      END AS lsn) AS cur
      LEFT JOIN pg_catalog.pg_stat_replication AS sr ON sr.pid = rs.active_pid
      LEFT JOIN pg_catalog.pg_stat_replication_slots AS srs
             ON srs.slot_name = rs.slot_name
      LEFT JOIN spock.get_slot_groups() AS sg
             ON rs.slot_name ~ '_[0-9]$'
            AND sg.slot_group_name = pg_catalog.regexp_replace(rs.slot_name, '_[0-9]$', '')
     WHERE rs.plugin = 'spock_output'
       AND rs.database = pg_catalog.current_database()
     ORDER BY rs.slot_name;

-- The whole node on one row.  Each aggregate below reads its view once.
CREATE OR REPLACE VIEW spock.node_status AS
    SELECT n.node_id,
           n.node_name,
           n.location,
           n.country,
           pg_catalog.current_database() AS database_name,
           si.hostname,
           si.os_name || ' ' || si.os_release AS operating_system,
           si.postmaster_pid,
           si.postmaster_start_time,
           spock.spock_version() AS spock_version,
           e.extversion AS extension_version,
           spock.spock_version() <> e.extversion AS extension_update_pending,
           pg_catalog.current_setting('server_version') AS postgres_version,
           m.started_at AS spock_started_at,
           m.supervisor_pid,
           wk.manager_pid,
           pg_catalog.current_setting('spock.readonly') AS readonly_mode,
           m.apply_paused,
           m.worker_slots,
           m.worker_slots_used,
           ss.subscriptions,
           ss.subscriptions_enabled,
           ss.subscriptions_replicating,
           sl.replication_slots,
           sl.replication_slots_active,
           wk.apply_workers,
           wk.sync_workers,
           wk.workers_restart_pending,
           ss.pending_exceptions,
           tb.replicated_tables,
           tb.unreplicated_tables,
           cur.lsn AS current_wal_lsn,
           spock.wal_size_bytes() AS wal_size_bytes,
           si.data_disk_free_bytes,
           si.wal_disk_free_bytes,
           sl.max_retained_wal_bytes,
           ss.max_replication_lag_bytes,
           ss.max_replication_lag,
           (SELECT count(*) FROM spock.exception_log) AS exceptions_logged,
           ev.last_event_time,
           ev.last_error_event_time,
           m.events_retained,
           m.events_recorded
      FROM spock.get_monitor_summary() AS m
      CROSS JOIN spock.get_system_info() AS si
      CROSS JOIN LATERAL (
               SELECT CASE WHEN pg_catalog.pg_is_in_recovery()
                           THEN pg_catalog.pg_last_wal_replay_lsn()
                           ELSE pg_catalog.pg_current_wal_lsn()
                      END AS lsn) AS cur
      CROSS JOIN LATERAL (
               SELECT count(*) AS subscriptions,
                      count(*) FILTER (WHERE enabled) AS subscriptions_enabled,
                      count(*) FILTER (WHERE status = 'replicating')
                          AS subscriptions_replicating,
                      count(*) FILTER (WHERE pending_exception_lsn IS NOT NULL)
                          AS pending_exceptions,
                      max(replication_lag_bytes) AS max_replication_lag_bytes,
                      max(replication_lag) AS max_replication_lag
                 FROM spock.subscription_status) AS ss
      CROSS JOIN LATERAL (
               SELECT count(*) AS replication_slots,
                      count(*) FILTER (WHERE active) AS replication_slots_active,
                      max(retained_wal_bytes) AS max_retained_wal_bytes
                 FROM spock.slot_status) AS sl
      CROSS JOIN LATERAL (
               SELECT max(pid) FILTER (WHERE worker_type = 'manager') AS manager_pid,
                      count(*) FILTER (WHERE worker_type = 'apply' AND pid IS NOT NULL)
                          AS apply_workers,
                      count(*) FILTER (WHERE worker_type = 'sync' AND pid IS NOT NULL)
                          AS sync_workers,
                      count(*) FILTER (WHERE worker_status = 'restart pending')
                          AS workers_restart_pending
                 FROM spock.worker_status) AS wk
      CROSS JOIN LATERAL (
               SELECT max(event_time) AS last_event_time,
                      max(event_time) FILTER (WHERE severity = 'error')
                          AS last_error_event_time
                 FROM spock.events) AS ev
      CROSS JOIN LATERAL (
               SELECT count(DISTINCT relid) FILTER (WHERE set_name IS NOT NULL)
                          AS replicated_tables,
                      count(*) FILTER (WHERE set_name IS NULL) AS unreplicated_tables
                 FROM spock.tables) AS tb
      LEFT JOIN spock.local_node AS ln ON true
      LEFT JOIN spock.node AS n ON n.node_id = ln.node_id
      LEFT JOIN pg_catalog.pg_extension AS e ON e.extname = 'spock';

-- Render the rows of a query as text, one block per row when expanded and
-- an aligned table otherwise.  Values are printed in their PostgreSQL text
-- form.  A failing query becomes one line, so a report is never cut short
-- by a single section.
CREATE OR REPLACE FUNCTION spock.report_section(title text, query text,
                                     expanded boolean DEFAULT false)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    first   json;
    keys    text[];
    cols    text;
    rec     record;
    cells   text[] := '{}';
    ncols   integer;
    nrows   integer;
    widths  integer[];
    r       integer;
    k       integer;
    line    text;
BEGIN
    RETURN NEXT '';
    RETURN NEXT '== ' || title || ' ==';

    BEGIN
        EXECUTE format('SELECT row_to_json(q) FROM (%s) AS q LIMIT 1', query)
           INTO first;
        IF first IS NULL THEN
            RETURN NEXT '(no rows)';
            RETURN;
        END IF;

        -- Column names in query order, then every value cast to text.
        keys := ARRAY(SELECT key FROM json_each_text(first));
        SELECT string_agg(format('regexp_replace(%I::text, ''[\n\r]+'', '' '', ''g'')',
                                 key), ', ' ORDER BY ordinality)
          INTO cols
          FROM unnest(keys) WITH ORDINALITY AS u(key, ordinality);

        FOR rec IN EXECUTE format('SELECT ARRAY[%s] AS vals FROM (%s) AS q',
                                  cols, query)
        LOOP
            cells := cells || rec.vals;
        END LOOP;
    EXCEPTION WHEN OTHERS THEN
        RETURN NEXT format('(error: %s)', SQLERRM);
        RETURN;
    END;

    ncols := cardinality(keys);
    nrows := cardinality(cells) / ncols;

    IF expanded THEN
        widths[1] := (SELECT max(length(key)) FROM unnest(keys) AS key);
        FOR r IN 1 .. nrows LOOP
            IF r > 1 THEN
                RETURN NEXT repeat('-', widths[1] + 3);
            END IF;
            FOR k IN 1 .. ncols LOOP
                RETURN NEXT format('%s | %s', rpad(keys[k], widths[1]),
                                   coalesce(cells[(r - 1) * ncols + k], ''));
            END LOOP;
        END LOOP;
        RETURN;
    END IF;

    FOR k IN 1 .. ncols LOOP
        widths[k] := length(keys[k]);
        FOR r IN 1 .. nrows LOOP
            widths[k] := greatest(widths[k],
                                  length(coalesce(cells[(r - 1) * ncols + k], '')));
        END LOOP;
    END LOOP;

    line := '';
    FOR k IN 1 .. ncols LOOP
        line := line || CASE WHEN k > 1 THEN ' | ' ELSE '' END
                     || rpad(keys[k], widths[k]);
    END LOOP;
    RETURN NEXT line;

    line := '';
    FOR k IN 1 .. ncols LOOP
        line := line || CASE WHEN k > 1 THEN '-+-' ELSE '' END
                     || repeat('-', widths[k]);
    END LOOP;
    RETURN NEXT line;

    FOR r IN 1 .. nrows LOOP
        line := '';
        FOR k IN 1 .. ncols LOOP
            line := line || CASE WHEN k > 1 THEN ' | ' ELSE '' END
                         || rpad(coalesce(cells[(r - 1) * ncols + k], ''), widths[k]);
        END LOOP;
        RETURN NEXT rtrim(line);
    END LOOP;
    RETURN NEXT format('(%s row%s)', nrows, CASE WHEN nrows = 1 THEN '' ELSE 's' END);
END;
$$;

-- The whole node as one text report: host and versions, installed
-- extensions, settings, and every monitoring view one after another.
-- "recent" bounds the events, exceptions and resolutions listed.
CREATE OR REPLACE FUNCTION spock.node_report(recent integer DEFAULT 50)
RETURNS SETOF text
LANGUAGE plpgsql AS $$
DECLARE
    host text;
BEGIN
    recent := greatest(coalesce(recent, 50), 0);

    -- get_system_info() is not granted to PUBLIC.  A caller without it
    -- still gets the report, with the host shown as unknown.
    BEGIN
        SELECT hostname INTO host FROM spock.get_system_info();
    EXCEPTION WHEN insufficient_privilege THEN
        host := '(unknown)';
    END;

    RETURN NEXT format('Spock node report: database %s on %s at %s',
                       current_database(), host,
                       to_char(now(), 'YYYY-MM-DD HH24:MI:SS TZ'));

    RETURN QUERY SELECT spock.report_section('System',
        'SELECT * FROM spock.system_status', true);
    RETURN QUERY SELECT spock.report_section('Installed extensions',
        'SELECT e.extname AS extension, e.extversion AS version,
                n.nspname AS schema, a.default_version AS available_version
           FROM pg_catalog.pg_extension AS e
           JOIN pg_catalog.pg_namespace AS n ON n.oid = e.extnamespace
           LEFT JOIN pg_catalog.pg_available_extensions AS a ON a.name = e.extname
          ORDER BY e.extname');
    RETURN QUERY SELECT spock.report_section('Settings',
        'SELECT name, setting, unit, source, pending_restart FROM spock.settings');
    RETURN QUERY SELECT spock.report_section('Node status',
        'SELECT * FROM spock.node_status', true);
    RETURN QUERY SELECT spock.report_section('Peers',
        'SELECT node_name, is_local, dsn, subscription_name,
                subscription_status, replication_lag, replication_lag_bytes
           FROM spock.peer_status');
    RETURN QUERY SELECT spock.report_section('Subscriptions',
        'SELECT * FROM spock.subscription_status', true);
    RETURN QUERY SELECT spock.report_section('Subscription statistics',
        'SELECT * FROM spock.subscription_stats', true);
    RETURN QUERY SELECT spock.report_section('Workers',
        'SELECT worker_slot, worker_type, pid, worker_status, subscription_name,
                sync_schema_name, sync_table_name, started_at, backend_state,
                wait_event_type, wait_event, blocked_by_pids, blocking_pid,
                in_exception_handling, paused, terminated_at, restart_delay
           FROM spock.worker_status');
    RETURN QUERY SELECT spock.report_section('Pending exceptions',
        'SELECT * FROM spock.get_pending_exceptions()');
    RETURN QUERY SELECT spock.report_section('Replication slots',
        'SELECT * FROM spock.slot_status', true);
    RETURN QUERY SELECT spock.report_section('Replication sets',
        'SELECT * FROM spock.replication_set_status');
    RETURN QUERY SELECT spock.report_section('Tables not in any replication set',
        'SELECT nspname AS schema_name, relname AS table_name
           FROM spock.tables WHERE set_name IS NULL ORDER BY 1, 2');
    RETURN QUERY SELECT spock.report_section('Table synchronization',
        'SELECT * FROM spock.table_sync_status');
    RETURN QUERY SELECT spock.report_section('Lag by node pair',
        'SELECT * FROM spock.lag_tracker');
    RETURN QUERY SELECT spock.report_section('Recent exceptions',
        format('SELECT retry_errored_at, remote_origin, remote_commit_ts,
                       operation, table_schema, table_name, error_message
                  FROM spock.exception_log
                 ORDER BY retry_errored_at DESC LIMIT %s', recent));
    RETURN QUERY SELECT spock.report_section('Recent conflict resolutions',
        format('SELECT log_time, relname, conflict_type, conflict_resolution,
                       local_origin, remote_origin, remote_lsn
                  FROM spock.resolutions
                 ORDER BY log_time DESC LIMIT %s', recent));
    RETURN QUERY SELECT spock.report_section('Recent events',
        format('SELECT event_time, event_type, severity, sqlstate,
                       subscription_name, provider_node, pid, lsn, detail
                  FROM spock.events
                 ORDER BY event_id DESC LIMIT %s', recent));
END;
$$;

-- ----------------------------------------------------------------------
-- Monitoring privileges
--
-- The event ring and the apply statistics carry error text -- message,
-- DETAIL and CONTEXT of whatever failed -- and the reset functions clear
-- state other sessions are reading.  Neither belongs to every role that can
-- connect, so follow the same rule as the other privileged entry points here
-- and hand them out deliberately.  The views over these functions resolve
-- EXECUTE against the calling role, so they follow this grant rather than
-- going around it.
-- ----------------------------------------------------------------------
REVOKE ALL ON FUNCTION spock.get_system_info() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.get_events() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.get_apply_stats() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.get_pending_exceptions() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.reset_events() FROM PUBLIC;
REVOKE ALL ON FUNCTION spock.reset_subscription_stats(oid) FROM PUBLIC;

-- The read side is granted to pg_monitor, as PostgreSQL does for its own
-- monitoring views.  USAGE on the schema is not: it would also reach the
-- management functions, which are still executable by PUBLIC, so a
-- monitoring role is granted that separately.  The reset functions stay
-- with the superuser.
GRANT EXECUTE ON FUNCTION spock.get_system_info(), spock.get_events(),
    spock.get_apply_stats(), spock.get_pending_exceptions(),
    spock.replication_origin_status() TO pg_monitor;
GRANT SELECT ON spock.settings, spock.system_status, spock.worker_status,
    spock.events, spock.subscription_stats, spock.table_sync_status,
    spock.subscription_status, spock.peer_status,
    spock.replication_set_status, spock.slot_status, spock.node_status
    TO pg_monitor;
