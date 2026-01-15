-- ============================================================================
-- Spock LSN Detection Procedure
--
-- Simple procedure to detect which node is ahead and which is behind
-- by comparing LSNs from the failed node to source and target nodes.
--
-- Usage:
--
--   CALL spock.detect_lag(
--       failed_node_name := 'n1',
--       source_node_name := 'n2',
--       source_dsn       := 'host=localhost port=5452 dbname=pgedge user=<user>',
--       target_node_name := 'n3',
--       target_dsn       := 'host=localhost port=5453 dbname=pgedge user=<user>'
--   );
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS dblink;

DROP PROCEDURE IF EXISTS spock.detect_lag(
    text, text, text, text, text
);
CREATE OR REPLACE PROCEDURE spock.detect_lag(
    failed_node_name text,
    source_node_name text,
    source_dsn text,
    target_node_name text,
    target_dsn text
)
LANGUAGE plpgsql
AS $$
DECLARE
    source_lag_lsn pg_lsn;
    target_lag_lsn pg_lsn;
BEGIN
    -- Get lag_tracker LSNs
    BEGIN
        SELECT commit_lsn INTO source_lag_lsn
          FROM dblink(
                   source_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L$_sql$,
                       failed_node_name,
                       source_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            source_lag_lsn := NULL;
    END;

    BEGIN
        SELECT commit_lsn INTO target_lag_lsn
          FROM dblink(
                   target_dsn,
                   format(
                       $_sql$SELECT commit_lsn
                                FROM spock.lag_tracker
                               WHERE origin_name = %L
                                 AND receiver_name = %L$_sql$,
                       failed_node_name,
                       target_node_name
                   )
               ) AS t(commit_lsn pg_lsn);
    EXCEPTION
        WHEN OTHERS THEN
            target_lag_lsn := NULL;
    END;

    -- Compare and report
    RAISE NOTICE '=== LSN Detection ===';
    RAISE NOTICE 'Source (%): %', source_node_name, COALESCE(source_lag_lsn::text, 'NULL');
    RAISE NOTICE 'Target (%): %', target_node_name, COALESCE(target_lag_lsn::text, 'NULL');

    IF source_lag_lsn IS NOT NULL AND target_lag_lsn IS NOT NULL THEN
        IF source_lag_lsn = target_lag_lsn THEN
            RAISE NOTICE '✓ SYNCED: Both nodes have the same LSN';
        ELSIF source_lag_lsn > target_lag_lsn THEN
            RAISE NOTICE '→ Source (%) is ahead by % bytes', 
                source_node_name, pg_wal_lsn_diff(source_lag_lsn, target_lag_lsn);
        ELSE
            RAISE NOTICE '→ Target (%) is ahead by % bytes', 
                target_node_name, pg_wal_lsn_diff(target_lag_lsn, source_lag_lsn);
        END IF;
    ELSIF source_lag_lsn IS NULL AND target_lag_lsn IS NOT NULL THEN
        RAISE NOTICE '→ Target (%) has LSN data, Source (%) does not', 
            target_node_name, source_node_name;
    ELSIF target_lag_lsn IS NULL AND source_lag_lsn IS NOT NULL THEN
        RAISE NOTICE '→ Source (%) has LSN data, Target (%) does not', 
            source_node_name, target_node_name;
    ELSE
        RAISE NOTICE '⚠ Both LSNs are NULL';
    END IF;
END;
$$;
