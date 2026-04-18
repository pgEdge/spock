# Using Spock with Snowflake Sequences

The [Snowflake extension](https://github.com/pgEdge/snowflake-sequences)
provides a sequence-based unique ID solution to replace the Postgres
built-in `bigserial` data type in distributed replication clusters.
Snowflake sequences minimize the risk of assigning an identical key
value on different nodes at the same time; this prevents potential data
conflicts.

!!! note

    Spock strongly recommends using Snowflake sequences instead of
    legacy Postgres sequences. Snowflake sequences alleviate concerns
    that network lag could disrupt sequences in distributed
    transactions.

Using a [`Snowflake` sequence](https://docs.pgedge.com/snowflake/v2-4/creating/)
allows you to take full advantage of the benefits offered by a
distributed, multi-master replication solution. Snowflake provides an
`int8` and sequence-based unique ID solution to optionally replace the
Postgres built-in `bigserial` data type.

## Comparing Sequence Types

The following example compares the level of detail stored with a
traditional Postgres sequence (`id` values `1` and `2`) versus the
level of detail available with a Snowflake sequence (`id` values
`135824181823537153` and `135824609030176769`):

```sql
acctg=# SELECT id, snowflake.format(id), customer, invoice FROM orders;
         id         |                          format                           |        customer        |  invoice
--------------------+-----------------------------------------------------------+------------------------+------------
                  1 | {"id": 1, "ts": "2022-12-31 19:00:00-05", "count": 0}     | Chesterfield Schools   | art_9338
                  2 | {"id": 2, "ts": "2022-12-31 19:00:00-05", "count": 0}     | Chesterfield Schools   | math_9663
 135824181823537153 | {"id": 1, "ts": "2024-01-10 14:16:48.438-05", "count": 0} | Prince William Schools | math_8330
 135824609030176769 | {"id": 1, "ts": "2024-01-10 14:18:30.292-05", "count": 0} | Fluvanna Schools       | art_9447
(9 rows)
```

## Snowflake Sequence Structure

Unlike Postgres sequences, a Snowflake sequence consists of a
timestamp, a counter, and a unique node identifier; the structure
ensures over 18 trillion unique sequence numbers. Snowflake sequences
provide the following capabilities:

- A Snowflake sequence lets you add or modify data in different regions
  while ensuring a unique transaction sequence.
- A Snowflake sequence preserves unique transaction identifiers without
  manual administrative management of a numbering scheme.
- A Snowflake sequence accurately identifies the order in which
  globally distributed transactions are performed.

Internally, Snowflake sequences are 64-bit integers represented
externally as `bigint` values. The 64 bits divide into the following
bit fields:

- Bit 63 is unused and represents the sign of `int8`.
- Bits 22–62 store the timestamp with millisecond precision.
- Bits 12–21 store the unique pgEdge Distributed Postgres node number.
- Bits 0–11 store the counter within one millisecond.

The timestamp is a 41-bit unsigned value representing millisecond
precision with an epoch of 2023-01-01. The counter is a 12-bit
unsigned value that increments per ID allocation; this provides 4096
unique IDs per millisecond, or 4 million IDs per second. The node
number is a 10-bit unique identifier for the Postgres instance inside
a global cluster; you set this value using the `snowflake.node` GUC
in the `postgresql.conf` file.
