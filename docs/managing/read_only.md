# Using Spock in Read-Only Mode

Spock supports operating a cluster in read-only mode. Read-only status is
managed using a GUC (Grand Unified Configuration) parameter named
`spock.readonly`.

This parameter can be used to enable or disable the read-only mode for one
or more nodes. Read-only mode restricts non-superusers to read-only
operations, while superusers can still perform both read and write
operations regardless of the setting.

Read-only mode is implemented by filtering SQL statements:

- `SELECT` statements are allowed if they do not call functions that write.
- DML (`INSERT`, `UPDATE`, `DELETE`) and DDL statements including
  `TRUNCATE` are forbidden entirely.
- DCL statements `GRANT` and `REVOKE` are also forbidden.

The databases are in read-only mode at SQL level only. However, the
checkpointer, background writer, WAL writer, and the autovacuum launcher
are still running. This means that the database files are not read-only
and that in some cases the database may still write to disk.

## Setting Read-Only Mode

You can control read-only mode with the `spock.readonly` parameter. Only a
superuser can modify this setting.

Your preferences for read-only mode are managed at cluster level. The
valid settings include:

- `all` - All databases are read-only for non-superusers and read-write
  for superusers.
- `user` - Each database is dependent on individual privileges to determine
  if a reader has write access.
- `off` - All databases are read-write to all users.

This value can be changed using the `ALTER SYSTEM` command.

In the following example, the `ALTER SYSTEM` command sets the cluster to
read-only mode for all non-superusers:

```sql
ALTER SYSTEM SET spock.readonly = 'all';
SELECT pg_reload_conf();
```

To set the cluster to read-only mode for a session, use the `SET` command.

In the following example, the `SET` command enables read-only mode for the
current session:

```sql
SET spock.readonly TO all;
```

To query the current status of the cluster, use the following SQL command.

In the following example, the `SHOW` command displays the current read-only
mode setting:

```sql
SHOW spock.readonly;
```

This command returns `on` if the cluster is in read-only mode and `off` if
the cluster is not.

!!! note

    - Only superusers can set and unset the `spock.readonly` parameter.
    - When a cluster is in read-only mode, only non-superusers are
      restricted to read-only operations. Superusers can continue to
      perform both read and write operations.
    - By using a GUC parameter, you can easily manage the cluster's
      read-only status through standard PostgreSQL configuration
      mechanisms.
