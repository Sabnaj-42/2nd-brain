- RaftExample: https://github.com/etcd-io/etcd/tree/main/contrib/raftexample

- Raftexample consist of three components. 
    1. Raft-backend: a key-value store
    2. A REST API server: that exposes the key-value store to clients
    3. A Raft consensus module(Raft Server): that manages the replication and consistency of the key-value
- How data flows:
    - PUT request flow: Client → REST Server → Raft → Cluster → Commit → Key-Value Store
    - GET request flow: Client → REST Server → Key-Value Store → Response
### RaftEexample flow diagram: 
```
                ┌────────────────────┐
                │    Client          │
                │ (GET / PUT API)    │
                └─────────┬──────────┘
                          │
                          ▼
                ┌────────────────────┐
                │   REST Server      │
                │ (HTTP Interface)   │
                └─────────┬──────────┘
                          │
            PUT request   │   GET request
                          ▼
                ┌────────────────────┐
                │   Raft Server      │
                │ (Consensus layer)  │
                └─────────┬──────────┘
                          │
          ┌───────────────┼────────────────┐
          │               │                │
          ▼               ▼                ▼
   ┌──────────┐   ┌──────────┐    ┌──────────┐
   │  Node A  │   │  Node B  │    │  Node C  │
   │ (peer)   │   │ (peer)   │    │ (peer)   │
   └────┬─────┘   └────┬─────┘    └────┬─────┘
        │              │               │
        └──────┬───────┴───────┬──────┘
               ▼               ▼
        ┌────────────────────────────┐
        │   Commit (majority agree)  │
        └────────────┬───────────────┘
                     ▼
        ┌────────────────────────────┐
        │ Key-Value Store (DB)       │
        │ - apply committed changes   │
        │ - store final state         │
        └────────────┬───────────────┘
                     ▼
        ┌────────────────────┐
        │ Response to Client │
        └────────────────────┘

```
## Data Replication:
- Leader receives client requests, appends them to its log, and sends entries to followers.
- Followers acknowledge receipt; once majority acknowledges, the entry is committed and applied to all state machines.
- Ensures consistent data across all nodes even during failures.


## Leader Election:
> Election timeout triggers elections; heartbeat timeout keeps current leader alive.

- Raft uses a randomized election timeout to trigger leader elections. Each follower starts an election timer with a random duration.
- If a follower does not receive a heartbeat from the leader before its election timer expires, it assumes the leader has failed and starts an election by transitioning to the candidate state. The candidate then requests votes from other nodes in the cluster. 
- If a candidate receives votes from a majority of nodes, it becomes the new leader. If multiple candidates start an election simultaneously, they may split the vote.
- How voting works:
    - Each node can vote for only one candidate in a given term.
    - Each voter check:
        - Compare last log term
        - If Candidate log term > voter log term → vote for candidate
        - If Candidate log term == voter log term → compare log index
            - If Candidate log index >= voter log index → vote for candidate
            - Else → reject vote
        - If Candidate log term < voter log term → reject vote
- Raft ensures that only one leader can be elected at a time by requiring candidates to receive votes from a majority of nodes in the cluster. 
- This means that even if multiple candidates start an election simultaneously, only one will receive the necessary votes to become the leader, while the others will fail and return to the follower state. This mechanism prevents split-brain scenarios and ensures that there is always a single source of truth for the cluster's state.
- Raft also includes a mechanism for handling network partitions. If a leader becomes isolated from the majority of nodes, it will eventually lose its leadership status as followers will not receive heartbeats and will start new elections. 
- This allows the cluster to continue functioning even in the presence of network issues, as a new leader can be elected from the remaining nodes that are still connected.
- When the network comes back, the old leader will recognize that it is no longer the leader and will step down to become a follower, ensuring that there is no conflict between the old and new leaders. 
- This process helps maintain the consistency and availability of the cluster even in the face of failures and network partitions.

## Log Replication:
- Leader appends client requests to log and sends AppendEntries to followers.
- Followers append entries to their logs and acknowledge. Leader commits(write into disk) once majority acknowledges.
- Leader sends commit instruction to followers; all apply to state machine.
- Guarantees consistent data across all nodes despite failures.
- Each log entry contains: [index, term, command]
    - Command to execute
    - Term number (election term when entry was received)
    - Index (position in log)
- How consistency is enforced:
    - Leader sends:
        - prevLogIndex: index of entry before new entries
        - prevLogTerm: term of entry at prevLogIndex
    - Follower checks:
        - If log contains entry at prevLogIndex with term prevLogTerm → append new entries
        - Else → reject and request missing entries
            - nextIndex -- and retry until match is found
            - Then delete conflicting entries and append correct entries from leader
  
    

### Raft vs PostgreSQL-Based System Mapping

| Raft Concept        | Your System Equivalent     | Description |
|--------------------|----------------------------|------------|
| Leader log         | Primary WAL                | Leader stores the authoritative sequence of operations; in PostgreSQL, WAL on primary is the source of truth |
| AppendEntries RPC  | WAL streaming              | Leader sends log entries to followers; primary streams WAL to standbys |
| Conflict resolution| Rewind / resync            | Raft overwrites inconsistent logs; PostgreSQL uses pg_rewind or full resync |
| Commit             | Safe replication           | Entry is committed after majority replication; WAL is considered safe after replication criteria met |
| Followers          | Standbys                   | Followers replicate and apply logs; standbys stream and replay WAL |