-- ============================================================================
-- Spock Consolidated Recovery System
-- A unified recovery solution with multiple modes and options
-- ============================================================================
--
-- USAGE:
--   Basic recovery (comprehensive):
--     CALL spock.recover_cluster(
--         p_source_dsn := 'host=localhost port=5453 dbname=pgedge user=pgedge'
--     );
--
--   Origin-aware recovery (only failed node's transactions):
--     CALL spock.recover_cluster(
--         p_source_dsn := 'host=localhost port=5453 dbname=pgedge user=pgedge',
--         p_recovery_mode := 'origin-aware',
--         p_origin_node_name := 'n1'
--     );
--
--   Dry run (no changes):
--     CALL spock.recover_cluster(
--         p_source_dsn := 'host=localhost port=5453 dbname=pgedge user=pgedge',
--         p_dry_run := true
--     );
--
-- RECOVERY MODES:
--   'comprehensive' - Recover ALL missing data from source (default)
--   'origin-aware'  - Recover ONLY transactions from a specific origin node
--   'manual'        - Use individual functions for custom workflows
--
-- ============================================================================

\echo '========================================================================'
\echo '         Spock Consolidated Recovery System'
\echo '  Unified recovery with comprehensive and origin-aware modes'
\echo '========================================================================'
\echo ''

-- Ensure dblink extension is available
CREATE EXTENSION IF NOT EXISTS dblink;

-- ============================================================================
-- Main Recovery Procedure
-- ============================================================================

CREATE OR REPLACE PROCEDURE spock.recover_cluster(
    -- Required
    p_source_dsn text,
    -- Optional
    p_target_dsn text DEFAULT NULL,  -- NULL means local node
    p_recovery_mode text DEFAULT 'comprehensive',  -- 'comprehensive' or 'origin-aware'
    p_origin_node_name name DEFAULT NULL,  -- Required only for 'origin-aware' mode
    p_dry_run boolean DEFAULT false,
    p_verbose boolean DEFAULT true,
    p_auto_repair boolean DEFAULT true,
    p_fire_triggers boolean DEFAULT false,
    p_include_schemas text[] DEFAULT ARRAY['public'],  -- Schemas to include (NULL for all)
    p_exclude_schemas text[] DEFAULT ARRAY['pg_catalog', 'information_schema', 'spock']  -- Schemas to exclude
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_source_dsn text := p_source_dsn;
    v_target_dsn text := p_target_dsn;
    v_recovery_mode text := lower(p_recovery_mode);
    v_origin_node_name name := p_origin_node_name;
    v_origin_node_id oid := NULL;
    v_replicated_tables RECORD;
    v_table_full_name text;
    v_source_count bigint;
    v_target_count bigint;
    v_source_origin_count bigint;
    v_missing_rows bigint;
    v_rows_affected bigint := 0;
    v_status text;
    v_details text;
    v_start_time timestamptz;
    v_end_time timestamptz;
    v_time_taken interval;
    v_recovery_report_id uuid := gen_random_uuid();
    v_tables_recovered int := 0;
    v_tables_already_ok int := 0;
    v_tables_still_need_recovery int := 0;
    v_tables_with_errors int := 0;
    v_total_rows_recovered bigint := 0;
    v_pk_cols text[];
    v_all_cols text[];
    v_col_types text;
    v_pk_col_list text;
    v_all_col_list text;
    v_insert_sql text;
    v_temp_table_name text;
    v_conn_name_source text := 'recovery_source_conn_' || md5(random()::text);
    v_conn_name_target text := 'recovery_target_conn_' || md5(random()::text);
    v_table_count int;
BEGIN
    v_start_time := clock_timestamp();
    
    -- Validate recovery mode
    IF v_recovery_mode NOT IN ('comprehensive', 'origin-aware') THEN
        RAISE EXCEPTION 'Invalid recovery mode "%". Must be "comprehensive" or "origin-aware".', v_recovery_mode;
    END IF;
    
    -- For origin-aware mode, require origin node name
    IF v_recovery_mode = 'origin-aware' AND v_origin_node_name IS NULL THEN
        RAISE EXCEPTION 'Origin-aware recovery requires p_origin_node_name parameter.';
    END IF;
    
    -- Get origin node ID if in origin-aware mode
    IF v_recovery_mode = 'origin-aware' THEN
        SELECT node_id INTO v_origin_node_id
        FROM spock.node
        WHERE node_name = v_origin_node_name;
        
        IF v_origin_node_id IS NULL THEN
            RAISE EXCEPTION 'Origin node "%" not found in spock.node table.', v_origin_node_name;
        END IF;
    END IF;
    
    IF p_verbose THEN
        RAISE NOTICE '';
        RAISE NOTICE '========================================================================';
        RAISE NOTICE '         Spock Recovery System - % Mode', 
            CASE v_recovery_mode 
                WHEN 'comprehensive' THEN 'COMPREHENSIVE  ' 
                WHEN 'origin-aware' THEN 'ORIGIN-AWARE   '
            END;
        RAISE NOTICE '========================================================================';
        RAISE NOTICE '';
        RAISE NOTICE 'Recovery Configuration:';
        RAISE NOTICE '  Mode: %', upper(v_recovery_mode);
        IF v_recovery_mode = 'comprehensive' THEN
            RAISE NOTICE '  Description: Recover ALL missing data from source node';
        ELSE
            RAISE NOTICE '  Description: Recover ONLY transactions from origin node %', v_origin_node_name;
            RAISE NOTICE '  Origin Node: % (Node ID: %)', v_origin_node_name, v_origin_node_id;
        END IF;
        RAISE NOTICE '  Source Node DSN: %', v_source_dsn;
        RAISE NOTICE '  Target Node: LOCAL (current database connection)';
        RAISE NOTICE '  Dry Run Mode: % (no changes will be made)', 
            CASE WHEN p_dry_run THEN 'ENABLED' ELSE 'DISABLED' END;
        RAISE NOTICE '  Auto Repair: % (automatically repair tables)', 
            CASE WHEN p_auto_repair THEN 'ENABLED' ELSE 'DISABLED' END;
        RAISE NOTICE '';
    END IF;
    
    -- ============================================================================
    -- Phase 0: Prechecks and Validation
    -- ============================================================================
    IF p_verbose THEN
        RAISE NOTICE 'Phase 0: Validating Prerequisites and Connectivity';
        RAISE NOTICE '  Purpose: Ensure all required components are available before starting recovery';
        RAISE NOTICE '';
    END IF;
    
    -- Check if dblink extension is available
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'dblink') THEN
            RAISE NOTICE '    ✗ %', rpad('dblink extension is not installed', 120, ' ');
            RAISE EXCEPTION 'Exiting recover_cluster: dblink extension is required. Please run: CREATE EXTENSION dblink;';
        ELSE
            IF p_verbose THEN
                RAISE NOTICE '    ✓ %', rpad('Checking dblink extension is installed', 120, ' ');
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '    ✗ %', rpad('Error checking dblink extension: ' || SQLERRM, 120, ' ');
        RAISE;
    END;
    
    -- Check if spock extension is installed on local (target) node
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'spock') THEN
            RAISE NOTICE '    ✗ %', rpad('Spock extension is not installed on target node', 120, ' ');
            RAISE EXCEPTION 'Exiting recover_cluster: Spock extension is required on target node. Please install it first.';
        ELSE
            IF p_verbose THEN
                RAISE NOTICE '    ✓ %', rpad('Checking Spock extension is installed on target node', 120, ' ');
            END IF;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '    ✗ %', rpad('Error checking Spock extension on target: ' || SQLERRM, 120, ' ');
        RAISE;
    END;
    
    -- Check if source database is accessible
    DECLARE
        source_db_exists boolean;
        source_db_name text;
    BEGIN
        -- Try to extract database name from DSN (simplified)
        source_db_name := substring(v_source_dsn from 'dbname=([^\s]+)');
        IF source_db_name IS NULL THEN
            source_db_name := 'unknown';
        END IF;
        
        BEGIN
            SELECT EXISTS(SELECT 1 FROM dblink(v_source_dsn, 'SELECT 1') AS t(dummy int)) INTO source_db_exists;
            IF source_db_exists THEN
                IF p_verbose THEN
                    RAISE NOTICE '    ✓ %', rpad('Checking source database ' || source_db_name || ' is accessible', 120, ' ');
                END IF;
            ELSE
                RAISE NOTICE '    ✗ %', rpad('Source database ' || source_db_name || ' is not accessible', 120, ' ');
                RAISE EXCEPTION 'Exiting recover_cluster: Cannot connect to source database. Please verify DSN and connectivity.';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Source database ' || source_db_name || ' connection failed: ' || SQLERRM, 120, ' ');
            RAISE EXCEPTION 'Exiting recover_cluster: Cannot connect to source database: %.', SQLERRM;
        END;
    END;
    
    -- Check if spock extension is installed on source node
    DECLARE
        source_spock_exists boolean;
    BEGIN
        BEGIN
            SELECT EXISTS(SELECT 1 FROM dblink(v_source_dsn, 'SELECT 1 FROM pg_extension WHERE extname = ''spock''') AS t(exists boolean)) INTO source_spock_exists;
            IF source_spock_exists THEN
                IF p_verbose THEN
                    RAISE NOTICE '    ✓ %', rpad('Checking Spock extension is installed on source node', 120, ' ');
                END IF;
            ELSE
                RAISE NOTICE '    ✗ %', rpad('Spock extension is not installed on source node', 120, ' ');
                RAISE EXCEPTION 'Exiting recover_cluster: Spock extension is required on source node. Please install it first.';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Error checking Spock extension on source: ' || SQLERRM, 120, ' ');
            RAISE;
        END;
    END;
    
    -- Check if source node has spock.node table (spock is configured)
    DECLARE
        source_spock_configured boolean;
    BEGIN
        BEGIN
            SELECT EXISTS(SELECT 1 FROM dblink(v_source_dsn, 'SELECT 1 FROM information_schema.tables WHERE table_schema = ''spock'' AND table_name = ''node''') AS t(exists boolean)) INTO source_spock_configured;
            IF source_spock_configured THEN
                IF p_verbose THEN
                    RAISE NOTICE '    ✓ %', rpad('Checking Spock is configured on source node', 120, ' ');
                END IF;
            ELSE
                RAISE NOTICE '    ✗ %', rpad('Spock is not configured on source node', 120, ' ');
                RAISE EXCEPTION 'Exiting recover_cluster: Spock is not configured on source node. Please configure Spock first.';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Error checking Spock configuration on source: ' || SQLERRM, 120, ' ');
            RAISE;
        END;
    END;
    
    -- Check if target node has spock.node table (spock is configured)
    BEGIN
        IF EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema = 'spock' AND table_name = 'node') THEN
            IF p_verbose THEN
                RAISE NOTICE '    ✓ %', rpad('Checking Spock is configured on target node', 120, ' ');
            END IF;
        ELSE
            RAISE NOTICE '    ✗ %', rpad('Spock is not configured on target node', 120, ' ');
            RAISE EXCEPTION 'Exiting recover_cluster: Spock is not configured on target node. Please configure Spock first.';
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE '    ✗ %', rpad('Error checking Spock configuration on target: ' || SQLERRM, 120, ' ');
        RAISE;
    END;
    
    IF p_verbose THEN
        RAISE NOTICE '';
        RAISE NOTICE 'Phase 0 Complete: All prerequisites validated';
        RAISE NOTICE '';
    END IF;
    
    -- Connect to source node via dblink
        BEGIN
            PERFORM dblink_connect(v_conn_name_source, v_source_dsn);
            IF p_verbose THEN
                RAISE NOTICE '    ✓ Connected to source node via dblink';
            END IF;
        EXCEPTION WHEN OTHERS THEN
            RAISE NOTICE '    ✗ %', rpad('Failed to connect to source node: ' || SQLERRM, 120, ' ');
        RAISE EXCEPTION 'Exiting recover_cluster: Cannot connect to source node: %.', SQLERRM;
    END;
    
    -- Create a temporary table to store recovery report
    CREATE TEMP TABLE IF NOT EXISTS recovery_report (
        report_id uuid,
        table_schema text,
        table_name text,
        source_total_rows bigint,
        source_origin_rows bigint,  -- Only populated in origin-aware mode
        target_rows_before bigint,
        target_rows_after bigint,
        rows_affected bigint,
        status text,
        details text,
        time_taken interval,
        error_message text
    ) ON COMMIT DROP;
    
    IF p_verbose THEN
        RAISE NOTICE '========================================================================';
        RAISE NOTICE 'Phase 1: Discovery - Finding All Replicated Tables';
        RAISE NOTICE '  Purpose: Identify all tables that are part of replication sets';
        RAISE NOTICE '';
    END IF;
    
    -- Discover all tables in replication sets
    CREATE TEMP TABLE replicated_tables AS
    SELECT DISTINCT
        n.nspname as schema_name,
        c.relname as table_name,
        c.oid as table_oid
    FROM spock.replication_set rs
    JOIN spock.replication_set_table rst ON rst.set_id = rs.set_id
    JOIN pg_class c ON c.oid = rst.set_reloid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname <> ALL(p_exclude_schemas)
      AND (p_include_schemas IS NULL OR n.nspname = ANY(p_include_schemas))
    ORDER BY n.nspname, c.relname;
    
    SELECT COUNT(*) INTO v_table_count FROM replicated_tables;
    
        IF p_verbose THEN
            RAISE NOTICE 'Discovery Complete: Found % replicated table(s) to analyze', v_table_count;
            RAISE NOTICE '';
        END IF;
    
    IF v_table_count = 0 THEN
        RAISE WARNING 'No replicated tables found. Nothing to recover.';
        PERFORM dblink_disconnect(v_conn_name_source);
        RETURN;
    END IF;
    
    IF p_verbose THEN
        RAISE NOTICE '========================================================================';
        RAISE NOTICE 'Phase 2: Analysis - Checking Each Table for Inconsistencies';
        RAISE NOTICE '  Purpose: Compare row counts between source and target nodes';
        IF v_recovery_mode = 'origin-aware' THEN
            RAISE NOTICE '  Mode: Only counting rows that originated from node %', v_origin_node_name;
        ELSE
            RAISE NOTICE '  Mode: Counting all rows in each table';
        END IF;
        RAISE NOTICE '';
    END IF;
    
    -- Analyze each table
    FOR v_replicated_tables IN SELECT * FROM replicated_tables LOOP
        v_table_full_name := format('%I.%I', v_replicated_tables.schema_name, v_replicated_tables.table_name);
        v_start_time := clock_timestamp();
        v_status := 'OK';
        v_details := 'Already synchronized';
        v_rows_affected := 0;
        v_source_origin_count := NULL;
        
        IF p_verbose THEN
            RAISE NOTICE 'Analyzing table [%/%]: %', 
                (SELECT COUNT(*) FROM recovery_report) + 1, 
                v_table_count, 
                v_table_full_name;
        END IF;
        
        BEGIN
            -- Check if table has primary key
            SELECT ARRAY_AGG(a.attname ORDER BY array_position(i.indkey, a.attnum))
            INTO v_pk_cols
            FROM pg_index i
            JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
            WHERE i.indrelid = v_replicated_tables.table_oid
            AND i.indisprimary;
            
            IF v_pk_cols IS NULL OR array_length(v_pk_cols, 1) = 0 THEN
                INSERT INTO recovery_report VALUES (
                    v_recovery_report_id, v_replicated_tables.schema_name, v_replicated_tables.table_name,
                    NULL, NULL, NULL, NULL, 0,
                    'SKIPPED', 'No primary key', NULL, NULL
                );
            IF p_verbose THEN
                RAISE NOTICE '  [SKIPPED] Table has no primary key - cannot recover without unique identifier';
            END IF;
                CONTINUE;
            END IF;
            
            -- Get row count from source
            EXECUTE format('SELECT * FROM dblink(%L, %L) AS t(cnt bigint)',
                v_conn_name_source,
                format('SELECT COUNT(*) FROM %I.%I', v_replicated_tables.schema_name, v_replicated_tables.table_name)
            ) INTO v_source_count;
            
            -- For origin-aware mode, get count of rows from origin node
            IF v_recovery_mode = 'origin-aware' THEN
                EXECUTE format('SELECT * FROM dblink(%L, %L) AS t(cnt bigint)',
                    v_conn_name_source,
                    format($sql$
                        SELECT COUNT(*) FROM %I.%I
                        WHERE (to_json(spock.xact_commit_timestamp_origin(xmin))->>'roident')::oid = %L
                    $sql$, v_replicated_tables.schema_name, v_replicated_tables.table_name, v_origin_node_id)
                ) INTO v_source_origin_count;
            END IF;
            
            -- Get target row count (local)
            EXECUTE format('SELECT COUNT(*) FROM %I.%I', 
                v_replicated_tables.schema_name, v_replicated_tables.table_name
            ) INTO v_target_count;
            
            -- Calculate missing rows
            IF v_recovery_mode = 'origin-aware' THEN
                -- For origin-aware, we only care about origin rows
                v_missing_rows := GREATEST(0, v_source_origin_count - v_target_count);
            ELSE
                -- For comprehensive, compare total counts
                v_missing_rows := v_source_count - v_target_count;
            END IF;
            
            -- Determine status
            IF v_missing_rows > 0 THEN
                v_status := 'NEEDS_RECOVERY';
                IF v_recovery_mode = 'origin-aware' THEN
                    v_details := format('%s rows from origin %s missing (source: %s origin-rows, target: %s rows)', 
                        v_missing_rows, v_origin_node_name, v_source_origin_count, v_target_count);
                ELSE
                    v_details := format('%s rows missing (source: %s, target: %s)', 
                        v_missing_rows, v_source_count, v_target_count);
                END IF;
            ELSIF v_missing_rows < 0 THEN
                v_status := 'WARNING';
                v_details := format('Target has %s more rows than source', -v_missing_rows);
            ELSE
                v_status := 'OK';
                IF v_recovery_mode = 'origin-aware' THEN
                    v_details := format('All origin rows present (source: %s origin-rows, target: %s rows)', 
                        v_source_origin_count, v_target_count);
                ELSE
                    v_details := format('Synchronized (source: %s, target: %s)', v_source_count, v_target_count);
                END IF;
            END IF;
            
            INSERT INTO recovery_report VALUES (
                v_recovery_report_id, v_replicated_tables.schema_name, v_replicated_tables.table_name,
                v_source_count, v_source_origin_count, v_target_count, v_target_count, 
                CASE WHEN v_missing_rows > 0 THEN v_missing_rows ELSE 0 END,
                v_status, v_details, clock_timestamp() - v_start_time, NULL
            );
            
            IF p_verbose THEN
                IF v_status = 'NEEDS_RECOVERY' THEN
                    RAISE NOTICE '  ⚠ %', v_details;
                ELSIF v_status = 'OK' THEN
                    RAISE NOTICE '  ✓ %', v_details;
                ELSE
                    RAISE NOTICE '  ⚠ %', v_details;
                END IF;
            END IF;
            
        EXCEPTION WHEN OTHERS THEN
            INSERT INTO recovery_report VALUES (
                v_recovery_report_id, v_replicated_tables.schema_name, v_replicated_tables.table_name,
                NULL, NULL, NULL, NULL, 0,
                'ERROR', NULL, clock_timestamp() - v_start_time, SQLERRM
            );
            IF p_verbose THEN
                RAISE NOTICE '  ✗ ERROR: %', SQLERRM;
            END IF;
        END;
    END LOOP;
    
    IF p_verbose THEN
        RAISE NOTICE '';
        RAISE NOTICE '========================================================================';
        RAISE NOTICE 'Phase 2 Complete: Analysis Summary';
        RAISE NOTICE '  All replicated tables have been analyzed for inconsistencies';
        RAISE NOTICE '';
        
        FOR v_replicated_tables IN 
            SELECT 
                table_schema || '.' || table_name as table_name,
                COALESCE(source_total_rows::text, 'N/A') as src_total,
                COALESCE(source_origin_rows::text, '-') as src_origin,
                COALESCE(target_rows_before::text, 'N/A') as tgt_rows,
                COALESCE(rows_affected::text, '0') as missing,
                status
            FROM recovery_report
            WHERE report_id = v_recovery_report_id
            ORDER BY 
                CASE status 
                    WHEN 'NEEDS_RECOVERY' THEN 1
                    WHEN 'WARNING' THEN 2
                    WHEN 'ERROR' THEN 3
                    WHEN 'OK' THEN 4
                    ELSE 5
                END,
                table_schema, table_name
        LOOP
            RAISE NOTICE '  % [%] src:%s tgt:%s missing:%s',
                rpad(v_replicated_tables.table_name, 30),
                rpad(v_replicated_tables.status, 15),
                lpad(v_replicated_tables.src_total, 6),
                lpad(v_replicated_tables.tgt_rows, 6),
                lpad(v_replicated_tables.missing, 6);
        END LOOP;
        RAISE NOTICE '';
    END IF;
    
    -- PHASE 3: Recovery
    IF p_auto_repair THEN
        IF p_verbose THEN
            RAISE NOTICE '========================================================================';
            RAISE NOTICE 'Phase 3: Recovery - Repairing Tables';
            RAISE NOTICE '  Purpose: Insert missing rows from source node to target node';
            RAISE NOTICE '';
        END IF;
        
        FOR v_replicated_tables IN 
            SELECT * FROM recovery_report 
            WHERE report_id = v_recovery_report_id 
            AND status = 'NEEDS_RECOVERY' 
            ORDER BY COALESCE(rows_affected, 0) DESC
        LOOP
            v_start_time := clock_timestamp();
            v_table_full_name := format('%I.%I', v_replicated_tables.table_schema, v_replicated_tables.table_name);
            
            IF p_verbose THEN
                RAISE NOTICE 'Recovering table [%/%]: %', 
                    v_tables_recovered + 1,
                    (SELECT COUNT(*) FROM recovery_report WHERE report_id = v_recovery_report_id AND status = 'NEEDS_RECOVERY'),
                    v_table_full_name;
            END IF;
            
            BEGIN
                -- Get primary key columns
                SELECT ARRAY_AGG(a.attname ORDER BY array_position(i.indkey, a.attnum))
                INTO v_pk_cols
                FROM pg_index i
                JOIN pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = ANY(i.indkey)
                WHERE i.indrelid = (v_table_full_name)::regclass
                AND i.indisprimary;
                
                -- Get all columns with types
                SELECT 
                    ARRAY_AGG(a.attname ORDER BY a.attnum),
                    string_agg(format('%I %s', a.attname, format_type(a.atttypid, a.atttypmod)), ', ' ORDER BY a.attnum)
                INTO v_all_cols, v_col_types
                FROM pg_attribute a
                WHERE a.attrelid = (v_table_full_name)::regclass
                AND a.attnum > 0 
                AND NOT a.attisdropped;
                
                v_pk_col_list := array_to_string(v_pk_cols, ', ');
                v_all_col_list := array_to_string(v_all_cols, ', ');
                v_temp_table_name := 'missing_rows_' || md5(v_table_full_name);
                
                -- Build query to find missing rows
                IF v_recovery_mode = 'origin-aware' THEN
                    -- Origin-aware: filter by origin node
                    v_insert_sql := format($sql$
                        CREATE TEMP TABLE %I AS
                        SELECT * FROM dblink(%L, %L) AS remote(%s)
                        WHERE (%s) NOT IN (SELECT %s FROM %s)
                    $sql$,
                        v_temp_table_name,
                        v_conn_name_source,
                        format($remote$
                            SELECT * FROM %I.%I
                            WHERE (to_json(spock.xact_commit_timestamp_origin(xmin))->>'roident')::oid = %L
                        $remote$, v_replicated_tables.table_schema, v_replicated_tables.table_name, v_origin_node_id),
                        v_col_types,
                        v_pk_col_list,
                        v_pk_col_list,
                        v_table_full_name
                    );
                ELSE
                    -- Comprehensive: get all missing rows
                    v_insert_sql := format($sql$
                        CREATE TEMP TABLE %I AS
                        SELECT * FROM dblink(%L, %L) AS remote(%s)
                        WHERE (%s) NOT IN (SELECT %s FROM %s)
                    $sql$,
                        v_temp_table_name,
                        v_conn_name_source,
                        format('SELECT * FROM %I.%I', v_replicated_tables.table_schema, v_replicated_tables.table_name),
                        v_col_types,
                        v_pk_col_list,
                        v_pk_col_list,
                        v_table_full_name
                    );
                END IF;
                
                IF p_dry_run THEN
                    -- Dry run: just show what would be done
                    v_rows_affected := v_replicated_tables.rows_affected;  -- Estimated
                    v_details := format('DRY RUN: Would insert %s rows', v_rows_affected);
                    v_status := 'DRY_RUN';
                ELSE
                    -- Execute the recovery
                    EXECUTE v_insert_sql;
                    
                    -- Insert missing rows
                    EXECUTE format('INSERT INTO %s SELECT * FROM %I', v_table_full_name, v_temp_table_name);
                    GET DIAGNOSTICS v_rows_affected = ROW_COUNT;
                    
                    v_total_rows_recovered := v_total_rows_recovered + v_rows_affected;
                    v_details := format('Successfully inserted %s rows', v_rows_affected);
                    v_status := 'RECOVERED';
                    v_tables_recovered := v_tables_recovered + 1;
                END IF;
                
                -- Update report
                UPDATE recovery_report
                SET status = v_status,
                    rows_affected = v_rows_affected,
                    target_rows_after = target_rows_before + v_rows_affected,
                    details = v_details,
                    time_taken = clock_timestamp() - v_start_time
                WHERE report_id = v_recovery_report_id
                AND table_schema = v_replicated_tables.table_schema
                AND table_name = v_replicated_tables.table_name;
                
                IF p_verbose THEN
                    IF v_status = 'RECOVERED' THEN
                        RAISE NOTICE '  ✓ Recovered % rows in %', 
                            v_rows_affected, clock_timestamp() - v_start_time;
                    ELSE
                        RAISE NOTICE '  [DRY_RUN] Would recover % rows', v_rows_affected;
                    END IF;
                END IF;
                
                -- Clean up temp table
                EXECUTE format('DROP TABLE IF EXISTS %I', v_temp_table_name);
                
            EXCEPTION WHEN OTHERS THEN
                UPDATE recovery_report
                SET status = 'RECOVERY_FAILED',
                    error_message = SQLERRM,
                    time_taken = clock_timestamp() - v_start_time
                WHERE report_id = v_recovery_report_id
                AND table_schema = v_replicated_tables.table_schema
                AND table_name = v_replicated_tables.table_name;
                
                v_tables_with_errors := v_tables_with_errors + 1;
                
                IF p_verbose THEN
                    RAISE NOTICE '  ✗ RECOVERY_FAILED: %', SQLERRM;
                END IF;
            END;
        END LOOP;
    ELSE
        IF p_verbose THEN
            RAISE NOTICE 'Auto-repair disabled. Skipping Phase 3.';
            RAISE NOTICE '';
        END IF;
    END IF;
    
    -- Disconnect from source
    PERFORM dblink_disconnect(v_conn_name_source);
    
    -- Calculate statistics
    SELECT 
        COUNT(*) FILTER (WHERE status = 'RECOVERED' OR status = 'DRY_RUN'),
        COUNT(*) FILTER (WHERE status = 'OK' OR status = 'SKIPPED'),
        COUNT(*) FILTER (WHERE status = 'NEEDS_RECOVERY'),
        COUNT(*) FILTER (WHERE status = 'ERROR' OR status = 'RECOVERY_FAILED')
    INTO v_tables_recovered, v_tables_already_ok, v_tables_still_need_recovery, v_tables_with_errors
    FROM recovery_report
    WHERE report_id = v_recovery_report_id;
    
    v_end_time := clock_timestamp();
    v_time_taken := v_end_time - v_start_time;
    
    -- Final Report
    IF p_verbose THEN
        RAISE NOTICE '';
        RAISE NOTICE '========================================================================';
        RAISE NOTICE '                    FINAL RECOVERY REPORT';
        RAISE NOTICE '========================================================================';
        RAISE NOTICE '';
        
        RAISE NOTICE 'Recovery Summary by Status:';
        FOR v_replicated_tables IN
            SELECT 
                status,
                COUNT(*) as table_count,
                SUM(COALESCE(rows_affected, 0)) as total_rows
            FROM recovery_report
            WHERE report_id = v_recovery_report_id
            GROUP BY status
            ORDER BY 
                CASE status 
                    WHEN 'RECOVERED' THEN 1
                    WHEN 'DRY_RUN' THEN 2
                    WHEN 'OK' THEN 3
                    WHEN 'NEEDS_RECOVERY' THEN 4
                    WHEN 'WARNING' THEN 5
                    WHEN 'ERROR' THEN 6
                    ELSE 7
                END
        LOOP
            RAISE NOTICE '  %: % tables, % rows affected', 
                rpad(v_replicated_tables.status, 20),
                v_replicated_tables.table_count,
                v_replicated_tables.total_rows;
        END LOOP;
        
        RAISE NOTICE '';
        RAISE NOTICE 'Detailed Recovery Report:';
        RAISE NOTICE '  Table Name                          Status            Source  Target Before  Target After  Details';
        RAISE NOTICE '  --------------------------------------------------------------------------------------------------------------------';
        FOR v_replicated_tables IN
            SELECT 
                table_schema || '.' || table_name as table_name,
                COALESCE(source_total_rows::text, 'N/A') as src,
                COALESCE(target_rows_before::text, 'N/A') as tgt_before,
                COALESCE(target_rows_after::text, 'N/A') as tgt_after,
                status,
                COALESCE(details, error_message, '') as info,
                COALESCE(time_taken::text, '') as time
            FROM recovery_report
            WHERE report_id = v_recovery_report_id
            ORDER BY 
                CASE status 
                    WHEN 'RECOVERED' THEN 1
                    WHEN 'DRY_RUN' THEN 2
                    WHEN 'NEEDS_RECOVERY' THEN 3
                    WHEN 'WARNING' THEN 4
                    WHEN 'ERROR' THEN 5
                    WHEN 'OK' THEN 6
                    ELSE 7
                END,
                table_schema, table_name
        LOOP
            RAISE NOTICE '  % % % % % %',
                rpad(v_replicated_tables.table_name, 35),
                rpad(v_replicated_tables.status, 18),
                lpad(v_replicated_tables.src, 8),
                lpad(v_replicated_tables.tgt_before, 15),
                lpad(v_replicated_tables.tgt_after, 14),
                CASE 
                    WHEN length(v_replicated_tables.info) > 50 THEN substring(v_replicated_tables.info, 1, 47) || '...'
                    ELSE v_replicated_tables.info
                END;
        END LOOP;
        
        RAISE NOTICE '';
        RAISE NOTICE '========================================================================';
        RAISE NOTICE 'Recovery Statistics';
        RAISE NOTICE '========================================================================';
        RAISE NOTICE '  ✓ Tables Successfully Recovered: %', v_tables_recovered;
        RAISE NOTICE '  ✓ Tables Already Synchronized: %', v_tables_already_ok;
        RAISE NOTICE '  ⚠ Tables Still Requiring Recovery: %', v_tables_still_need_recovery;
        RAISE NOTICE '  ✗ Tables With Errors: %', v_tables_with_errors;
        RAISE NOTICE '  Total Rows Recovered: %', v_total_rows_recovered;
        RAISE NOTICE '  Total Recovery Time: %', v_time_taken;
        RAISE NOTICE '';
        
        IF p_dry_run THEN
            RAISE NOTICE '========================================================================';
            RAISE NOTICE '              DRY RUN COMPLETE - NO CHANGES MADE';
            RAISE NOTICE '  This was a preview run. No data was modified.';
            RAISE NOTICE '  To apply recovery, run again with p_dry_run := false';
            RAISE NOTICE '========================================================================';
        ELSIF v_tables_still_need_recovery = 0 AND v_tables_with_errors = 0 THEN
            RAISE NOTICE '========================================================================';
            RAISE NOTICE '                  RECOVERY COMPLETE - SUCCESS';
            RAISE NOTICE '  All tables have been successfully recovered and synchronized.';
            RAISE NOTICE '  Total rows recovered: %', v_total_rows_recovered;
            RAISE NOTICE '========================================================================';
        ELSE
            RAISE NOTICE '========================================================================';
            RAISE NOTICE '              RECOVERY COMPLETED WITH ISSUES';
            IF v_tables_still_need_recovery > 0 THEN
                RAISE NOTICE '  Warning: % tables still require recovery', v_tables_still_need_recovery;
            END IF;
            IF v_tables_with_errors > 0 THEN
                RAISE NOTICE '  Error: % tables encountered errors during recovery', v_tables_with_errors;
            END IF;
            RAISE NOTICE '  Please review the detailed report above for more information.';
            RAISE NOTICE '========================================================================';
        END IF;
        RAISE NOTICE '';
    END IF;
    
    DROP TABLE IF EXISTS replicated_tables;
    
EXCEPTION
    WHEN OTHERS THEN
        IF p_verbose THEN
            RAISE EXCEPTION 'Recovery failed: %', SQLERRM;
        END IF;
        BEGIN
            PERFORM dblink_disconnect(v_conn_name_source);
        EXCEPTION WHEN OTHERS THEN END;
        DROP TABLE IF EXISTS replicated_tables;
        RAISE;
END;
$$;

COMMENT ON PROCEDURE spock.recover_cluster IS 'Unified recovery procedure with comprehensive and origin-aware modes';

-- ============================================================================
-- Quick Start Examples
-- ============================================================================

\echo 'Consolidated Recovery System Loaded!'
\echo ''
\echo 'Quick Start Examples:'
\echo ''
\echo '1. Comprehensive Recovery (recover ALL missing data):'
\echo '   CALL spock.recover_cluster('
\echo '       p_source_dsn := ''host=localhost port=5453 dbname=pgedge user=pgedge'''
\echo '   );'
\echo ''
\echo '2. Origin-Aware Recovery (recover only n1 transactions):'
\echo '   CALL spock.recover_cluster('
\echo '       p_source_dsn := ''host=localhost port=5453 dbname=pgedge user=pgedge'','
\echo '       p_recovery_mode := ''origin-aware'','
\echo '       p_origin_node_name := ''n1'''
\echo '   );'
\echo ''
\echo '3. Dry Run (preview changes without applying):'
\echo '   CALL spock.recover_cluster('
\echo '       p_source_dsn := ''host=localhost port=5453 dbname=pgedge user=pgedge'','
\echo '       p_dry_run := true'
\echo '   );'
\echo ''
