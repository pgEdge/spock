## NAME

`spock.get_country()`

### SYNOPSIS

`spock.get_country ()`

### DESCRIPTION

Returns the country code for the current node. The country code is set via the `spock.country` GUC parameter. If the country has not been explicitly set, the function returns `??`.

### EXAMPLE

`SELECT spock.get_country();`
