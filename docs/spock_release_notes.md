
 **Version 4.0** includes the following features:

* Full re-work of parallel slots implementation to support mixed OLTP workloads
* Improved support for delta_apply columns to support various data types
* Improved regression test coverage
* Support for [Large Object LOgical Replication](https://github.com/pgedge/lolor)
* Support for pg17

Version is v3.3 includes the following features:

* Automatic replication of DDL statements

**Version 3.2** includes the following features:

* Support for pg14
* Support for [Snowflake Sequences](https://github.com/pgedge/snowflake)
* Support for setting a database to ReadOnly
* A couple small bug fixes from pgLogical
* Native support for Failover Slots via integrating pg_failover_slots extension
* Paralell slots support for insert only workloads

**Version 3.1** included the following features:

* Support for both pg15 *and* pg16
* Prelim testing for online upgrades between pg15 & pg16
* Regression testing improvements
* Improved support for in-region shadow nodes (in different AZ's)
* Improved and document support for replication and maintaining partitioned tables.


**Version 3.0 (Beta)** includes the following features:

* Support for pg15 (support for pg10 thru pg14 dropped)
* Support for Asynchronous Multi-Master Replication with conflict resolution
* Conflict-free delta-apply columns
* Replication of partitioned tables (to help support geo-sharding) 
* Making database clusters location aware (to help support geo-sharding)
* Better error handling for conflict resolution
* Better management & monitoring stats and integration
* A 'pii' table for making it easy for personally identifiable data to be kept in country
* Better support for minimizing system interuption during switch-over and failover
