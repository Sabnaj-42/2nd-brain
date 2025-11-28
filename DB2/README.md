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
- db2 hadr setup not possible issue: https://community.ibm.com/community/user/discussion/need-help-to-set-up-hadr-on-db2-v115-in-docker
-  https://community.ibm.com/community/user/discussion/how-to-setup-hadr-on-an-already-existing-dockers
- not completed docker hadr setup: https://freedium.cfd/https://medium.com/@larry.prestosa/db2-hadr-implementation-in-docker-cf0d3a27de16
- initializing hadr: https://www.ibm.com/docs/en/db2/11.5.x?topic=availability-initializing-hadr
- hadr multiple standby: https://www.ibm.com/docs/en/db2/11.5.x?topic=solution-hadr-multiple-standby-databases
- Example: Setting up Db2 HADR in a single OpenShift project: https://www.ibm.com/docs/en/software-hub/5.2.x?topic=suhc-example-setting-up-hadr-in-single-openshift-project
- data recovery: https://www.ibm.com/docs/en/db2/11.5.x?topic=administration-data-recovery
- Examples: Takeover in a multiple HADR standby setup: https://www.ibm.com/docs/en/db2/11.5.x?topic=databases-examples-takeover-in-multiple-hadr-standby-setup
- ibm db2 chart artifacts: https://artifacthub.io/packages/helm/ibm-charts/ibm-db2
- ibm db2 helm chart: https://github.com/IBM/charts/tree/master/stable/ibm-db2
- GET DATABASE CONFIGURATION command: https://www.ibm.com/docs/en/db2/11.1.0?topic=commands-get-database-configuration
- ibm wiki: https://ibm.github.io/db2-hadr-wiki/hadrCommands.html
- Setting DB2 Configuration Parameters for DB2 HADR Using IBM Tivoli System Automation (TSA) with a Virtual IP Address: https://documentation.commvault.com/11.20/setting_db2_configuration_parameters_for_db2_hadr_using_ibm_tivoli_system_automation_tsa_with_virtual_ip_address.html
- DB2 AWS: https://docs.aws.amazon.com/prescriptive-guidance/latest/patterns/set-up-disaster-recovery-for-sap-on-ibm-db2-on-aws.html
- Backing up and restoring: https://www.ibm.com/docs/en/db2/11.5.x?topic=ad-backing-up-restoring-db2
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
<br>***Note:*** We can make replica of a specific database in DB2.
### key Features:
1. **Replication:** Uses transaction logs to keep standby in sync with primary.
2. **Zero or minimal data loss:** Depending on synchronization mode (SYNC, NEARSYNC, ASYNC, SUPERASYNC).
3. **Automatic client reroute (ACR):** Clients automatically reconnect to the new primary after failover.
4. **Peer Window:** Grace period that allows zero data loss even during temporary disconnections.
5. **Up to 3 standbys:** One for high availability (local), others for disaster recovery (remote).
6. **Pacemaker Integration:** From Db2 11.5.4+, Pacemaker can automate failover decisions.

### HADR multiple standby database
- IBM Tivoli System Automation for Multiplatforms (SA MP) and Pacemaker automated failover is supported only for the principal standby. You must issue a takeover manually on one of the auxiliary standbys to make one of them the primary.
- All of the HADR synchronization modes are supported on the principal standby, but the auxiliary standbys can only be in SUPERASYNC mode.
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

## Pacemaker
In IBM Db2 HADR (High Availability Disaster Recovery), Pacemaker is an open-source cluster manager that provides automatic failover and high availability capabilities. It essentially automates the disaster recovery process that HADR alone cannot perform.
<br> **What pacemaker does:**
1. Automates HADR Faileover
   - HADR by itself is only a replication technology—it has no built-in failure detection or automatic takeover . A manual takeover requires DBA intervention.
   - Pacemaker continuously monitors the health of primary and standby database instances 
   - When the primary database fails (e.g., process crash, VM halt), Pacemaker automatically initiates an HADR takeover by the standby server
2. Manages Virtual IP (VIP) Address
   - Pacemaker maintains a single VIP address that clients use to connect to the database, regardless of which node is primary
   - During failover, it automatically transfers the VIP to the new primary server, enabling seamless client reconnections (especially when combined with Automatic Client Reroute - ACR) 
3. Prevents Split-Brain scenarios
   - Pacemaker uses quorum mechanisms (including QDevice) and fencing to ensure only one primary exists .
   - If both nodes somehow become primary, Pacemaker detects and resolves this "dual-primary" condition .
4. Replace legacy TSAMP technology
   - Pacemaker is the modern replacement for Tivoli System Automation for Multiplatforms (TSAMP) . It offers simpler configuration and management compared to TSAMP.

## DB2 backup and restoring
### DB2 backup
A backup creates a copy of your entire database or individual table spaces at a specific point in time. This copy can be used to rebuild the database if it becomes corrupted, damaged, or if you need to revert to a previous state.<br>
**Backup Types:** 
1. **Full Backup:** Copies the entire database 
  ```bash
   db2 backup db <dbname> to <path>
  ```
2. **Incremental Backup:** All changes since last Full backup
3. **Delta Backup:** Changes since any previous backup (full, incremental, or delta)

**Backup Modes:**
1. **Offline Backup:** Database must be inaccessible to users during backup
2. **Online Backup:** Database remains available during backup, but requires subsequent log files to make the data consistent (for production)

### DB2 restoring
Restore rebuilds a damaged or corrupted database from a backup image. The restored database returns to the exact state it was in when the backup was created .<br> DB2 supports two primary recovery methods:
1. **Version Recovery:** Restores the database to the state captured in a backup image. All transactions after the backup are lost. This method uses circular logging (default) and requires regular full backups
2. **Rollforward Recovery:** Restores from backup, then applies transaction log files to recover the database to its most recent state or a specific point in time. Requires archive logging enabled

### DB2 Online Full Backup — Command Sequence with Comments
```bash
su - db2inst1                 # Switch to DB2 instance owner (must run DB2 commands)

. ~/sqllib/db2profile         # Load DB2 environment variables (PATH, DB2INSTANCE, etc.) .Replace the directory with the db2profile actual path
db2start                      # Start the DB2 instance
db2 connect to testdb         # Connect to your database (replace testdb with your DB name)

db2 get db cfg for testdb | grep -i LOG     # Check database logging settings (required for online backup)

db2 update db cfg for testdb using LOGARCHMETH1 LOGRETAIN   # Enable archive logging mode (required for on line backup)
                                                             # LOGRETAIN = required for online full backup

db2stop                      # Restart DB2 to apply logging configuration
db2start

mkdir -p /backup/db2         # Create backup directory (must exist before backup)

db2 backup db testdb online to /backup/db2 compress include logs   # Take ONLINE full backup with logs
                                                                   # compress = reduces size
                                                                   # include logs = needed for recovery

db2 list history backup all for testdb      # Show backup history with timestamps

db2ckbkp /backup/db2/<backup_timestamp>.001 # Verify the backup image validity
                                            # Replace <backup_timestamp> with the actual timestamp file

db2 disconnect testdb          # Disconnect from the database (cleanup step)

```

### DB2 Restore Commands — With Comments (Assuming database is testdb and backup is in /backup/db2)
```bash
su - db2inst1                 # Switch to DB2 instance owner (required for DB2 admin commands)

. ~/sqllib/db2profile         # Load DB2 environment variables (PATH, DB2INSTANCE, etc.). Replace the path with the actual db2profile path

db2stop                        # Stop the database instance before restore (optional but safe)

db2 restore db testdb from /backup/db2 taken at <backup_timestamp>   # Restore the database from backup
                                                                     # Replace <backup_timestamp> with actual backup timestamp
                                                                     # Example timestamp from `list history backup all`

db2 connect to testdb          # Connect to the restored database

db2 rollforward db testdb to end of logs and complete  # Apply transaction logs to bring DB to consistent state
                                                         # 'end of logs' = recover to latest committed state
                                                         # 'complete' = finalize restore

db2 list db directory           # Verify database is restored and visible

db2 list history backup all for testdb    # Optional: verify backup history for restored database

db2 connect reset               # Disconnect from database after restore

db2start                        # Start the DB2 instance (if it was stopped)

```
## Snapshot Backup
**Snapshot Backup:** An instant, point-in-time copy of your database created by the storage system, not by copying data through the database engine. It uses metadata pointers instead of full data duplication. <br>
**How it works:**
1. **Quiesce:** Db2 pauses writes for ~10 seconds to ensure consistency
2. **Capture:** Storage system captures metadata pointers to data blocks (instant)
3. **Resume:** Normal operations continue immediately
4. **Copy-on-Write:** Original blocks are preserved when changed, maintaining the snapshot view
### Snapshot backup in db2
Snapshot backup works only when:
1. Your database is encrypted, and
2. You are using Db2's own built-in (IBM) encryption libraries
  – either
    - the normal encryption library, or
    - the combined encryption + compression library.
<br> Snapshot backup does not work when you configured a non-IBM(third-party) encryption library for backups.