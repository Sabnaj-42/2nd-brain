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