# Using Spock with Snowflake Sequences

We strongly recommend that you use Snowflake Sequences instead of legacy Postgres sequences.

[Snowflake](https://github.com/pgEdge/snowflake-sequences) is an extension that provides an `int8` and sequence based unique ID solution to optionally replace the Postgres built-in `bigserial` data type. This extension allows Snowflake IDs that are unique within one sequence across multiple instances in a distributed cluster.

The Spock extension includes the following functions to help you manage Snowflake sequences:

* `spock.convert_sequence_to_snowflake`
* `spock.convert_column_to_int8`

You can find more information about using Snowflake sequences [here](https://docs.pgedge.com/platform/snowflake).



