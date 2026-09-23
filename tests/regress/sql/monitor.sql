-- Monitoring views: node, workers, subscriptions, slots, events, counters
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn

-- The node on one row
SELECT node_name, extension_update_pending, apply_paused,
       subscriptions, replication_slots, replication_slots_active,
       apply_workers, workers_restart_pending,
       wal_size_bytes > 0 AS has_wal,
       max_retained_wal_bytes >= 0 AS retains_wal
  FROM spock.node_status;

-- The supervisor and the database manager are running
SELECT worker_type, worker_status, pid IS NOT NULL AS has_pid
  FROM spock.worker_status
 WHERE worker_type IN ('supervisor', 'manager')
 ORDER BY worker_type;

-- The provider side: an active slot served by a walsender
SELECT active, state, client_name = slot_name AS client_is_subscriber,
       retained_wal_bytes >= 0 AS retains_wal,
       pending_wal_bytes >= 0 AS has_pending,
       wal_status
  FROM spock.slot_status;

-- Events recorded on the provider
SELECT DISTINCT event_type, severity
  FROM spock.events
 WHERE event_type IN ('node_created', 'slot_created', 'stream_started')
 ORDER BY event_type;

\c :subscriber_dsn

-- The subscription on one row
SELECT subscription_name, enabled, status, provider_node,
       provider_dsn NOT LIKE '%password%' OR provider_dsn LIKE '%********%'
           AS password_hidden,
       sync_status, worker_status, worker_pid IS NOT NULL AS has_worker,
       in_exception_handling, worker_paused,
       received_lsn >= remote_commit_lsn AS received_past_commit,
       replication_lag_bytes >= 0 AS lag_known,
       worker_starts >= 1 AS worker_started,
       apply_errors, last_error_message
  FROM spock.subscription_status;

-- The apply worker as seen from the worker list
SELECT worker_type, worker_status, subscription_name,
       started_at IS NOT NULL AS has_backend
  FROM spock.worker_status
 WHERE worker_type = 'apply';

-- Whole-subscription sync state
SELECT subscription_name, schema_name, table_name, sync_kind, sync_status
  FROM spock.table_sync_status
 WHERE table_name IS NULL;

-- Counters reflect the traffic of the previous tests
SELECT subscription_name,
       worker_starts >= 1 AS started,
       provider_connects >= 1 AS connected,
       messages_received > 0 AS received_messages,
       bytes_received > 0 AS received_bytes,
       xacts_applied > 0 AS applied_xacts,
       n_tup_ins > 0 AS inserted_tuples,
       xacts_skipped, xacts_discarded, apply_errors, sync_errors,
       last_xact_applied IS NOT NULL AS has_last_xact,
       stats_reset
  FROM spock.subscription_stats;

-- Events recorded on the subscriber
SELECT DISTINCT event_type, severity
  FROM spock.events
 WHERE event_type IN ('subscription_created', 'worker_started',
                      'provider_connected')
 ORDER BY event_type;

-- Resetting the counters keeps the row and stamps it
SELECT spock.reset_subscription_stats();
SELECT subscription_name, xacts_applied, messages_received, worker_starts,
       stats_reset IS NOT NULL AS was_reset
  FROM spock.subscription_stats;

-- Disabling and enabling the subscription is recorded and restarts the worker
SELECT spock.reset_events();
SELECT spock.sub_disable('test_subscription');
SELECT spock.sub_enable('test_subscription');

DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.subscription_status
                    WHERE status = 'replicating') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;

SELECT status, worker_status FROM spock.subscription_status;

SELECT event_type, severity, subscription_name
  FROM spock.events
 WHERE event_type IN ('subscription_disabled', 'subscription_enabled')
 ORDER BY event_id;

SELECT count(*) >= 1 AS worker_stopped
  FROM spock.events
 WHERE event_type = 'worker_stopped';

SELECT count(*) >= 1 AS worker_started
  FROM spock.events
 WHERE event_type = 'worker_started'
   AND subscription_name = 'test_subscription';

-- The restart shows up in the counters
SELECT worker_starts >= 1 AS restarted, worker_failures
  FROM spock.subscription_stats;

-- Host, versions and capacity
SELECT hostname IS NOT NULL AS has_hostname, os_name IS NOT NULL AS has_os,
       postgres_version_num = current_setting('server_version_num')::int AS pg_version_matches,
       spock_version = spock.spock_version() AS spock_version_matches,
       protocol_version >= min_protocol_version AS protocol_ok,
       postmaster_start_time <= now() AS started_before_now
  FROM spock.get_system_info();

SELECT hostname IS NOT NULL AS has_hostname, worker_slots > 0 AS has_slots,
       worker_slots_used <= worker_slots AS slots_within_limit,
       pending_exceptions, replicated_tables, unreplicated_tables
  FROM spock.node_status;

-- Host and instance health
SELECT data_disk_free_bytes > 0 AS has_disk_free,
       data_disk_free_bytes <= data_disk_total_bytes AS disk_within_total,
       wal_disk_free_bytes > 0 AS has_wal_disk_free,
       wal_size_bytes > 0 AS has_wal,
       database_size_bytes > 0 AS has_database,
       uptime > interval '0' AS has_uptime,
       in_recovery,
       connections >= 1 AND connections <= max_connections AS connections_sane,
       longest_transaction IS NOT NULL AS has_transaction,
       prepared_transactions,
       oldest_xid_age > 0 AS has_xid_age,
       xact_commit > 0 AS has_commits,
       archive_mode
  FROM spock.system_status;

-- Settings, peers and replication sets
SELECT count(*) FILTER (WHERE name LIKE 'spock.%') > 0 AS has_spock_settings,
       count(*) FILTER (WHERE name = 'wal_level') AS has_wal_level
  FROM spock.settings;

SELECT node_name, is_local, dsn IS NOT NULL AS has_dsn,
       subscription_name, subscription_status
  FROM spock.peer_status
 ORDER BY node_name;

SELECT set_name, replicate_insert, replicate_update, replicate_delete,
       replicate_truncate, table_count > 0 AS has_tables, subscription_count
  FROM spock.replication_set_status;

-- No transaction is being retried
SELECT count(*) AS pending_exceptions FROM spock.get_pending_exceptions();

-- The report lists every section and never fails as a whole
SELECT line
  FROM spock.spock_info(5) AS line
 WHERE line LIKE '== % =='
 ORDER BY line;

-- Values are rendered in PostgreSQL text form, tables are aligned
SELECT line
  FROM spock.report_section('Sample',
       $q$ SELECT 't'::boolean AS flag, ARRAY['a','b'] AS items,
                  '2026-01-02 03:04:05+00'::timestamptz AT TIME ZONE 'UTC' AS at,
                  NULL::text AS missing, E'two\nlines' AS note $q$) AS line;
SELECT line
  FROM spock.report_section('Sample', 'SELECT 1 AS one, 2 AS two', true) AS line;
SELECT line
  FROM spock.report_section('Broken', 'SELECT * FROM spock.no_such_view') AS line;

SELECT count(*) > 30 AS has_content,
       count(*) FILTER (WHERE line LIKE '(error:%') AS failed_sections
  FROM spock.spock_info() AS line;

-- Nothing blocks the apply worker and data arrived recently
SELECT blocked_by_pids, blocking_pid
  FROM spock.worker_status WHERE worker_type = 'apply';
SELECT time_since_last_message < interval '1 hour' AS recent_data,
       worker_blocked_by_pids, last_error_sqlstate, last_error_pid
  FROM spock.subscription_status;

-- A real apply error is captured with SQLSTATE, detail, time and pid
\c :provider_dsn
SELECT spock.replicate_ddl($$
    CREATE TABLE public.monitor_errors (id integer PRIMARY KEY, amount integer);
$$);
SELECT * FROM spock.repset_add_table('default', 'monitor_errors');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
ALTER TABLE public.monitor_errors
    ADD CONSTRAINT monitor_errors_positive CHECK (amount > 0);
TRUNCATE spock.exception_log;
SELECT spock.reset_subscription_stats();
SELECT spock.reset_events();

\c :provider_dsn
INSERT INTO monitor_errors VALUES (1, -5);
SELECT spock.sync_event() AS sync_lsn \gset

\c :subscriber_dsn
CALL spock.wait_for_sync_event(NULL, 'test_provider', :'sync_lsn', 30);

-- The default exception behaviour discards the transaction and logs it
SELECT count(*) AS rows_applied FROM monitor_errors;
SELECT operation, table_name FROM spock.exception_log ORDER BY command_counter;

SELECT apply_errors >= 1 AS errors_counted,
       constraint_violations >= 1 AS classified,
       deadlocks, lock_timeouts, resource_errors, worker_failures,
       xacts_discarded,
       last_error_sqlstate,
       last_error_pid IS NOT NULL AS has_pid,
       last_apply_error IS NOT NULL AS has_time,
       last_error_message LIKE '%violates check constraint%' AS has_message,
       last_error_message LIKE '%DETAIL: Failing row contains%' AS has_detail
  FROM spock.subscription_stats;

SELECT status, pending_exception_lsn IS NULL AS nothing_pending,
       last_error_sqlstate, last_error_pid = worker_pid AS error_from_worker
  FROM spock.subscription_status;

SELECT DISTINCT event_type, severity, sqlstate, pid IS NOT NULL AS has_pid
  FROM spock.events
 WHERE event_type IN ('worker_error', 'transaction_discarded')
 ORDER BY event_type;

SELECT count(*) > 0 AS exception_reported
  FROM spock.spock_info() AS line
 WHERE line LIKE '%monitor_errors_positive%';

TRUNCATE spock.exception_log;
SELECT spock.reset_subscription_stats();

\c :provider_dsn
SELECT spock.replicate_ddl($$ DROP TABLE public.monitor_errors CASCADE; $$);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn

-- Shared memory summary
SELECT worker_slots > 0 AS has_slots, worker_slots_used > 0 AS slots_in_use,
       events_capacity, events_retained > 0 AS has_events,
       events_recorded >= events_retained AS ids_monotonic,
       subscription_stats_used >= 1 AS has_stats, channel_stats_full
  FROM spock.get_monitor_summary();

\c :provider_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
