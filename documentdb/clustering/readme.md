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
