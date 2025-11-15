CREATE OR REPLACE FUNCTION wait_subscription(
  remote_node_name Name,
  report_it        Boolean DEFAULT false,
  timeout          Interval DEFAULT '0 second',
  delay            Real DEFAULT 1.
) RETURNS bigint AS $$
DECLARE
  state              Record;
  lag                Bigint := 1;
  end_time           Timestamp := 'infinity';
  time_remained      Interval;
  local_node_name    Name;
  wal_sender_timeout Bigint;
  prev_received_lsn  pg_lsn := '0/0'::pg_lsn;
BEGIN
  -- spock.local_node.node_id->spock.node(node_id -> node_name)
  SELECT node_name FROM spock.node
  WHERE node_id = (SELECT node_id FROM spock.local_node)
  INTO local_node_name;

  SELECT EXTRACT(epoch
    FROM (
      SELECT (current_setting('wal_sender_timeout')::Interval))
    )::real * 1024
  INTO wal_sender_timeout;

  -- Calculate the End Time, if requested.
  IF timeout > '0 second' THEN
    SELECT now() + timeout INTO end_time;
  END IF;
  -- SELECT EXTRACT(epoch FROM my_interval)/3600
  WHILE lag > 0 LOOP

    SELECT end_time - clock_timestamp() INTO time_remained;
    IF time_remained < '0 second' THEN
      RETURN state.lag;
    END IF;

    -- NOTE: Remember, an apply group may contain more than a single worker.
    SELECT
      MAX(remote_insert_lsn) AS remote_write_lsn,
      MAX(received_lsn) AS received_lsn
    FROM spock.lag_tracker
    WHERE origin_name = remote_node_name AND receiver_name = local_node_name
    INTO state;

    -- Special case: nothing arrived yet
    IF (state.received_lsn = '0/0'::pg_lsn) THEN
      IF report_it = true THEN
        raise NOTICE 'Replication % -> %: waiting WAL ... . Time remained: % (HH24:MI:SS)',
          remote_node_name, local_node_name,
          to_char(time_remained, 'HH24:MI:SS');
      END IF;
      PERFORM pg_sleep(delay);
      CONTINUE;
    END IF;

    -- Special case: No transactions has been executed on the remote yet.
    IF (state.remote_write_lsn = '0/0'::pg_lsn) THEN
      IF report_it = true THEN
        raise NOTICE 'Replication % -> %: waiting anything substantial ... Received LSN: %. Time remained: % (HH24:MI:SS)',
          remote_node_name, local_node_name, state.received_lsn,
          to_char(time_remained, 'HH24:MI:SS');
        PERFORM pg_sleep(delay);
        CONTINUE;
      END IF;

      -- Check any progress
      IF (state.received_lsn = prev_received_lsn) THEN
        raise EXCEPTION 'Replication % -> %: publisher seems get stuck into something',
        remote_node_name, local_node_name;
      END IF;

      -- We have a progress, wait further.
      prev_received_lsn = state.received_lsn;
      -- To be sure we get a 'keepalive' message
      PERFORM pg_sleep(wal_sender_timeout * 2);

      PERFORM pg_sleep(delay);
      CONTINUE;
    END IF;

    SELECT MAX(remote_insert_lsn - received_lsn) FROM spock.lag_tracker
    WHERE origin_name = remote_node_name AND receiver_name = local_node_name
    INTO lag;

    IF report_it = true THEN
      raise NOTICE 'Replication % -> %: current lag % MB, Time remained: % (HH24:MI:SS)',
        remote_node_name, local_node_name, lag/1024/1024,
        to_char(time_remained, 'HH24:MI:SS');
    END IF;

    PERFORM pg_sleep(delay);
  END LOOP;

  RETURN lag;
END
$$ LANGUAGE plpgsql VOLATILE;
