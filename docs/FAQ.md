# Frequently Asked Questions

### Using a Column Filter

* What happens if I set up a column filter on a table with OIDS? Can I
  filter on xmin?

  Column filters work fine on tables with OIDs, but spock cannot filter on
  system columns like `oid` or `xmin`.

* What happens if a column being filtered on is dropped?

  Currently in spock replication, you can drop even a primary key on the
  provider.  If a column being filtered on is dropped on the provider, it
  is removed from the column filter too. Use `spock.repset_show_table()` to
  confirm this behavior.

  Columns on each subscriber remain as defined, which is correct and
  expected. In this state, the subscriber replicates INSERTs, but does not
  replicate UPDATEs and DELETEs.

* If I add a column, does it automatically get included?

  If you add a column to a table on the provider, it is not automatically
  added to the column filter.

### Using a Row Filter

* Can I create a `row_filter` on a table with OIDS? Can I filter on xmin?

  Yes, `row_filter` behavior works fine for table with OIDs, but spock
  cannot filter on system columns (like `xmin`).

* What types of functions can we execute in a `row_filter`? Can we use a
  volatile sampling function, for example?

  We can execute immutable, stable and volatile functions in a
  `row_filter`. Exercise caution with regard to writes as any expression
  which will do writes can potentially throw an error and stop replication.

  Volatile sampling function in `row_filter`: This would not work in
  practice as it would not get correct snapshot of the data in live system.
  Theoretically with static data, it works.

* Can we test a JSONB datatype that includes some form of attribute
  filtering?

  Yes, a `row_filter` on attributes of JSONB datatype works fine.

### Using apply_delay with Time Changes

* Does `apply_delay` accommodate time zone changes, for example Daylight
  Savings Time?

  Note: the physical replication parameter `recovery_min_apply_delay` behaves
  differently — if set during daylight savings time, you may get that interval
  plus the time change (e.g., 1h delay instead of 2h), which could require
  stopping and starting the database service twice per year.

  Spock's `apply_delay` is interval-based and accommodates time changes like
  Daylight Savings Time. The configured interval stays constant and is not
  affected by DST or other time zone shifts. However, we do not recommend
  running heavy workloads during a time change as spock replication needs
  some time (~5 minutes) to recover.

### Node failure and recovery

* What should I do if a node crashes and another node is left behind (for
  example, missing some transactions)?

  If one node fails and a subscriber did not receive all of that node's
  transactions before the failure, you can recover the lagging node using
  the Active Consistency Engine (ACE). ACE compares table data across the
  surviving nodes, identifies what is missing on the lagging node, and
  repairs it using a fully synchronized node as the source of truth. You
  can preserve original timestamps and origin IDs so that replication
  metadata stays correct. For a step-by-step procedure, see
  [Recovering from Catastrophic Node Failure](recovery/catastrophic_node_failure.md).

