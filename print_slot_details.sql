-- ============================================================================
-- Print Detailed Information for Recovery Slot and Cloned Slot
-- ============================================================================

\echo '============================================================================'
\echo 'RECOVERY SLOT DETAILS'
\echo '============================================================================'

SELECT 
    'Recovery Slot' AS slot_type,
    slot_name,
    restart_lsn,
    confirmed_flush_lsn,
    min_unacknowledged_ts,
    active,
    in_recovery
FROM spock.get_recovery_slot_status();

\echo ''
\echo '============================================================================'
\echo 'CLONED SLOT DETAILS (from pg_replication_slots)'
\echo '============================================================================'

SELECT 
    'Cloned Slot' AS slot_type,
    slot_name,
    plugin,
    slot_type,
    datoid,
    database,
    temporary,
    active,
    active_pid,
    xmin,
    catalog_xmin,
    restart_lsn,
    confirmed_flush_lsn,
    wal_status,
    safe_wal_size,
    two_phase
FROM pg_replication_slots
WHERE slot_name = 'spock_rescue_clone_2025_12_17_15_22_46_049726_05';

\echo ''
\echo '============================================================================'
\echo 'COMPARISON: Recovery Slot vs Cloned Slot'
\echo '============================================================================'

SELECT 
    'Original Recovery Slot' AS slot_name,
    rs.slot_name,
    rs.restart_lsn AS recovery_restart_lsn,
    rs.confirmed_flush_lsn AS recovery_confirmed_flush_lsn,
    rs.active AS recovery_active,
    rs.in_recovery,
    NULL::pg_lsn AS cloned_restart_lsn,
    NULL::pg_lsn AS cloned_confirmed_flush_lsn,
    NULL::boolean AS cloned_active,
    NULL::xid AS cloned_catalog_xmin
FROM spock.get_recovery_slot_status() rs
WHERE rs.active = true

UNION ALL

SELECT 
    'Cloned Slot' AS slot_name,
    prs.slot_name,
    NULL::pg_lsn AS recovery_restart_lsn,
    NULL::pg_lsn AS recovery_confirmed_flush_lsn,
    NULL::boolean AS recovery_active,
    NULL::boolean AS in_recovery,
    prs.restart_lsn AS cloned_restart_lsn,
    prs.confirmed_flush_lsn AS cloned_confirmed_flush_lsn,
    prs.active AS cloned_active,
    prs.catalog_xmin AS cloned_catalog_xmin
FROM pg_replication_slots prs
WHERE prs.slot_name = 'spock_rescue_clone_2025_12_17_15_22_46_049726_05';

\echo ''
\echo '============================================================================'
\echo 'LSN COMPARISON'
\echo '============================================================================'

WITH recovery_slot AS (
    SELECT 
        slot_name,
        restart_lsn,
        confirmed_flush_lsn
    FROM spock.get_recovery_slot_status()
    WHERE active = true
),
cloned_slot AS (
    SELECT 
        slot_name,
        restart_lsn,
        confirmed_flush_lsn,
        catalog_xmin
    FROM pg_replication_slots
    WHERE slot_name = 'spock_rescue_clone_2025_12_17_15_22_46_049726_05'
)
SELECT 
    'Recovery Slot' AS slot_type,
    rs.slot_name,
    rs.restart_lsn,
    rs.confirmed_flush_lsn,
    NULL::xid AS catalog_xmin,
    CASE 
        WHEN rs.restart_lsn IS NOT NULL AND cs.restart_lsn IS NOT NULL 
        THEN rs.restart_lsn - cs.restart_lsn
        ELSE NULL
    END AS lsn_difference_bytes
FROM recovery_slot rs
CROSS JOIN cloned_slot cs

UNION ALL

SELECT 
    'Cloned Slot' AS slot_type,
    cs.slot_name,
    cs.restart_lsn,
    cs.confirmed_flush_lsn,
    cs.catalog_xmin,
    NULL::bigint AS lsn_difference_bytes
FROM cloned_slot cs;

\echo ''
\echo '============================================================================'
\echo 'ALL RESCUE CLONE SLOTS (if any others exist)'
\echo '============================================================================'

SELECT 
    slot_name,
    plugin,
    slot_type,
    database,
    temporary,
    active,
    active_pid,
    xmin,
    catalog_xmin,
    restart_lsn,
    confirmed_flush_lsn,
    wal_status,
    safe_wal_size,
    two_phase,
    pg_size_pretty(safe_wal_size) AS safe_wal_size_pretty
FROM pg_replication_slots
WHERE slot_name LIKE 'spock_rescue_clone_%'
ORDER BY slot_name;



