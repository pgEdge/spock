## NAME

spock.cleanup_resolutions()

### SYNOPSIS

spock.cleanup_resolutions()

### RETURNS

bigint — the number of rows deleted from `spock.resolutions`.

### DESCRIPTION

Deletes rows from `spock.resolutions` whose `log_time` is older than the
value configured by `spock.resolutions_retention_days`. Returns the number
of rows deleted.

This function is a superuser-only manual trigger for the same cleanup that
the apply worker runs automatically once per day. It is useful for
immediate cleanup via `pg_cron` or when the apply worker has not been
running.

The function respects both `spock.save_resolutions` and
`spock.resolutions_retention_days`. If either setting disables cleanup
(`save_resolutions = off` or `resolutions_retention_days = 0`), the
function returns `0` without deleting anything.

### ARGUMENTS

None.

### EXAMPLE

Delete conflict history rows older than the configured retention window:

    SELECT spock.cleanup_resolutions();

### SEE ALSO

`spock.save_resolutions`, `spock.resolutions_retention_days`
