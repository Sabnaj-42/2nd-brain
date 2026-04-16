## To see the postgres role name and roles attributes
```bash
psql -h localhost -p 9712 -U default_user -d postgres -c "\du"
#output:
#                                     List of roles
#         Role name         |                         Attributes                         
#---------------------------+------------------------------------------------------------
# default_user              | 
# docdb_admin               | 
# documentdb                | Superuser, Create role, Create DB, Replication, Bypass RLS
# documentdb_admin_role     | Cannot login
# documentdb_bg_worker_role | 
# documentdb_readonly_role  | Cannot login

```
## Raft consensus algorithm
- Raft is a consensus algorithm designed to manage a replicated log across a cluster of servers.
- It ensures that all servers in the cluster agree on the same sequence of log entries.
- Raft achieves consensus through a leader-follower model, where one server is elected as the leader and the others are followers.
- The leader is responsible for handling client requests, appending log entries, and replicating them to the followers.

## Independent components:
1. Leader Election
2. Log Replication
3. Safety
4. Membership Changes

