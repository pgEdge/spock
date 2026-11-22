## NAME

spock.toast_pointer()

### SYNOPSIS

spock.toast_pointer (value "any")

### RETURNS

  - The on-disk TOAST pointer of a value stored out of line, as
    `toastrelid/valueid/rawsize/extsize`.

  - NULL for any other value: one stored inline, compressed in the row, or
    of a type that is never toasted.

### DESCRIPTION

Shows the TOAST pointer that `spock.toast_suspect` records in `toast_ptrs`
for each suspect column. The TOAST divergence repair worker compares the
recorded pointer with the current one to tell whether the column was
written locally since the row was flagged.

The pointer stays the same when an UPDATE leaves the column alone or sets
it to itself, and through `VACUUM FULL` and `CLUSTER`. Any write of new
contents, even the same text, gives the value a new pointer, and so does a
table rewrite by `ALTER TABLE`.

Pass a column of a table, not an expression: only a value read from the
table carries its pointer.

### ARGUMENTS

value

    A table column.

### EXAMPLE

    postgres=# SELECT id, spock.toast_pointer(big) FROM public.orders WHERE id = 42;
     id |      toast_pointer
    ----+--------------------------
     42 | 16391/16402/200004/200000
