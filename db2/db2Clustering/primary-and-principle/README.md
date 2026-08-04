### Kind Load Image
```bash
➤ mkdir -p $HOME/kind-tmp
  export TMPDIR=$HOME/kind-tmp
  kind load docker-image ibmcom/db2:11.5.8.0

```

#### taking backup of db2 database in primary pod
```bash
db2 BACKUP DATABASE $db_name TO "/database/config/db2inst1/backup" compress
```

####   Copying backup file from pod to local machine
```bash
➤ kubectl cp demo/db2-2:/database/config/db2inst1/backup/ABC.0.db2inst1.DBPART000.20260217124604.001 /home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/DB2/db2Clustering/primary-and-principle/backup/ABC.0.db2inst1.DBPART000.20260217124604.001


```

###  Copying backup file from local machine to pod
```bash
➤ kubectl cp /home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/DB2/db2Clustering/primary-and-principle/backup/ABC.0.db2inst1.DBPART000.20260217124604.001 demo/db2-1:/database/config/db2inst1/backup/ABC.0.db2inst1.DBPART000.20260217124604.001

```

### Load db2 environment variables
```bash
. ~db2inst1/sqllib/db2profile
```