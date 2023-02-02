-- ----------------------------------------------------------------------
-- Add a primary key to pgbench_history.
--
-- NOTE: The :branch below needs to be replaced with the node number.
--       This can be accomplished by running this SQL script via
--       pgbench ... -D branch=N -f spock-bench-alter.sql ...
-- ----------------------------------------------------------------------
DROP TABLE pgbench_history;

-- CREATE TABLE pgbench_history (hid bigserial, tid integer, bid integer, aid integer, delta integer, mtime timestamp, filler char(22), PRIMARY KEY (hid));

CREATE TABLE pgbench_history (hid bigserial, tid integer, bid integer, aid integer, delta integer, mtime timestamp, filler char(22), PRIMARY KEY (bid, hid)) PARTITION BY RANGE (bid);

CREATE TABLE pgbench_history_node1 PARTITION OF pgbench_history FOR VALUES FROM (1) TO (2);
CREATE TABLE pgbench_history_node2 PARTITION OF pgbench_history FOR VALUES FROM (2) TO (3);
CREATE TABLE pgbench_history_node3 PARTITION OF pgbench_history FOR VALUES FROM (3) TO (4);

ALTER SEQUENCE pgbench_history_hid_seq START :branch RESTART :branch INCREMENT 100;
