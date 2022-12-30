# *spock-bench* - A stress test for distributed databases

***spock-bench*** is a stress test for multi-directional distributed databases
based on ***pgbench***. The purpose is to allow a configurable
probability of conflicting
updates that require **conflict-free** as well as **last-update-wins**
types of conflict resolution strategies in a distributed database.


## Problem Description

A distributed database that allows updates to the same data on multiple
nodes may require more that one conflict resolution strategy. A common
one is **last-update-wins** where a commit timestamp is used to determine
which of the conflicting row versions ultimately should survive on all
nodes. While this method works well for a large number of use cases,
there is another very common use case where it is insufficien. This is
the type of conflict found on columns that represent counters or balances
like inventory levels or bank account balances.

This problem can be well illustrated with the classic ATM-scenario. Let
us assume a bank account has a balance of $500. Two persons with ATM
cards for this account go to ATMs in two different cities. The ATMs
are connected to different nodes of the Bank's distributed database.
Person A withdraws $100. Person B withdraws $150. The two withdrawals
happen so close together that the distributed database has not replicated
the first when the second happens. This means that on node A the
withdrawal of $100 results in a new account balance of $400, while on
node B the withdrawal of $150 results in a new balance of $350. Neither
of these two values is correct. The correct *final* value for the account
balance is actually $250, because a total of $250 was withdrawn.

***spock*** solves this problem with the
[**delta-resolve**](http://link-required)
mechanism. Columns marked for **delta-resolve** are never updated
to the remote's **new** value. Instead the provider transmits the
**old** and **new** values of the columns in the replication stream.
the ***spock-apply-worker*** on the subscriber then computes the new
value for the column from the current **local** value and the **delta**
between the **old** and **new** values of the provider.
***spock's*** **delta-resolve** mechanism has the same effect as
*Conflict-free Replicated Data Types* (CRDTs), but does it very different
internally and without the need for custom data types.

Only counter and balance type columns need this special handling and
usually one will find additional columns in a table, that still require
**last-update-wins** conflict resolution. Which mechanism applies to
a particular column depends on the underlying business process. For
example changing an eMail address or phone number is a business process
that does not depend on the old value. The customer just has a new
phone number and we always want the last one. So this is a classic
**last-update-wins** case. Withdrawing or depositing money in an account
on the other hand very much depends on the previous value, so that
is a classic **delta-resolve** case.

To stress test this we
need to generate a load that updates both types of columns on the
same table and conflicting on multiple nodes.


## Using *pgbench*

***pgbench*** is very popular for quickly generating heavy stress
loads. It is generally available on every PostgreSQL installation
and provides a number of very useful features like rate-limiting.

However, the default ***pgbench*** schema and transaction
profile do not have any columns, that require **last-update-wins**
conflict resolution. **pgbench** also does not implement the TPC-B's
idea of local and remote transactions (see 
[TPC-B specification](https://www.tpc.org/tpc_documents_current_versions/pdf/tpc-b_v2.0.0.pdf) 5.1 and 5.3). 
In the TPC-B every teller and account have a home branch, which is
held in their **bid** column. Their **aid** and **tid** have a 1:n
relationship to that **bid** in that there are for example 10 teller
rows with **bid**=1 and **tid**=[1..10], followed by 10 teller rows
with **bid**=2 and **tid**=[11..20] and so forth. The same pattern
occurs in the accounts table with 100,000 rows per branch.

In order to use ***pgbench*** we therefore have to modify the schema
as well as the transaction profile to suit our needs. 


### Modifying the *pgbench* schema

The first thing we need is to modify the table **pgbench_history**
so that we can replicate it. This table lacks a primary key and
many replication systems, ***spock*** included, don't normally replicate
tables like that. The process is a bit tricky as it requires a different
configuration on each node. The SQL below assumes that `branch`
expands into the local node ID, like it would if the SQL was
provided by a shell here-document and `$nid` was set accordingly.
It creates a sequence based primary key **hid** where the sequence on
each node is generating unique numers that start on the node-id and
increment in steps of 100. This means node 1 will create **hid** values
of 1, 101, 201, ... while node 2 creates 2, 102, 202, ... . This is
conflict free on inserts across the entire distributed database. These
changes can be found in ***spock-bench-alter-H.sql***.

```
ALTER TABLE pgbench_history ADD COLUMN hid bigserial;
ALTER TABLE pgbench_history ADD PRIMARY KEY (hid);
ALTER SEQUENCE pgbench_history_hid_seq START :branch RESTART :branch INCREMENT 100;
```

It is important to perform this change before creating the ***spock***
replication setup since the history table cannot be added to the
replication set without a primary key.

Next we create two additional columns on the **pgbench_tellers** and
**pgbench_accounts** tables. The test would be sufficient with just
one column on each, but why not have two for the price of two? These
changes can be found in ***spock-bench-alter-TA.sql***.

```
ALTER TABLE pgbench_tellers ADD COLUMN trandom integer DEFAULT 0;
ALTER TABLE pgbench_tellers ADD COLUMN tlastts timestamp with time zone DEFAULT 'EPOCH';

ALTER TABLE pgbench_accounts ADD COLUMN arandom integer DEFAULT 0;
ALTER TABLE pgbench_accounts ADD COLUMN alastts timestamp with time zone DEFAULT 'EPOCH';
```

Third we configure the balance columns on each of the three main
tables to **LOG_OLD_VALUE=true** (which causes ***spock***
to use **delta-resolve** for those columns). These changes are also
found in ***spock-bench-alter-TA.sql***.

```
ALTER TABLE pgbench_accounts ALTER COLUMN abalance SET (LOG_OLD_VALUE=true);
ALTER TABLE pgbench_branches ALTER COLUMN bbalance SET (LOG_OLD_VALUE=true);
ALTER TABLE pgbench_tellers ALTER COLUMN tbalance SET (LOG_OLD_VALUE=true);
```

The changes in ***spock-bench-alter-TA.sql*** can only be performed
after the data has been loaded into the pgbench tables since they break
the way pgbench does the initial load for the accounts table.


### Custom pgbench transaction profiles

The idea behind the ***spock-bench*** transaction profiles is to have
one branch per ***spock*** node and make that node the *home* of
the branch. To meet the transaction input generation requirements of
the TPC-B clauses under 5.3 (specifically 5.3.5), we would only need
two profiles. However, there are 100,000 accounts per branch and this
may not generate as much per-row concurrency as we need. Therefore
we create a third profile that allows to access remote tellers as well.

* **spock-bench-local.sql** - generating bid, tid and aid so that they always belong to the node's home branch.
* **spock-bench-remote-A.sql** - generating bid and tid so that they belong to the node's home branch and generating aid random across the entire range of accounts. (NOTE: this is slightly different from claus 5.3.5 in that it specifies the AID should be chosen random from all non-bid branches; we can compensate for that later).
* **spock-bench-remote-TA.sql** - use the local node's branch for bid always, generate a random remote-bid across all branches and generate a random tid and aid within that remote-bid.

**spock-bench-remote-A.sql** in detail:
```
\set bid :branch
\set rmtbid random(1,:scale)
\set aid random(1, 100000) + 100000 * (:rmtbid - 1)
\set tid random(1, 10) + 10 * (:bid - 1)
\set delta random(-5000, 5000)
\set trandom random(0,999)
\set arandom random(0,999)
BEGIN;
UPDATE pgbench_accounts SET abalance = abalance + :delta, arandom = :arandom, alastts = CURRENT_TIMESTAMP WHERE aid = :aid;
SELECT abalance FROM pgbench_accounts WHERE aid = :aid;
UPDATE pgbench_tellers SET tbalance = tbalance + :delta, trandom = :trandom, tlastts = CURRENT_TIMESTAMP WHERE tid = :tid;
UPDATE pgbench_branches SET bbalance = bbalance + :delta WHERE bid = :bid;
INSERT INTO pgbench_history (tid, bid, aid, delta, mtime) VALUES (:tid, :bid, :aid, :delta, CURRENT_TIMESTAMP);
END;
```

* `\set bid :branch` is set to the (externally supplied branch).
* `\set rmtbid random(1,:scale)` the remote-bid is generated.
* `\set aid random(1, 100000) + 100000 * (:rmtbid - 1)` the aid is generated from the pool of accounts that belong to the remote-bid.
* `\set tid random(1, 10) + 10 * (:bid - 1)` the aid is generated from the pool of tellers belonging to the local bid.


### Running pgbench

When using custom transaction profiles ***pgbench*** allows to
define variables from the outside and specify multiple profiles and
their weight (probability). The command

```
pgbench -n -c50 -T600 [CONNECTION OPTIONS] \
    -D branch=2 -D scale=3 \
    -f spock-bench-local.sql@775 \
    -f spock-bench-remote-A.sql@225 \
    [DBNAME]
```

would run the TPC-B Spec compliant transaction mix of home and remote
transactions against node 2 of a 3-node cluster. The Spec requires 15%
of the accounts to be remote. Since **spock-bench-remote-A.sql** is
using the entire range over all 3 branches, we need to compensate for
that and use a transaction mix of 77.5% local and 22.5% remote.

A weight is allowed to be zero, which makes using all three transaction
profiles in a script, then control the actual mix with shell variables,
very easy.
