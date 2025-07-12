## Creating a Subscriber Node with pg_basebackup

Spock supports creating a subscriber node by cloning the provider with [`pg_basebackup`](https://www.postgresql.org/docs/current/app-pgbasebackup.html) and starting it as a Spock subscriber. Use the `spock_create_subscriber` utility (located in the `bin` directory of your pgEdge platform installation) to register the node.

#### Synopsis:

  `spock_create_subscriber [OPTION]...`

**Options**

Specify the following options as needed.

| Option   | Description
|----------|-------------
| `-D`, `--pgdata=DIRECTORY` | The `data` directory to be used for new node. This can be either an empty/non-existing directory, or a directory populated using the `pg_basebackup -X stream` command.
| `--databases`              |  An optional list of databases to replicate.
| `-n`, `--subscriber-name=NAME` | The name of the newly created subscriber.
| `--subscriber-dsn=CONNSTR` | A connection string to the newly created subscriber.
| `--provider-dsn=CONNSTR` | A connection string to the provider.
| `--replication-sets=SETS` | A comma separated list of replication set names.
| `--apply-delay=DELAY` | The apply delay in seconds (by default 0).
| `--drop-slot-if-exists` | Drop replication slot of conflicting name.
| `-s`, `--stop` | Stop the server once the initialization is done.
| `-v` | Increase logging verbosity.
| `--extra-basebackup-args` | Additional arguments to pass to `pg_basebackup`. Safe options are: `-T`, `-c`, `--xlogdir`/`--waldir`

**Configuration files overrides**

You can use the following options to override the location of the configuration files.

| Option   | Description
|----------|-------------
|`--hba-conf` | path to the new pg_hba.conf
| `--postgresql-conf` | path to the new postgresql.conf
| `--recovery-conf` | path to the template recovery configuration

Unlike `spock.sub_create`'s other data sync options, this method of cloning ignores replication sets and copies all tables on all databases. However, it's often much faster, especially over high-bandwidth links.
