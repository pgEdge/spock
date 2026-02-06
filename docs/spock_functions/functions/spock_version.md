## NAME

spock.spock_version()

### SYNOPSIS

spock.spock_version ()

### RETURNS

The version string of the installed Spock extension.

### DESCRIPTION

Returns the version number of the Spock extension.

This function queries the Spock extension and returns its version as a text
string. The version string typically follows semantic versioning format
(e.g., "4.0.1" or "5.0.4").

This is a read-only query function that does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

The following command returns the Spock version:

    postgres=# SELECT spock.spock_version();
     spock_version 
    ---------------
     5.0.4
    (1 row)