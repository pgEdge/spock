## Conflict-Free Delta-Apply Columns (Conflict Avoidance)

Conflicts can arise if a node is subscribed to multiple providers, or when local writes happen on a subscriber node.  Without Spock, logical replication can also encounter issues when resolving the value of a running sum (such as a YTD balance). 

Suppose that a running bank account sum contains a balance of `$1,000`.   Two transactions "conflict" because they overlap with each from two different multi-master nodes.   Transaction A is a `$1,000` withdrawal from the account.  Transaction B is also a `$1,000` withdrawal from the account.  The correct balance is `$-1,000`.  Our Delta-Apply algorithm fixes this problem and highly conflicting workloads with this scenario (like a tpc-c like benchmark) now run correctly at lightning speeds.

 In the past, Postgres users have relied on special data types and numbering schemes to help prevent conflicts. Unlike other solutions, Spock's powerful and simple conflict-free delta-apply columns instead manage data update conflicts with logic:

    - the old value is captured in WAL files. 
    - a new value comes in from a transaction.
    - before the new value overwrites the old value, a delta value is created from the above two steps; that delta is correctly applied.

To simplify: *local_value + (new_value - old_value)*

Note that on a conflicting transaction, the delta-apply column will be correctly calculated and applied.  

To make a column a conflict-free delta-apply column, ensuring that the value replicated is the delta of the committed changes (the old value plus or minus any new value) to a given record, you need to apply the following settings to the column:  `log_old_value=true, delta_apply_function=spock.delta_apply`.  For example:

```sql
ALTER TABLE pgbench_accounts ALTER COLUMN abalance SET (log_old_value=true, delta_apply_function=spock.delta_apply);
ALTER TABLE pgbench_branches ALTER COLUMN bbalance SET (log_old_value=true, delta_apply_function=spock.delta_apply);
ALTER TABLE pgbench_tellers ALTER COLUMN tbalance SET (log_old_value=true, delta_apply_function=spock.delta_apply);
```

As a special safety-valve feature, if you ever need to re-set a `log_old_value` column you can temporarily alter the column to `log_old_value` is `false`.

### Conflict Configuration Options

You can configure some Spock extension behaviors with configuration options that are set in the `postgresql.conf` file or via `ALTER SYSTEM SET`:

- `spock.conflict_resolution = last_update_wins`
  Sets the resolution method to `last_update_wins` for any detected conflicts between local data and incoming changes - the version of data with newest commit timestamp is kept. Note that the `track_commit_timestamp` PostgreSQL setting must also be `enabled`. 

- `spock.conflict_log_level`
  Sets the log level for reporting detected conflicts. The default is `LOG`. If the parameter is set to a value lower than `log_min_messages`, resolved conflicts are not written to the server log. This setting is used primarily to suppress logging of conflicts.  The [possible values](https://www.postgresql.org/docs/15/runtime-config-logging.html#RUNTIME-CONFIG-SEVERITY-LEVELS) are the same as for the `log_min_messages` PostgreSQL setting.

- `spock.batch_inserts`
  Tells Spock to use a batch insert mechanism if possible. The batch mechanism uses PostgreSQL internal batch insert mode (also used by the `COPY` command).  The default is `on`.


### Handling `INSERT-RowExists` or `INSERT/INSERT` Conflicts

If Spock encounters a conflict caused by a constraint violation (unique constraint, primary key, or replication identity) Spock can automatically transform an `INSERT` into an `UPDATE`, updating all columns of the existing row.

By default, when an `INSERT` statement targets a row that already exists, Spock detects the conflict and transforms the operation into an `UPDATE` statement, applying changes to all columns of the existing row. The event is recorded in the `spock.resolutions` table.

Extended constraint violation behavior is controlled by the `spock.check_all_uc_indexes` parameter. The default value is `off`; when set to `on`, Spock will:

* Scan all valid unique constraints (as well as the primary key and replica identity).
* Scan non-null unique constraints (including the primary key / replica identity index) in OID order. 
* Locate and resolve conflicting rows encountered during an `INSERT` statement.
 
If `spock.check_all_uc_indexes` is `enabled`, Spock will resolve only the first conflict identified, using Last-Write-Wins logic. If a second conflict occurs, an exception is recorded in the `spock.resolutions` table as either `Keep-Local` or `Apply-Remote`.

Note: This feature is experimental; enable this feature at your own risk.

### Handling `DELETE-RowMissing` Conflicts

Given that the purpose of the DELETE statement is to remove the row anyway, we do not log these as exceptions, since the desired outcome of removing the row has obviously been achieved, one way or the other. Instead `DELETE-RowMissing` conflicts are automatically written to the `spock.resolutions` table since the desired result has been achieved. 
