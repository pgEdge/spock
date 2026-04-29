# Using Spock in Read-Only Mode

Spock supports operating a node in read-only mode. Read-only status is managed using a GUC parameter named `spock.readonly`, which can be set to one of three values:

| Value   | Description |
|---------|-------------|
| `off`   | No restrictions. All users may write. This is the default. |
| `local` | Non-superuser local sessions are read-only. Replicated writes from apply workers are still permitted, so inbound replication continues normally. Superusers may still perform write operations. (The legacy alias `user` is accepted for backward compatibility.) |
| `all`   | Non-superuser local sessions and apply workers are blocked from writing. Superusers may still perform write operations. Use this mode when you need to stop both local application writes and inbound replication. |

The setting is at cluster level: either all databases are read-only or all
databases are read-write (the usual setting).

Read-only mode is enforced by setting PostgreSQL's `transaction_read_only` flag for affected sessions. This means that any statement that would modify data — including DML (`INSERT`, `UPDATE`, `DELETE`), DDL, `TRUNCATE`, and DCL (`GRANT`, `REVOKE`) — will be rejected by PostgreSQL's standard read-only transaction checks.

The databases are in read-only mode at the SQL level: however, the checkpointer,
background writer, walwriter, and the autovacuum launcher are still running. This
means that the database files are not read-only and that in some cases the
database may still write to disk.

## Setting Read-Only Mode

Only a superuser can modify the `spock.readonly` parameter. The value can be changed using the `ALTER SYSTEM` command:

```sql
-- Block non-superuser local writes; inbound replication continues
ALTER SYSTEM SET spock.readonly = 'local';
SELECT pg_reload_conf();

-- Block all non-superuser writes including replication
ALTER SYSTEM SET spock.readonly = 'all';
SELECT pg_reload_conf();

-- Restore normal operation
ALTER SYSTEM SET spock.readonly = 'off';
SELECT pg_reload_conf();
```

To set the mode for the current session only:

```sql
SET spock.readonly TO local;
```

To query the current status:

```sql
SHOW spock.readonly;
```

## Superuser writes and outbound replication

In both `local` and `all` modes, superusers are exempt from the read-only
restriction and may perform write operations. **The readonly setting has no
effect on the walsender (outbound replication).** Any writes made by a
superuser are captured in WAL and will be replicated outbound to other nodes
in the cluster, regardless of the readonly mode.

To perform repair operations that should **not** replicate to other nodes, use
[`spock.repair_mode()`](../spock_functions/index.md) to suppress outbound
replication of DML/DDL statements:

```sql
BEGIN;
SELECT spock.repair_mode(true);

-- Perform repair DML/DDL here...

SELECT spock.repair_mode(false);
COMMIT;
```

## Behavior of `all` mode

In `all` mode, apply workers detect the setting and stop consuming inbound WAL.
When the mode is switched back to `off` or `local`, replication resumes from
where it left off — no data is lost.

Notes:
 - Only superusers can set and unset the `spock.readonly` parameter.
 - By using a GUC parameter, you can easily manage the node's read-only status through standard PostgreSQL configuration mechanisms.

