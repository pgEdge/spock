## NAME

spock.get_country()

### SYNOPSIS

spock.get_country ()

### RETURNS

The country code configured for the current session as text, or an error if
not set.

### DESCRIPTION

Returns the country code that has been configured for the current database
session.

This function retrieves the value of the spock.country configuration
parameter for the current session. The country code is typically used in
multi-region or geo-distributed replication topologies to identify the
geographic location of nodes and apply region-specific routing or filtering
rules.

The country code must be set using PostgreSQL's SET command or in the
session configuration before calling this function. If the spock.country
parameter has not been set, this function will raise an error.

This is a read-only query function that does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

SET spock.country = 'US';
SELECT spock.get_country();
