# Spock Release Notes


## Version 4.0.11 on August 29, 2025

* Backport 7057507: Bug fix for an incorrect commit timestamp being used for the case of updating a row that was inserted in the same transaction. A consequence was possible incorrect resolution handling for updates.
* Backport f8b1147: Fix default column values to use defaults on the subscriber when no values provided from the publisher
* Backport 3ed5e3c: Fix resource leak

## Version 4.1
* Hardening Parallel Slots for OLTP production use.
  - Commit Order
  - Skip LSN
  - Optionally stop replicating in an Error
* Enhancements to Automatic DDL replication

## Version 4.0

* Full re-work of paralell slots implementation to support mixed OLTP workloads
* Improved support for delta_apply columns to support various data types
* Improved regression test coverage
* Support for [Large Object LOgical Replication](https://github.com/pgedge/lolor)
* Support for pg17

Our current production version is v3.3 and includes the following enhancements over v3.2:

* Automatic replication of DDL statements

## Version 3.2 

* Support for pg14
* Support for [Snowflake Sequences](https://github.com/pgedge/snowflake)
* Support for setting a database to ReadOnly
* A couple small bug fixes from pgLogical
* Native support for Failover Slots via integrating pg_failover_slots extension
* Parallel slots support for insert only workloads

## Version 3.1

* Support for both pg15 *and* pg16
* Prelim testing for online upgrades between pg15 & pg16
* Regression testing improvements
* Improved support for in-region shadow nodes (in different AZ's)
* Improved and document support for replication and maintaining partitioned tables.


**Version 3.0 (Beta)** includes the following important enhancements beyond the BDR/pg_logical base:

* Support for pg15 (support for pg10 thru pg14 dropped)
* Support for Asynchronous Multi-Master Replication with conflict resolution
* Conflict-free delta-apply columns
* Replication of partitioned tables (to help support geo-sharding) 
* Making database clusters location aware (to help support geo-sharding)
* Better error handling for conflict resolution
* Better management & monitoring stats and integration
* A 'pii' table for making it easy for personally identifiable data to be kept in country
* Better support for minimizing system interuption during switch-over and failover
