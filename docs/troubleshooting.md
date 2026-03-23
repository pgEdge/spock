# Troubleshooting

If you encounter issues, review the following common problems and
solutions.

1. Replication not starting: Check `pg_hba.conf` entries and ensure nodes
   can connect to each other.

2. Subscription stuck in initializing: Verify that `max_replication_slots`
   and `max_wal_senders` are sufficient.

3. DDL not replicating: Confirm automatic DDL replication settings are
   enabled on both nodes.

4. Check logs: Review PostgreSQL logs for detailed error messages.
