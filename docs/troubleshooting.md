# Troubleshooting Spock

This document provides solutions to common issues encountered when using
Spock for PostgreSQL logical replication.

## Common Replication Issues

This section describes common problems that prevent replication from
working correctly and provides solutions for each issue.

### Replication Not Starting

If replication fails to start, check the following items:

- Verify `pg_hba.conf` entries allow secure connections between nodes.
- Test network connectivity between nodes with the following command:

  ```bash
  psql -h <remote_node_ip> -U postgres -d <database_name>
  ```

- You can check the PostgreSQL logs for detailed error messages with this
  command:

  ```bash
  tail -f /var/lib/pgsql/18/data/log/postgresql-*.log
  ```

- You can verify that the Spock extension is created on both nodes with this
  query:

  ```sql
  SELECT extname, extversion FROM pg_extension WHERE extname = 'spock';
  ```

### Subscription Stuck in Initializing State

If a subscription remains in the initializing state, verify the following
configuration parameters.

- Check that `max_replication_slots` is set to a sufficient value:

  ```sql
  SHOW max_replication_slots;
  ```

  The minimum value is one per node on the provider.

- Verify that `max_wal_senders` is set to a sufficient value:

  ```sql
  SHOW max_wal_senders;
  ```

  The minimum value is one per node on the provider.

- For PostgreSQL 18+, check the `max_active_replication_origins` setting:

  ```sql
  SHOW max_active_replication_origins;
  ```

  Ensure that the value to at least the number of subscriptions plus headroom.

- If parameters were modified, restart PostgreSQL with this command:

  ```bash
  sudo systemctl restart postgresql-18
  ```

- Check the subscription status with this query:

  ```sql
  SELECT * FROM spock.sub_show_status();
  ```

### DDL Not Replicating

If DDL statements are not replicating across nodes, check the following
settings.

- Verify that automatic DDL replication is enabled with this query:

  ```sql
  SHOW spock.enable_ddl_replication;
  ```

  The value should be `on`.

- Check that the `include_ddl_repset` parameter is enabled:

  ```sql
  SHOW spock.include_ddl_repset;
  ```

- Ensure that schema structures match on both nodes before enabling auto-DDL.
- To confirm that DDL is replicated from functions, verify this setting is
  enabled:

  ```sql
  SHOW spock.allow_ddl_from_functions;
  ```

!!! warning

    Some DDL statements are intentionally not replicated, such as `CREATE
    DATABASE`. The `CREATE TABLE...AS...` statement generates a warning:
    "DDL statement replicated, but could be unsafe."

### UPDATE or DELETE Operations Fail

If `UPDATE` or `DELETE` operations fail with *unable to find tuple* errors,
the table may be missing a primary key or replica identity.

To resolve this issue, choose one of the following solutions:

- Add a primary key to the table with the following command:

  ```sql
  ALTER TABLE table_name ADD PRIMARY KEY (column_name);
  ```

- Alternatively, set a replica identity using a unique index:

  ```sql
  ALTER TABLE table_name REPLICA IDENTITY USING INDEX index_name;
  ```

The unique index must be non-partial, non-deferrable, and use `NOT NULL`
columns.

!!! note

    `REPLICA IDENTITY FULL` is only supported with Delta-Apply columns on
    primary key tables.

### Unique Constraint Conflicts

If you encounter unique constraint violations during replication, ensure
only one `UNIQUE` index or constraint exists on downstream tables.

The error message for deferrable index constraints appears as follows:

```
ERROR: spock doesn't support index rechecks needed for deferrable indexes
DETAIL: relation "public"."test_relation" has deferrable indexes: "index1"
```

To resolve this issue, convert deferrable constraints to non-deferrable:

```sql
ALTER TABLE table_name DROP CONSTRAINT constraint_name;
ALTER TABLE table_name ADD CONSTRAINT constraint_name UNIQUE (column_name);
```

### Delta-Apply Column Errors

If you receive a *delta apply column can't operate NULL values* error,
ensure all Delta-Apply columns have NOT NULL constraints.

```sql
ALTER TABLE table_name ALTER COLUMN column_name SET NOT NULL;
```

Then configure the Delta-Apply column with the following command:

```sql
ALTER TABLE table_name ALTER COLUMN column_name
  SET (log_old_value=true, delta_apply_function=spock.delta_apply);
```

## Configuration Issues

This section covers problems related to PostgreSQL and Spock configuration
parameters that can cause replication issues.

### Missing Required Parameters

The following parameters are required in `postgresql.conf` for Spock to
function properly:

```sql
wal_level = logical
max_worker_processes = 10
max_replication_slots = 10
max_wal_senders = 10
shared_preload_libraries = 'spock'
track_commit_timestamp = on
```

After modifying `postgresql.conf`, restart PostgreSQL with this command:

```bash
sudo systemctl restart postgresql-18
```

### Conflict Resolution Issues

If conflicts are causing replication to stop, check the conflict
resolution setting with this query:

```sql
SHOW spock.conflict_resolution;
```

The following values are available:

- `error` - Stop replication on conflict (requires manual resolution).
- `apply_remote` - Always apply the remote change.
- `keep_local` - Keep the local version.
- `last_update_wins` - Keep the version with the newest commit timestamp.

To change the setting, use the following command:

```sql
ALTER SYSTEM SET spock.conflict_resolution = 'last_update_wins';
SELECT pg_reload_conf();
```

!!! note

    The `last_update_wins` setting requires `track_commit_timestamp = on`.

### Exception Handling Behavior

If replication is stopping due to errors, check the exception behavior
setting with this query:

```sql
SHOW spock.exception_behaviour;
```

The following values are available:

- `transdiscard` - Discard the entire transaction on ERROR.
- `discard` - Continue processing without the ERROR statement.
- `sub_disable` - Disable the subscription and queue transactions.

To change the setting, use the following command:

```sql
ALTER SYSTEM SET spock.exception_behaviour = 'discard';
SELECT pg_reload_conf();
```

You can check the exception log table for details with this query:

```sql
SELECT * FROM spock.exception_log ORDER BY timestamp DESC LIMIT 10;
```

## Performance Issues

This section addresses performance-related problems that can affect
replication speed and efficiency.

### High Replication Lag

If replication lag is increasing, check the lag status with this query:

```sql
SELECT * FROM spock.lag_tracker;
```

The query displays `replication_lag_bytes` and `replication_lag` for each
subscription.

Possible causes and solutions include:

- Insufficient `max_worker_processes` - increase the value.
- Network bandwidth limitations - check network throughput.
- Large transactions - break into smaller transactions if possible.
- Slow subscriber hardware - upgrade hardware or reduce workload.

### Batch Insert Mode Not Activating

Batch insert mode requires specific conditions to activate automatically.

Check the following requirements:

- Verify batch inserts are enabled with this query:

  ```sql
  SHOW spock.batch_inserts;
  ```

- Check that conflict resolution is set to error:

  ```sql
  SHOW spock.conflict_resolution;
  ```

- Ensure tables have no INSTEAD OF INSERT or BEFORE INSERT triggers.
- Batch mode activates after 5+ inserts in a single transaction.

### Feedback Frequency Issues

If you experience feedback overhead during bulk operations, adjust the
feedback frequency with the following command:

```sql
ALTER SYSTEM SET spock.feedback_frequency = 500;
SELECT pg_reload_conf();
```

The default value is 200. Higher values reduce overhead during bulk
catch-up; lower values provide more frequent feedback.

## Node Failure and Recovery

This section explains how to recover from node failures and restore
replication after a node becomes unavailable.

### Catastrophic Node Failure

If a node fails catastrophically, use ACE (Active Consistency Engine) to
recover missing data.

The recovery workflow involves five phases:

1. Assess damage by checking subscription status on surviving nodes.

2. Clean up Spock metadata by dropping subscriptions to the failed node:

   ```sql
   SELECT spock.sub_drop(subscription_name := 'sub_to_failed_node');
   SELECT spock.node_drop(node_name := 'failed_node');
   ```

3. Identify missing data using ACE table-diff with these flags:

   ```bash
   ./ace table-diff --nodes n2,n3,n4 --preserve-origin n1 \
     --until 2026-02-11T14:30:00Z --output json cluster public.table_name
   ```

4. Repair affected tables using ACE table-repair:

   ```bash
   ./ace table-repair --diff-file=diff_file.json \
     --nodes n2,n3,n4 --recovery-mode --source-of-truth n3 \
     --preserve-origin cluster public.table_name
   ```

5. Validate by re-running table-diff without flags to confirm tables match.

!!! warning

    Always use the `--preserve-origin` flag during recovery to maintain
    replication metadata. Without this flag, repaired rows get wrong
    origin IDs and timestamps, causing conflicts.

### Subscription Down Status

If a subscription shows `down` status, check the following items:

- Verify the provider node is running and accessible.
- Check replication slots on the provider with this query:

  ```sql
  SELECT slot_name, active FROM pg_replication_slots;
  ```

- Review PostgreSQL logs on both provider and subscriber nodes.
- Restart the subscription with these commands:

  ```sql
  SELECT spock.sub_disable(subscription_name := 'sub_name');
  SELECT spock.sub_enable(subscription_name := 'sub_name');
  ```

## Upgrade Issues

This section provides guidance on verifying and troubleshooting Spock
installations after upgrading to a new version.

### Post-Upgrade Verification

After upgrading Spock, verify the installation with the following checks.

1. Check the extension version with this query:

   ```sql
   SELECT extname, extversion FROM pg_extension WHERE extname = 'spock';
   ```

2. Verify subscription status with this query:

   ```sql
   SELECT sub_name, sub_enabled FROM spock.subscription;
   ```

3. Check replication slots with this query:

   ```sql
   SELECT slot_name, active FROM pg_replication_slots;
   ```

4. Monitor replication lag with this query:

   ```sql
   SELECT application_name, state, write_lag FROM pg_stat_replication;
   ```

### DDL Replication After Upgrade

If DDL replication was disabled for the upgrade, re-enable it on all
nodes with the following commands:

```sql
SELECT spock.replicate_ddl('SET spock.enable_ddl_replication = on');
SELECT pg_reload_conf();
```

## Special Feature Issues

This section covers troubleshooting for advanced Spock features including
row filters, column filters, and partitioned tables.

### Row Filter Errors

If row filters are causing replication to stop, check for volatile
functions in the filter expression.

Volatile functions (like `random()` or `now()`) can produce different
results on evaluation and cause errors.

Replace volatile functions with stable or immutable alternatives, or
remove them from the filter.

### Column Filter Issues

If columns are missing after filtering, note the following behaviors:

- System columns (`oid`, `xmin`) cannot be filtered.
- Dropping a filtered column automatically removes it from the filter.
- New columns are not automatically included in existing filters.

Update the filter to include new columns with this command:

```sql
SELECT spock.repset_alter_table(
    set_name := 'default',
    relation := 'public.table_name',
    columns := ARRAY['col1', 'col2', 'new_col']
);
```

### Partitioned Table Replication

If new partitions are not replicating, add them manually with the
following command:

```sql
SELECT spock.repset_add_partition(
    set_name := 'default',
    relation := 'public.parent_table',
    partition_name := 'public.new_partition'
);
```

The parent table is synced during initial sync, but new partitions
created after sync must be added explicitly.


## Checking Logs

PostgreSQL logs provide detailed information about replication errors and
issues.

Locate log files with this query:

```sql
SHOW log_directory;
SHOW log_filename;
```

On RHEL/Rocky Linux, logs are typically located at:

```
/var/lib/pgsql/18/data/log/
```

Monitor logs in real-time with this command:

```bash
tail -f /var/lib/pgsql/18/data/log/postgresql-*.log
```

Filter for Spock-related messages with this command:

```bash
grep -i spock /var/lib/pgsql/18/data/log/postgresql-*.log
```

## Getting Help

If you cannot resolve your issue using this troubleshooting guide, gather
the following information before requesting support:

- Spock version from `SELECT extversion FROM pg_extension WHERE extname = 'spock';`
- PostgreSQL version from `SELECT version();`
- Operating system and version
- Configuration settings from `postgresql.conf`
- Relevant error messages from PostgreSQL logs
- Subscription status from `SELECT * FROM spock.sub_show_status();`
- Node status from `SELECT * FROM spock.node;`
- Replication lag from `SELECT * FROM spock.lag_tracker;`

For more information, see the following resources:

- The [Spock Functions Reference](spock_functions/index.md) document
  provides detailed function documentation.
- The [Configuring Spock](configuring.md) document describes configuration
  parameters and settings.
- The [Limitations and Restrictions](limitations.md) document explains
  known limitations and constraints that may affect your replication setup.
- The [FAQ](FAQ.md) document answers frequently asked questions.
