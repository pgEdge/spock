# Using Spock with Snowflake Sequences

We strongly recommend that you use Snowflake Sequences instead of legacy Postgres sequences.

[Snowflake](https://github.com/pgEdge/snowflake-sequences) is an extension that provides an `int8` and sequence based unique ID solution to optionally replace the Postgres built-in `bigserial` data type. This extension allows Snowflake IDs that are unique within one sequence across multiple instances in a distributed cluster.
