## DB2 Resources Link
- pdf pages: https://www.ibm.com/support/pages/node/627743
- DB2 sync: https://ibm.github.io/db2-hadr-wiki/hadrSyncMode.html
- Setting up the HADR configuration for Db2: https://www.ibm.com/docs/en/software-hub/5.1.x?topic=scripts-setting-up-hadr-configuration
- some important files: https://www.dropbox.com/scl/fo/64d3i8fa6uihqjzs7553i/AGzviDu1yQzfhphYaqu2NsE?rlkey=jipqxr3yi51it9m1ax5mc69hn&e=1&dl=0
- learn MLN: https://www1.columbia.edu/sec/acis/db2/db2d0/db2d006.htm
- mem-scaling: https://www.ibm.com/docs/en/db2/11.5.x?topic=ad-scaling-up-db2
- pre-requisite of hadr: https://www.ibm.com/docs/en/db2/11.5.x?topic=dhadrh-prerequisites-configuring-hadr
- deploy db2 wh: https://www.ibm.com/docs/en/db2-warehouse?topic=resource-deploying-db2-warehouse-using-db2uinstance-custom
- deploy db2: https://www.ibm.com/docs/en/db2/11.5.x?topic=resource-deploying-db2-using-db2ucluster-custom
- deploying db2 k8s: https://www.linkedin.com/pulse/deploying-db2-ibm-cloud-rashmi-s-pai
- db2 hadr: https://www.ibm.com/docs/en/db2/11.5.x?topic=server-high-availability-disaster-recovery-hadr

## HADR-High Availability Disaster Recovery
HADR (High Availability Disaster Recovery) in Db2 is a built-in feature that provides data protection, high availability, and disaster recovery for your database.<br>
HADR allows a Db2 database to automatically replicate data changes from a primary database (the main one handling user requests) to one or more(up to 3 standby) standby databases (copies kept in sync).<br>
If the primary database fails, one of the standby databases can take over and become the new primary — keeping your application online with minimal downtime and little or no data loss.
1. Primary Database:
  - Handles all reads and writes operation
  - continuously sends transaction logs to the standby database
2. Standby Database
   - Receives and replays these logs to stay nearly identical to the primary.
   - Stays ready to take over if the primary fails.
3. Failover / Takeover
   - If the primary crashes or becomes unreachable, the standby automatically takes over as the new primary.
   -  When the old primary comes back online, it can rejoin as a standby (this is called failback).

### key Features:
1. Replication: Uses transaction logs to keep standby in sync with primary.
2. Zero or minimal data loss: Depending on synchronization mode (SYNC, NEARSYNC, ASYNC, SUPERASYNC).
3. Automatic client reroute (ACR): Clients automatically reconnect to the new primary after failover.
4. Peer Window: Grace period that allows zero data loss even during temporary disconnections.
5. Up to 3 standbys: One for high availability (local), others for disaster recovery (remote).
6. Pacemaker Integration: From Db2 11.5.4+, Pacemaker can automate failover decisions.

## HADR Synchronization mode
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