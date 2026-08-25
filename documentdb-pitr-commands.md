# DocumentDB PITR — Commands Only

Base backup with **`pg_basebackup`** (the same command KubeDB Postgres uses), WAL with **wal-g**.
Two stock images, nothing to build. Run top to bottom.

Verified end to end on 2026-08-25 in namespace `ddb-pgbb`, KubeDB `v2026.8.14-rc.0`.

---

## 1. Variables (run once per terminal)

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
NS=ddb-hands
```

---

## 2. Namespace, DocumentDB, MinIO, workspace

```bash
kubectl create ns $NS

kubectl apply -f - <<EOF
apiVersion: kubedb.com/v1alpha2
kind: DocumentDB
metadata: {name: docdb, namespace: $NS}
spec:
  version: 'pg17-0.109.0'
  replicas: 1
  storageType: Durable
  sslMode: disable
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: local-path
    resources: {requests: {storage: 5Gi}}
  deletionPolicy: Halt
---
apiVersion: v1
kind: Secret
metadata: {name: minio-creds, namespace: $NS}
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin123
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: minio-data, namespace: $NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources: {requests: {storage: 10Gi}}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: backup-workspace, namespace: $NS}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources: {requests: {storage: 10Gi}}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: minio, namespace: $NS}
spec:
  replicas: 1
  selector: {matchLabels: {app: minio}}
  template:
    metadata: {labels: {app: minio}}
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - {name: MINIO_ROOT_USER,     value: minioadmin}
        - {name: MINIO_ROOT_PASSWORD, value: minioadmin123}
        ports:
        - {containerPort: 9000}
        - {containerPort: 9001}
        volumeMounts:
        - {name: data, mountPath: /data}
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: minio-data}
---
apiVersion: v1
kind: Service
metadata: {name: minio, namespace: $NS}
spec:
  selector: {app: minio}
  ports:
  - {name: api,     port: 9000, targetPort: 9000}
  - {name: console, port: 9001, targetPort: 9001}
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Ready documentdb/docdb -n $NS --timeout=600s
kubectl wait --for=condition=Available deploy/minio -n $NS --timeout=300s
```

---

## 3. Tools pod — two containers, one shared workspace

No stock image has both a Postgres client and an S3 client, so use one of each and share `/work`.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: backup-tools, namespace: $NS}
spec:
  containers:
  - name: pg
    image: ghcr.io/kubedb/postgres-archiver:v0.27.0_17.2-bookworm
    securityContext: {runAsUser: 1000}
    command: ["sleep","infinity"]
    env:
    - {name: USER,                    value: "postgres"}
    - {name: WALG_S3_PREFIX,          value: "s3://documentdb-backup/$NS/docdb"}
    - {name: AWS_ENDPOINT,            value: "http://minio.$NS.svc:9000"}
    - {name: AWS_S3_FORCE_PATH_STYLE, value: "true"}
    - {name: AWS_REGION,              value: "us-east-1"}
    - {name: PGHOST,                  value: "docdb.$NS.svc"}
    - {name: PGPORT,                  value: "9712"}
    - {name: PGDATABASE,              value: "postgres"}
    - name: PGUSER
      valueFrom: {secretKeyRef: {name: docdb-admin-auth, key: username}}
    - name: PGPASSWORD
      valueFrom: {secretKeyRef: {name: docdb-admin-auth, key: password}}
    envFrom:
    - secretRef: {name: minio-creds}
    volumeMounts:
    - {name: data, mountPath: /var/pv}
    - {name: work, mountPath: /work}
  - name: mc
    image: minio/mc:latest
    command: ["sleep","infinity"]
    env:
    - {name: HOME,          value: "/work"}
    - {name: MC_HOST_local, value: "http://minioadmin:minioadmin123@minio.$NS.svc:9000"}
    volumeMounts:
    - {name: work, mountPath: /work}
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: data-docdb-0}
  - name: work
    persistentVolumeClaim: {claimName: backup-workspace}
EOF

kubectl wait --for=condition=Ready pod/backup-tools -n $NS --timeout=300s
kubectl exec -n $NS backup-tools -c mc -- mc mb --ignore-existing local/documentdb-backup
```

---

## 4. psql wrapper

```bash
APW=$(kubectl get secret docdb-admin-auth -n $NS -o jsonpath='{.data.password}' | base64 -d)
PSQL="kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD=$APW psql -q -U documentdb -p 9712"
```

---

## 5. Enable WAL archiving

```bash
kubectl exec -n $NS docdb-0 -c documentdb -- mkdir -p /var/pv/wal_archive/archive_status

$PSQL -d postgres -c "ALTER SYSTEM SET archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f';"
$PSQL -d postgres -c "ALTER SYSTEM SET archive_timeout = '60s';"
$PSQL -d postgres -Atc "SELECT pg_reload_conf();"
$PSQL -d postgres -Atc "select name||' = '||setting from pg_settings where name in ('archive_mode','archive_command');"
```

---

## 6. Create data (before base backup)

```bash
$PSQL -d postgres -c "CREATE DATABASE pitrdemo;"
$PSQL -d pitrdemo -c "CREATE TABLE t1 (id int primary key, phase text, note text, created timestamptz default now());"
$PSQL -d pitrdemo -c "INSERT INTO t1 (id,phase,note) SELECT g,'before-basebackup','row-'||g FROM generate_series(1,500) g;"
$PSQL -d pitrdemo -Atc "select 'rows='||count(*) from t1;"
```

```
rows=500
```

---

## 7. Base backup — pg_basebackup, then upload

**7a. Write the tar to the workspace** (`-D - -F t -X fetch -c fast` are KubeDB's exact flags —
`-X fetch` is required, because `-X stream` cannot write a tar to stdout):

```bash
kubectl exec -n $NS backup-tools -c pg -- bash -c '
  rm -rf /work/base && mkdir -p /work/base
  pg_basebackup -D /work/base -F t -X fetch -c fast -P
  ls -la /work/base/'
```

```
56962/56962 kB (100%), 1/1 tablespace
-rw------- 1 1000 root   189587 backup_manifest
-rw------- 1 1000 root 58329600 base.tar
```

**7b. Verify the tar, then upload:**

```bash
kubectl exec -n $NS backup-tools -c pg -- bash -c \
  'tar -tf /work/base/base.tar >/dev/null 2>&1 && echo "tar OK: $(tar -tf /work/base/base.tar | wc -l) entries" || echo "TAR CORRUPT"'

kubectl exec -n $NS backup-tools -c mc -- \
  mc cp /work/base/base.tar /work/base/backup_manifest local/documentdb-backup/$NS/docdb/base/

kubectl exec -n $NS backup-tools -c mc -- mc ls -r local/documentdb-backup/
```

```
tar OK: 1354 entries
[…] 185KiB  ddb-pgbb/docdb/base/backup_manifest
[…]  56MiB  ddb-pgbb/docdb/base/base.tar
```

> **Do not pipe `kubectl exec … pg_basebackup | kubectl exec -i … mc pipe`.** It looks elegant and it
> silently corrupts: at ~58 MB the stream died with
> `websocket: close 1006 (abnormal closure): unexpected EOF`, `mc` reported success and exited 0, and
> the object in the bucket failed `tar -tf` with `Unexpected EOF in archive`. Always land the tar on
> a volume, verify it, then upload.
>
> `tar -tf … >/dev/null` (checking the **exit code**) is the test that catches this. Counting entries
> does not — the truncated tar listed the same 1354 entries before erroring.

---

## 8. More data (WAL only) + recovery target

```bash
$PSQL -d pitrdemo -c "INSERT INTO t1 (id,phase,note) SELECT g,'after-basebackup','row-'||g FROM generate_series(501,800) g;"
$PSQL -d pitrdemo -Atc "select 'total='||count(*)||'  before='||count(*) filter (where phase='before-basebackup')||'  after='||count(*) filter (where phase='after-basebackup') from t1;"
$PSQL -d postgres -Atc "SELECT pg_switch_wal();"
sleep 4

T1=$($PSQL -d postgres -Atc "SELECT now();" | tr -d '\r')
echo "T1 = $T1"
echo "$T1" > /tmp/T1.txt
sleep 4
```

```
total=800  before=500  after=300
T1 = 2026-08-25 08:13:43.906328+00
```

---

## 9. Delete all data (the disaster)

```bash
$PSQL -d pitrdemo -c "DELETE FROM t1;"
$PSQL -d pitrdemo -Atc "select 'rows after DELETE = '||count(*) from t1;"
$PSQL -d postgres -Atc "SELECT pg_switch_wal();"
sleep 5
```

```
rows after DELETE = 0
```

---

## 10. Ship WAL → MinIO

```bash
kubectl exec -n $NS backup-tools -c pg -- bash -c '
  shopt -s nullglob; n=0
  for f in /var/pv/wal_archive/0*; do
    [ -f "$f" ] || continue
    if wal-g wal-push "$f" >/dev/null 2>&1; then echo "pushed: $(basename $f)"; rm -f "$f"; n=$((n+1)); fi
  done
  echo "shipped $n"'
```

```
pushed: 000000010000000000000002
pushed: 000000010000000000000003
pushed: 000000010000000000000003.00000028.backup
pushed: 000000010000000000000004
pushed: 000000010000000000000005
shipped 5
```

---

## 11. Save secrets, stop the database

```bash
mkdir -p ~/docdb-restore
kubectl get secret docdb-auth       -n $NS -o yaml > ~/docdb-restore/docdb-auth.yaml
kubectl get secret docdb-admin-auth -n $NS -o yaml > ~/docdb-restore/docdb-admin-auth.yaml

kubectl delete documentdb docdb -n $NS --wait=false
sleep 5
kubectl patch documentdb docdb -n $NS --type=merge -p '{"metadata":{"finalizers":null}}'

until ! kubectl get pod docdb-0 -n $NS >/dev/null 2>&1; do sleep 5; done
echo "docdb-0 gone"
kubectl get pvc data-docdb-0 -n $NS
```

---

## 12. Restore the base backup into PGDATA

```bash
kubectl exec -n $NS backup-tools -c mc -- sh -c \
  "rm -rf /work/restore && mkdir -p /work/restore && mc cp local/documentdb-backup/$NS/docdb/base/base.tar /work/restore/base.tar"

kubectl exec -n $NS backup-tools -c pg -- bash -c '
  set -e
  tar -tf /work/restore/base.tar >/dev/null || { echo "TAR CORRUPT - abort"; exit 1; }
  echo "tar OK"
  export PGDATA=/var/pv/data
  rm -rf $PGDATA; mkdir -p $PGDATA; chmod 700 $PGDATA
  tar -xf /work/restore/base.tar -C $PGDATA
  echo "extracted: $(du -sh $PGDATA | cut -f1)"
  echo "backup_label present: $([ -f $PGDATA/backup_label ] && echo yes || echo NO)"'
```

```
tar OK
extracted: 56M
backup_label present: yes
```

> `backup_label` is what tells Postgres this is a base backup needing recovery, and which WAL segment
> to start replaying from. It comes inside the tar — nothing extra to track.

---

## 13. Stage every WAL segment

```bash
SEGS=$(kubectl exec -n $NS backup-tools -c mc -- mc ls local/documentdb-backup/$NS/docdb/wal_005/ 2>/dev/null \
        | awk '{print $NF}' | sed 's/\.lz4$//' | sort)
echo "$SEGS"

kubectl exec -n $NS backup-tools -c pg -- bash -c "
  rm -rf /var/pv/wal_restore; mkdir -p /var/pv/wal_restore
  for f in $(echo $SEGS | tr '\n' ' '); do
    wal-g wal-fetch \"\$f\" /var/pv/wal_restore/\"\$f\" >/dev/null 2>&1 && echo \"staged \$f\" || echo \"FAILED \$f\"
  done
  echo \"staged \$(ls /var/pv/wal_restore | wc -l) files\""
```

```
staged 5 files
```

---

## 14. Write recovery config

```bash
T1=$(cat /tmp/T1.txt)

kubectl exec -n $NS backup-tools -c pg -- bash -c "
  export PGDATA=/var/pv/data
  cat >> \$PGDATA/postgresql.auto.conf <<EOC
restore_command = 'cp /var/pv/wal_restore/%f %p'
recovery_target_time = '$T1'
recovery_target_action = 'promote'
EOC
  touch \$PGDATA/recovery.signal
  cat \$PGDATA/postgresql.auto.conf"
```

```
archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f'
archive_timeout = '60s'
restore_command = 'cp /var/pv/wal_restore/%f %p'
recovery_target_time = '2026-08-25 08:13:43.906328+00'
recovery_target_action = 'promote'
```

---

## 15. Restore secrets + restart the database

```bash
kubectl apply -f ~/docdb-restore/docdb-auth.yaml
kubectl apply -f ~/docdb-restore/docdb-admin-auth.yaml

kubectl apply -f - <<EOF
apiVersion: kubedb.com/v1alpha2
kind: DocumentDB
metadata: {name: docdb, namespace: $NS}
spec:
  version: 'pg17-0.109.0'
  replicas: 1
  storageType: Durable
  sslMode: disable
  authSecret: {name: docdb-auth}
  adminAuthSecret: {name: docdb-admin-auth}
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: local-path
    resources: {requests: {storage: 5Gi}}
  deletionPolicy: Halt
EOF

kubectl wait --for=condition=Ready pod/docdb-0 -n $NS --timeout=600s
```

---

## 16. Verify

```bash
APW=$(kubectl get secret docdb-admin-auth -n $NS -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD="$APW" psql -U documentdb -p 9712 -d pitrdemo -c \
  "select phase, min(id) id_from, max(id) id_to, count(*) from t1 group by phase order by 1;"

kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD="$APW" psql -q -U documentdb -p 9712 -d postgres -Atc \
  "select 'timeline = '||(select timeline_id from pg_control_checkpoint()) union all select 'in_recovery = '||pg_is_in_recovery();"

kubectl get pod docdb-0 -n $NS -o jsonpath='restarts={.status.containerStatuses[0].restartCount}{"\n"}'

kubectl exec -n $NS backup-tools -c pg -- grep -E \
  'restored log file|point-in-time|recovery stopping|selected new timeline|archive recovery complete' \
  /var/pv/data/pglog.log | tail
```

```
       phase       | id_from | id_to | count
-------------------+---------+-------+-------
 after-basebackup  |     501 |   800 |   300
 before-basebackup |       1 |   500 |   500

timeline = 2
in_recovery = false
restarts=0

LOG:  restored log file "000000010000000000000003" from archive
LOG:  starting point-in-time recovery to 2026-08-25 08:13:43.906328+00
LOG:  restored log file "000000010000000000000004" from archive
LOG:  restored log file "000000010000000000000005" from archive
LOG:  recovery stopping before commit of transaction 1230, time 2026-08-25 08:13:44.563422+00
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
```

**800 rows** — the 300 that existed only in WAL were replayed onto the base backup, by the database's
own Postgres. The DocumentDB pod never had wal-g.

---

## 17. Teardown

```bash
kubectl delete pod backup-tools -n $NS --ignore-not-found
kubectl delete documentdb docdb -n $NS --ignore-not-found
kubectl patch documentdb docdb -n $NS --type=merge -p '{"metadata":{"finalizers":null}}' 2>/dev/null
kubectl delete ns $NS
```

---

## Flags you cannot drop

| Thing                                                           | Why                                                                            |
| --------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `pg_basebackup -X fetch`                                      | `-X stream` (the default) cannot write a tar; KubeDB injects this too        |
| `tar -tf … >/dev/null` before upload                         | the only reliable corruption check — entry count does not catch truncation    |
| land the tar on a volume, never`kubectl exec │ kubectl exec` | the websocket drops mid-stream and`mc` still exits 0                         |
| `USER=postgres` on the pg container                           | wal-g fails with`user: Current requires cgo or $USER set in environment`     |
| `PGPASSWORD` via `secretKeyRef`                             | the secret's keys are`username`/`password`, which libpq ignores            |
| `psql -q`                                                     | the image's`~/.psqlrc` echoes `SET` lines and corrupts `-Atc` output     |
| `psql -c "…"` not heredoc                                    | `kubectl exec` without `-i` discards stdin                                 |
| `-c documentdb` on DB exec, `-c pg`/`-c mc` on tools exec | multi-container pods                                                           |
| `-d postgres` / `-d pitrdemo`                               | the default db`documentdb` does not exist                                    |
| `-p 9712`                                                     | not 5432                                                                       |
| `postgresql.auto.conf` not `postgresql.conf`                | startup overwrites`postgresql.conf`; `auto.conf` survives and is read last |
| `touch recovery.signal`                                       | without it nothing recovers                                                    |
| `recovery_target_action = 'promote'`                          | otherwise it stays read-only                                                   |
| `deletionPolicy: Halt`                                        | `WipeOut` destroys the PVC you restore into                                  |
| save the secrets before deleting the CR                         | `Halt` keeps the PVC but **deletes the Secrets**                       |
| `kubectl patch … finalizers:null`                            | deletion hangs otherwise                                                       |
| stage WAL from`mc ls`, not `wal-g wal-show`                 | wal-show parsing silently skips segments                                       |

Expected and harmless: `ERROR: cannot execute ALTER ROLE in a read-only transaction` during startup
(the DB is still replaying; `start.sh` has no `set -e` and later runs `pg_ctl promote`), and
`ERROR: … archive_status: no such file` from `wal-push` (exit code is 0).
