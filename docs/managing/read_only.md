# Using Spock in Read-Only Mode

Spock supports operating a cluster in read-only mode for non-superuser roles.
Read-only status is managed using a GUC parameter named `spock.readonly`.
Superusers can change this parameter at runtime without restarting the server.

This parameter can be used to enable or disable the read-only mode for a
cluster. Read-only mode restricts non-superusers to read-only
operations, while superusers can still perform both read and write
operations regardless of the setting.

Read-only mode is enforced by setting PostgreSQL's `XactReadOnly` flag for
each transaction, which prevents writes at the storage and transaction level.
The practical effect is:

- `SELECT` statements are allowed if they do not call functions that write.
- DML (`INSERT`, `UPDATE`, `DELETE`) and DDL statements including
  `TRUNCATE` are blocked.
- DCL statements `GRANT` and `REVOKE` are also blocked.

!!! note

    Databases are in read-only mode for SQL queries only. The Postgres
    core does not know about read-only mode, so some functions (like the 
    `SELECT lo_open()` call to C functions), as well as the checkpointer, 
    background writer, WAL writer, and the autovacuum launcher are still
    running. This means that not all files are read-only and that in
    some cases Postgres may still write to disk.

## Setting Read-Only Mode

The `spock.readonly` parameter supports three configuration methods:

- **Session-level** — takes effect immediately for the current session
  (superuser only):

  ```sql
  SET spock.readonly = 'all';
  ```

- **System-wide persistent** — takes effect after reloading the configuration:

  ```sql
  ALTER SYSTEM SET spock.readonly = 'all';
  SELECT pg_reload_conf();
  ```

- **Configuration file** — set in `postgresql.conf`, then reload:

  ```ini
  spock.readonly = all
  ```

  ```sql
  SELECT pg_reload_conf();
  ```

The valid settings are:

- `off` - No restrictions; all users may write.
- `local` - Non-superuser local sessions are read-only; replicated writes from
  apply workers are still permitted. (`user` is a backward-compatible alias for
  this value.)
- `all` - The node is fully read-only: both local sessions and apply workers are
  blocked from writing.

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

