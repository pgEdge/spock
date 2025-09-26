# Automatic DDL Replication

The spock extension can automatically replicate DDL statements. To enable automatic DDL replication, set the following parameters to `on`:

* `spock.enable_ddl_replication` enables replication of ddl statements through the default replication set. Some DDL statements are intentionally not replicated (like `CREATE DATABASE`).  Other DDL statements are replicated, but can cause lead to replication issues (like the `CREATE TABLE... AS...` statement).  In the case of `CREATE TABLE... AS...`, the DDL statement is replicated before the table is added to the replication set, leading to potential data irregularities.  Some DDL statements are replicated, but might potentially create an issue in a 3+ node cluster (ie. `DROP TABLE`).

* `spock.include_ddl_repset` enables spock to automatically add tables to replication sets at the time they are created on each node. Tables with Primary Keys will be added to the `default` replication set, and tables without Primary Keys will be added to the `default_insert_only` replication set. Altering a table to add or remove a Primary Key will also modify which replication set the table is a member of. Setting a table to `unlogged` removes the table from replication. Detaching a partition will not remove a table from replication.

* `spock.allow_ddl_from_functions` enables spock to automatically replicate DDL statements that are called within functions. You can turned this `off` if the functions are expected to run on every node. When  set to `off`, statements replicated from functions adhere to the same rule previously described for `include_ddl_repset`. If a table possesses a primary key, it will be added into the `default` replication set; alternatively, they will be added to the `default_insert_only` replication set.

It's best to set these parameters to `on` only when the database schema matches exactly on all nodes - either when all databases have no objects, or when all databases have exactly the same objects and all tables are added to replication sets.

!!! info

    You can also use the `spock.replicate_ddl()` function to instruct Spock to enable automatic DDL replication.  Starting automatic DDL replication with this function instructs Spock to check the statement type of each transaction, and execute and replicate statements identified as DDL.

During the auto replication process, spock generates messages that provide information about the execution. Here are the descriptions for each message:

- `DDL statement replicated.`

  This message is a INFO level message. It is displayed whenever a DDL statement is successfully replicated. To include these messages in the server log files, the configuration must have `log_min_messages=INFO` set.

- `DDL statement replicated, but could be unsafe.`

  This message serves as a warning. It is generated when certain DDL statements, though successfully replicated, are deemed potentially unsafe. For example, statements like `CREATE TABLE... AS...` will trigger this warning.

- `This DDL statement will not be replicated.`

  This warning message is generated when auto replication is active, but the specific DDL is either unsupported or intentionally excluded from replication.

- `table 'test' was added to default replication set.`

  This is a LOG message providing information about the replication set used for a given table when `spock.include_ddl_repset` is set.

