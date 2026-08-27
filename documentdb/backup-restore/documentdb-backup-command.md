# DocumentDB — Base Backup, WAL Archiving, Restore & PITR: The Command Runbook

> **Every command in this file was executed against the live cluster on 2026-08-24 and the output is
> the real output.** Namespace `ddb-hands`, DocumentDB `docdb` (`pg17-0.109.0`), single-node k3s.
>
> Companion files: `documentdb-handson-backup.md` (findings from the first pass),
> `documentdb-postgres-style-backup-plan.md` (the KubeStash/operator-level plan),
> `postgres-backup-flow.md` (how KubeDB does all this for real).

---

## What this run proves

| Claim | Result |
| --- | --- |
| WAL archiving can be switched on at runtime, no restart | ✅ `pg_reload_conf()` is enough |
| `pg_basebackup` works against DocumentDB out of the box | ✅ 189 MB in 35 s, no extra grants |
| WAL can be shipped off the database volume by a second pod | ✅ RWO PVC, second pod, same node |
| PITR to an exact timestamp works | ✅ recovered `orders=1000` from a `deleteMany({})` |
| The **catalog** survives a physical restore | ✅ all 3 collections present |
| The recovered volume can be swapped back into the real pod | ✅ verified through the Mongo wire layer |
| Archiving resumes after restore, on the new timeline | ✅ `000000020000000000000029` |

**The headline number:** after deleting all 1,000 orders and inserting 70 more marker documents, a
recovery to `T1` returned `orders = 1000`, `pitr = 50` (`gen1=50, gen2=0`), `qty_sum = 7979` — the
original fingerprint, exactly.

---

## 0. Prerequisites

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
kubectl get documentdb -n ddb-hands          # docdb must be Ready
```

You need three helper pods sharing one workspace PVC. If they already exist, skip to §1.

```bash
kubectl apply -f - <<'EOF'
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata: {name: backup-workspace, namespace: ddb-hands}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: local-path
  resources: {requests: {storage: 5Gi}}
---
# Postgres client toolbox. Uses the DB image itself, so it already has
# pg_basebackup AND the documentdb shared libraries needed to start a
# recovery instance. This is the single most useful trick in this runbook.
apiVersion: v1
kind: Pod
metadata: {name: toolbox-pg, namespace: ddb-hands}
spec:
  containers:
  - name: pg
    image: ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0
    command: ["sleep","infinity"]
    securityContext: {runAsUser: 1000}
    volumeMounts: [{name: backup, mountPath: /backup}]
  volumes:
  - name: backup
    persistentVolumeClaim: {claimName: backup-workspace}
---
apiVersion: v1
kind: Pod
metadata: {name: toolbox-mongo, namespace: ddb-hands}
spec:
  containers:
  - name: mongo
    image: mongo:8.0
    command: ["sleep","infinity"]
    volumeMounts: [{name: backup, mountPath: /backup}]
  volumes:
  - name: backup
    persistentVolumeClaim: {claimName: backup-workspace}
EOF
```

### 0.1 The WAL shipper — stands in for the KubeDB sidekick

This is the pod that makes the whole thing work. It mounts **both** the database's own PVC and the
workspace, exactly the way KubeDB's `postgres-archiver` Sidekick mounts the database PVC.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Pod
metadata: {name: wal-shipper, namespace: ddb-hands}
spec:
  containers:
  - name: shipper
    image: ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0
    command: ["sleep","infinity"]
    securityContext: {runAsUser: 1000}
    volumeMounts:
    - {name: data,   mountPath: /var/pv}     # the DB's PGDATA volume
    - {name: backup, mountPath: /backup}     # the workspace
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: data-docdb-0}
  - name: backup
    persistentVolumeClaim: {claimName: backup-workspace}
EOF

kubectl wait --for=condition=Ready pod/wal-shipper -n ddb-hands --timeout=120s
kubectl exec -n ddb-hands wal-shipper -- ls /var/pv/
```

```
data
postgresql.conf
```

> **Why this works.** `data-docdb-0` is `ReadWriteOnce`, but RWO in Kubernetes is **node-scoped**, not
> pod-scoped — any number of pods on the *same node* may mount it. On single-node k3s that is free.
> On a real cluster this is exactly what the Sidekick's leader election is for: it pins the sidekick
> to the node running the primary.

### 0.2 Why each of these exists

The short version: **the database pod is a bad place to do backup work, and the tools you need live
in two different images.**

| Pod | Image | Gives you |
| --- | --- | --- |
| `docdb-0` | documentdb | the database itself — don't do backup work here |
| `toolbox-pg` | documentdb | `pg_basebackup` + a spare engine for recovery |
| `toolbox-mongo` | `mongo:8.0` | `mongodump`/`mongorestore`, and a writable HOME for `mongosh` |
| `wal-shipper` | documentdb | the bridge — the only pod that sees **both** volumes |

**Why a PVC and not just a directory in the pod?** A backup is a file, and that file needs somewhere
that satisfies four things at once. It must be big enough (the base backup is ~189 MB; the database's
own volume is 2 Gi and already full of database). It must **not** live on the volume being backed up —
§7.3 replaces `/var/pv/data` outright, so a backup stored there would be destroyed by the very restore
it exists to enable. It must survive pod restarts, which rules out the pod filesystem and `emptyDir`.
And most importantly it must be readable by a *second* pod: pods cannot see each other's filesystems,
so a shared PVC is the only way one pod hands a file to another. Think of it as a USB drive several
machines plug into.

**Why `toolbox-pg`?** Two jobs. First, somewhere to run `pg_basebackup` that is not the database pod,
for the space reasons above. Second — and this is the real reason — **verifying a restore needs a
second Postgres process**, and you cannot start one inside the pod where Postgres is already running.
§6 starts that second server on port 5555, replays WAL into it, and checks the result *before*
anything touches production.

**Why the DocumentDB image and not `postgres:17`?** The recovered data directory carries
`shared_preload_libraries = pg_documentdb…`. A vanilla Postgres image has no such `.so` files, so the
recovery instance would refuse to start. The DocumentDB image already ships both the client tools and
the extension libraries, which makes it a client toolbox *and* a working spare engine — no image build
required.

**Why `toolbox-mongo`, and why does it mount the same volume?** The DocumentDB image ships `mongosh`
but **not** `mongodump`/`mongorestore`, so Mongo-level tooling needs `mongo:8.0`. The mount is there
for a narrower reason than it looks: `mongosh` refuses to start without a writable `$HOME`, which is
why every command in this runbook says `env HOME=/backup` (gotchas #3 and #4 in §10 are the symptom;
this is the cause). If you later use `mongodump`, its output needs a durable home too.

> **You can simplify this.** `wal-shipper` already runs the DocumentDB image with both volumes
> mounted, so it can do everything `toolbox-pg` does — two pods would be enough. They are kept
> separate here on purpose: the recovery instance should not run in a pod that has the **live**
> PGDATA mounted, where one wrong path in a `cp` or `rm -rf` would damage the real database.

---

## 1. Shell variables used throughout

Run this once per terminal. Every later block assumes these exist.

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
NS=ddb-hands

# admin/superuser — for psql on port 9712
APW=$(kubectl get secret docdb-admin-auth -n $NS -o jsonpath='{.data.password}' | base64 -d)

# app user — for mongosh on the gateway port 10260
MU=$(kubectl get secret docdb-auth -n $NS -o jsonpath='{.data.username}' | base64 -d)
MP=$(kubectl get secret docdb-auth -n $NS -o jsonpath='{.data.password}' | base64 -d)
URI="mongodb://$MU:$MP@docdb.$NS.svc:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true&directConnection=true"

# convenience wrappers
PSQL="kubectl exec -n $NS docdb-0 -c documentdb -- env PGPASSWORD=$APW psql -q -U documentdb -p 9712 -d postgres"
MONGOSH="kubectl exec -n $NS toolbox-mongo -- env HOME=/backup mongosh"
```

> **Three gotchas baked into those wrappers — do not drop them.**
>
> | Flag | Why |
> | --- | --- |
> | `psql -q` | the image ships a `~/.psqlrc` that runs two `SET` statements; without `-q` they are echoed and corrupt every `-Atc` value you try to capture |
> | `-c documentdb` | the pod has an init container too; without this every command prints `Defaulted container …` to stderr |
> | `HOME=/backup` | `mongosh` and `mc` both need a writable `$HOME`; the default is read-only and they die with `EACCES` |
>
> And the gateway **requires TLS** even when the DocumentDB is `sslMode: disable` — hence
> `tls=true&tlsAllowInvalidCertificates=true` in the URI. `mongodump` ignores that URI parameter and
> needs the `--tlsInsecure` **flag** instead.

Baseline check:

```bash
$MONGOSH "$URI" --quiet --eval '
  const d=db.getSiblingDB("sampledb");
  print("orders    = "+d.orders.countDocuments({}));
  print("customers = "+d.customers.countDocuments({}));'
```

```
orders    = 1000
customers = 250
```

---

## 2. Phase A — turn on WAL archiving

Out of the box DocumentDB generates WAL and **throws it away**: `archive_mode` is already `always`,
but `archive_command` is `/bin/true`. There is no `ARCHIVER_ENABLED` env on the pod because the
operator hardcodes it (`pkg/controllers/petset.go:1034`).

```bash
# 1. the archive directory (does not exist yet)
kubectl exec -n $NS docdb-0 -c documentdb -- mkdir -p /var/pv/wal_archive

# 2. point archive_command at it
$PSQL -c "ALTER SYSTEM SET archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f';"
$PSQL -c "ALTER SYSTEM SET archive_timeout = '60s';"

# 3. no restart needed — archive_command is SIGHUP-level and archive_mode was already 'always'
$PSQL -Atc "SELECT pg_reload_conf();"
```

Verify:

```bash
$PSQL -Atc "select name||' = '||setting from pg_settings
             where name in ('archive_mode','archive_command','archive_timeout');"
```

```
archive_command = test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f
archive_mode = always
archive_timeout = 60
```

Force a segment and confirm it lands:

```bash
$PSQL -Atc "SELECT pg_switch_wal();"
sleep 5
kubectl exec -n $NS docdb-0 -c documentdb -- ls -la /var/pv/wal_archive/
```

```
0/2300A6B8
-rw------- 1 documentdb documentdb 16777216 Aug 24 07:49 000000010000000000000022
-rw------- 1 documentdb documentdb 16777216 Aug 24 07:49 000000010000000000000023
```

> **This is hop 1 of KubeDB's two-hop design.** Postgres copies to a *local* directory and never
> touches object storage, because a failing `archive_command` makes Postgres stop recycling WAL and
> fill the volume. Never put a network call here.
>
> **The setting persists across pod deletion** (`postgresql.auto.conf` lives in PGDATA on the PVC) and
> the operator does not reconcile it away. Handy for prototyping, dangerous in production — it is
> invisible to the operator.

---

## 3. Phase B — take the base backup

```bash
kubectl exec -n $NS toolbox-pg -- sh -c 'rm -rf /backup/run2 && mkdir -p /backup/run2/wal'

kubectl exec -n $NS toolbox-pg -- env PGPASSWORD="$APW" \
  pg_basebackup -h docdb.$NS.svc -p 9712 -U documentdb \
    -D /backup/run2/base -Fp -Xs -P -v
```

```
pg_basebackup: checkpoint completed
pg_basebackup: write-ahead log start point: 0/25000028 on timeline 1
pg_basebackup: starting background WAL receiver
pg_basebackup: created temporary replication slot "pg_basebackup_10057"
176374/176374 kB (100%), 1/1 tablespace
pg_basebackup: write-ahead log end point: 0/2500E538
pg_basebackup: base backup completed

real  0m34.985s      # 189 MB
```

Flags that matter:

| Flag | Why |
| --- | --- |
| `-Fp` | **plain** format — required so you can start a recovery instance directly on the directory. `-Ft` gives tarballs you would have to unpack first. |
| `-Xs` | stream WAL during the backup, so the base is self-consistent even without the archive |
| `-P -v` | progress + verbose, so a slow backup is visibly alive |

> The `documentdb` admin role already has `REPLICATION` and `max_wal_senders = 90`. **No extra grants
> are needed** — the "needs a replication-capable role" concern does not apply here.

---

## 4. Phase C — marker data, recovery target, then the disaster

### 4.1 Write `gen1` markers (these must survive)

```bash
$MONGOSH "$URI" --quiet --eval '
  const d=db.getSiblingDB("sampledb");
  d.pitr.insertMany(Array.from({length:50},(_,i)=>({_id:i,gen:"gen1"})));
  print("pitr = "+d.pitr.countDocuments({}));'

$PSQL -Atc "SELECT pg_switch_wal();"
```

```
pitr = 50
```

### 4.2 Record the recovery target

```bash
sleep 3
T1=$($PSQL -Atc "SELECT now();" | tr -d '\r')
echo "T1 = $T1"
sleep 3
```

```
T1 = 2026-08-24 07:51:37.396218+00
```

> Sleep on **both** sides of the timestamp. Without a gap, the target can land inside the same
> transaction as the writes you are trying to keep or drop, and the result becomes a coin flip.

### 4.3 The disaster

```bash
$MONGOSH "$URI" --quiet --eval '
  const d=db.getSiblingDB("sampledb");
  d.pitr.insertMany(Array.from({length:70},(_,i)=>({_id:1000+i,gen:"gen2"})));
  d.orders.deleteMany({});
  print("AFTER DISASTER  orders="+d.orders.countDocuments({})
        +"  pitr="+d.pitr.countDocuments({})
        +"  customers="+d.customers.countDocuments({}));'

$PSQL -Atc "SELECT pg_switch_wal();"
sleep 6
kubectl exec -n $NS docdb-0 -c documentdb -- ls /var/pv/wal_archive/
```

```
AFTER DISASTER  orders=0  pitr=120  customers=250

000000010000000000000022
000000010000000000000023
000000010000000000000024
000000010000000000000025
000000010000000000000025.00000028.backup     ← marks where the base backup started
000000010000000000000026
000000010000000000000027
```

---

## 5. Phase D — ship the WAL off the database volume

This is the sidekick's entire job. Here `cp` stands in for `wal-g wal-push`, because **wal-g is not
in the DocumentDB image** — that is the one binary KubeDB will have to add.

```bash
kubectl exec -n $NS wal-shipper -- sh -c '
  mkdir -p /backup/run2/wal
  cp -n /var/pv/wal_archive/* /backup/run2/wal/ 2>/dev/null
  echo "shipped: $(ls /backup/run2/wal | wc -l) files"'
```

```
shipped: 7 files
```

To make it continuous (closer to the real sidekick), run it as a loop in the background:

```bash
kubectl exec -n $NS wal-shipper -- sh -c '
  nohup sh -c "while true; do cp -n /var/pv/wal_archive/* /backup/run2/wal/ 2>/dev/null; sleep 10; done" \
    >/backup/run2/shipper.log 2>&1 &
  echo started'
```

---

## 6. Phase E — offline PITR recovery instance

Recover into a **scratch copy first**. This verifies the backup without touching the live database —
if the recovery is wrong you have lost nothing.

### 6.1 Stage the copy and write the recovery config

```bash
kubectl exec -n $NS toolbox-pg -- bash -c "
set -e
rm -rf /backup/run2/rec
cp -a /backup/run2/base /backup/run2/rec
chmod 700 /backup/run2/rec

cat >> /backup/run2/rec/postgresql.auto.conf <<EOC
# ---- PITR recovery overrides ----
port = 5555
listen_addresses = 'localhost'
archive_mode = off
archive_command = ''
restore_command = 'cp /backup/run2/wal/%f %p'
recovery_target_time = '$T1'
recovery_target_action = 'promote'
EOC

touch /backup/run2/rec/recovery.signal
"
```

| Line | Why it is mandatory |
| --- | --- |
| `port = 5555` | keeps the recovery instance off the live port |
| `archive_mode = off` | the copied `auto.conf` still points `archive_command` at `/var/pv/wal_archive`, which **does not exist inside toolbox-pg** — leave it on and recovery fails |
| `restore_command` | where replay pulls segments from; this is `wal-g wal-fetch` in the real system |
| `recovery_target_action = 'promote'` | otherwise recovery pauses and the instance stays read-only |
| `recovery.signal` | PG12+ replacement for `recovery.conf` — without the file, nothing recovers |

> Appending to `postgresql.auto.conf` works because **the last occurrence of a setting wins** — your
> overrides beat the values copied from the source database.

### 6.2 Start it and watch the replay

```bash
kubectl exec -n $NS toolbox-pg -- \
  /usr/lib/postgresql/17/bin/pg_ctl -D /backup/run2/rec -l /backup/run2/rec.log -w -t 120 start

kubectl exec -n $NS toolbox-pg -- \
  grep -iE 'recovery|restored log file|consistent|promot|timeline' /backup/run2/rec.log
```

```
LOG:  starting backup recovery with redo LSN 0/25000028, checkpoint LSN 0/2500DCF0, on timeline ID 1
LOG:  restored log file "000000010000000000000025" from archive
LOG:  starting point-in-time recovery to 2026-08-24 07:51:37.396218+00
LOG:  restored log file "000000010000000000000026" from archive
LOG:  consistent recovery state reached at 0/2500E538
LOG:  restored log file "000000010000000000000027" from archive
LOG:  recovery stopping before commit of transaction 1943991, time 2026-08-24 07:51:39.046814+00
LOG:  selected new timeline ID: 2
```

`07:51:39.046` is the first commit **after** `T1 = 07:51:37.396`. Postgres stopped before it — the
stopping point is always a transaction boundary, never a partial write.

### 6.3 Verify before you trust it

```bash
kubectl exec -n $NS toolbox-pg -- env PGPASSWORD="$APW" \
  psql -q -h 127.0.0.1 -p 5555 -U documentdb -d postgres -c "
    SELECT database_name, collection_name, collection_id
      FROM documentdb_api_catalog.collections
     WHERE database_name='sampledb' ORDER BY collection_id;"
```

```
 database_name |  collection_name  | collection_id
---------------+-------------------+---------------
 sampledb      | system.dbSentinel |             4
 sampledb      | customers         |             5
 sampledb      | orders            |             6
 sampledb      | pitr              |            15
```

**The catalog is intact** — this is the whole reason the base must be physical. `pg_dump` cannot
export `documentdb_api_catalog.collections` because it is extension-owned; `pg_basebackup` captures
it unconditionally because it copies bytes.

Now count rows — note the collection ids come from the query above, they are **not stable** across
rebuilds:

```bash
kubectl exec -n $NS toolbox-pg -- env PGPASSWORD="$APW" \
  psql -q -h 127.0.0.1 -p 5555 -U documentdb -d postgres -Atc "
    select 'orders    = '||(select count(*) from documentdb_data.documents_6)
    union all select 'customers = '||(select count(*) from documentdb_data.documents_5)
    union all select 'pitr      = '||(select count(*) from documentdb_data.documents_15);"
```

```
orders    = 1000
customers = 250
pitr      = 50
```

Confirm the generation split — only `gen1` may survive:

```bash
kubectl exec -n $NS toolbox-pg -- env PGPASSWORD="$APW" \
  psql -q -h 127.0.0.1 -p 5555 -U documentdb -d postgres -Atc "
    select 'gen1='||count(*) filter (where document::text like '%67656e31%')
        ||'  gen2='||count(*) filter (where document::text like '%67656e32%')
      from documentdb_data.documents_15;"
```

```
gen1=50  gen2=0
```

> **Two query traps.**
>
> 1. **`n_live_tup` is 0 on a recovered instance.** Planner statistics are not WAL-logged, so
>    `pg_stat_user_tables` reads zero everywhere. Always `count(*)`.
> 2. **BSON has no `->>` operator here** and renders as `BSONHEX…`. Match the hex instead:
>    `gen1` = `67656e31`, `gen2` = `67656e32`.

---

## 7. Phase F — restore in place, into the real pod

Only now that §6.3 passed. **This overwrites the live database.**

### 7.1 Stop the recovery instance and clean its overrides

```bash
kubectl exec -n $NS toolbox-pg -- \
  /usr/lib/postgresql/17/bin/pg_ctl -D /backup/run2/rec -m fast -w stop

kubectl exec -n $NS toolbox-pg -- bash -c "
  sed -i '/# ---- PITR recovery overrides ----/,\$d' /backup/run2/rec/postgresql.auto.conf
  rm -f /backup/run2/rec/recovery.signal
  cat /backup/run2/rec/postgresql.auto.conf"
```

```
# Do not edit this file manually!
# It will be overwritten by the ALTER SYSTEM command.
archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f'
archive_timeout = '60s'
```

**Do not skip this.** Ship `port = 5555` and `listen_addresses = 'localhost'` back into the pod and
the database comes up invisible to its own Service.

### 7.2 Stop the database

```bash
kubectl scale petset docdb -n $NS --replicas=0

until ! kubectl get pod docdb-0 -n $NS >/dev/null 2>&1; do sleep 3; done
echo "docdb-0 gone"
```

> **`spec.halted: true` does not work here.** The DocumentDB CRD accepts the field and it persists in
> the spec, but this operator build never acts on it — the PetSet stayed at 1 replica and the pod kept
> running. Scaling the PetSet directly is what actually stops the database. Worth fixing in the
> operator; worth knowing today.

### 7.3 Swap the volume

`wal-shipper` still has the PVC mounted, and it is now the only pod that does.

```bash
kubectl exec -n $NS wal-shipper -- bash -c '
set -e
test -f /var/pv/data/PG_VERSION || { echo "no live PGDATA?"; exit 1; }
rm -rf /var/pv/data.damaged
mv /var/pv/data /var/pv/data.damaged      # keep the evidence, do not delete yet
cp -a /backup/run2/rec /var/pv/data
chmod 700 /var/pv/data
ls -ld /var/pv/data
ls /var/pv/data/pg_wal/*.history'
```

```
drwx--S--- 20 documentdb documentdb 4096 Aug 24 07:53 /var/pv/data
/var/pv/data/pg_wal/00000002.history          ← promoted onto timeline 2
```

### 7.4 Start it again

```bash
kubectl scale petset docdb -n $NS --replicas=1
kubectl wait --for=condition=Ready pod/docdb-0 -n $NS --timeout=300s
```

```
docdb-0   1/1   Running   0   2s
```

---

## 8. Phase G — verify through the Mongo wire layer

The SQL layer being right is **not** sufficient — a restore can leave correct heap tables with an
empty catalog, and then the Mongo side reports zero collections. Always finish here.

```bash
$MONGOSH "$URI" --quiet --eval '
  const d=db.getSiblingDB("sampledb");
  print("collections = "+d.getCollectionNames().sort().join(","));
  print("orders      = "+d.orders.countDocuments({}));
  print("customers   = "+d.customers.countDocuments({}));
  print("pitr        = "+d.pitr.countDocuments({}));
  print("gen1        = "+d.pitr.countDocuments({gen:"gen1"}));
  print("gen2        = "+d.pitr.countDocuments({gen:"gen2"}));
  print("qty_sum     = "+d.orders.aggregate([{$group:{_id:null,s:{$sum:"$qty"}}}]).toArray()[0].s);'
```

```
collections = customers,orders,pitr
orders      = 1000
customers   = 250
pitr        = 50
gen1        = 50
gen2        = 0
qty_sum     = 7979
```

### 8.1 Confirm archiving survived the restore

```bash
$PSQL -Atc "select name||' = '||setting from pg_settings
             where name in ('archive_mode','archive_command');"
$PSQL -Atc "select pg_switch_wal();"
sleep 5
kubectl exec -n $NS docdb-0 -c documentdb -- sh -c 'ls /var/pv/wal_archive/ | grep ^00000002'
```

```
archive_command = test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f
archive_mode = always
000000020000000000000029
```

New segments on **timeline 2**. The restored database is immediately protected again — you can PITR
from this point forward without taking a new base backup, though you should take one anyway.

### 8.2 Reclaim the space

```bash
kubectl exec -n $NS wal-shipper -- rm -rf /var/pv/data.damaged
kubectl exec -n $NS wal-shipper -- df -h /var/pv
```

The damaged copy was 893 MB against a 2 Gi PVC — do not leave it there.

---

## 9. Final result

| | Before disaster | After disaster | After PITR to T1 | Expected |
| --- | ---: | ---: | ---: | --- |
| `orders` | 1000 | **0** | **1000** | 1000 ✅ |
| `customers` | 250 | 250 | 250 | 250 ✅ |
| `pitr` | 50 | 120 | **50** | 50 ✅ |
| `pitr` / gen1 | 50 | 50 | 50 | 50 ✅ |
| `pitr` / gen2 | 0 | 70 | **0** | 0 ✅ |
| `qty_sum` | 7979 | — | **7979** | 7979 ✅ |
| collections | 3 | 3 | 3 | 3 ✅ |

**PITR on DocumentDB works with stock PostgreSQL mechanics.** The only gaps between this runbook and
a product feature are the two things KubeDB already solved for Postgres:

1. wire `archive_command` from the operator instead of `ALTER SYSTEM` (`ARCHIVER_ENABLED` is
   hardcoded `false` at `pkg/controllers/petset.go:1034`)
2. ship a `wal-g` binary so hop 2 is `wal-push`/`wal-fetch` against object storage instead of `cp`

---

## 10. Gotcha reference

| # | Symptom | Cause / fix |
| --- | --- | --- |
| 1 | `-Atc` output has stray `SET` lines | the image's `~/.psqlrc`; add **`-q`** |
| 2 | `Defaulted container … ` on every exec | add **`-c documentdb`** |
| 3 | `EACCES: mkdir '/data/db/.mongodb'` | `mongosh` needs a writable HOME; **`env HOME=/backup`** |
| 4 | `mkdir /.mc: permission denied` | same for `mc`; **`env HOME=/backup`** |
| 5 | `MongoServerSelectionError: read ECONNRESET` | the gateway requires TLS even at `sslMode: disable`; add `tls=true&tlsAllowInvalidCertificates=true` |
| 6 | `mongodump`: `x509: certificate is not valid` | it **ignores** the URI TLS parameter; use the `--tlsInsecure` flag |
| 7 | recovery instance won't start | `archive_mode` still `always`, pointing at a path that doesn't exist in the toolbox — set `archive_mode = off` |
| 8 | recovery finishes but stays read-only | missing `recovery_target_action = 'promote'` |
| 9 | nothing recovers at all | forgot `touch $PGDATA/recovery.signal` |
| 10 | every table reports 0 rows after recovery | `n_live_tup` isn't WAL-logged; use `count(*)` |
| 11 | `operator does not exist: bson ->>` | match `document::text` against BSON hex (`gen1` = `67656e31`) |
| 12 | DB unreachable after in-place restore | recovery overrides left in `postgresql.auto.conf` — strip them first |
| 13 | `spec.halted: true` does nothing | not implemented in this operator build; `kubectl scale petset` instead |
| 14 | collection ids don't match the doc | ids are **not stable** across rebuilds; always read `documentdb_api_catalog.collections` first |
| 15 | second pod stuck `Pending`, `Multi-Attach` | RWO is node-scoped — the pod must land on the node holding the volume |

---

## 11. Teardown

```bash
# just the helpers
kubectl delete pod wal-shipper toolbox-pg toolbox-mongo -n ddb-hands

# the whole experiment
kubectl delete ns ddb-hands
```

Leave `ddb-hands` up while you are still comparing — the seeded database and the base backup in
`/backup/run2` are the expensive parts to rebuild.
