## How Raft replicates data in distributed system:
- There's a leader node that handles all client requests and replicates data to follower nodes.
- When a client sends a request to the leader, the leader appends the request to its log and then sends the log entry to its followers.
- The followers append the log entry to their logs and send an acknowledgment back to the leader.
- Once the leader receives acknowledgments from a majority of followers, it considers the log entry committed and applies it to its state machine(after that leader node value will be changed).
- The leader then sends a commit message to the followers, instructing them to apply the log entry to their state machines as well.
- This process ensures that all nodes in the cluster have a consistent view of the data, even in the presence of failures.


## Leader Election:
> There are two times out in Raft: election timeout and heartbeat timeout. Election timeout is used to trigger leader elections, while heartbeat timeout is used by the leader to send periodic heartbeats to followers to maintain its leadership status (let followers know that leader is alive).

- Raft uses a randomized election timeout to trigger leader elections. Each follower starts an election timer with a random duration. If a follower does not receive a heartbeat from the leader before its election timer expires, it assumes the leader has failed and starts an election by transitioning to the candidate state. The candidate then requests votes from other nodes in the cluster. If a candidate receives votes from a majority of nodes, it becomes the new leader. If multiple candidates start an election simultaneously, they may split the vote, leading to a new election timeout and another round of voting until a leader is elected.
- Raft ensures that only one leader can be elected at a time by requiring candidates to receive votes from a majority of nodes in the cluster. This means that even if multiple candidates start an election simultaneously, only one will receive the necessary votes to become the leader, while the others will fail and return to the follower state. This mechanism prevents split-brain scenarios and ensures that there is always a single source of truth for the cluster's state.
- Raft also includes a mechanism for handling network partitions. If a leader becomes isolated from the majority of nodes, it will eventually lose its leadership status as followers will not receive heartbeats and will start new elections. This allows the cluster to continue functioning even in the presence of network issues, as a new leader can be elected from the remaining nodes that are still connected.
- When the network comes back, the old leader will recognize that it is no longer the leader and will step down to become a follower, ensuring that there is no conflict between the old and new leaders. This process helps maintain the consistency and availability of the cluster even in the face of failures and network partitions.

## Log Replication: