## Using Spock in Read-Only Mode

Spock supports operating a cluster in read-only mode.  Read-only status is managed using a GUC (Grand Unified Configuration) parameter named `spock.readonly`. This parameter can be set to enable or disable the read-only mode. Read-only mode restricts non-superusers to read-only operations, while superusers can still perform both read and write operations regardless of the setting.

The flag is at cluster level: either all databases are read-only or all databases
are read-write (the usual setting).

Read-only mode is implemented by filtering SQL statements:

- `SELECT` statements are allowed if they don't call functions that write.
- DML (`INSERT`, `UPDATE`, `DELETE`) and DDL statements including `TRUNCATE` are 
  forbidden entirely.
- DCL statements `GRANT` and `REVOKE` are also forbidden.

This means that the databases are in read-only mode at SQL level: however, the
checkpointer, background writer, walwriter, and the autovacuum launcher are still
running. This means that the database files are not read-only and that in some
cases the database may still write to disk.

#### Setting Read-Only Mode

You can control read-only mode with the Spock parameter `spock.readonly`; only a superuser can modify this setting. When the cluster is set to read-only mode, non-superusers will be restricted to read-only operations, while superusers will still be able to perform read and write operations regardless of the setting.

This value can be changed using the `ALTER SYSTEM` command.

```sql
ALTER SYSTEM SET spock.readonly = 'on';
SELECT pg_reload_conf();
```

To set the cluster to read-only mode for a session, use the `SET` command. Here are the steps:

```sql
SET spock.readonly TO on;
```

To query the current status of the cluster, you can use the following SQL command:
  
```sql
SHOW spock.readonly;
```

This command will return on if the cluster is in read-only mode and off if it is not.

Notes:
 - Only superusers can set and unset the `spock.readonly` parameter.
 - When the cluster is in read-only mode, only non-superusers are restricted to read-only operations. Superusers can continue to perform both read and write operations.
 - By using a GUC parameter, you can easily manage the cluster's read-only status through standard PostgreSQL configuration mechanisms.

