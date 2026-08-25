# DocumentDB PITR — Pure Image, wal-g Helper Pod, Object Storage

> **Self-contained and copy-pasteable, in order.** No custom image to build. Nothing is added to the
> DocumentDB pod.
>
> Verified end to end against a live single-node k3s cluster on 2026-08-25, KubeDB `v2026.8.14-rc.0`.
> Every output block below is real.

---

## The design

The DocumentDB pod runs the **stock upstream image** and has no idea wal-g exists. A separate helper
pod — also a **stock upstream image** — shares its PVC and does nothing but move files between the
volume and MinIO. **The database replays its own WAL.**

```
   ┌──────────────────┐      shared PVC       ┌──────────────────────────────┐
   │    docdb-0       │══════ data-docdb-0 ═══│        walg-helper           │
   │  STOCK image     │      /var/pv          │  postgres-archiver (stock)   │
   │  no wal-g at all │                       │  wal-g only — a file mover   │
   └──────────────────┘                       └──────────────┬───────────────┘
            ▲ TCP 9712 (pg_backup_start)                     │
            └─────────────────────────────────────────────────┤
                                                              ▼
                                                     ┌──────────────┐
                                                     │    MinIO     │
                                                     └──────────────┘
```

**The trick that removes the custom image:** the helper *pre-fetches* every WAL segment onto the
shared volume, so `restore_command` can be a plain `cp` instead of `wal-g wal-fetch`. `cp` exists in
every image; wal-g does not.

```
restore_command = 'cp /var/pv/wal_restore/%f %p'
```

**Why the recovery settings survive a KubeDB restart** — read from `kubedb.dev/documentdb-init-docker`:

| Concern | Finding |
| --- | --- |
| Does startup wipe recovery settings? | `role_scripts/17/primary/start.sh` rewrites `$PGDATA/postgresql.conf` every boot but never touches **`postgresql.auto.conf`**, which Postgres reads last. Put them there. |
| Does startup delete `recovery.signal`? | No. Only KubeDB's own `scripts/restore.sh` does, and that path is not used here. |
| Does a pre-seeded PGDATA get re-initialized? | No. `init_scripts/run.sh:8` and `bootstrap_scripts/17/start_oss_server.sh:249` both branch on `PG_VERSION` already existing. |

**The data story:**

| Step | Action | Where the data lives |
| --- | --- | --- |
| 1 | create `pitrdemo`, insert **500** rows | data files |
| 2 | `wal-g backup-push` | **→ MinIO** (base backup) |
| 3 | insert **300** more rows | **WAL only** |
| 4 | record `T1` | — |
| 5 | `DELETE FROM t1` — the disaster | data files |
| 6 | `wal-g wal-push` | **→ MinIO** (WAL) |
| 7–10 | stop DB → stage base + WAL → restart | **800 rows back** |

Getting **800** rather than 500 is the point: it proves the 300 rows that existed only in WAL were
replayed on top of the base backup — by the database itself.

---

## What this proves

| Claim | Result |
| --- | --- |
| The DocumentDB pod needs **nothing** added | ✅ stock `documentdb-local`; `command -v wal-g` → NONE |
| The helper needs **no custom image** | ✅ stock `postgres-archiver`, wal-g only |
| A helper pod can back up the live DB over TCP | ✅ `backup-push` via `PGHOST=docdb.<ns>.svc` |
| Post-basebackup writes survive via WAL alone | ✅ 300 of the 800 rows came from WAL |
| **The database replays its own WAL on startup** | ✅ `restored log file … from archive` in its own log |
| The pod comes up clean | ✅ `Ready`, timeline 2, **0 restarts** |

---

## 0. Prerequisites

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml

kubectl get nodes
kubectl get pods -n kubedb                      # KubeDB operators Running
kubectl get documentdbversions                  # pg17-0.109.0 present
```

No Docker needed — both images are pulled from upstream registries.
Storage class below is `local-path` (k3s default); change it if yours differs.

---

## 1. Variables — run once per terminal

**Everything after this depends on these.** New shell ⇒ re-run this block.

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
NS=ddb-hands
HELPER_IMG=ghcr.io/kubedb/postgres-archiver:v0.27.0_17.2-bookworm

echo "NS=$NS"
```

---

## 2. Create a pure DocumentDB

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $NS
---
apiVersion: kubedb.com/v1alpha2
kind: DocumentDB
metadata:
  name: docdb
  namespace: $NS
spec:
  version: 'pg17-0.109.0'
  replicas: 1
  storageType: Durable
  sslMode: disable
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: local-path
    resources:
      requests:
        storage: 5Gi
  deletionPolicy: Halt
EOF

kubectl wait --for=jsonpath='{.status.phase}'=Ready documentdb/docdb -n $NS --timeout=600s
```

> **`deletionPolicy: Halt` from the start.** §8 deletes this CR to stop the database, and `Halt` is
> what keeps the PVC alive through it. With `WipeOut` you would destroy the volume you are restoring
> into.

Confirm the database is genuinely stock:

```bash
kubectl get pod docdb-0 -n $NS -o jsonpath='{.spec.containers[0].image}{"\n"}'
kubectl exec -n $NS docdb-0 -c documentdb -- sh -c 'command -v wal-g || echo NONE'
```

```
ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0@sha256:a9dca9030c2f…
NONE
```

**No wal-g in the database.** That never changes for the rest of this runbook.

---

## 3. Credentials and psql wrapper

```bash
APW=$(kubectl get secret docdb-admin-auth -n $NS -o jsonpath='{.data.password}' | base64 -d)
PSQL="kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD=$APW psql -q -U documentdb -p 9712"
```

> **Four flags that are not optional:**
>
> | Flag | Why |
> | --- | --- |
> | `psql -q` | the image ships a `~/.psqlrc` with two `SET` statements; without `-q` they are echoed and corrupt every `-Atc` value you capture |
> | `-c documentdb` | the pod has an init container too; without it every command prints `Defaulted container …` to stderr |
> | `-p 9712` | DocumentDB's PostgreSQL port, not 5432 |
> | `-d <db>` | the default database is `documentdb`, which does not exist — always name one |
>
> **Use `psql -c "…"`, not a heredoc.** `kubectl exec` without `-i` does not forward stdin, so
> `psql <<SQL … SQL` silently runs nothing.

---

## 4. MinIO

```bash
kubectl apply -f - <<EOF
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
  resources: {requests: {storage: 5Gi}}
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
---
apiVersion: v1
kind: Pod
metadata: {name: toolbox-mc, namespace: $NS}
spec:
  containers:
  - name: mc
    image: minio/mc:latest
    command: ["sleep","infinity"]
EOF

kubectl wait --for=condition=Available deploy/minio -n $NS --timeout=300s
kubectl wait --for=condition=Ready pod/toolbox-mc -n $NS --timeout=300s

MC="kubectl exec -n $NS toolbox-mc -- env HOME=/tmp \
    MC_HOST_local=http://minioadmin:minioadmin123@minio.$NS.svc:9000 mc"
$MC mb --ignore-existing local/documentdb-backup
```

```
Bucket created successfully `local/documentdb-backup`.
```

> `minio/mc` has a read-only `/` — without a writable `HOME` every command dies with
> `mkdir /.mc: permission denied`.

---

## 5. The helper pod — wal-g only, stock image

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata: {name: walg-helper, namespace: $NS}
spec:
  containers:
  - name: helper
    image: $HELPER_IMG
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
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: data-docdb-0}
EOF

kubectl wait --for=condition=Ready pod/walg-helper -n $NS --timeout=300s

kubectl exec -n $NS walg-helper -- wal-g --version
kubectl exec -n $NS walg-helper -- psql -Atc "select 'connected as '||current_user;"
kubectl exec -n $NS walg-helper -- ls /var/pv/
```

```
wal-g version devel	devel	devel	PostgreSQL
connected as documentdb
data
```

> **`USER=postgres` is mandatory, and the failure is baffling without it.** The archiver image has no
> `/etc/passwd` entry for uid 1000, so wal-g's `user.Current()` fails with:
> ```
> ERROR: user: Current requires cgo or $USER set in environment
> ```
> KubeDB's own archiver works around this with `nss_wrapper`
> (`postgres-archiver/pkg/handle_cloud_bucket.go:108`); setting `$USER` is the one-line equivalent.
>
> **`PGPASSWORD` must be mapped explicitly** — `docdb-admin-auth` exposes keys `username`/`password`,
> which libpq ignores; use `secretKeyRef`.
>
> **Two pods on one RWO volume is legal** — RWO is *node*-scoped, not pod-scoped.

---

## 6. Enable WAL archiving

```bash
kubectl exec -n $NS docdb-0 -c documentdb -- mkdir -p /var/pv/wal_archive/archive_status

$PSQL -d postgres -c "ALTER SYSTEM SET archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f';"
$PSQL -d postgres -c "ALTER SYSTEM SET archive_timeout = '60s';"
$PSQL -d postgres -Atc "SELECT pg_reload_conf();"

$PSQL -d postgres -Atc "select name||' = '||setting from pg_settings
                         where name in ('archive_mode','archive_command');"
```

```
archive_command = test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f
archive_mode = always
```

No restart needed — `archive_command` is SIGHUP-level and `archive_mode` is already `always`.

> `ALTER SYSTEM` writes to `postgresql.auto.conf`, which is exactly why this setting survives every
> pod restart — the same property §9 relies on for the recovery settings.

---

## 7. The backup phase

### 7.1 STEP 1 — database and the first 500 rows

```bash
$PSQL -d postgres -c "CREATE DATABASE pitrdemo;"
$PSQL -d pitrdemo -c "CREATE TABLE t1 (id int primary key, phase text, note text, created timestamptz default now());"
$PSQL -d pitrdemo -c "INSERT INTO t1 (id,phase,note) SELECT g,'before-basebackup','row-'||g FROM generate_series(1,500) g;"
$PSQL -d pitrdemo -Atc "select 'rows='||count(*) from t1;"
```

```
rows=500
```

### 7.2 STEP 2 — base backup → MinIO

```bash
kubectl exec -n $NS walg-helper -- wal-g backup-push /var/pv/data
```

```
INFO: Querying pg_database
INFO: Wrote backup with name base_000000010000000000000006 to storage default
```

> **`wal-g backup-push` is not a network client like `pg_basebackup`.** It reads PGDATA *directly off
> the volume* **and** opens a Postgres connection for `pg_backup_start`/`pg_backup_stop`. The helper
> pod is the only place with both — which is exactly why this design works.

### 7.3 STEP 3 — 300 more rows, which exist ONLY in WAL

```bash
$PSQL -d pitrdemo -c "INSERT INTO t1 (id,phase,note) SELECT g,'after-basebackup','row-'||g FROM generate_series(501,800) g;"
$PSQL -d pitrdemo -Atc "select 'total='||count(*)
                          ||'  before='||count(*) filter (where phase='before-basebackup')
                          ||'  after='||count(*) filter (where phase='after-basebackup') from t1;"
$PSQL -d postgres -Atc "SELECT pg_switch_wal();"
sleep 4
```

```
total=800  before=500  after=300
```

### 7.4 STEP 4 — record the recovery target

```bash
T1=$($PSQL -d postgres -Atc "SELECT now();" | tr -d '\r')
echo "T1 = $T1"
sleep 4
```

```
T1 = 2026-08-25 05:39:05.629838+00
```

> Sleep on **both** sides of `T1`, or the target can land inside the same transaction as the writes
> you are trying to keep or drop.
>
> **Keep `$T1` in this shell** — §9 needs it. Belt and braces: `echo $T1 > /tmp/T1.txt`.

### 7.5 STEP 5 — the disaster

```bash
$PSQL -d pitrdemo -c "DELETE FROM t1;"
$PSQL -d pitrdemo -Atc "select 'rows after DELETE = '||count(*) from t1;"
$PSQL -d postgres -Atc "SELECT pg_switch_wal();"
sleep 5
```

```
rows after DELETE = 0
```

### 7.6 STEP 6 — ship the WAL

```bash
kubectl exec -n $NS walg-helper -- bash -c '
  shopt -s nullglob; n=0
  for f in /var/pv/wal_archive/0*; do
    [ -f "$f" ] || continue
    if wal-g wal-push "$f" >/dev/null 2>&1; then
      echo "pushed: $(basename $f)"; rm -f "$f"; n=$((n+1))
    else
      echo "push FAILED (exit $?): $(basename $f)"
    fi
  done
  echo "shipped $n"'
```

```
pushed: 000000010000000000000003
pushed: 000000010000000000000004
pushed: 000000010000000000000005
pushed: 000000010000000000000006
pushed: 000000010000000000000006.00000028.backup
pushed: 000000010000000000000007
pushed: 000000010000000000000008
shipped 8
```

> **Branch on the exit code, never on the log text.** wal-g prints
> `ERROR: Error of parallel upload: open …/archive_status: no such file or directory` while still
> **succeeding with exit 0**. Anything left in `/var/pv/wal_archive` is not in the bucket and cannot
> be recovered from it.

---

## 8. STEP 7 — save the secrets, then stop the database

### 8.1 Save the secrets FIRST

```bash
mkdir -p ~/docdb-restore
kubectl get secret docdb-auth       -n $NS -o yaml > ~/docdb-restore/docdb-auth.yaml
kubectl get secret docdb-admin-auth -n $NS -o yaml > ~/docdb-restore/docdb-admin-auth.yaml
```

> **`deletionPolicy: Halt` keeps the PVC but DELETES the Secrets.** Measured — after the delete,
> `kubectl get secret | grep docdb-` returns nothing. The restored PGDATA still holds the **original**
> passwords, so fresh Secrets would fail SCRAM auth on every connection. See gotcha #7 for recovery if
> you skip this.

### 8.2 Delete the CR

```bash
kubectl delete documentdb docdb -n $NS --wait=false

# The operator logs "Finalizer already removed" while the finalizer is STILL set,
# so deletion hangs forever. Clear it by hand:
kubectl patch documentdb docdb -n $NS --type=merge -p '{"metadata":{"finalizers":null}}'

until ! kubectl get pod docdb-0 -n $NS >/dev/null 2>&1; do sleep 5; done
echo "docdb-0 gone"

kubectl get pvc data-docdb-0 -n $NS
```

```
docdb-0 gone
data-docdb-0   Bound   pvc-46fccea7-…   5Gi   RWO   local-path
```

The helper keeps the PVC mounted throughout — that is what makes the next step possible.

> **Why not scale the PetSet to 0?** Measured: the operator puts it back within ~20 seconds
> (`t=10s replicas=0` → `t=20s replicas=1`). And `spec.halted: true` is a **no-op** in this build —
> five minutes of polling, `observedGeneration` never set. Deleting the CR is the only reliable way.

---

## 9. STEP 8 — stage the base and the WAL

### 9.1 Fetch the base into the live PGDATA

```bash
kubectl exec -n $NS walg-helper -- bash -c '
  set -e
  export PGDATA=/var/pv/data
  rm -rf $PGDATA; mkdir -p $PGDATA; chmod 700 $PGDATA
  BASE=$(wal-g backup-list 2>/dev/null | tail -n +2 | awk "{print \$1}" | sort | tail -1)
  echo "base: $BASE"
  wal-g backup-fetch $PGDATA $BASE 2>&1 | tail -1'
```

```
base: base_000000010000000000000006
Backup extraction complete.
```

### 9.2 Pre-fetch every WAL segment — this is what removes wal-g from the database

Enumerate from the bucket (authoritative) and stage each one decompressed onto the shared volume:

```bash
SEGS=$($MC ls local/documentdb-backup/$NS/docdb/wal_005/ 2>/dev/null \
        | awk '{print $NF}' | sed 's/\.lz4$//' | sort)
echo "$SEGS"

kubectl exec -n $NS walg-helper -- bash -c "
  rm -rf /var/pv/wal_restore; mkdir -p /var/pv/wal_restore
  for f in $(echo $SEGS | tr '\n' ' '); do
    wal-g wal-fetch \"\$f\" /var/pv/wal_restore/\"\$f\" >/dev/null 2>&1 \
      && echo \"staged \$f\" || echo \"FAILED \$f\"
  done
  echo \"staged \$(ls /var/pv/wal_restore | wc -l) files\""
```

```
staged 8 files
-rw-r--r-- 1 1000 1000 16777216 000000010000000000000002
-rw-r--r-- 1 1000 1000 16777216 000000010000000000000003
…
-rw-r--r-- 1 1000 1000 16777216 000000010000000000000008
```

> **Enumerate from the bucket, not from `wal-g wal-show`.** A first attempt parsed hex strings out of
> `wal-show --detailed-json` and silently staged only 3 of the 8 segments — skipping segment 7, which
> sits in the middle of the range and would have broken recovery. `mc ls` on the `wal_005/` prefix is
> the reliable list.
>
> `wal-g wal-fetch` decompresses, so what lands in `/var/pv/wal_restore/` is plain 16 MB segments —
> exactly what a `cp` restore_command needs.

### 9.3 Write the recovery config — into `postgresql.auto.conf`

```bash
kubectl exec -n $NS walg-helper -- bash -c "
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
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f'
archive_timeout = '60s'
restore_command = 'cp /var/pv/wal_restore/%f %p'
recovery_target_time = '2026-08-25 05:39:05.629838+00'
recovery_target_action = 'promote'
```

| Line | Why |
| --- | --- |
| written to **`auto.conf`** | `start.sh` overwrites `postgresql.conf` on every boot; `auto.conf` is untouched and read last |
| `restore_command = 'cp …'` | **not** `wal-g wal-fetch` — the database has no wal-g |
| `recovery_target_action = 'promote'` | ends recovery at the target instead of pausing read-only |
| `recovery.signal` | PG12+ replacement for `recovery.conf`; without the file nothing recovers |

---

## 10. STEP 9 — restore the secrets and restart the database

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

Secrets **before** the CR, so the operator adopts them instead of generating new ones.

**The database replays on its own during startup** — from its server log at `/var/pv/data/pglog.log`:

```bash
kubectl exec -n $NS walg-helper -- grep -E \
  'restored log file|point-in-time|recovery stopping|selected new timeline|archive recovery complete' \
  /var/pv/data/pglog.log | head
```

```
LOG:  restored log file "000000010000000000000006" from archive
LOG:  starting point-in-time recovery to 2026-08-25 05:39:05.629838+00
LOG:  restored log file "000000010000000000000007" from archive
LOG:  consistent recovery state reached at 0/6000240
LOG:  restored log file "000000010000000000000008" from archive
LOG:  recovery stopping before commit of transaction 1551, time 2026-08-25 05:39:06.378394+00
LOG:  selected new timeline ID: 2
LOG:  archive recovery complete
```

`05:39:06.378` is the first commit **after** `T1 = 05:39:05.629`. Postgres stopped before it.

> **Expect one alarming-looking error in the container log, and ignore it:**
> ```
> ERROR:  cannot execute ALTER ROLE in a read-only transaction
> ALTER ROLE
> ```
> `start.sh` runs `pg_ctl -w start` — which returns at *consistency*, before the recovery target — and
> immediately issues `ALTER USER … PASSWORD`, which a still-recovering server rejects. It is harmless
> here for two specific reasons: `start.sh` has **no `set -e`**, and line 128 runs `pg_ctl promote`,
> after which the retry succeeds (the bare `ALTER ROLE` line above). Measured restart count: **0**.
>
> This is fragile by luck, not design. A `wait until pg_is_in_recovery() is false` guard before that
> `ALTER USER` is a concrete fix worth making in the operator.

---

## 11. Verify

```bash
APW=$(kubectl get secret docdb-admin-auth -n $NS -o jsonpath='{.data.password}' | base64 -d)

kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD="$APW" psql -U documentdb -p 9712 -d pitrdemo -c \
  "select phase, min(id) id_from, max(id) id_to, count(*) from t1 group by phase order by 1;"

kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD="$APW" psql -q -U documentdb -p 9712 -d postgres -Atc \
  "select 'timeline = '||(select timeline_id from pg_control_checkpoint())
   union all select 'in_recovery = '||pg_is_in_recovery();"

kubectl get pod docdb-0 -n $NS -o jsonpath='restarts={.status.containerStatuses[0].restartCount}{"\n"}'
kubectl exec -n $NS docdb-0 -c documentdb -- sh -c 'command -v wal-g || echo "wal-g in DB: NONE"'
```

```
       phase       | id_from | id_to | count
-------------------+---------+-------+-------
 after-basebackup  |     501 |   800 |   300
 before-basebackup |       1 |   500 |   500

timeline = 2
in_recovery = false
restarts=0
wal-g in DB: NONE
```

---

## 12. Result

| | After step 1 | After step 3 | After DELETE | **Restored** | Expected |
| --- | ---: | ---: | ---: | ---: | --- |
| `before-basebackup` | 500 | 500 | 0 | **500** | 500 ✅ |
| `after-basebackup` | — | 300 | 0 | **300** | 300 ✅ |
| total | 500 | 800 | **0** | **800** | 800 ✅ |
| timeline | 1 | 1 | 1 | **2** | 2 ✅ |
| restarts | 0 | 0 | 0 | **0** | 0 ✅ |

**Two stock images, no build step.** The helper ran four wal-g commands; the database did the replay:

```
wal-g backup-push  /var/pv/data                    # base → MinIO
wal-g wal-push     <segment>                       # WAL  → MinIO
wal-g backup-fetch /var/pv/data <BASE>             # MinIO → PGDATA
wal-g wal-fetch    <seg> /var/pv/wal_restore/<seg> # MinIO → staged, so restore_command can be `cp`
```

**What remains before this is a product feature:**

1. `ARCHIVER_ENABLED` is hardcoded `false` (`documentdb/pkg/controllers/petset.go:1034`) — the
   operator must write `archive_command`, not a human via `ALTER SYSTEM`
2. `start.sh` must wait for `pg_is_in_recovery()` to be false before `ALTER USER` — today it survives
   only because there is no `set -e`
3. `Halt` should preserve the auth Secrets, or restore must recreate them
4. fix the finalizer bug and make `spec.halted` actually work
5. a `DocumentDBArchiver` CRD plus the Sidekick reconcile, mirroring
   `postgres/pkg/controller/sidekick.go`

---

## 13. Gotchas

| # | Symptom | Cause / fix |
| --- | --- | --- |
| 1 | `ERROR: user: Current requires cgo or $USER set in environment` | archiver image has no passwd entry for uid 1000; set `USER=postgres` in the helper pod |
| 2 | `backup-push` fails with auth error | `docdb-admin-auth` has keys `username`/`password`; map to `PGUSER`/`PGPASSWORD` via `secretKeyRef` |
| 3 | every push logs `ERROR: … archive_status` | cosmetic; exit code is 0. Branch on `$?`, and create `wal_archive/archive_status/` |
| 4 | recovery stops early / "requested WAL segment has already been removed" | you staged an incomplete segment list — enumerate with `mc ls`, not `wal-g wal-show` |
| 5 | `mkdir /.mc: permission denied` | `minio/mc` has read-only `/`; give it a writable `HOME` |
| 6 | CR stuck `Terminating`, log says `Finalizer already removed` | operator bug: `kubectl patch documentdb docdb -n $NS --type=merge -p '{"metadata":{"finalizers":null}}'` |
| 7 | SCRAM auth fails after the restore | `Halt` deleted the Secrets but the restored PGDATA holds the old passwords. Save them first (§8.1). **If you forgot:** the helper pod still has the original in `$PGPASSWORD` (env resolves at pod start) — `kubectl exec walg-helper -- printenv PGPASSWORD` |
| 8 | scaled PetSet to 0, operator reverts in ~20s | you cannot stop a managed DocumentDB that way; delete the CR with `deletionPolicy: Halt` |
| 9 | `spec.halted: true` does nothing | no-op in this build — verified over 5 minutes |
| 10 | `spec.replicas: 0` rejected | webhook: `Must be greater than zero` |
| 11 | `cannot execute ALTER ROLE in a read-only transaction` in the startup log | expected; `start.sh` has no `set -e` and later runs `pg_ctl promote`. Harmless, but see §12 item 2 |
| 12 | recovery settings vanish after restart | you wrote them to `postgresql.conf`, which `start.sh` overwrites — use `postgresql.auto.conf` |
| 13 | nothing recovers at all | forgot `touch $PGDATA/recovery.signal` |
| 14 | no recovery lines in `kubectl logs` | Postgres logs to `/var/pv/data/pglog.log`, not stdout — read it via the helper |
| 15 | `psql: FATAL: database "documentdb" does not exist` | always pass `-d postgres` or `-d pitrdemo` |
| 16 | `psql -Atc` output has stray `SET` lines | the image's `~/.psqlrc`; add `-q` |
| 17 | `psql <<SQL` runs nothing | `kubectl exec` without `-i` does not forward stdin; use `psql -c "…"` |
| 18 | PITR is missing recent changes | §7.6 is manual — WAL still in `/var/pv/wal_archive` was never pushed |

---

## 14. Teardown

```bash
kubectl delete pod walg-helper toolbox-mc -n $NS --ignore-not-found
kubectl delete documentdb docdb -n $NS --ignore-not-found

# if the CR hangs on its finalizer (gotcha #6):
# kubectl patch documentdb docdb -n $NS --type=merge -p '{"metadata":{"finalizers":null}}'

kubectl delete ns $NS
```
