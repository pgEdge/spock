## NAME

spock.spock_version_num()

### SYNOPSIS

spock.spock_version_num ()

### RETURNS

The version number of the installed Spock extension as an integer.

### DESCRIPTION

Returns the version number of the Spock extension as an integer.

This function queries the Spock extension and returns its version encoded as
an integer value. The integer format allows for easy version comparison in
SQL queries without string parsing.

The integer typically represents the version in a format like XXYYZZ where XX
is the major version, YY is the minor version, and ZZ is the patch version.
For example, version 3.1.0 might be represented as 30100.

This is a read-only query function that does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

    SELECT spock.spock_version_num();
