## NAME

`spock.wait_slot_confirm_lsn()`

### SYNOPSIS

`spock.wait_slot_confirm_lsn (slotname name, target pg_lsn)`

### DESCRIPTION

Waits until the specified replication slot has confirmed receipt of changes up to the target Log Sequence Number (LSN). If `slotname` is NULL, waits for all logical replication slots. The function will block until the target LSN is reached.

### EXAMPLE

`SELECT spock.wait_slot_confirm_lsn('spk_postgres_n1_sub_n2n1', '0/3000000');`

### ARGUMENTS
    slotname
        The name of the replication slot to monitor. If NULL, waits for all logical slots.
    target
        The target LSN to wait for. The function returns when the slot's confirmed flush LSN reaches or exceeds this value.
