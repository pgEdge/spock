# spock.cleanup_resolutions

The `spock.cleanup_resolutions()` function manually deletes old rows from the
`spock.resolutions` table.

## Synopsis

```sql
spock.cleanup_resolutions(days integer DEFAULT NULL) RETURNS bigint
```

## Description

Deletes rows from `spock.resolutions` whose `log_time` is older than the
retention window. Returns the number of rows deleted.

This function is a superuser-only manual trigger for the same cleanup that
the apply worker runs automatically once per day. It is useful for
immediate cleanup via `pg_cron` or when the apply worker has not been
running.

When `days` is provided it takes precedence over
`spock.resolutions_retention_days`, including when the GUC is set to `0`
(automatic cleanup disabled). If `days` is omitted, the GUC value is used;
if the GUC is also `0`, the function returns `0` without deleting anything.

## Arguments

The function accepts the following argument:

- `days` - Retention window in days. Overrides `spock.resolutions_retention_days`
  for this call. Pass an explicit value to perform a one-off cleanup when
  automatic cleanup is disabled (`resolutions_retention_days = 0`). Default
  is `NULL` (use the GUC value).

## Example

Delete rows older than the configured retention window:

```sql
SELECT spock.cleanup_resolutions();
```

Delete rows older than 60 days, regardless of the GUC setting:

```sql
SELECT spock.cleanup_resolutions(60);
```

## See Also

`spock.resolutions_retention_days`
