
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

/*
 * XXX: there is still a small chance that we see an old state of the apply
 * worker if it is highly loaded or in a stall state.  Someday we should expose
 * the 'generation' value or invent something else to identify that it is
 * actually a new apply worker that has re-read the fresh subscription state.
 * But for now the current change should be enough.
 */
DO $$
BEGIN
    WHILE EXISTS (SELECT 1 FROM spock.sub_show_status()
				  WHERE status != 'replicating')
	LOOP
    END LOOP;
END;$$;

SELECT
  subscription_name, status, provider_node, replication_sets, forward_origins
FROM spock.sub_show_status();

\c :provider_dsn
SELECT spock.wait_slot_confirm_lsn(NULL, NULL);

DO $$
BEGIN
    WHILE EXISTS (SELECT 1 FROM pg_replication_slots WHERE active = 'false')
	LOOP
    END LOOP;
END;$$;
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT usename FROM pg_stat_replication WHERE application_name = 'test_subscription';

\c :subscriber_dsn
SELECT * FROM spock.sub_alter_interface('test_subscription', 'test_provider');

DO $$
BEGIN
    WHILE EXISTS (SELECT 1 FROM spock.sub_show_status() WHERE status != 'replicating')
	LOOP
	-- TODO: The multimaster testing buildfarm should have a general parameter
	-- like 'wait_change_timeout' that may be used to take control over infinite
	-- waiting cycles.
    END LOOP;
END;$$;

SELECT
  subscription_name, status, provider_node, replication_sets, forward_origins
FROM spock.sub_show_status();

\c :provider_dsn
DROP USER super2;
-- Creation of a slot needs some time. Just wait.
DO $$
BEGIN
    WHILE EXISTS (SELECT 1 FROM pg_replication_slots WHERE active = 'false')
	LOOP
    END LOOP;
END;$$;
SELECT plugin, slot_type, active FROM pg_replication_slots;
SELECT usename FROM pg_stat_replication WHERE application_name = 'test_subscription';
