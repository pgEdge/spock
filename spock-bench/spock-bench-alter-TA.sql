-- ----------------------------------------------------------------------
-- Add two columns to the pgbench schema that require last_update_wins
-- for tables pgbench_tellers and pgbench_accounts.
-- ----------------------------------------------------------------------
ALTER TABLE pgbench_tellers ADD COLUMN trandom integer DEFAULT 0;
ALTER TABLE pgbench_tellers ADD COLUMN tlastts timestamp with time zone DEFAULT 'EPOCH';

ALTER TABLE pgbench_accounts ADD COLUMN arandom integer DEFAULT 0;
ALTER TABLE pgbench_accounts ADD COLUMN alastts timestamp with time zone DEFAULT 'EPOCH';

-- ----------------------------------------------------------------------
-- Configure all the balance columns for delta_resolve.
-- ----------------------------------------------------------------------
ALTER TABLE pgbench_accounts ALTER COLUMN abalance SET (LOG_OLD_VALUE=true);
ALTER TABLE pgbench_branches ALTER COLUMN bbalance SET (LOG_OLD_VALUE=true);
ALTER TABLE pgbench_tellers ALTER COLUMN tbalance SET (LOG_OLD_VALUE=true);
