## NAME

spock.toast_divergence_clear()

### SYNOPSIS

spock.toast_divergence_clear (relation regclass, pkey jsonb)

### RETURNS

  - true if an entry was removed.

  - false if there was no entry for that row.

### DESCRIPTION

Removes one row's entry from `spock.toast_suspect`, for use after the row
has been repaired by other means, for example with ACE's table repair, or
after a `remote_missing` entry has been dealt with.

The key is the JSON object shown in the `pkey` column of
`spock.toast_divergence`: the replica identity key columns (normally the
primary key) by name, with values in their text form.

### ARGUMENTS

relation

    The table, as a regclass (for example `'public.orders'`).

pkey

    The row's key as JSON, exactly as shown in `spock.toast_divergence`.

### EXAMPLE

    postgres=# SELECT spock.toast_divergence_clear('public.orders', '{"id": "42"}');
     toast_divergence_clear
    ------------------------
     t
