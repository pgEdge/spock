-- ----------------------------------------------------------------------
-- Add a primary key to pgbench_history.
--
-- NOTE: The :branch below needs to be replaced with the node number.
--       This can be accomplished by running this SQL script via
--       pgbench ... -D branch=N -f spock-bench-alter.sql ...
-- ----------------------------------------------------------------------
ALTER TABLE pgbench_history ADD COLUMN hid bigserial;
ALTER TABLE pgbench_history ADD PRIMARY KEY (hid);
ALTER SEQUENCE pgbench_history_hid_seq START :branch RESTART :branch INCREMENT 100;
