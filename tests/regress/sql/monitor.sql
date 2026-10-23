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

-- The supervisor and the database manager are running.  The manager is
-- started by the supervisor a moment after the node exists, so wait for it
-- rather than depend on an earlier test having given it the time.
DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.worker_status
                    WHERE worker_type = 'manager'
                      AND worker_status = 'running') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;
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

-- The worker has started and connected since the subscription was made
SELECT subscription_name,
       worker_starts >= 1 AS started,
       provider_connects >= 1 AS connected,
       xacts_applied > 0 AS applied_xacts,
       stats_reset
  FROM spock.subscription_stats;

-- The test makes its own traffic, so it does not depend on what ran before
-- it: a table, then from a clean slate three inserted rows in two
-- transactions, two updated rows and one deleted row, one transaction each.
\c :provider_dsn
SELECT spock.replicate_ddl($$
    CREATE TABLE public.monitor_dml (id integer PRIMARY KEY, data text);
$$);
SELECT * FROM spock.repset_add_table('default', 'monitor_dml');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- The provider counts the table as replicated
SELECT replicated_tables >= 1 AS has_replicated_tables,
       pending_exceptions
  FROM spock.node_status;

\c :subscriber_dsn
SELECT spock.reset_subscription_stats();
SELECT spock.reset_channel_stats();

\c :provider_dsn
INSERT INTO monitor_dml VALUES (1, 'one');
INSERT INTO monitor_dml VALUES (2, 'two'), (3, 'three');
UPDATE monitor_dml SET data = data || '!' WHERE id IN (1, 2);
DELETE FROM monitor_dml WHERE id = 3;
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT id, data FROM monitor_dml ORDER BY id;

-- Every counter moved by exactly that traffic.  Messages and bytes also
-- carry keepalives, so those are only known to be positive.
SELECT subscription_name,
       xacts_applied, n_tup_ins, n_tup_upd, n_tup_del,
       xacts_skipped, xacts_discarded, apply_errors, sync_errors,
       messages_received > 0 AS received_messages,
       bytes_received > 0 AS received_bytes,
       last_xact_applied IS NOT NULL AS has_last_xact,
       stats_reset IS NOT NULL AS was_reset
  FROM spock.subscription_stats;

-- A reset of one subscription by its OID clears its counters and stamps the
-- row; an invalid OID is refused.
SELECT sub_id AS test_sub_id FROM spock.subscription
 WHERE sub_name = 'test_subscription' \gset
SELECT spock.reset_subscription_stats(:test_sub_id);
SELECT spock.reset_channel_stats();
SELECT xacts_applied, n_tup_ins, n_tup_upd, n_tup_del,
       stats_reset IS NOT NULL AS was_reset
  FROM spock.subscription_stats;
SELECT spock.reset_subscription_stats(0);

-- Events recorded on the subscriber
SELECT DISTINCT event_type, severity
  FROM spock.events
 WHERE event_type IN ('subscription_created', 'worker_started',
                      'provider_connected')
 ORDER BY event_type;

-- Disabling and enabling the subscription is recorded and restarts the worker
SELECT spock.reset_events();
SELECT spock.sub_disable('test_subscription');
SELECT spock.sub_enable('test_subscription');

-- sub_disable()/sub_enable() return without waiting for the old apply worker
-- to exit, and the subscription reads as replicating while it is still
-- running.  Waiting on that alone would let the worker_stopped assertion
-- below run before the restart had been recorded.  Wait for a worker_started
-- that is newer than the worker_stopped instead, so the events this test
-- checks are known to be in.
DO $$
DECLARE
    stopped_id bigint;
    started_id bigint;
BEGIN
    FOR i IN 1..600 LOOP
        SELECT max(event_id) INTO stopped_id
          FROM spock.events
         WHERE event_type = 'worker_stopped';

        SELECT max(event_id) INTO started_id
          FROM spock.events
         WHERE event_type = 'worker_started'
           AND subscription_name = 'test_subscription';

        IF stopped_id IS NOT NULL AND started_id IS NOT NULL
           AND started_id > stopped_id
           AND EXISTS (SELECT 1 FROM spock.subscription_status
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

-- The restart shows up in the counters.  worker_failures is not asserted to
-- be zero: sub_disable()/sub_enable() restart the worker by killing it, and
-- the replacement can lose a race for the provider's slot ("replication slot
-- ... is active for PID n") and exit once before succeeding.  That is a
-- transient of restarting, not a fault, so only check it stays bounded by the
-- number of starts.
SELECT worker_starts >= 1 AS restarted, worker_failures <= worker_starts AS failures_bounded
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
       pending_exceptions
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

-- A role without EXECUTE on the revoked functions still gets the report:
-- the header shows the host as unknown and each such section is one
-- error line rather than a failure of the whole call.
CREATE ROLE monitor_reader;
GRANT USAGE ON SCHEMA spock TO monitor_reader;
SET ROLE monitor_reader;
SELECT line LIKE 'Spock node report: database ' || current_database() ||
       ' on (unknown) at %' AS header_without_host
  FROM spock.spock_info(0) AS line
 LIMIT 1;
SELECT count(*) FILTER (WHERE line LIKE '== % ==') > 0 AS has_sections,
       count(*) FILTER (WHERE line LIKE '(error: permission denied%') > 0
         AS has_denied_sections
  FROM spock.spock_info(0) AS line;
RESET ROLE;
REVOKE USAGE ON SCHEMA spock FROM monitor_reader;
DROP ROLE monitor_reader;

-- Nothing blocks the apply worker and data arrived recently
SELECT blocked_by_pids, blocking_pid
  FROM spock.worker_status WHERE worker_type = 'apply';
-- last_error_* is deliberately not asserted empty here, for the reason given
-- at the restart counters above; the dedicated apply-error section below is
-- where those columns are checked against a known failure.
SELECT time_since_last_message < interval '1 hour' AS recent_data,
       worker_blocked_by_pids
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

-- A provider that cannot be reached is a lost connection, not an apply error
SELECT spock.reset_subscription_stats();
SELECT spock.reset_events();
SELECT spock.node_add_interface('test_provider', 'unreachable',
                                'host=127.0.0.1 port=1 dbname=regression connect_timeout=1');
SELECT spock.sub_alter_interface('test_subscription', 'unreachable');

-- The disconnect is counted when the connection attempt fails; the worker
-- failing and its worker_failed event are recorded separately, a moment
-- later.  Waiting only for the disconnect leaves the two assertions below
-- racing those, which is what fails under spock.random_delays.
DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.subscription_stats
                    WHERE provider_disconnects >= 1
                      AND worker_failures >= 1)
           AND EXISTS (SELECT 1 FROM spock.events
                        WHERE event_type = 'worker_failed') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;

SELECT provider_disconnects >= 1 AS disconnects_counted,
       apply_errors, worker_failures >= 1 AS worker_failed,
       last_error_sqlstate,
       last_error_message LIKE 'could not connect to the postgresql server%' AS has_message
  FROM spock.subscription_stats;

SELECT DISTINCT event_type, severity, sqlstate,
       detail LIKE '%could not connect%' AS names_cause
  FROM spock.events
 WHERE event_type IN ('provider_disconnected', 'worker_failed', 'worker_error')
 ORDER BY event_type;

SELECT spock.sub_alter_interface('test_subscription', 'test_provider');
SELECT spock.node_drop_interface('test_provider', 'unreachable');

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

SELECT status FROM spock.subscription_status;

-- Altering the subscription's interface was recorded as well
SELECT count(*) >= 2 AS interface_changes_recorded
  FROM spock.events
 WHERE event_type = 'subscription_altered'
   AND subscription_name = 'test_subscription';

-- A conflict is resolved, counted and, with save_resolutions on, logged,
-- not treated as an error.  The row is inserted here first, then with the
-- same key on the provider; the later commit wins under the default
-- resolver.
SELECT spock.reset_subscription_stats();
SELECT spock.reset_channel_stats();
TRUNCATE spock.resolutions;
ALTER SYSTEM SET spock.save_resolutions = on;
SELECT pg_reload_conf();
INSERT INTO monitor_dml VALUES (10, 'subscriber first');

\c :provider_dsn
INSERT INTO monitor_dml VALUES (10, 'provider second');
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

\c :subscriber_dsn
SELECT id, data FROM monitor_dml WHERE id = 10;
SELECT relname, conflict_type, conflict_resolution FROM spock.resolutions;
-- The per-type counters are kept from PostgreSQL 18 on and are null before.
SELECT n_conflict, apply_errors, xacts_applied,
       confl_insert_exists IS NULL OR confl_insert_exists = 1
           AS insert_exists_counted
  FROM spock.subscription_stats;
ALTER SYSTEM RESET spock.save_resolutions;
SELECT pg_reload_conf();
TRUNCATE spock.resolutions;

-- Pausing the apply workers shows on the node, and both the pause and the
-- resume are recorded.  The worker's own paused flag is not asserted: an
-- idle worker only sets it when it next handles a message, and
-- pause_apply_workers() returns as soon as no worker has a transaction
-- open.
SELECT spock.reset_events();
SELECT spock.pause_apply_workers();
SELECT apply_paused FROM spock.node_status;
SELECT spock.resume_apply_workers();
SELECT apply_paused FROM spock.node_status;
SELECT event_type, severity, subscription_name
  FROM spock.events
 WHERE event_type IN ('apply_paused', 'apply_resumed')
 ORDER BY event_id;

-- Repair mode is recorded with the pid of the session that switched it
SELECT spock.repair_mode(true) IS NOT NULL AS enabled;
SELECT spock.repair_mode(false) IS NOT NULL AS disabled;
SELECT event_type, severity, pid = pg_backend_pid() AS from_this_session
  FROM spock.events
 WHERE event_type IN ('repair_mode_enabled', 'repair_mode_disabled')
 ORDER BY event_id;

-- Resynchronising a table runs a sync worker, counts the table and records
-- the start and the finish
SELECT spock.reset_subscription_stats();
SELECT spock.reset_events();
SELECT spock.sub_resync_table('test_subscription', 'monitor_dml', true);
SELECT spock.table_wait_for_sync('test_subscription', 'monitor_dml');
SELECT id, data FROM monitor_dml ORDER BY id;

-- The finish is recorded by the sync worker after the table is marked
-- synced, so wait for it
DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.events
                    WHERE event_type = 'sync_finished') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;
SELECT tables_synced, sync_errors,
       last_table_synced IS NOT NULL AS has_time
  FROM spock.subscription_stats;
SELECT schema_name, table_name, sync_kind, sync_status
  FROM spock.table_sync_status
 WHERE table_name = 'monitor_dml';
SELECT event_type, severity, subscription_name, detail
  FROM spock.events
 WHERE event_type IN ('sync_started', 'sync_finished', 'sync_failed')
 ORDER BY event_id;

-- With exception_behaviour = sub_disable a failing transaction disables the
-- subscription, which the worker records; skipping that transaction and
-- enabling the subscription again counts and records the skip
TRUNCATE spock.exception_log;
SELECT spock.reset_subscription_stats();
SELECT spock.reset_events();
ALTER TABLE public.monitor_dml
    ADD CONSTRAINT monitor_dml_small CHECK (id < 1000);
ALTER SYSTEM SET spock.exception_behaviour = 'sub_disable';
SELECT pg_reload_conf();

\c :provider_dsn
INSERT INTO monitor_dml VALUES (1000, 'rejected');
SELECT fetch_last_xid('I') AS remote_xid \gset

\c :subscriber_dsn
DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.subscription_status
                    WHERE NOT enabled)
           AND EXISTS (SELECT 1 FROM spock.events
                        WHERE event_type = 'subscription_disabled') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;
SELECT enabled, status FROM spock.subscription_status;
SELECT operation, table_name FROM spock.exception_log ORDER BY command_counter;
SELECT event_type, severity, subscription_name, sqlstate
  FROM spock.events
 WHERE event_type IN ('worker_error', 'subscription_disabled')
 ORDER BY event_id;
SELECT apply_errors, constraint_violations, xacts_discarded, xacts_skipped
  FROM spock.subscription_stats;

SELECT skiplsn_and_enable_sub('test_subscription', :remote_xid);
DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.subscription_stats
                    WHERE xacts_skipped >= 1)
           AND EXISTS (SELECT 1 FROM spock.subscription_status
                        WHERE status = 'replicating') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;
SELECT count(*) AS rejected_rows FROM monitor_dml WHERE id = 1000;
SELECT xacts_skipped, apply_errors FROM spock.subscription_stats;
SELECT event_type, severity, subscription_name, detail
  FROM spock.events
 WHERE event_type IN ('subscription_enabled', 'transaction_skipped')
 ORDER BY event_id;

ALTER SYSTEM RESET spock.exception_behaviour;
SELECT pg_reload_conf();
ALTER TABLE public.monitor_dml DROP CONSTRAINT monitor_dml_small;
TRUNCATE spock.exception_log;

-- Resetting the events empties this database's history and keeps the count
-- of everything ever recorded; the provider's history, checked below, is
-- not touched
SELECT database_id IS NULL AS node_wide, count(*) > 0 AS present
  FROM spock.get_events() GROUP BY 1 ORDER BY 1;
SELECT spock.reset_events();
SELECT events_recorded > 0 AS kept_total
  FROM spock.get_monitor_summary();
SELECT count(*) AS events FROM spock.events;
SELECT database_id IS NULL AS node_wide, count(*) > 0 AS present
  FROM spock.get_events() GROUP BY 1 ORDER BY 1;

-- Shared memory summary
SELECT worker_slots > 0 AS has_slots, worker_slots_used > 0 AS slots_in_use,
       events_capacity, events_retained > 0 AS has_events,
       events_recorded >= events_retained AS ids_monotonic,
       subscription_stats_used >= 1 AS has_stats, channel_stats_full
  FROM spock.get_monitor_summary();

\c :provider_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

-- The restarts of the apply worker ended and restarted the stream here, and
-- the subscriber's reset of its events left this history alone.  The
-- walsender records the stop as it exits, so wait for it.
DO $$
BEGIN
    FOR i IN 1..600 LOOP
        IF EXISTS (SELECT 1 FROM spock.events
                    WHERE event_type = 'stream_stopped') THEN
            RETURN;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;
$$;
SELECT count(*) >= 1 AS stream_stopped,
       count(*) FILTER (WHERE event_type = 'stream_started') >= 2
           AS stream_restarted
  FROM spock.events
 WHERE event_type IN ('stream_stopped', 'stream_started');

SELECT spock.replicate_ddl($$ DROP TABLE public.monitor_dml CASCADE; $$);
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);
