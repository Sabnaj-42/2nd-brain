## Postgres failover:
### To make standby pod new primary:
- Stop WAL streaming: The standby stops fetching WAL from the old primary.
- Switch to read-write mode: PostgreSQL allows writes from now on.
- Create new timeline: Marks the point of divergence from old primary.
- Accept client connections: The standby now acts as primary.

### Rejoin old primary as standby:
- Firstly, ensure clean shutdown  (single user mode sart and stop) to avoid split brain
- Chek if rewind(incremental backup) possible or not
    - conditions: 
        - WAL files from the divergence point are still available on the new primary.
        - wal_log_hints = on or data checksums enabled on the old primary.
    - If possible, use pg_rewind to synchronize old primary with new primary. And then start it as standby.
- If pg_rewind is not possible, take a new base backup from the new primary and restore it on the old primary. Then start it as standby.

### PG coordinator:
- raft sidecar container in each pod to manage leader election and failover
    - raft server
    - client for raft server
    - postgres sync (process)
- raft server:
   - storage for cluster state and leader election
   - raft server communicate with storage
   - client server to handle requests from postgres sync process to raft server
- postgres sync process:
   - if last leader != current leader got from raft:
        - request raft to select reader
        - sync others replica
   - otherwise:
        - health check
            - primary health check in primary pod
            - standby health check in standby pod

## How failover works in pg-coordinator:
### 1. Raft Sidecar

Responsible for:

- Cluster membership
- Leader election (consensus)
- Maintaining cluster-wide state

---

### 2. pg-coordinator

Responsible for:

- Monitoring PostgreSQL instances
- Validating replication health
- Promoting/demoting PostgreSQL nodes
- Enforcing failover rules

---

##  Failover Workflow

### 1. Failure Detection

- Each Raft node continuously sends **heartbeats**
- If the current leader becomes unreachable:
    - Followers detect a **heartbeat timeout**
    - Raft transitions to the **election phase**

>  Detection is done by Raft, not PostgreSQL itself

---

### 2. Raft Leader Election

- Each surviving node becomes a **candidate**
- Nodes exchange **vote requests**
- A node receiving **majority votes (quorum)** becomes:

 **Raft Leader**

> This leader is *not yet* the PostgreSQL primary

---

### 3. Leadership vs PostgreSQL Primary

At this point:

- Raft has selected a **cluster leader**
- But the PostgreSQL primary may:
    - Be **down**
    - Be **network partitioned**
    - Still be running (**risk of split-brain**)

> Raft leader and PostgreSQL primary are **not guaranteed to be the same**

This is where **pg-coordinator** takes control.

---

### 4. Health Check & Safety Validation

Before failover, **pg-coordinator** performs strict checks:

#### a. Leader Mismatch Check

Compare:

- Current PostgreSQL primary
- Newly elected Raft leader

If different → **failover scenario detected**

---

#### b. Candidate Health Validation

The Raft leader is validated for:

- **Replication lag**
    - Must be within `maximumLagBeforeFailover`
- **WAL replay status**
    - Must be up-to-date
- **Connectivity and readiness**
    - Node must be reachable and responsive

---

### Failover Blocking Condition

If the Raft leader is **not healthy**:

- Failover is **blocked**
- System waits until:
    - A **healthier node wins election**, OR
    - The current leader **catches up**

> This prevents data loss and unsafe promotion

---

### 5. Failover Execution

Once a **healthy Raft leader** is confirmed:

#### Promotion

pg-coordinator promotes the node:

```bash
pg_ctl promote
```
#### Reconfiguration

After a new primary is promoted, the remaining replicas are reconfigured:

- Follow the **new primary**
- Update recovery/replication configuration
- Resume **streaming replication**

---

### 6. Cluster Stabilization

Once reconfiguration is complete:

- The new primary starts **accepting write traffic**
- Replicas resume **normal streaming replication**
- Raft state converges across all nodes

> Cluster returns to a **consistent and healthy state**


