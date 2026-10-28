## NAME

spock.core_patchset()

### SYNOPSIS

spock.core_patchset ()

### RETURNS

The generation of the Spock core patch set on the server, as an integer.

### DESCRIPTION

Returns the generation of the Spock core patch set that the PostgreSQL server
was built with.

Spock reads the generation once, when the server starts and loads the Spock
library. A server built with the current Spock core patches reports the
generation that this Spock release targets. The function returns 0 when the
server reports no generation; either the server has no Spock core patches, or
its patches predate generation tracking.

When the generation differs from the one this Spock release targets, Spock
writes a line to the server log at startup.

This is a read-only query function that does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

The following command returns the core patch-set generation of the server:

    postgres=# SELECT spock.core_patchset();
     core_patchset
    ---------------
                 1
    (1 row)
