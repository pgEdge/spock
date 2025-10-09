
SELECT * FROM spock_regress_variables()
\gset

\c :provider_dsn
CREATE USER super2 SUPERUSER;

\c :subscriber_dsn
SELECT * FROM spock.node_add_interface('test_provider', 'super2', (SELECT provider_dsn FROM spock_regress_variables()) || ' user=super2');

-- Check that the signal_worker_xact_callback routine process subscription
-- change in a right way, considering abortion and prepared transactions.
BEGIN;
SELECT * FROM spock.sub_alter_interface('test_subscription', 'super2');
ROLLBACK;
BEGIN;
SELECT * FROM spock.sub_alter_interface('test_subscription', 'super2');
PREPARE TRANSACTION 't1';
ABORT PREPARED 't1'; -- ERROR between preparation and abortion
ROLLBACK PREPARED 't1';
BEGIN;
SAVEPOINT s1;
SELECT * FROM spock.sub_alter_interface('test_subscription', 'super2');
ROLLBACK TO SAVEPOINT s1;
COMMIT;

SELECT * FROM spock.sub_alter_interface('test_subscription', 'super2');

DO $$
BEGIN
    FOR i IN 1..100 LOOP
        IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status != 'down') THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;$$;

SELECT pg_sleep(0.1);
SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.sub_show_status();

\c :provider_dsn
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT usename FROM pg_stat_replication WHERE application_name = 'test_subscription';

\c :subscriber_dsn
SELECT * FROM spock.sub_alter_interface('test_subscription', 'test_provider');

DO $$
BEGIN
    FOR i IN 1..100 LOOP
        IF EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status != 'down') THEN
            EXIT;
        END IF;
        PERFORM pg_sleep(0.1);
    END LOOP;
END;$$;

SELECT pg_sleep(0.1);
SELECT subscription_name, status, provider_node, replication_sets, forward_origins FROM spock.sub_show_status();

\c :provider_dsn
DROP USER super2;
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT usename FROM pg_stat_replication WHERE application_name = 'test_subscription';
