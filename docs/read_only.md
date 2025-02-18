## Using Spock in Read Only Mode

Spock supports enabling a cluster to be operated in read-only mode.

The read-only status is managed using a GUC (Grand Unified Configuration) parameter 
named `spock.readonly`. This parameter can be set to enable or disable the read-only 
mode. The read-only mode restricts non-superusers to read-only operations, while 
superusers can still perform both read and write operations regardless of the setting.

The flag is at cluster level: either all databases are read-only or all databases
are read-write (the usual setting).

The read-only mode is implemented by filtering SQL statements:

- SELECT statements are allowed if they don't call functions that write.
- DML (INSERT, UPDATE, DELETE) and DDL statements including TRUNCATE are 
  forbidden entirely.
- DCL statements GRANT and REVOKE are also forbidden.

This means that the databases are in read-only mode at SQL level: however, the
checkpointer, background writer, walwriter, and the autovacuum launcher are still
running; this means that the database files are not read-only and that in some
cases the database may still write to disk.

### Cluster Read-Only Mode

The cluster read-only mode can now be controlled using the GUC parameter `spock.readonly`. 
This configuration parameter allows you to set the cluster to read-only mode. Note that only a
superuser can change this setting. When the cluster is set to read-only mode, non-superusers will
be restricted to read-only operations, while superusers will still be able to perform read and write
operations regardless of the setting.

### Setting Read-Only Mode

This value can be changed using the ALTER SYSTEM command.

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

Notes
 - Only superusers can set and unset the spock.readonly parameter.
 - When the cluster is in read-only mode, only non-superusers are restricted to read-only operations. Superusers can continue to perform both read and write operations.
 - By switching to using a GUC parameter, you can easily manage the cluster's read-only status through standard PostgreSQL configuration mechanisms.

