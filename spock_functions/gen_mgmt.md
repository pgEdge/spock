## Management Functions

You can use the following settings to manage your replication clusters. 

| Command  | Description
|----------|-------------
| [spock.replicate_ddl](../../spock_ext/spock_functions/functions/spock_replicate_ddl) | Executes a DDL command on subscribers. |
| [spock.seq_sync](../../spock_ext/spock_functions/functions/spock_seq_sync) | Push a sequence state to all subscribers. |
| [spock.set_readonly](../../spock_ext/spock_functions/functions/spock_set_readonly.md) | Turn PostgreSQL read_only mode 'on' or 'off'. |


### spock.replicate_ddl

**`spock.replicate_ddl(command text, repsets text[])`**

Execute the `command` locally before then sending the specified command to the replication queue for execution on subscribers which are subscribed to one of the specified `repsets`.

Parameters:

- `command` is the DDL query to execute.
- `repsets` specifies an array of replication sets which this command should be sent to.  The default is `{ddl_sql}`.

### spock.seq_sync

**`spock.seq_sync(relation regclass)`**

Push a sequence state to all subscribers. Unlike the subscription and table synchronization function, this function should be run on the provider node. The command forces an update of the tracked sequence state which will be consumed by all subscribers (replication set filtering still applies) once they replicate the transaction in which this function has been executed.

Parameters:

- `relation` is the (optionally schema-qualified) name of an existing sequence.
