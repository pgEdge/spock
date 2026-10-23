# Monitoring the Configuration and Health of Your Cluster

The Spock extension provides several ways you can monitor data health in your Postgres cluster:

* You can [query informational tables](spock_info.md) in the `spock` schema to review information about your cluster configuration and status.
* The [status views](node_monitoring.md) `spock.node_status`, `spock.subscription_status`, `spock.worker_status`, `spock.slot_status` and `spock.events` give a complete picture of a node without reading the server log.
* The Spock extension's [Lag Tracking](lag_tracking.md) utility allows you to review node-specific metrics for replication lag.
* Use Spock's [Sync Event](spock_sync_event.md) utility to watch for a specific transaction to replicate.
* Use the [ACE (Active Consistency Engine)](https://docs.pgedge.com/platform/ace) to evaluate cluster health.