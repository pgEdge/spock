## NAME

spock.spock_max_proto_version()

### SYNOPSIS

spock.spock_max_proto_version()

### RETURNS

The maximum spock protocol version supported by the installed Spock extension
as an integer.  The protocol version determines compatibility between Spock
versions.

### DESCRIPTION

Returns the maximum protocol version supported by the Spock extension.

This function queries the Spock extension and returns the highest protocol
version number it can use for replication communication. The protocol
version determines the features and capabilities available for replication
between nodes.

When establishing replication connections between nodes running different
Spock versions, the nodes negotiate to use the lower of the two maximum
protocol versions. This ensures compatibility between nodes running
different Spock releases.

The protocol version is returned as an integer value. Higher numbers
indicate newer protocol versions with additional features.

This is a read-only query function that does not modify data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

postgres=# SELECT spock.spock_max_proto_version();
 spock_max_proto_version
-------------------------
                       4
(1 row)

