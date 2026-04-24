# spock.sync_seq

The `spock.sync_seq()` function synchronizes the current state of a sequence
to all subscribers.

## Synopsis

```sql
spock.sync_seq(relation regclass) RETURNS boolean
```

## Description

Captures the current value of a sequence on the provider node and pushes it
into the replication stream so that subscribers can update their local copy to
match. This ensures sequence values remain coordinated across nodes.

This function must be executed on the provider node. The sequence state update
is embedded in the transaction where this function is called, and subscribers
apply the update when they replicate that transaction.

Replication set filtering applies — only subscribers whose subscriptions
include the replication set containing this sequence will receive the update.

## Arguments

The function accepts the following argument:

- `relation` - The name of the sequence to synchronize, optionally
  schema-qualified.

## Example

In the following example, the `spock.sync_seq()` function synchronizes a
sequence named `public.sales_order_no_seq`:

```sql
SELECT spock.sync_seq('public.sales_order_no_seq');
 sync_seq
----------
 t
(1 row)
```
