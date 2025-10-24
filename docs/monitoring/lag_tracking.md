# Lag Tracking

The Spock extension's lag tracking feature shows how far behind a subscriber is when compared to a provider node in terms of write-ahead log (WAL) replication. You can use this feature to understand replication delays and monitor streaming health.

Tracking is implemented via a SQL view named `spock.lag_tracker`, which exposes key metrics for replication lag on a per-node basis. For example:

```sql
-[ RECORD 1 ]---------+------------------------------
origin_name           | node1
receiver_name         | node2
commit_timestamp      | 2025-06-30 09:27:57.317779+00
commit_lsn            | 0/15A2780
remote_insert_lsn     | 0/15A2780
replication_lag_bytes | 0
replication_lag       | 00:00:04.014177
```

`spock.lag tracker` displays the following information:

| Column Name | Description |
|-------------|-------------|
| origin_name | Name of the provider node. |
| receiver_name | Name of the subscriber node. |
| commit_timestamp | Commit time of the last transaction received from the provider. |
| commit_lsn | Last acknowledged log sequence number (LSN) of last commit applied from the provider. |
| remote_insert_lsn | WAL insert position on the provider when the commit was sent. |
| replication_lag_bytes | The amount of data the subscriber is behind. |
| replication_lag | Time delay between when the transaction was committed on the provider and when processed locally. |


