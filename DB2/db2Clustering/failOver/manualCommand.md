### Primary Pod
```bash
db2 create db abc
db2set DB2_STANDBY_ISO=UR
db2set DB2_HADR_ROS=ON
db_name=abc

host=db2-2.my-db2-svc.demo.svc.cluster.local

db2 UPDATE DB CFG FOR $db_name USING LOGINDEXBUILD     ON
db2 UPDATE DB CFG FOR $db_name USING INDEXREC          RESTART
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_HOST   $host
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_SVC    55006
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_HOST  db2-1.my-db2-svc.demo.svc.cluster.local
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_SVC   55006
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_INST  db2inst1
db2 UPDATE DB CFG FOR $db_name USING HADR_SYNCMODE     NEARSYNC
db2 UPDATE DB CFG FOR $db_name USING HADR_REPLAY_DELAY 0
db2 UPDATE DB CFG FOR $db_name USING HADR_TIMEOUT      120
db2 UPDATE DB CFG FOR $db_name USING LOGARCHMETH1      "DISK:/database"
db2 UPDATE DB CFG FOR $db_name USING HADR_PEER_WINDOW 180


db2 UPDATE DB CFG FOR $db_name USING HADR_TARGET_LIST  "db2-1.my-db2-svc.demo.svc.cluster.local:55006|db2-0.my-db2-svc.demo.svc.cluster.local:55006"



#after starting hadr on standby
db2 terminate 
db2 activate db abc
db2 start hadr on db abc as primary
```

### Principal Standby Pod
```bash
db2set DB2_STANDBY_ISO=UR
db2set DB2_HADR_ROS=ON
db_name=abc

host=db2-1.my-db2-svc.demo.svc.cluster.local

db2 UPDATE DB CFG FOR $db_name USING LOGINDEXBUILD     ON
db2 UPDATE DB CFG FOR $db_name USING INDEXREC          RESTART
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_HOST   $host
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_SVC    55006
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_HOST  db2-2.my-db2-svc.demo.svc.cluster.local
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_SVC   55006
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_INST  db2inst1
db2 UPDATE DB CFG FOR $db_name USING HADR_SYNCMODE     NEARSYNC
db2 UPDATE DB CFG FOR $db_name USING HADR_REPLAY_DELAY 0
db2 UPDATE DB CFG FOR $db_name USING HADR_TIMEOUT      120
db2 UPDATE DB CFG FOR $db_name USING LOGARCHMETH1      "DISK:/database"
db2 UPDATE DB CFG FOR $db_name USING HADR_PEER_WINDOW 180



db2 UPDATE DB CFG FOR $db_name USING HADR_TARGET_LIST  "db2-0.my-db2-svc.demo.svc.cluster.local:55006|db2-2.my-db2-svc.demo.svc.cluster.local:55006"


db2 start hadr on db abc as standby
```

### Auxiliar Standby Pod
```bash
db2set DB2_STANDBY_ISO=UR
db2set DB2_HADR_ROS=ON
db_name=abc

host=db2-0.my-db2-svc.demo.svc.cluster.local

db2 UPDATE DB CFG FOR $db_name USING LOGINDEXBUILD     ON
db2 UPDATE DB CFG FOR $db_name USING INDEXREC          RESTART
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_HOST   $host
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_SVC    55006
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_HOST  db2-2.my-db2-svc.demo.svc.cluster.local
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_SVC   55006
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_INST  db2inst1
db2 UPDATE DB CFG FOR $db_name USING HADR_SYNCMODE     SUPERASYNC
db2 UPDATE DB CFG FOR $db_name USING HADR_REPLAY_DELAY 0
db2 UPDATE DB CFG FOR $db_name USING HADR_TIMEOUT      120
db2 UPDATE DB CFG FOR $db_name USING LOGARCHMETH1      "DISK:/database"
db2 UPDATE DB CFG FOR $db_name USING HADR_PEER_WINDOW 180



db2 UPDATE DB CFG FOR $db_name USING HADR_TARGET_LIST  "db2-1.my-db2-svc.demo.svc.cluster.local:55006|db2-2.my-db2-svc.demo.svc.cluster.local:55006"

db2 start hadr on db abc as standby
```

### backup restore 
```bash

mkdir /database/config/db2inst1/backup #in all pods
db2 BACKUP DATABASE $db_name TO "/database/config/db2inst1/backup" compress



 kubectl cp demo/db2-2:/database/config/db2inst1/backup/ABC.0.db2inst1.DBPART000.20260218105923.001 /home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/DB2/db2Clustering/primary-and-principle/backup/ABC.0.db2inst1.DBPART000.20260218105923.001



 kubectl cp /home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/DB2/db2Clustering/primary-and-principle/backup/ABC.0.db2inst1.DBPART000.20260218105923.001 demo/db2-0:/database/config/db2inst1/backup/ABC.0.db2inst1.DBPART000.20260218105923.001


db2 restore db abc from /database/config/db2inst1/backup/
```

### Takeover in principal standby
```bash
db2 deactivate db abc
db2 terminate
db2stop
db2start
db2 STOP HADR ON DATABASE abc
db2 activate db abc
db2 UPDATE DB CFG FOR $db_name USING HADR_TARGET_LIST  "db2-0.my-db2-svc.demo.svc.cluster.local:55006"
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_HOST  db2-0.my-db2-svc.demo.svc.cluster.local
db2 start hadr on db abc as primary
```

### How to activate primary pod db when it come back after down as primary (No takeover is done in standby):
```bash
db2 activate db abc
```

### What need to do when the failed primary come back(takeover is done in standby):
- stop hadr on standby
- drop the database in failed primary
- Take backup from the new primary
- Restore backup in the failed primary
- Run all configuration commands in it to make it standby
- Also add its hostname in new primary pod target lists