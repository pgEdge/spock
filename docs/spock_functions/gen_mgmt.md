# Management Functions

You can use the following settings to manage your replication clusters.

| Command  | Description
|----------|-------------
| [spock.get_country](functions/spock_get_country.md) | Returns the country code configured for the node. |
| [spock.max_proto_version](functions/spock_max_proto_version.md) | Returns the maximum protocol version supported by Spock. |
| [spock.min_proto_version](functions/spock_min_proto_version.md) | Returns the minimum protocol version supported by Spock. |
| [spock.node_info](functions/spock_node_info.md) | Returns information about the local Spock node. |
| [spock.version](functions/spock_version.md) | Returns the version string of the Spock extension. |
| [spock.version_num](functions/spock_version_num.md) | Returns the version number of Spock as an integer. |

## spock.get_country

Use `spock.get_country` to retrieve the country code configured for the node.

`spock.get_country()`

Returns the `spock.country` property that was set during node creation. You
can modify the property after configuration; modification requires a server
restart to apply the change.

This function retrieves the value of the spock.country configuration
parameter for the current session. The country code is typically used in
multi-region or geo-distributed replication topologies to identify the
geographic location of nodes and apply region-specific routing or filtering
rules.

This function takes no arguments.

## spock.max_proto_version

Use `spock.max_proto_version` to retrieve the maximum protocol version
supported by Spock.

`spock.max_proto_version()`

Returns the maximum protocol version supported by the Spock extension.

This function queries the Spock extension and returns the highest protocol
version number it can use for replication communication. The protocol
version determines the features and capabilities available for replication
between nodes.

When establishing replication connections between nodes running different
Spock versions, the nodes negotiate to use the lower of the two maximum
protocol versions. This ensures compatibility between nodes running
different Spock releases.

This function takes no arguments.

## spock.min_proto_version

Use `spock.min_proto_version` to retrieve the minimum protocol version
supported by Spock.

`spock.min_proto_version()`

Returns the minimum protocol version supported by the Spock extension.

This function queries the Spock extension and returns the lowest protocol
version number it can use for replication communication. The protocol
version determines the features and capabilities available for replication
between nodes.

When establishing replication connections between nodes running different
Spock versions, the nodes negotiate to use a protocol version that falls
within the supported range of both nodes. The minimum protocol version
defines the lower bound of compatibility.

This function takes no arguments.

## spock.node_info

Use `spock.node_info` to retrieve information about the local Spock node.

`spock.node_info()`

This function queries the Spock catalogs and returns metadata about the
current node, including its identifier, name, database information, and any
optional descriptive fields that were set during node creation.

This function takes no arguments.

## spock.version

Use `spock.version` to retrieve the version string of the Spock extension.

`spock.version()`

Returns the version number of the Spock extension.

This function queries the Spock extension and returns its version as a text
string. The version string typically follows semantic versioning format
(for example, "4.0.1" or "5.0.4").

This function takes no arguments.

## spock.version_num

Use `spock.version_num` to retrieve the version number of Spock as an
integer.

`spock.version_num()`

Returns the version number of the Spock extension as an integer.

This function queries the Spock extension and returns its version encoded
as an integer value. The integer format allows for easy version comparison
in SQL queries without string parsing.

The integer typically represents the version in a format like XXYYZZ where
XX is the major version, YY is the minor version, and ZZ is the patch
version. For example, version 3.1.0 might be represented as 30100.

This function takes no arguments.
