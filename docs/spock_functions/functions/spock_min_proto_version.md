## NAME

spock.spock_min_proto_version()

### SYNOPSIS

spock.spock_min_proto_version ()

### RETURNS

The minimum protocol version supported by the installed Spock extension as
an integer.

### DESCRIPTION

Returns the minimum protocol version supported by the Spock extension.

This function queries the Spock extension and returns the lowest protocol
version number it can use for replication communication. The protocol
version determines the features and capabilities available for replication
between nodes.

When establishing replication connections between nodes running different
Spock versions, the nodes negotiate to use a protocol version that falls
within the supported range of both nodes. The minimum protocol version
defines the lower bound of compatibility - nodes supporting only protocol
versions below this minimum cannot replicate with this Spock installation.

The protocol version is returned as an integer value. This minimum version
ensures backward compatibility with older Spock releases while still
allowing the use of newer protocol features when both nodes support them.

This is a read-only query function that does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

SELECT spock.spock_min_proto_version();
