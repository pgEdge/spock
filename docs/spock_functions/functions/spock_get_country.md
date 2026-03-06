## NAME

spock.get_country()

### SYNOPSIS

spock.get_country ()

### RETURNS

The country code configured for the node as text, or `??` if not set.

### DESCRIPTION

Returns the spock.country property that was set during node creation. You can
modify the property after configuration; modification requires a server
restart to apply the change.

This function retrieves the value of the spock.country configuration
parameter for the current session. The country code is typically used in
multi-region or geo-distributed replication topologies to identify the
geographic location of nodes and apply region-specific routing or filtering
rules.

This function does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

If the spock.country parameter has not been set, the function returns:

    postgres=# SELECT spock.get_country();
     get_country
    -------------
     ??
    (1 row)

If spock.country is set to `US`, the function returns:

    postgres=# SELECT spock.get_country();
     get_country
    -------------
     US
    (1 row)