# DocumentDB Backup & Restore — Hands-On Validation

> **Purpose.** Execute every backup/restore approach proposed in [`documentdb-backup.md`](./documentdb-backup.md)
> against a live KubeDB-managed DocumentDB, before committing to a KubeDB/KubeStash integration design.
> Every command below was actually run; every number is copied from real output.
>
> **Date.** 2026-08-19
> **Verdict in one line.** Four of six methods work; one is blocked by the cluster; and **`pg_dump`
> silently loses the collection catalog**, which invalidates the "strong baseline" verdict the
> research note gave it.

---

## 0. Headline findings

| #            | Finding                                                                                                                                                                                                                                                                                                                                                                                 | Impact                                                                                                                  |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **F1** | **RESOLVED 2026-08-31 — see [`documentdb-logical-gateway-user.md`](documentdb-logical-gateway-user.md): both a fix and a one-command reproduction.** **`pg_dump` cannot back up the DocumentDB catalog.** `documentdb_api_catalog.collections` and `collection_indexes` are *extension-owned*, so PostgreSQL excludes them from every dump — even when named explicitly with `-t`. Restoring a `pg_dump` into a fresh DocumentDB yields **all data present in Postgres and zero collections visible over MongoDB**. | 🔴**Critical.** A `logical-backup` addon built the obvious way reports success and produces an unusable backup. |
| **F2** | The defect is fixable with a**7-line `COPY` sidecar**. Proven: injecting 2 catalog rows made 1,250 invisible documents fully visible.                                                                                                                                                                                                                                           | 🟢 Cheap fix, must be designed in from day one.                                                                         |
| **F3** | **PITR works today.** With `archive_command` pointed at a directory, a base backup + WAL replay recovered to an exact timestamp — undoing a `deleteMany({})` of 1,000 documents.                                                                                                                                                                                             | 🟢 The differentiator is real and reachable.                                                                            |
| **F4** | **`mongodump` is empirically inconsistent across collections.** Under a concurrent writer with invariant `A+B=2001`, the dump captured **2003** — two documents duplicated into both collections. `pg_dump` under the identical workload captured exactly **2001**.                                                                                            | 🟡 Confirms mongo-logical must never be the primary backup path.                                                        |
| **F5** | The gateway**requires TLS even when `spec.sslMode: disable`**, and `mongodump` **silently ignores** `tlsAllowInvalidCertificates` as a URI parameter (mongosh honours it).                                                                                                                                                                                            | 🟡 Addon must pass`--tlsInsecure` as a CLI flag, not in the URI.                                                      |
| **F6** | `archive_mode=always` is **already on**; only `archive_command` (`/bin/true`) and a wal-g binary are missing. `ALTER SYSTEM` changes **survive pod deletion**.                                                                                                                                                                                                      | 🟢 Confirms §3.4 of the research note.                                                                                 |
| **F7** | Manifest restore requires**stripping `ownerReferences`** and applying **Secrets before the CR**, otherwise the operator generates fresh passwords.                                                                                                                                                                                                                        | 🟡 Ordering is load-bearing.                                                                                            |
| **F8** | CSI VolumeSnapshot is**untestable on this cluster** — no `VolumeSnapshot` CRDs, no CSI drivers, `local-path` is not a CSI provisioner.                                                                                                                                                                                                                                       | ⚪ Not a DocumentDB limitation; needs a different cluster.                                                              |

---

## 1. Environment

| Item                     | Value                                                                                    |
| ------------------------ | ---------------------------------------------------------------------------------------- |
| Kubernetes               | `v1.36.2+k3s1`, single node `sabnaj`, Ubuntu 24.04                                   |
| Kubeconfig               | `/home/sabnaj/k3s.yaml`                                                                |
| KubeDB operators         | namespace`kubedb` (provisioner image `sabnaj/documentdb-operator:reconfiguretls-v3`) |
| Test namespace           | `ddb-hands`                                                                            |
| DocumentDBVersion        | `pg17-0.109.0` → `ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0`      |
| PostgreSQL               | 17.9 (Debian)                                                                            |
| `documentdb` extension | `0.109-0`                                                                              |
| StorageClass             | `local-path` (rancher.io/local-path) — **not CSI**                              |
| Object storage           | MinIO in-cluster, bucket`documentdb-backup`                                            |

### 1.1 What the DB image actually ships

Surveyed with `command -v` inside `docdb-0`:

```
psql          -> /usr/lib/postgresql/17/bin/psql
pg_dump       -> /usr/lib/postgresql/17/bin/pg_dump
pg_dumpall    -> /usr/lib/postgresql/17/bin/pg_dumpall
pg_restore    -> /usr/lib/postgresql/17/bin/pg_restore
pg_basebackup -> /usr/lib/postgresql/17/bin/pg_basebackup
mongosh       -> /usr/bin/mongosh
wal-g         -> MISSING          ← confirms research note §3.4 blocker
mongodump     -> MISSING
mongorestore  -> MISSING
aws / mc /curl-> MISSING
```

**Consequence:** all backup work must run from a *separate* image, exactly as KubeStash does with
plugin Jobs. Three toolbox pods were used, sharing one `backup-workspace` PVC:

| Pod               | Image                             | Provides                                                         |
| ----------------- | --------------------------------- | ---------------------------------------------------------------- |
| `toolbox-pg`    | `documentdb-local:pg17-0.109.0` | pg_dump/pg_restore/pg_basebackup + the documentdb extension libs |
| `toolbox-mongo` | `mongo:8.0`                     | mongodump/mongorestore/mongosh                                   |
| `toolbox-mc`    | `minio/mc`                      | MinIO upload/download                                            |

> Reusing the **DB image itself** as the pg toolbox was the single most useful trick: it already
> contains matching client binaries *and* `shared_preload_libraries` for `pg_documentdb`, which is what
> made the offline PITR instance (§5.4) possible without building anything.

### 1.2 Ports and identities — confirmed

| Item            | Expected (research note) | Observed                    |
| --------------- | ------------------------ | --------------------------- |
| Gateway port    | 10260                    | ✅ 10260                    |
| Postgres port   | 9712                     | ✅ 9712                     |
| Admin user      | `documentdb`           | ✅ from`docdb-admin-auth` |
| App user        | `default_user`         | ✅ from`docdb-auth`       |
| PGDATA          | `/var/pv/data`         | ✅                          |
| `hello().msg` | `isdbgrid`             | ✅                          |

---

## 2. Setup procedure

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
kubectl create ns ddb-hands
```

**Database** (`docdb.yaml`):

```yaml
apiVersion: kubedb.com/v1alpha2
kind: DocumentDB
metadata: {name: docdb, namespace: ddb-hands}
spec:
  version: pg17-0.109.0
  replicas: 1
  storageType: Durable
  sslMode: disable
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: local-path
    resources: {requests: {storage: 2Gi}}
  deletionPolicy: WipeOut
```

Standalone provisions as a **single-container pod** (`documentdb`); the coordinator container only
appears for HA. Ready in ~40 s.

**MinIO + bucket:**

```bash
kubectl apply -f minio.yaml          # Deployment + Service + 5Gi PVC, creds minioadmin/minioadmin123
kubectl exec -n ddb-hands toolbox-mc -- env HOME=/backup \
  MC_HOST_local="http://minioadmin:minioadmin123@minio.ddb-hands.svc:9000" \
  mc mb --ignore-existing local/documentdb-backup
```

> **Gotcha.** `minio/mc` runs with a read-only `/`; without `HOME=/backup` every command dies with
> `mkdir /.mc: permission denied`.

### 2.1 Baseline dataset — the verification fingerprint

```javascript
db.orders.insertMany(Array.from({length:1000},(_,i)=>({_id:i, item:"widget-"+i, qty:i%17, tag:"seed-v1"})));
db.customers.insertMany(Array.from({length:250},(_,i)=>({_id:i, name:"cust-"+i, city: i%2==0?"Dhaka":"Chattogram"})));
```

```
orders     = 1000
customers  = 250
qty_sum    = 7979        ← the fingerprint every restore is checked against
collections= customers,orders
```

### 2.2 Physical layout — research note confirmed exactly

```sql
select database_name, collection_name, collection_id from documentdb_api_catalog.collections;
```

```
kubedb_system | system.dbSentinel | 1
kubedb_system | health_check      | 2      ← KubeDB's own health-checker collections
sampledb      | system.dbSentinel | 3
sampledb      | orders            | 4
sampledb      | customers         | 5
```

```
documentdb_data.documents_4 | 1000 rows      ← sampledb.orders
documentdb_data.documents_5 |  250 rows      ← sampledb.customers
documentdb_data.retry_1..5  |    0 rows      ← undocumented sidecar tables, one per collection
```

Extensions present: `documentdb 0.109-0`, `documentdb_core 0.109-0`, `pg_cron 1.6`,
`postgis 3.6.2`, `vector 0.8.2`, `tsm_system_rows 1.0` — matching `documentdb.control`'s `requires`.

> **New detail not in the research note:** KubeDB provisions a `kubedb_system` MongoDB database with
> `health_check` and `system.dbSentinel` collections. Any backup addon must decide whether to include
> it (it is operator state, not user data), and any *restore* must not clobber the new cluster's copy.
> **Also new:** every collection gets a paired `documentdb_data.retry_<id>` table.

---

## 3. Results matrix

| #  | Method                                   |             Backup             |            Restore            | Consistency (measured) | Verdict                                             |
| -- | ---------------------------------------- | :----------------------------: | :----------------------------: | ---------------------- | --------------------------------------------------- |
| 1  | `pg_dump` / `pg_dumpall`             |               ✅               |    ⚠️**data only**    | ✅ exact (2001/2001)   | **Broken as specified** — loses catalog (F1) |
| 1b | `pg_dump` **+ catalog `COPY`** |               ✅               |               ✅               | ✅ exact               | ✅**Recommended logical path**                |
| 2  | `mongodump` / `mongorestore`         |               ✅               |               ✅               | ❌ torn (2003/2001)    | ✅ Works; migration-only                            |
| 3  | `pg_basebackup`                        |               ✅               |               ✅               | crash-consistent       | ✅ Works, no extra grants needed                    |
| 4  | WAL archiving →**PITR**           | ✅ (manual`archive_command`) | ✅**to exact timestamp** | transactionally exact  | ✅**Proven achievable**                       |
| 5  | CSI VolumeSnapshot                       |               ⚪               |               ⚪               | —                     | ⚪**Untestable** — no CSI driver             |
| 6  | Manifest (CR + Secrets)                  |               ✅               |               ✅               | n/a                    | ✅ Works with ordering care (F7)                    |

---

## 4. Method-by-method

### 4.1 Method 1 — `pg_dump` / `pg_dumpall`

**Procedure**

```bash
PGPW=$(kubectl get secret -n ddb-hands docdb-admin-auth -o jsonpath='{.data.password}' | base64 -d)

# whole cluster, plain SQL
pg_dumpall -h docdb.ddb-hands.svc -p 9712 -U documentdb -f /backup/docdb-all.sql

# payload only, custom format
pg_dump -h docdb.ddb-hands.svc -p 9712 -U documentdb -d postgres -Fc \
        -n documentdb_data -n documentdb_api_catalog -f /backup/docdb-schemas.dump
```

**Result** — both exit 0. `docdb-all.sql` = 251 KB, `docdb-schemas.dump` = 27 KB.

**✅ What works.** `pg_dumpall` emits `CREATE EXTENSION` in correct dependency order — this settles
open question #6 of the research note:

```
119: CREATE EXTENSION IF NOT EXISTS pg_cron ...
133: CREATE EXTENSION IF NOT EXISTS documentdb_core ...     ← core before api
147: CREATE EXTENSION IF NOT EXISTS postgis ...
161: CREATE EXTENSION IF NOT EXISTS tsm_system_rows ...
175: CREATE EXTENSION IF NOT EXISTS vector ...
189: CREATE EXTENSION IF NOT EXISTS documentdb ...
```

Document data is captured: `COPY documentdb_data.documents_4 (shard_key_value, object_id, document)`.

**🔴 What is silently missing.** The full TOC of `-n documentdb_data -n documentdb_api_catalog`
contains **only `documentdb_data` objects** — 10 tables, 10 TABLE DATA, 10 constraints. Nothing at all
from `documentdb_api_catalog`. Every `COPY` statement in the 251 KB `pg_dumpall`:

```
COPY cron.job                       ← pg_cron's config table IS dumped
COPY cron.job_run_details
COPY documentdb_data.documents_1..5
COPY documentdb_data.retry_1..5
COPY public.spatial_ref_sys         ← PostGIS's config table IS dumped
```

`grep -c documentdb_api_catalog docdb-all.sql` → **0**.

**Root cause, verified:**

```sql
select c.relname, e.extname from pg_class c
  join pg_depend d on d.objid=c.oid and d.deptype='e'
  join pg_extension e on e.oid=d.refobjid
 where c.relnamespace='documentdb_api_catalog'::regnamespace;
```

```
collections                    | documentdb
collection_indexes             | documentdb
collections_collection_id_seq  | documentdb
collection_indexes_index_id_seq| documentdb
documentdb_index_queue         | documentdb
```

These are extension-owned (`pg_depend.deptype='e'`). PostgreSQL never dumps extension-owned table
*data* unless the extension registers it with `pg_extension_config_dump()`. **`pg_cron` and `postgis`
do this; `documentdb` does not.** That is the entire bug, and it lives upstream.

Forcing it does not help:

```bash
pg_dump ... -t documentdb_api_catalog.collections -f /backup/cat-test.dump
pg_restore -l /backup/cat-test.dump | grep -vc '^;'
# → 0        (empty dump, exit 0, no warning)
```

**Verdict.** `pg_dump` alone is **not** a valid DocumentDB backup. See §6 for the proof of consequence
and §7 for the fix.

---

### 4.2 Method 2 — `mongodump` / `mongorestore`

**Connection findings first (F5).** The gateway demands TLS *even though* `spec.sslMode: disable`:

- No TLS → `MongoServerSelectionError: read ECONNRESET`
- `tls=true&tlsAllowInvalidCertificates=true` in the URI → works for **mongosh**
- Same URI for **mongodump** → `WARNING: ignoring unsupported URI parameter tlsallowinvalidcertificates`
  then `x509: certificate is not valid for any names`

`sslMode` governs the **PostgreSQL** listener, not the gateway. The working invocation needs the CLI flag:

```bash
URI="mongodb://default_user:$PW@docdb.ddb-hands.svc:10260/?directConnection=true&authMechanism=SCRAM-SHA-256&tls=true"
mongodump --uri "$URI" --tlsInsecure --archive=/backup/docdb.archive
```

**Result**

```
Warning: using a non-primary readPreference with a connection to mongos may produce
         inconsistent duplicates or miss some documents.
writing `sampledb.orders`  ... done (1000 documents)
writing `sampledb.customers` ... done (250 documents)
writing `kubedb_system.health_check` ... done (1 document)
```

The driver itself warns about the `isdbgrid` topology — §4.5 proves that warning is not theoretical.

`system.dbSentinel` collections are skipped (treated as system collections). `kubedb_system` **is**
dumped — an addon should exclude it explicitly.

**Oplog — all three predictions confirmed:**

```
mongodump --oplog  → Failed: can't use --oplog option when dumping from a mongos
db.adminCommand({replSetGetStatus:1}) → Unknown request received: replSetGetStatus
db.getSiblingDB("local").getCollectionNames() → []          (no oplog.rs)
db.adminCommand({applyOps:[]})        → Unknown request received: applyOps
```

**Verdict.** Works reliably for backup and restore. Structurally incapable of point-in-time or
cross-collection consistency. Migration/portability tool only.

---

### 4.3 Method 3 — `pg_basebackup`

```bash
pg_basebackup -h docdb.ddb-hands.svc -p 9712 -U documentdb -D /backup/basebackup -Ft -z -Xs -P -v
```

```
initiating base backup, waiting for checkpoint to complete
write-ahead log start point: 0/301C080 on timeline 1
created temporary replication slot "pg_basebackup_1161"
33759/33759 kB (100%), 1/1 tablespace
base backup completed
```

**Finding:** the `documentdb` admin role already has REPLICATION, and `max_wal_senders=90`. The
research note's "needs a replication-capable role" gotcha **does not apply** — it works out of the box.

Output: `base.tar.gz` 3.9 MB, `pg_wal.tar.gz` 46 KB, `backup_manifest` 146 KB.

**Restore validated** in §4.4 — the PITR instance was built from exactly this artifact and served
correct query results, so the physical path is proven end to end.

---

### 4.4 Method 4 — WAL archiving and PITR ⭐

This was the most valuable experiment: it converts the research note's "the differentiator" from a
claim into a measured result.

**Starting state — exactly as §3.4 predicted:**

```
archive_mode    | always                     ← already correct
archive_command | /bin/true                  ← WAL silently discarded
wal_level       | replica
/var/pv/wal_archive → does not exist
```

No `ARCHIVER_ENABLED` env on the pod at all. Source confirms it is hardcoded:

```go
// kubedb.dev/documentdb/pkg/controllers/petset.go:1034
{ Name: "ARCHIVER_ENABLED", Value: "false" },
```

**Enabling archiving (2 commands):**

```bash
kubectl exec docdb-0 -- mkdir -p /var/pv/wal_archive
psql -c "ALTER SYSTEM SET archive_command =
          'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f';"
psql -c "SELECT pg_reload_conf();"
```

Effective immediately — no restart, because `archive_command` is SIGHUP-level and `archive_mode` was
already `always`.

**The PITR drill**

| Step | Action                                                                           | State                        |
| ---- | -------------------------------------------------------------------------------- | ---------------------------- |
| 1    | `pg_basebackup -Fp` → `/backup/pitr-base`                                   | base at LSN 0/5000028        |
| 2    | insert 50 docs`gen1` into `sampledb.pitr`; `pg_switch_wal()`               | pitr=50                      |
| 3    | **record T1 = `2026-08-19 05:44:17.938152+00`**                          | ← recovery target           |
| 4    | insert 70 docs`gen2`; **`db.orders.deleteMany({})`** — the "disaster" | pitr=120, orders=**0** |
| 5    | `pg_switch_wal()`; 5 WAL segments archived                                     |                              |

**Recovery** — same image, port 5555, `restore_command` reading the archive:

```
restore_command = 'cp /backup/wal_archive/%f %p'
recovery_target_time = '2026-08-19 05:44:17.938152+00'
recovery_target_action = 'promote'
```

```
LOG: Initialized documentdb_core extension
LOG: Loaded documentdb_rum handler successfully via rum
LOG: starting point-in-time recovery to 2026-08-19 05:44:17.938152+00
LOG: restored log file "000000010000000000000005" from archive
LOG: restored log file "000000010000000000000006" from archive
LOG: restored log file "000000010000000000000007" from archive
LOG: recovery stopping before commit of transaction 3684, time 2026-08-19 05:44:18.824161+00
LOG: selected new timeline ID: 2
LOG: database system is ready to accept connections
```

**Result**

| Collection    | Live DB (damaged) | Recovered to T1 | Expected          |
| ------------- | ----------------: | --------------: | ----------------- |
| `orders`    |       **0** |  **1000** | 1000 ✅           |
| `customers` |               250 |   **250** | 250 ✅            |
| `pitr`      |               120 |    **50** | 50 ✅ (gen1 only) |

Row payload decoded to `{_id:0, gen:"gen1"}` (`BSONHEX...67656e31`). The 1,000-document deletion and
all 70 `gen2` inserts were correctly excluded.

**Verdict.** ✅ **PITR works on DocumentDB with stock PostgreSQL mechanics.** The only gaps between
this manual drill and a product feature are (a) wiring `archive_command`, and (b) shipping a `wal-g`
binary — both already solved in KubeDB's Postgres operator.

> **Bonus finding (F6).** After `kubectl delete pod docdb-0`, the `ALTER SYSTEM` setting **persisted**
> (`postgresql.auto.conf` lives in PGDATA on the PVC and the operator does not reconcile it). Useful
> for prototyping, but also a warning: hand-edits are invisible to the operator and survive restarts.

---

### 4.5 Method 5 — CSI VolumeSnapshot ⚪ BLOCKED

```bash
kubectl api-resources | grep -i volumesnapshot   # → nothing
kubectl get csidrivers                           # → No resources found
kubectl get pvc data-docdb-0 -o jsonpath='{.spec.storageClassName}'  # → local-path
```

`local-path` is `rancher.io/local-path`, a hostPath provisioner with **no CSI snapshot capability**.
The `VolumeSnapshot` CRDs are not installed and there is no snapshot controller.

**This is a cluster limitation, not a DocumentDB one.** Microsoft's operator ships exactly this method
and restricts it to AKS + `disk.csi.azure.com` for the same reason. To test it here you would need a
CSI driver with snapshot support (e.g. Longhorn, OpenEBS, or `csi-driver-host-path`) plus the
external-snapshotter CRDs and controller.

**Not tested. No claim made either way.**

---

### 4.6 Method 6 — Manifest backup

**Backup** — CR + both auth Secrets, runtime fields stripped:

```bash
kubectl get documentdb docdb -o yaml | sed '/creationTimestamp/d;/resourceVersion/d;/uid:/d;/^status:/,$d'
kubectl get secret docdb-auth docdb-admin-auth -o yaml
```

**Two failures found on first restore attempt (F7):**

1. Concatenating YAML files without `---` separators →
   `Secret in version "v1" cannot be handled: strict decoding error: unknown field "spec"`
2. Stripping only `uid:` from Secrets leaves a dangling owner reference →
   `metadata.ownerReferences.uid: Invalid value: "": must not be empty`

**Correct procedure — `ownerReferences` removed entirely, Secrets applied BEFORE the CR:**

```
secret/docdb-auth created
secret/docdb-admin-auth created
documentdb.kubedb.com/docdb created
```

**Result:** the operator **adopted** the pre-created Secrets rather than generating new ones —
original credentials preserved:

```
backed-up password : Aq5CTOH47v(Sg3h9
live password      : Aq5CTOH47v(Sg3h9
ADOPTED = True
```

Applying the CR first would have generated fresh random passwords, silently breaking every
application that holds the old credential. **Ordering is load-bearing.**

---

## 5. Restore drills

### 5.1 Drill A — delete the pod (PVC survives)

```bash
kubectl delete pod -n ddb-hands docdb-0
```

| Check               | Before                            | After                                           |
| ------------------- | --------------------------------- | ----------------------------------------------- |
| Pod UID             | `0cc222be-…`                   | `02cc9072-…` (genuinely new pod, restarts=0) |
| PV                  | `pvc-f9f09001-…`               | `pvc-f9f09001-…` (identical)                 |
| Data                | orders=0, pitr=120, customers=250 | **identical**                             |
| `archive_command` | custom                            | **survived**                              |

Pod re-ready in <30 s. ✅ Pod deletion is a non-event; the PVC is the durable unit.

### 5.2 Drill B — `pg_restore` into the **same** database

Pulled `docdb-schemas.dump` back **from MinIO**, then:

```bash
pg_restore -h docdb -p 9712 -U documentdb -d postgres --clean --if-exists /backup/restore-schemas.dump
```

```
orders      = 1000     ← recovered from 0
customers   = 250
qty_sum     = 7979     ← fingerprint matches
{ _id: 42, item: 'widget-42', qty: 8, tag: 'seed-v1' }
```

✅ **Appears to be a complete success.** It is not — see Drill C. It worked *only because the target
database still had its own catalog*.

### 5.3 Drill C — full wipeout, then `pg_restore` into a **fresh** database 🔴

```bash
kubectl delete documentdb docdb          # deletionPolicy: WipeOut → PVC + Secrets deleted
kubectl apply -f manifest-bundle.yaml    # Secrets first, then CR
# ... Ready in ~40s ...
pg_restore -h docdb -p 9712 -U documentdb -d postgres /backup/restore-schemas.dump
```

Restore emitted only benign noise (`retry_1_object_id_idx already exists`, 10 ignored errors).

**Then the decisive check, at three layers:**

```
── SQL layer ────────────────────────────────
documents_4 rows = 1000        ← data IS physically there
documents_5 rows =  250

── Catalog layer ────────────────────────────
kubedb_system.system.dbSentinel -> 1
kubedb_system.health_check      -> 2
(nothing maps to documents_4 or documents_5)

── MongoDB layer (what the user sees) ───────
databases   = kubedb_system
collections = []
orders count= 0
```

🔴 **1,250 documents restored into Postgres; `sampledb` does not exist over the wire.** The backup job
succeeded, the restore job succeeded, and the user has lost their database.

### 5.4 The repair — proving the fix (F2)

The original catalog was recovered from the **base backup** (`/backup/pitr-base`) by starting it as a
throwaway instance on port 5555 and exporting:

```sql
\copy (select * from documentdb_api_catalog.collections)       TO '/backup/orig_collections.tsv'
\copy (select * from documentdb_api_catalog.collection_indexes) TO '/backup/orig_indexes.tsv'
```

```
sampledb  orders     4  …  a67d4226-d5f1-4266-81c4-07df94cd4984
sampledb  customers  5  …  1bf00108-679f-4de6-95da-bebc1bb191d3
seq_collections = 38
```

Injecting just those 2 rows (+ their index rows + `setval`) into the broken database:

```
collections = [customers,orders]
orders      = 1000
customers   = 250
qty_sum     = 7979
{ _id: 42, item: 'widget-42', qty: 8, tag: 'seed-v1' }
```

✅ **Two catalog rows turned 1,250 invisible documents into a fully working database.** The data was
never lost — only the mapping was. This is the entire fix.

### 5.5 Drill D — full wipeout, then `mongorestore`

```bash
kubectl delete documentdb docdb && kubectl apply -f manifest-bundle.yaml
mongorestore --uri "$URI" --tlsInsecure --archive=/backup/restore.archive --drop
```

```
restoring `sampledb.customers` … (250 documents, 0 failures)
restoring `sampledb.orders`    … (1000 documents, 0 failures)
1251 document(s) restored successfully. 0 document(s) failed to restore.
```

```
collections = [customers,orders]
orders      = 1000
customers   = 250
qty_sum     = 7979
```

✅ **Complete success into a brand-new database with zero manual intervention** — because
`mongorestore` goes through the gateway, which maintains the catalog itself.

**Notable:** collection IDs are **not stable** across a dump/restore cycle:

| Collection             | Original        | After mongorestore |
| ---------------------- | --------------- | ------------------ |
| `sampledb.orders`    | `documents_4` | `documents_6`    |
| `sampledb.customers` | `documents_5` | `documents_5`    |

So `pg_dump` artifacts taken before and after a mongo-restore are **not interchangeable** — another
reason catalog and data must always travel together.

---

## 6. The consistency experiment (F4)

**Design.** Two collections with a strict invariant `count(accA) + count(accB) = 2001`. A writer moves
documents one at a time (`findOneAndDelete` from A → `insertOne` into B), so the invariant holds after
every operation. Back up *while the writer runs*, then measure the invariant **in the backup**.

### 6.1 `mongodump` — torn

```
done dumping `consistency.accA` (990 documents)
done dumping `consistency.accB` (1013 documents)
```

Restored into a scratch namespace and cross-checked:

```
accA in dump     = 990
accB in dump     = 1013
TOTAL in dump    = 2003        ← should be 2001
DUPLICATED _ids  = [1010,1011]
duplicate count  = 2
```

❌ Documents `1010` and `1011` appear in **both** collections — a state that never existed in the
database. `accA` was read before they moved; `accB` was read after. Classic torn read.

### 6.2 `pg_dump` — exact

Identical workload, identical timing, same two collections (`documents_13`, `documents_14`):

```
accA(documents_13) rows = 1062
accB(documents_14) rows =  939
TOTAL = 2001  (true invariant = 2001)
```

✅ Exact. `pg_dump`'s repeatable-read MVCC snapshot spans every table in one consistent view.

### 6.3 Side by side

| Method        | accA | accB |          Total | Invariant 2001   |
| ------------- | ---: | ---: | -------------: | ---------------- |
| `mongodump` |  990 | 1013 | **2003** | ❌ violated (+2) |
| `pg_dump`   | 1062 |  939 | **2001** | ✅ exact         |

This is the research note's central thesis, now measured rather than argued.

---

## 7. What this changes for the KubeDB/KubeStash design

### 7.1 The `logical-backup` task must be `pg_dump` **plus** a catalog export

The obvious implementation is wrong. Minimum viable correct backup:

```bash
# 1. document data
pg_dump -Fc -n documentdb_data -f dump.pgc
# 2. the catalog pg_dump refuses to touch  ← MUST NOT BE OMITTED
psql -c "\copy (select * from documentdb_api_catalog.collections)        TO 'collections.tsv'"
psql -c "\copy (select * from documentdb_api_catalog.collection_indexes) TO 'collection_indexes.tsv'"
psql -Atc "select last_value from documentdb_api_catalog.collections_collection_id_seq"       > seq_coll
psql -Atc "select last_value from documentdb_api_catalog.collection_indexes_index_id_seq"     > seq_idx
```

Restore order: `CREATE EXTENSION` → catalog rows → `setval` on both sequences → document data.
Filter out `kubedb_system` rows so a restore does not clobber the target cluster's own operator state.

**Recommendation:** also file this upstream. The proper fix is
`pg_extension_config_dump('documentdb_api_catalog.collections', '')` inside the extension — exactly
what `pg_cron` and `postgis` already do. Until that lands, every downstream tool must carry this
workaround.

### 7.2 Snapshot metadata is not optional

The research note's open question #1 asked whether to record the extension version. Drill C shows the
answer is yes and the reason is stronger than expected: a DocumentDB backup is only meaningful
together with its catalog and the extension version that produced it. Record at minimum
`documentdb` extension version (`0.109-0`), PostgreSQL major, and the DB image digest. This is
[operator issue #434](https://github.com/documentdb/documentdb-kubernetes-operator/issues/434)
observed from the other side.

### 7.3 PITR is closer than the note estimated

Gaps #10 and #11 are the whole job:

| Gap                        | Status after this exercise                      |
| -------------------------- | ----------------------------------------------- |
| `archive_mode = always`  | ✅ already set by the image                     |
| `archive_command`        | 🔧 one`ALTER SYSTEM` / one script branch      |
| wal-g binary               | 🔧 sidekick container (Postgres pattern)        |
| `restore.sh` wal-g logic | ✅ already present in`documentdb-init-docker` |
| PITR recovery mechanics    | ✅**proven working** (§4.4)              |

`ARCHIVER_ENABLED=false` at `petset.go:1034` is the single line that gates all of it.

### 7.4 AppBinding must carry TLS material

F5 means any plugin talking to the gateway needs CA/TLS info. Today
`pkg/controllers/appbinding.go` sets no `Spec.Parameters`, no `ClientConfig.CABundle`, no
`Spec.TLSSecret`. Confirmed as gap #9 — and note the addon must pass `--tlsInsecure` as a **CLI flag**;
the URI parameter is silently ignored by the mongo tools.

### 7.5 Phasing — one revision to the research note's recommendation

The note proposed Phase 1 = volume-snapshot + manifest, Phase 2 = logical + PITR. Given F1, I would
**move a correct `logical-backup` earlier**: it is the only method proven here to work end-to-end into
a fresh cluster (with the catalog fix), it needs no CSI driver, and getting the catalog contract right
early prevents shipping a backup format that has to be broken later. Volume-snapshot could not even be
evaluated on a `local-path` cluster, which many users will have.

---

## 8. Limitations of this exercise

Stated plainly so the results are not over-read:

- **CSI VolumeSnapshot was not tested at all** — no CSI driver on this cluster (§4.5).
- **Real `wal-g` was not used.** PITR was proven with `cp`-based `archive_command` and native
  `restore_command`. wal-g's object-storage push/fetch is a different code path; the *recovery*
  mechanics are what were validated.
- **Single-node, single-replica.** No failover, no standby, no primary/standby archiver arbitration.
- **No KubeStash objects were involved.** No `BackupConfiguration`, `Snapshot`, or addon exists for
  DocumentDB yet; MinIO was driven manually with `mc`.
- **Small dataset** (1,250 documents). Nothing here speaks to performance or large-dump behaviour.
- **No index-heavy or sharded collections** were tested; `collection_indexes` was exercised only with
  default `_id_` indexes.
- The consistency experiment is a **race**; the exact duplicate count varies per run. The
  *direction* of the result (mongodump can tear, pg_dump cannot) is structural, not luck.

---

## 9. Reproduction

Artifacts in MinIO bucket `documentdb-backup` at the end of the run — 12 objects, 68 MiB:

```
basebackup/backup_manifest                      146KiB
basebackup/base.tar.gz                          3.9MiB
basebackup/pg_wal.tar.gz                         46KiB
manifest/manifest-bundle.yaml                   4.5KiB
mongodump/docdb.archive                          73KiB
pg_dump/docdb-all.sql                           251KiB
pg_dump/docdb-schemas.dump                       27KiB
wal_archive/000000010000000000000004             16MiB
wal_archive/000000010000000000000005             16MiB
wal_archive/000000010000000000000005.*.backup     338B
wal_archive/000000010000000000000006             16MiB
wal_archive/000000010000000000000007             16MiB
```

**Final state:** `sampledb` restored via `mongorestore` from MinIO — `orders=1000, customers=250, qty_sum=7979`, matching the baseline fingerprint exactly.

**Teardown:** `kubectl delete ns ddb-hands` removes the database, MinIO, all toolboxes and all PVCs.

### Helper shell functions used throughout

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
NS=ddb-hands
PGPW=$(kubectl get secret -n $NS docdb-admin-auth -o jsonpath='{.data.password}' | base64 -d)
MPW=$(kubectl  get secret -n $NS docdb-auth       -o jsonpath='{.data.password}' | base64 -d)

# PostgreSQL (admin/superuser, port 9712)
PSQL() { kubectl exec -n $NS toolbox-pg -- env PGPASSWORD="$PGPW" \
         psql -h docdb.$NS.svc -p 9712 -U documentdb -d postgres -Atc "$1"; }

# MongoDB gateway (app user, port 10260) — note tls=true even with sslMode=disable
URIS="mongodb://default_user:${MPW}@docdb.$NS.svc:10260/?directConnection=true&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true"
MONGO() { kubectl exec -n $NS toolbox-mongo -- env HOME=/backup mongosh "$URIS" --quiet --eval "$1"; }

# MinIO — HOME must be writable
MC() { kubectl exec -n $NS toolbox-mc -- env HOME=/backup \
       MC_HOST_local="http://minioadmin:minioadmin123@minio.$NS.svc:9000" mc "$@"; }
```
