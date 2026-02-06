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
(e.g., "3.1.0" or "4.0.1").

This is a read-only query function that does not modify any data.

### ARGUMENTS

This function takes no arguments.

### EXAMPLE

    SELECT spock.spock_version();
