## NAME

`spock.node_create()`

### SYNOPSIS

`spock.node_create (node_name name, dsn text, location text, country text, info jsonb)`

### DESCRIPTION

Create a spock node.
    Initialize internal state of the spock extension that will be used further in communications with other replication participants to identify the node and connection settings.
	It doesn't check correctness or reachability of the dsn at the moment.
	Parameters 'location', 'country', and 'info' are optional and is intended for simplifying automatisation infrastructure.

### EXAMPLE

`spock.node_create ('n1', 'host=10.1.2.5 user=rocky dbname=demo')`

### ARGUMENTS
    node_name
        The name of the node. Only one node is allowed per database, and each node in a cluster must have a unique name. Example: n1
    dsn
        The connection string to the node. The user in this string should equal the OS user. This connection string should be reachable from outside and match the one used later in the sub-create command. Example: host=10.1.2.5 port= 5432 user=rocky dbname=demo
	location
		(optional) Text string identifying the node location as precise as needed. Doesn't affect any internal logic.
    country
        (optional) Text string dedicated to conveniently store and expose the country code where the spock node is located. Doesn't affect any internal logic.
	info
		(optional) JSONB field where arbitrary meta information may be stored in structured form. The only optional field that affects the spock behaviour is the 'tiebreaker' integer value that serves as a priority value (less value - more priority) that is used in conflict resolution cases in case commit timestamp is the same for all the concurrent transactions updating the same row.
