## NAME

`spock.replicate_ddl()`

### SYNOPSIS

`spock.replicate_ddl(command text, repsets text[])`
 
### DESCRIPTION

Execute locally and then send the specified command to the replication queue for execution on subscribers which are subscribed to one of the specified `repsets`. 
 
### ARGUMENTS
    command
        The DDL query to execute.
    repsets
        The array of replication sets which this command should be associated with, default "{ddl_sql}".
