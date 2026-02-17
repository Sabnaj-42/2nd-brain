
db2 LIST DATABASE DIRECTORY # list databases
db2 CREATE DATABASE $db_name # (IF NOT EXISTS ANY db)

db2set DB2_STANDBY_ISO=UR
db2set DB2_HADR_ROS=ON
db_name=abc
host=db2-service-0.default.svc.cluster.local


db2 UPDATE DB CFG FOR $db_name USING LOGINDEXBUILD     ON
db2 UPDATE DB CFG FOR $db_name USING INDEXREC          RESTART
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_HOST   $host
db2 UPDATE DB CFG FOR $db_name USING HADR_LOCAL_SVC    55001
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_HOST  db2-service-1.default.svc.cluster.local
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_SVC   55002
db2 UPDATE DB CFG FOR $db_name USING HADR_REMOTE_INST  db2inst1
#db2 UPDATE DB CFG FOR $db_name USING HADR_TARGET_LIST  "db2-service-1.default.svc.cluster.local:55007"
db2 UPDATE DB CFG FOR $db_name USING HADR_SYNCMODE     NEARSYNC
db2 UPDATE DB CFG FOR $db_name USING HADR_REPLAY_DELAY 0
db2 UPDATE DB CFG FOR $db_name USING HADR_TIMEOUT      120
db2 UPDATE DB CFG FOR $db_name USING LOGARCHMETH1      "DISK:/database"

db2 BACKUP DATABASE $db_name TO "/database/config/db2inst1/backup" compress # I have use pipe to backup and restore database

db2 terminate

# Activate database again
db2 activate db $db_name


# ================================
# 4. Start HADR on primary
# ================================

# Start HADR (only after standby is fully configured and in PEER_SYNC mode)
# At first start HADR on all standby pod  and then start HADR on primary pod
db2 START HADR ON DB $db_name AS PRIMARY