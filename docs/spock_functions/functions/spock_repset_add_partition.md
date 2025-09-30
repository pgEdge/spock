## NAME

`spock.repset-add-partition ()`

## SYNOPSIS

`spock.repset-add-partition (PARENT_TABLE DB <flags>)`
 
## DESCRIPTION
    
Add a partition to the same replication set that the parent table is a part of. 

## EXAMPLE

`spock.repset-add-partition (mytable demo --partition=mytable_202012)`
 
## POSITIONAL ARGUMENTS
    PARENT_TABLE
        The name of the parent table. Example: mytable
    DB
        The name of the database. Example: demo
 
## FLAGS
    -p, --partition=PARTITION
        The name of the partition. If none is provided, it will add all unreplicated partitions to the replication set. Example: mytable_202012
    
    -r, --row_filter=ROW_FILTER
        The row filtering expression. Example: my_id = 1001
    
