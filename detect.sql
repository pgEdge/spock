-- ============================================================================
-- Spock LSN Detection Procedure (using PostgreSQL replication slots)
--
-- Simple procedure to detect which node is ahead and which is behind
-- by comparing replication slot LSNs and replication origin status.
--
-- Usage:
--
--   CALL spock.detect_slot_lag(
--       failed_node_name := 'n1',
--       source_node_name := 'n2',
--       source_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
--       target_node_name := 'n3',
--       target_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>'
--   );
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

DROP PROCEDURE IF EXISTS spock.detect_slot_lag(
    text, text, text, text, text
);
CREATE OR REPLACE PROCEDURE spock.detect_slot_lag(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text
)
LANGUAGE plpgsql
AS $$
DECLARE
    source_slot_lsn pg_lsn;
    target_slot_lsn pg_lsn;
    source_origin_lsn pg_lsn;
    target_origin_lsn pg_lsn;
BEGIN
    -- Get replication slot confirmed_flush_lsn from source
    BEGIN
        SELECT rs.confirmed_flush_lsn INTO source_slot_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT rs.confirmed_flush_lsn
                                FROM pg_catalog.pg_replication_slots rs
                                JOIN spock.subscription s ON rs.slot_name = s.sub_slot_name
                                JOIN spock.node o ON o.node_id = s.sub_origin
                               WHERE o.node_name = %L
                                 AND rs.confirmed_flush_lsn IS NOT NULL
                               ORDER BY rs.confirmed_flush_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name
                   )
               ) AS t(confirmed_flush_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            source_slot_lsn := NULL;
    END;

    -- Get replication slot confirmed_flush_lsn from target
    BEGIN
        SELECT rs.confirmed_flush_lsn INTO target_slot_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT rs.confirmed_flush_lsn
                                FROM pg_catalog.pg_replication_slots rs
                                JOIN spock.subscription s ON rs.slot_name = s.sub_slot_name
                                JOIN spock.node o ON o.node_id = s.sub_origin
                               WHERE o.node_name = %L
                                 AND rs.confirmed_flush_lsn IS NOT NULL
                               ORDER BY rs.confirmed_flush_lsn DESC
                               LIMIT 1$_sql$,
                       failed_node_name
                   )
               ) AS t(confirmed_flush_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            target_slot_lsn := NULL;
    END;

    -- Get replication origin remote_lsn from source
    BEGIN
        SELECT remote_lsn INTO source_origin_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT ros.remote_lsn
                                FROM pg_catalog.pg_replication_origin_status ros
                                JOIN pg_catalog.pg_replication_origin ro ON ro.roident = ros.local_id
                               WHERE ro.roname LIKE 'spk_%%_' || %L || '_sub_' || %L || '_' || %L
                                 AND ros.remote_lsn IS NOT NULL
                               LIMIT 1$_sql$,
                       failed_node_name,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(remote_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            source_origin_lsn := NULL;
    END;

    -- Get replication origin remote_lsn from target
    BEGIN
        SELECT remote_lsn INTO target_origin_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT ros.remote_lsn
                                FROM pg_catalog.pg_replication_origin_status ros
                                JOIN pg_catalog.pg_replication_origin ro ON ro.roident = ros.local_id
                               WHERE ro.roname LIKE 'spk_%%_' || %L || '_sub_' || %L || '_' || %L
                                 AND ros.remote_lsn IS NOT NULL
                               LIMIT 1$_sql$,
                       failed_node_name,
                       failed_node_name,
                       target_node_name
                   )
               ) AS t(remote_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            target_origin_lsn := NULL;
    END;

    -- Compare and report slot LSNs
    RAISE NOTICE '=== Replication Slot LSN Detection ===';
    RAISE NOTICE 'Source (%): %', source_node_name, COALESCE(source_slot_lsn::text, 'NULL');
    RAISE NOTICE 'Target (%): %', target_node_name, COALESCE(target_slot_lsn::text, 'NULL');

    IF source_slot_lsn IS NOT NULL AND target_slot_lsn IS NOT NULL THEN
        IF source_slot_lsn = target_slot_lsn THEN
            RAISE NOTICE '✓ SYNCED: Both nodes have the same slot LSN';
        ELSIF source_slot_lsn > target_slot_lsn THEN
            RAISE NOTICE '→ Source (%) is ahead by % bytes (slot)', 
                source_node_name, pg_wal_lsn_diff(source_slot_lsn, target_slot_lsn);
        ELSE
            RAISE NOTICE '→ Target (%) is ahead by % bytes (slot)', 
                target_node_name, pg_wal_lsn_diff(target_slot_lsn, source_slot_lsn);
        END IF;
    ELSIF source_slot_lsn IS NULL AND target_slot_lsn IS NOT NULL THEN
        RAISE NOTICE '→ Target (%) has slot LSN data, Source (%) does not', 
            target_node_name, source_node_name;
    ELSIF target_slot_lsn IS NULL AND source_slot_lsn IS NOT NULL THEN
        RAISE NOTICE '→ Source (%) has slot LSN data, Target (%) does not', 
            source_node_name, target_node_name;
    ELSE
        RAISE NOTICE '⚠ Both slot LSNs are NULL';
    END IF;

    -- Compare and report origin LSNs
    RAISE NOTICE '';
    RAISE NOTICE '=== Replication Origin LSN Detection ===';
    RAISE NOTICE 'Source (%): %', source_node_name, COALESCE(source_origin_lsn::text, 'NULL');
    RAISE NOTICE 'Target (%): %', target_node_name, COALESCE(target_origin_lsn::text, 'NULL');

    IF source_origin_lsn IS NOT NULL AND target_origin_lsn IS NOT NULL THEN
        IF source_origin_lsn = target_origin_lsn THEN
            RAISE NOTICE '✓ SYNCED: Both nodes have the same origin LSN';
        ELSIF source_origin_lsn > target_origin_lsn THEN
            RAISE NOTICE '→ Source (%) is ahead by % bytes (origin)', 
                source_node_name, pg_wal_lsn_diff(source_origin_lsn, target_origin_lsn);
        ELSE
            RAISE NOTICE '→ Target (%) is ahead by % bytes (origin)', 
                target_node_name, pg_wal_lsn_diff(target_origin_lsn, source_origin_lsn);
        END IF;
    ELSIF source_origin_lsn IS NULL AND target_origin_lsn IS NOT NULL THEN
        RAISE NOTICE '→ Target (%) has origin LSN data, Source (%) does not', 
            target_node_name, source_node_name;
    ELSIF target_origin_lsn IS NULL AND source_origin_lsn IS NOT NULL THEN
        RAISE NOTICE '→ Source (%) has origin LSN data, Target (%) does not', 
            source_node_name, target_node_name;
    ELSE
        RAISE NOTICE '⚠ Both origin LSNs are NULL';
    END IF;
END;
$$;
