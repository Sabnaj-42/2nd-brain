## DB2 Resources Link
- pdf pages: https://www.ibm.com/support/pages/node/627743
- DB2 sync: https://ibm.github.io/db2-hadr-wiki/hadrSyncMode.html
- Setting up the HADR configuration for Db2: https://www.ibm.com/docs/en/software-hub/5.1.x?topic=scripts-setting-up-hadr-configuration
- some important files: https://www.dropbox.com/scl/fo/64d3i8fa6uihqjzs7553i/AGzviDu1yQzfhphYaqu2NsE?rlkey=jipqxr3yi51it9m1ax5mc69hn&e=1&dl=0


## DB2 POC

### HADR-High Availability Disaster Recovery
HADR 4 mode: Sync, Nearsync, Async, Supersync

**SYNC :** Highest protection | Slowest performance
- A transaction is committed only after the log is written to both the primary and standby disks, and an acknowledgment is received from the standby.
- If the standby fails, it can recover logs from its own files; if the primary fails, failover ensures no data loss.

**NEARSYNC :** Good protection | Faster than SYNC
- Transaction is committed when:
    - Logs are written to the primary disk, and
    - Standby acknowledges they’ve been received in memory (not yet written to disk).
- Data loss occurs only if both primary and standby fail before standby writes logs to disk.
- Possible log loss if standby crashes before flushing memory to disk.

**ASYNC(Asynchronous Mode) :** Faster transactions |  Higher data loss risk
- Primary commits after writing logs locally and sending them to the network (TCP layer),
  without waiting for standby acknowledgment.
- Data in transit may be lost if the primary or network fails.
- Standby can catch up later if primary survives, but if failover occurs, some transactions are lost.

**SUPERASYNC :** Fastest performance | Lowest protection
- Primary commits as soon as logs are written locally — no waiting for standby at all.
- Standby always lags behind; the log gap can become large.
- If failover happens, all logs not yet replicated are lost permanently.
- Best suited for cases where performance and availability are prioritized over data protection (e.g., long-distance disaster recovery).

SYNC and NEARSYNC modes are typically used on LAN. ASYNC and SUPERASYNC modes are typically used over WAN.

## HADR configuration
We must set up an etcd store to enable automated failover in Db2 HADR.
Four available method of setting up an etcd store for HADR:
- Use an external etcd store that can be a cloud-provided service, which is deployed on the OpenShift cluster, or hosted on-premises.
- Deploy etcd packaged with the Db2 installation.
- Deploy etcd packaged by Bitnami for Db2.
- Using the built-in Db2 etcd store (only nonproduction, single OpenShift cluster environments).

## DB2 automated failover (using Governor mechanism)
- Automated failover is only supported between the primary and principal standby, so a single etcd endpoint must be shared between the two deployments

## To set up HADR, follow these steps:
Procedure:
1. Set up HADR by using the setup_config_hadr script on the primary database pod. 
2. Copy the database backup image and keystore file in the backup storage area (/mnt/backup/) from the primary database to the standby database or databases by using rsync. <br>
**Note:** If the backup volume is shared between the primary and standby databases, you can skip this step.
3. Set up HADR by using the setup_config_hadr script on each standby database pod.

## Nodegroup in DB2
A nodegroup is basically a logical grouping of one or more database partitions.

Each database partition(or node) is like a separate DB2 process managing a piece of the data.
- When we create a table, we specify which nodegroup it belongs to.
- That means DB2 knows which partitions should store and manage that table’s data.

### Data Partitioning
When you put a table in a multi-partition nodegroup, DB2 splits (partitions) the table’s data across all those nodes using a partitioning key (a column or columns you define).
This means:
- Each partition stores a portion of the table’s rows.
- DB2 automatically routes queries to the correct partitions.
- It helps with parallel processing and performance for large datasets.

### Why Use Nodegroups?
1. Performance & Scalability:
Distribute large tables across multiple nodes for parallel query execution.
2. Workload Isolation:
Separate reporting data and transactional data into different nodegroups.
3. Storage Management:
Assign specific tables to nodes with more storage or computing power.

***In Summary:***<br>
***Database Partition(Node):*** A physical or logical DB2 process holding a slice of data<br>
***NodeGroup:*** A named collection of one or more database partitions<br>
***Multi-Partition Nodegroup:*** Nodegroup containing 2+ partitions<br>
***Table-to-Nodegroup Mapping:*** Determines where a table's data physically resides<br>

## DB2 Parallelism
DB2 can work in a parallel, multi-node environment, database is not confined to a single machine or CPU — it can be split and processed across multiple nodes (servers or processors). Each node handles part of the data and works together to make the whole database faster and more scalable.
Core Components: Database partition, Node/Nodegroup, Coordinator Node <br>
***Coordinator Node:*** The partition where a user or application connects. It coordinates the SQL request and gathers results from all nodes.

### Multi-Partition (Parallel) Database
When you have two or more database partitions, DB2 can distribute data and workload among them.
```
+-------------+       +-------------+       +-------------+
| Partition 1 |       | Partition 2 |       | Partition 3 |
|  Data: A–H  |       |  Data: I–P  |       |  Data: Q–Z  |
+-------------+       +-------------+       +-------------+

```
- Each partition holds a subset of the table's rows
- A nodegroup defines which partition the table used
- DB2 can process queries in parallel, using multiple CPUs/Nodes simultaneously.

### Parallel Query Execution
When a query runs (e.g., SELECT * FROM customers WHERE region='Asia'):
1. The application connects to one database partition (the coordinator node).
2. The coordinator breaks the query into sub-queries — one for each relevant partition.
3. Each partition executes its part of the query using its local data.
4. The coordinator combines the results and returns them to the user.<br>

All this is transparent — users write normal SQL and DB2 handles the parallelism automatically.