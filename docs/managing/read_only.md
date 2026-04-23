# Using Spock in Read-Only Mode

Spock supports operating a cluster in read-only mode for non-superuser roles.
Read-only status is managed using a `postgresql.conf` parameter named
`spock.readonly`.

This parameter can be used to enable or disable the read-only mode for a
cluster. Read-only mode restricts non-superusers to read-only
operations, while superusers can still perform both read and write
operations regardless of the setting.

Read-only mode is implemented by filtering SQL statements:

- `SELECT` statements are allowed if they do not call functions that write.
- DML (`INSERT`, `UPDATE`, `DELETE`) and DDL statements including
  `TRUNCATE` are forbidden entirely.
- DCL statements `GRANT` and `REVOKE` are also forbidden.

!!! note

    Databases are in read-only mode for SQL queries only. The Postgres
    core does not know about read-only mode, so some functions (like the 
    `SELECT lo_open()` call to C functions), as well as the checkpointer, 
    background writer, WAL writer, and the autovacuum launcher are still
    running. This means that not all files are read-only and that in
    some cases Postgres may still write to disk.

## Setting Read-Only Mode

You can control read-only mode by setting the `spock.readonly` parameter in
the `postgresql.conf` file. This allows you to easily manage the cluster's
read-only status through standard PostgreSQL configuration mechanisms.

The valid settings are:

- `all` - All databases are read-only for non-superusers and read-write
  for superusers.
- `local` - Each database is dependent on individual privileges to determine
  if a reader has write access. (`user` is a deprecated alias for this value.)
- `off` - All databases are read-write to all users.

After modifying this setting, you must restart the server to apply the change.

To query the current status of the cluster, use the SQL `SHOW` command. In the
following example, the `SHOW` command displays the current read-only mode
setting:

```sql
postgres=# SHOW spock.readonly;
-[ RECORD 1 ]--+----
spock.readonly | on
```

This command returns `on` if the cluster is in read-only mode and `off` if
the cluster is not.

