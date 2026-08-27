# Testing DocumentDB Backup/Restore *the Postgres Way* — Hands-On Plan

> Companion to `documentdb-handson-backup.md` (raw-tool drills, done) and `postgres-backup.md`
> (how the KubeDB Postgres pipeline is built). This document is the **procedure to run next**:
> exercise the *actual* KubeDB/KubeStash machinery — BackupStorage → Repository → BackupConfiguration
> → Snapshot → RestoreSession, plus the wal-g archiver Sidekick and PITR — against DocumentDB,
> **without writing a line of operator code**.
>
> Cluster state below was verified on **2026-08-21** against `/home/sabnaj/k3s.yaml`.

---

## 0. The idea: two tracks

The last round proved the *primitives* work (pg_basebackup, WAL/PITR, pg_dump's catalog defect).
What it did **not** touch is the machinery: no KubeStash, no Repository, no Snapshot, no Sidekick,
no restic. Those are exactly the parts you have to write operator code for. So run two tracks and
diff them.

| | Track A — **reference run** | Track B — **the real target** |
|---|---|---|
| Database object | `Postgres` CR, version `17.4-documentdb` | `DocumentDB` CR, version `pg17-0.109.0` |
| Backup driver | `PostgresArchiver` (operator does everything) | hand-written KubeStash + Sidekick YAML |
| Code needed | **none** | **none** |
| What it tells you | what "done" looks like, end to end, including PITR | which of those pieces the DocumentDB operator must emit, and which break |

**Track A is the shortcut nobody noticed.** The catalog already ships a Postgres version whose
image *is* a DocumentDB build, with a complete archiver stanza:

```
$ kubectl get postgresversion 17.4-documentdb -o yaml
spec:
  distribution: DocumentDB
  db:
    image: ghcr.io/appscode-images/postgres-documentdb:17-0.102.0-ferretdb-2.0.0   # exists, verified
  archiver:
    addon: {name: postgres-addon, tasks: {fullBackup: physical-backup, fullBackupRestore: physical-backup-restore, volumeSnapshot: volume-snapshot, manifestBackup: manifest-backup, manifestRestore: manifest-restore}}
    walg:  {image: ghcr.io/kubedb/postgres-archiver:v0.27.0_17.2-bookworm}          # exists, verified
```

That means you can run the **entire** Postgres backup + PITR pipeline today, against a database
that has the `documentdb` extensions loaded, and watch what happens to the extension-owned catalog
at every stage. It is a different DocumentDB build (0.102.0 + FerretDB gateway, not Microsoft's
`documentdb-local` 0.109.0 with the Rust gateway) — so it is a **reference**, not a substitute. But
every question about *the machinery* gets answered there for free.

Run A first. It takes ~40 minutes and gives you a working baseline to compare B against.

---

## 1. What is actually missing in your cluster right now

Verified today:

| Component | State | Consequence |
|---|---|---|
| KubeStash **CRDs** (`core.kubestash.com`, `storage.kubestash.com`) | ❌ **not installed** | no BackupStorage / BackupConfiguration / Snapshot / RestoreSession at all |
| KubeStash **operator** | ❌ no pod anywhere | nothing would reconcile them |
| `addons.kubestash.com` Addon + Function | ✅ installed (`postgres-addon`, 5 postgres functions) | came with the kubedb chart's `kubedb-kubestash-catalog` subchart — catalog only, no operator |
| `Sidekick` CRD + operator | ✅ `kubedb-sidekick` running | the WAL pusher can run |
| `PostgresArchiver` CRD | ✅ installed | Track A is possible |
| `DocumentDBArchiver` CRD | ❌ does not exist | Track B must be hand-wired |
| CSI driver / VolumeSnapshot CRDs | ❌ `local-path` only | `volume-snapshot` task is **untestable here**; skip it |
| MinIO + bucket `documentdb-backup` | ✅ up in `ddb-hands` | reuse it |
| `docdb` DocumentDB | ✅ Ready, 2d old, seeded | reuse it |

**So step one is: install KubeStash.** Everything else follows.

### 1.1 A layout coincidence that makes Track B possible

```
DocumentDB pod docdb-0:   PVC data-docdb-0  →  mounted at /var/pv,  PGDATA=/var/pv/data
Postgres archiver image:  hardcodes         /var/pv/data  and  /var/pv/wal_archive
                          (pkg/wal_coordinator.go:39-41, pkg/handle_cloud_bucket.go:125)
```

They match **exactly**. The stock `postgres-archiver` container will work against a DocumentDB PVC
with no changes — mount `data-docdb-0` at `/var/pv` and it finds everything where it expects.
That is the single most important thing to confirm in Track B.

---

## 2. Prerequisites (do once)

### P1 — Get a license that covers KubeStash

```bash
# your cluster UID, needed on the license page
kubectl get ns kube-system -o jsonpath='{.metadata.uid}'
# → 276b97f7-92ee-4e15-a398-4a7d41f1c043
```

Issue a license for that UID including the **KubeStash** product and save it as
`/home/sabnaj/kubestash-license.txt`. (Your existing `kubedb-kubedb-*-license` secrets cover the
KubeDB operators only.)

### P2 — Install the KubeStash operator

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml

helm install kubestash oci://ghcr.io/appscode-charts/kubestash \
  --version v2026.7.10 \
  --namespace kubedb --create-namespace \
  --set-file global.license=/home/sabnaj/kubestash-license.txt \
  --wait --debug
```

Pin the chart version to whatever the release matrix pairs with `kubedb-v2026.7.10` (your installed
chart). Verify:

```bash
kubectl get pods -n kubedb | grep kubestash
kubectl api-resources | grep -E 'backupstorages|repositories|backupconfigurations|backupsessions|snapshots|restoresessions|retentionpolicies'
```

You should see 7 new resources. If `snapshots` is missing you got the catalog chart, not the operator.

### P3 — Storage plumbing (one namespace, shared to all)

`ddb-hands` already has MinIO. Create the three objects KubeStash needs.

```bash
kubectl apply -f - <<'EOF'
---
# MinIO credentials, in the key names KubeStash's S3 backend expects
apiVersion: v1
kind: Secret
metadata: {name: s3-creds, namespace: ddb-hands}
stringData:
  AWS_ACCESS_KEY_ID: minioadmin
  AWS_SECRET_ACCESS_KEY: minioadmin123
---
# restic repository password. LOSE THIS AND EVERY BACKUP IS UNREADABLE.
apiVersion: v1
kind: Secret
metadata: {name: encrypt-secret, namespace: ddb-hands}
stringData:
  RESTIC_PASSWORD: changeit
---
apiVersion: storage.kubestash.com/v1alpha1
kind: BackupStorage
metadata: {name: minio-storage, namespace: ddb-hands}
spec:
  storage:
    provider: s3
    s3:
      endpoint: http://minio.ddb-hands.svc:9000
      bucket: documentdb-backup
      region: us-east-1
      prefix: kubestash
      secretName: s3-creds
  usagePolicy:
    allowedNamespaces: {from: All}      # so Track A can live in its own namespace
  default: true
  deletionPolicy: WipeOut
---
apiVersion: storage.kubestash.com/v1alpha1
kind: RetentionPolicy
metadata: {name: keep-all, namespace: ddb-hands}
spec:
  maxRetentionPeriod: 30d
  successfulSnapshots: {last: 20}
  failedSnapshots: {last: 5}
EOF
```

Wait for `kubectl get backupstorage -n ddb-hands` → `Ready`. If it stays empty, the operator can't
reach MinIO — check the endpoint scheme (`http://`, not https) and that `s3-creds` key names are
exactly `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`.

### P4 — Make a scratch namespace for Track A

```bash
kubectl create ns pg-docdb
# copy the encryption secret; the BackupStorage is already shared via usagePolicy
kubectl get secret encrypt-secret -n ddb-hands -o yaml \
  | sed 's/namespace: ddb-hands/namespace: pg-docdb/; /resourceVersion\|uid\|creationTimestamp\|selfLink/d' \
  | kubectl apply -f -
```

---

## 3. Track A — the reference run (Postgres CR + PostgresArchiver)

### A1 — Provision the DocumentDB-flavoured Postgres

```bash
kubectl apply -f - <<'EOF'
apiVersion: kubedb.com/v1
kind: Postgres
metadata: {name: pgdoc, namespace: pg-docdb}
spec:
  version: 17.4-documentdb
  replicas: 1
  storageType: Durable
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: local-path
    resources: {requests: {storage: 2Gi}}
  deletionPolicy: WipeOut
EOF

kubectl get pg -n pg-docdb -w      # wait for Ready
```

### A2 — Confirm the extensions are really there

This is the whole reason for using this image. **If this step fails, Track A is worthless — stop
and say so rather than working around it.**

```bash
PW=$(kubectl get secret pgdoc-auth -n pg-docdb -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres -c '\dx'
```

Expect `documentdb`, `documentdb_core`, plus `postgis`/`vector`/`pg_cron`. If they are absent:

```bash
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" \
  psql -U postgres -c 'CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;'
```

### A3 — Seed the same fingerprint dataset, through the extension API

No mongo gateway is guaranteed here, so drive the extension directly. This is equivalent — it goes
through the same `documentdb_api` functions the wire gateway calls.

```bash
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres <<'SQL'
SELECT documentdb_api.create_collection('sampledb','orders');
SELECT documentdb_api.create_collection('sampledb','customers');
SELECT documentdb_api.insert_one('sampledb','orders',
  format('{"_id":%s,"item":"widget-%s","qty":%s,"tag":"seed-v1"}', i, i, i % 17)::bson)
  FROM generate_series(0,999) i;
SELECT documentdb_api.insert_one('sampledb','customers',
  format('{"_id":%s,"name":"cust-%s"}', i, i)::bson)
  FROM generate_series(0,249) i;
SQL
```

**Record the fingerprint** — you will check every restore against it:

```bash
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres <<'SQL'
SELECT database_name, collection_name, collection_id FROM documentdb_api_catalog.collections ORDER BY collection_id;
SELECT relname, n_live_tup FROM pg_stat_user_tables WHERE schemaname='documentdb_data' ORDER BY relname;
SQL
```

### A4 — Turn on the archiver

```bash
kubectl apply -f - <<'EOF'
apiVersion: archiver.kubedb.com/v1alpha1
kind: PostgresArchiver
metadata: {name: pgdoc-archiver, namespace: pg-docdb}
spec:
  databases:
    namespaces: {from: Selector, selector: {matchLabels: {"kubernetes.io/metadata.name": pg-docdb}}}
    selector: {matchLabels: {"app.kubernetes.io/instance": pgdoc}}
  pause: false
  backupStorage:
    ref: {name: minio-storage, namespace: ddb-hands}
  encryptionSecret: {name: encrypt-secret, namespace: pg-docdb}
  retentionPolicy: {name: keep-all, namespace: ddb-hands}
  fullBackup:
    driver: Restic                    # NOT VolumeSnapshotter — no CSI in this cluster
    scheduler:
      schedule: "*/30 * * * *"
      successfulJobsHistoryLimit: 3
      failedJobsHistoryLimit: 3
  manifestBackup:
    scheduler:
      schedule: "*/45 * * * *"
  logBackup:
    successfulLogHistoryLimit: 5
    failedLogHistoryLimit: 3
  deletionPolicy: WipeOut
EOF
```

### A5 — Watch the bootstrap sequence (**this is the point of Track A**)

Open three terminals. The ordering is the thing you are here to see.

```bash
# 1. the objects the operator generates for you
kubectl get backupconfiguration,backupsession,snapshot,sidekick -n pg-docdb -w

# 2. the gate
kubectl get pg pgdoc -n pg-docdb -o jsonpath='{.status.conditions}' | jq '.[] | select(.type|test("Backup|Archiver"))'

# 3. operator reasoning
kubectl logs -n kubedb kubedb-kubedb-provisioner-0 -f | grep -i -E 'archiver|sidekick|snapshot|backupconfig'
```

**What you should observe, in order:**

1. `BackupConfiguration pgdoc-backup-config` appears with **two sessions** — `full` and `manifest`.
2. A long-lived `Snapshot pgdoc-incremental-snapshot` appears in `Running` phase and *never
   completes*. That is the WAL ledger, not a backup — it is a mutable row the archiver writes
   LSN/timestamp bookkeeping into.
3. An immediate `BackupSession` for the `full` session fires — **not** waiting for the cron.
4. Only **after** that session succeeds does `Sidekick pgdoc-sidekick` get created and its pod start.

Step 4 is the `InitialBackupSucceeded` gate (`pkg/controller/reconciler.go:155-215`). Between
Postgres starting (which already writes `archive_command`) and the sidekick starting, WAL just
accumulates on the PVC. Confirm the backlog is real and then drained:

```bash
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- ls -la /var/pv/wal_archive/ | head
kubectl logs -n pg-docdb -l app.kubernetes.io/name=sidekicks.apps.k8s.appscode.com --tail=100 | grep -i 'pushing'
```

### A6 — Verify the object layout in MinIO

```bash
alias MC='kubectl exec -n ddb-hands toolbox-mc -- env HOME=/backup MC_HOST_local=http://minioadmin:minioadmin123@minio.ddb-hands.svc:9000 mc'
MC ls -r local/documentdb-backup/kubestash/ | head -40
```

Expect three distinct trees:

```
kubestash/pg-docdb/pgdoc/full/       ← restic repo, contains base.tar (pg_basebackup -D - -F t)
kubestash/pg-docdb/pgdoc/manifest/   ← restic repo, CR + Secrets YAML
kubestash/pg-docdb/pgdoc/wal/        ← wal-g native layout: basebackups_005/ + wal_005/
```

The `wal/` tree is written by wal-g directly (no restic, no encryption secret). The other two are
restic repos. **This split is a design fact worth internalising** — the WAL path and the full-backup
path do not share a format, a tool, or a credential.

### A7 — PITR drill

```bash
# t0 : known-good state, note the count
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres -Atc \
  "SELECT count(*) FROM documentdb_data.documents_4;"          # → 1000

# force a WAL boundary so the archive is current
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres -c "SELECT pg_switch_wal();"
sleep 20

# T1 : the recovery target
T1=$(kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres -Atc "SELECT now();")
echo "TARGET T1 = $T1"

# the disaster
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres -c \
  "SELECT documentdb_api.delete('sampledb', '{\"delete\":\"orders\",\"deletes\":[{\"q\":{},\"limit\":0}]}'::bson);"
kubectl exec -n pg-docdb pgdoc-0 -c postgres -- env PGPASSWORD="$PW" psql -U postgres -c "SELECT pg_switch_wal();"
sleep 20
```

Now restore into a **new** Postgres CR — this is the KubeDB restore idiom, a fresh database that
initialises itself from the archive:

```bash
kubectl apply -f - <<EOF
apiVersion: kubedb.com/v1
kind: Postgres
metadata: {name: pgdoc-restored, namespace: pg-docdb}
spec:
  version: 17.4-documentdb
  replicas: 1
  storageType: Durable
  storage:
    accessModes: ["ReadWriteOnce"]
    storageClassName: local-path
    resources: {requests: {storage: 2Gi}}
  init:
    archiver:
      encryptionSecret: {name: encrypt-secret, namespace: pg-docdb}
      fullDBRepository:  {name: pgdoc-full, namespace: pg-docdb}
      recoveryTimestamp: "$T1"
  deletionPolicy: WipeOut
EOF
```

> `fullDBRepository` must be the **Repository object name** for the `full` session — read it off
> `kubectl get repository -n pg-docdb` rather than guessing.

Watch it resolve the base backup and replay:

```bash
kubectl get restoresession -n pg-docdb -w
kubectl logs -n pg-docdb pgdoc-restored-0 -c postgres -f | grep -iE 'recovery|restored log file|consistent|promote'
```

You want to see, in the log: `starting point-in-time recovery to <T1>`, a run of
`restored log file ...`, then `recovery stopping before commit of transaction ...`, then
`selected new timeline ID: 2`.

**Verify against the fingerprint:**

```bash
PW2=$(kubectl get secret pgdoc-restored-auth -n pg-docdb -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n pg-docdb pgdoc-restored-0 -c postgres -- env PGPASSWORD="$PW2" psql -U postgres <<'SQL'
SELECT database_name, collection_name, collection_id FROM documentdb_api_catalog.collections ORDER BY collection_id;
SELECT count(*) FROM documentdb_data.documents_4;
SQL
```

Success = **catalog has both collections** *and* `documents_4` = 1000.

The catalog surviving here is the load-bearing result. It survives because the base is
`pg_basebackup` — a byte-level copy that captures extension-owned tables unconditionally, which
`pg_dump` does not. Record it explicitly; it is the argument for why the DocumentDB addon's full
backup must be physical.

### A8 — The negative control (do not skip this)

Run the **logical** task against the same database and prove it loses the catalog *inside the real
pipeline*, not just in a manual `pg_dump`:

```bash
kubectl apply -f - <<'EOF'
apiVersion: core.kubestash.com/v1alpha1
kind: BackupConfiguration
metadata: {name: pgdoc-logical, namespace: pg-docdb}
spec:
  target: {apiGroup: kubedb.com, kind: Postgres, name: pgdoc, namespace: pg-docdb}
  backends:
  - name: minio
    storageRef: {name: minio-storage, namespace: ddb-hands}
    retentionPolicy: {name: keep-all, namespace: ddb-hands}
  sessions:
  - name: logical
    scheduler: {schedule: "0 */6 * * *", jobTemplate: {backoffLimit: 1}}
    repositories:
    - name: pgdoc-logical-repo
      backend: minio
      directory: /pg-docdb/pgdoc/logical
      encryptionSecret: {name: encrypt-secret, namespace: pg-docdb}
    addon:
      name: postgres-addon
      tasks: [{name: logical-backup}]
EOF

kubectl create -f - <<'EOF'
apiVersion: core.kubestash.com/v1alpha1
kind: BackupSession
metadata: {generateName: pgdoc-logical-manual-, namespace: pg-docdb}
spec:
  invoker: {apiGroup: core.kubestash.com, kind: BackupConfiguration, name: pgdoc-logical}
EOF
```

Restore that into a *fresh* Postgres and query `documentdb_api_catalog.collections`. Expected result:
**empty catalog, populated `documents_*` tables** — the exact F1/Drill-C failure, now reproduced
through KubeStash. That is your evidence for why a DocumentDB `logical-backup` task needs a catalog
export step and cannot just be `pg_dumpall`.

---

## 4. Track B — the real target (DocumentDB CR, hand-wired)

Everything here is YAML you write by hand that the DocumentDB operator would eventually generate.
Reuse the existing `docdb` in `ddb-hands`.

### B1 — Give DocumentDB a Postgres-shaped face

The postgres plugins resolve their target by doing a plain `Get` on the target's name/namespace **as
an AppBinding** — they never check the kind (`pkg/common/helpers.go:166`). So a second AppBinding is
all it takes.

Two details matter:

* **Target the AppBinding, not the DocumentDB CR.** If `spec.target.apiGroup` is `kubedb.com`, the
  plugin takes the `IsTargetManagedByKubeDB()` branch and calls `WaitForDatabaseReadyCondition()`,
  which does `Get` into a **`Postgres{}` struct** (`helpers.go:139-164`). Against a DocumentDB that
  poll never succeeds and the job dies at `--wait-timeout`. Pointing at
  `appcatalog.appscode.com/AppBinding` skips that branch entirely.
* **Declare `version: "17.2"`.** The Function image is
  `ghcr.io/kubedb/postgres-restic-plugin:v0.29.0_${DB_VERSION}` and `availableVersions` is
  `[12.17, 14.10, 16.4, 17.2, 18.2]`. `0.109.0` resolves to a tag that does not exist.

```bash
kubectl apply -f - <<'EOF'
apiVersion: appcatalog.appscode.com/v1alpha1
kind: AppBinding
metadata: {name: docdb-pg, namespace: ddb-hands}
spec:
  type: kubedb.com/postgres
  version: "17.2"
  clientConfig:
    service:
      name: docdb
      port: 9712            # the PostgreSQL port, NOT 10260
      scheme: postgresql
  secret: {name: docdb-admin-auth}   # superuser 'documentdb'; keys are username/password ✓
EOF
```

### B2 — Physical backup through KubeStash

```bash
kubectl apply -f - <<'EOF'
apiVersion: core.kubestash.com/v1alpha1
kind: BackupConfiguration
metadata: {name: docdb-physical, namespace: ddb-hands}
spec:
  target: {apiGroup: appcatalog.appscode.com, kind: AppBinding, name: docdb-pg, namespace: ddb-hands}
  backends:
  - name: minio
    storageRef: {name: minio-storage, namespace: ddb-hands}
    retentionPolicy: {name: keep-all, namespace: ddb-hands}
  sessions:
  - name: full
    scheduler: {schedule: "*/30 * * * *", jobTemplate: {backoffLimit: 1}}
    repositories:
    - name: docdb-full-repo
      backend: minio
      directory: /ddb-hands/docdb/full
      encryptionSecret: {name: encrypt-secret, namespace: ddb-hands}
    addon:
      name: postgres-addon
      tasks: [{name: physical-backup}]
EOF

kubectl create -f - <<'EOF'
apiVersion: core.kubestash.com/v1alpha1
kind: BackupSession
metadata: {generateName: docdb-full-manual-, namespace: ddb-hands}
spec:
  invoker: {apiGroup: core.kubestash.com, kind: BackupConfiguration, name: docdb-physical}
EOF

kubectl get backupsession,snapshot -n ddb-hands -w
kubectl logs -n ddb-hands -l kubestash.com/invoker-name=docdb-physical --tail=200
```

The plugin runs `pg_basebackup -D - -F t` (`pkg/options.go:47`) and pipes it straight into restic as
`base.tar` — nothing lands on local disk. Confirm the Snapshot reaches `Succeeded` and that
`kubestash/ddb-hands/docdb/full/` in MinIO has a restic repo.

**Then verify the thing you actually care about**: extract `base.tar` into a scratch pod, start it
with the `documentdb-local` image (the trick from §5.4 of the hands-on doc — the DB image is its own
best toolbox), and confirm `documentdb_api_catalog.collections` has 6 rows. That closes the loop:
physical backup through the real pipeline preserves the catalog.

### B3 — Turn on WAL archiving

`ARCHIVER_ENABLED` is hardcoded `false` in `pkg/controllers/petset.go:1034`, and `archive_command`
is therefore `/bin/true` — WAL is being generated and silently discarded right now. For the drill,
set it at runtime. It persists in `postgresql.auto.conf` on the PVC and survives pod deletion
(finding F6), which is convenient here and a footgun in production.

```bash
kubectl exec -n ddb-hands docdb-0 -- mkdir -p /var/pv/wal_archive/complete
APW=$(kubectl get secret docdb-admin-auth -n ddb-hands -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n ddb-hands docdb-0 -- env PGPASSWORD="$APW" psql -U documentdb -p 9712 -d postgres <<'SQL'
ALTER SYSTEM SET archive_command = 'test ! -f /var/pv/wal_archive/%f && cp %p /var/pv/wal_archive/%f';
SELECT pg_reload_conf();
SHOW archive_mode; SHOW archive_command;
SQL
```

`archive_mode` is already `always`, and `archive_command` is SIGHUP-level, so no restart is needed.

> **Note the shape of this.** Postgres copies to a local directory; it never talks to object
> storage. That is deliberate: if `archive_command` fails, Postgres stops recycling WAL and fills
> the disk. A local `cp` always succeeds in milliseconds; the flaky network push is the sidekick's
> problem, and the sidekick is allowed to crash. When you write the DocumentDB operator, reproduce
> this two-hop design — do not put wal-g in `archive_command`.

### B4 — The WAL ledger Snapshot

The archiver writes its bookkeeping into a Snapshot that must already exist (`EnsureIncSnapshot`
does this in the Postgres operator). Create it by hand:

```bash
kubectl apply -f - <<'EOF'
apiVersion: storage.kubestash.com/v1alpha1
kind: Snapshot
metadata: {name: docdb-incremental-snapshot, namespace: ddb-hands}
spec:
  type: Manifest
  repository: docdb-full-repo
  session: full
  snapshotID: docdb-incremental-snapshot
  appRef: {apiGroup: appcatalog.appscode.com, kind: AppBinding, name: docdb-pg, namespace: ddb-hands}
EOF
```

If the Snapshot CRD rejects fields here, read the **generated** one from Track A
(`kubectl get snapshot pgdoc-incremental-snapshot -n pg-docdb -o yaml`) and copy its shape verbatim.
That is the authoritative template and is exactly why Track A runs first.

### B5 — Hand-write the archiver Sidekick

Env values below are transcribed from `pkg/controller/archiver.go:68-140` (`getArchiverEnvs`) and
`pkg/controller/provider.go:67` (`getS3Env`); the args from `pkg/controller/sidekick.go:337-400`.

```bash
kubectl apply -f - <<'EOF'
apiVersion: apps.k8s.appscode.com/v1alpha1
kind: Sidekick
metadata: {name: docdb-sidekick, namespace: ddb-hands}
spec:
  leader:
    selector: {matchLabels: {"app.kubernetes.io/instance": docdb}}
    selectionPolicy: First
  restartPolicy: Always
  containers:
  - name: wal-g
    image: ghcr.io/kubedb/postgres-archiver:v0.27.0_17.2-bookworm
    args:
    - archive
    - --snapshot-namespace=ddb-hands
    - --snapshot-name=docdb-incremental-snapshot
    env:
    - {name: PRIMARY_DNS_NAME, value: docdb.ddb-hands.svc}
    - {name: NAMESPACE,        value: ddb-hands}
    - {name: DBNAME,           value: docdb}
    - {name: SSL_MODE,         value: disable}
    - {name: PGDATA,           value: /var/pv/data}
    - {name: SUCCESSFUL_LOG_HISTORY_LIMIT, value: "5"}
    - {name: FAILED_LOG_HISTORY_LIMIT,     value: "3"}
    - {name: POSTGRES_USER,     valueFrom: {secretKeyRef: {name: docdb-admin-auth, key: username}}}
    - {name: POSTGRES_PASSWORD, valueFrom: {secretKeyRef: {name: docdb-admin-auth, key: password}}}
    - {name: AWS_S3_FORCE_PATH_STYLE, value: "true"}
    - {name: AWS_REGION,   value: us-east-1}
    - {name: AWS_ENDPOINT, value: http://minio.ddb-hands.svc:9000}
    - {name: WALG_S3_PREFIX, value: s3://documentdb-backup/kubestash/ddb-hands/docdb/wal}
    envFrom:
    - secretRef: {name: s3-creds}
    volumeMounts:
    - {name: data, mountPath: /var/pv}
  volumes:
  - name: data
    persistentVolumeClaim: {claimName: data-docdb-0}
EOF
```

Two things to be aware of:

* **`PGDATA` must be `/var/pv/data`, and the mount must be at `/var/pv`.** The archiver hardcodes
  `/var/pv/wal_archive*` — mounting anywhere else silently archives nothing.
* **RWO PVC, two pods.** `ReadWriteOnce` is node-scoped in Kubernetes, so a second pod on the *same
  node* can mount it. Single-node k3s makes this free; on a real cluster the sidekick's leader
  election is what keeps it co-located with the primary. If the sidekick pod hangs in `Pending` with
  a `Multi-Attach` event, that is why.

You will likely also need a ServiceAccount + Role granting `get/list/watch/update/patch` on
`snapshots.storage.kubestash.com` — copy it from Track A
(`kubectl get role,rolebinding,sa -n pg-docdb | grep sidekick`).

### B6 — Prove WAL is reaching object storage

```bash
kubectl exec -n ddb-hands docdb-0 -- env PGPASSWORD="$APW" psql -U documentdb -p 9712 -d postgres -c "SELECT pg_switch_wal();"
sleep 20
kubectl logs -n ddb-hands -l app.kubernetes.io/instance=docdb-sidekick --tail=50
MC ls -r local/documentdb-backup/kubestash/ddb-hands/docdb/wal/
```

Expect `wal_005/0000000100000000000000XX.br` objects appearing. Also check that the local
`/var/pv/wal_archive` directory drains — files should move to `complete/`, not pile up forever.

### B7 — PITR restore

No operator support exists, so drive it by hand. Two sources: base from the restic repo (B2), WAL
from MinIO via wal-g.

1. New empty PVC + a pod running `documentdb-local:pg17-0.109.0` with the entrypoint overridden to
   `sleep infinity`, plus a second container (or an init container) using the **archiver image** so
   `wal-g` is on PATH with the same env as B5.
2. Restore the base into the fresh `PGDATA`: extract `base.tar` out of the restic repo (`restic -r
   s3:... restore latest`), or — simpler for a drill — take a fresh `pg_basebackup -Fp` before the
   disaster, exactly as you did in §4.4.
3. Write the recovery config into `$PGDATA/postgresql.auto.conf`:
   ```
   restore_command = 'wal-g wal-fetch %f %p'
   recovery_target_time = '<T1>'
   recovery_target_action = 'promote'
   ```
   and `touch $PGDATA/recovery.signal`.
4. Start Postgres in the documentdb image and watch for `starting point-in-time recovery`.
5. Verify through **both** layers — SQL *and* mongo, because that is where the catalog defect hides:
   ```bash
   psql  -c "SELECT * FROM documentdb_api_catalog.collections;"       # must be non-empty
   mongosh "mongodb://...:10260/...&tls=true&tlsAllowInvalidCertificates=true" \
     --eval 'db.getSiblingDB("sampledb").orders.countDocuments({})'   # must be 1000
   ```

The difference from §4.4 is only step 3's `restore_command`: `wal-g wal-fetch` instead of `cp`. If
that works, the WAL path is genuinely object-storage-backed and Track B is complete.

### B8 — Manifest backup

Reuse the `manifest-backup` task from the addon, targeting the DocumentDB CR. Expect it to fail or
produce something wrong — it is `kubedbmanifest-backup`, which knows Postgres kinds. Record the exact
failure; it tells you whether you need a DocumentDB-specific manifest task or just a kind mapping.
Recall from F7 that a manifest **restore** must apply Secrets *before* the CR (so the operator adopts
them) and must strip the whole `ownerReferences` list, not just `uid`.

---

## 5. What to record

Keep one table. This is the deliverable — a design memo for the operator work, not a test log.

| Question | Track A | Track B |
|---|---|---|
| Does `physical-backup` preserve `documentdb_api_catalog`? | | |
| Does `logical-backup` preserve it? (expect **no**) | | |
| Does PITR replay produce a queryable Mongo layer? | | |
| Does the stock archiver image work unmodified on a DocumentDB PVC? | n/a | |
| Does the WAL ledger Snapshot need DocumentDB-specific fields? | | |
| Does `manifest-backup` handle `kind: DocumentDB`? | | |
| How long between DB Ready and sidekick start? (the gate window) | | n/a |
| Does anything require `ARCHIVER_ENABLED=true`, or is `ALTER SYSTEM` enough? | n/a | |

---

## 6. Failures you should expect, and what they mean

| Symptom | Cause | This is |
|---|---|---|
| Backup job hangs then times out at `--wait-timeout` | target `apiGroup: kubedb.com` → plugin polls for a `Postgres` CR that doesn't exist | **known**; use the AppBinding target (B1) |
| `ImagePullBackOff` on `postgres-restic-plugin:v0.29.0_0.109.0` | `${DB_VERSION}` came from the AppBinding's version | **known**; set AppBinding `version: "17.2"` |
| Restore has data but `documentdb_api_catalog.collections` is empty | extension-owned tables; `pg_dump` skips them silently (exit 0, no warning) | **known — finding F1**, the whole reason for this exercise |
| Sidekick logs "no wal files found" forever | mount path isn't `/var/pv`, or `archive_command` is still `/bin/true` | setup error |
| `volume-snapshot` task never starts | no CSI driver on `local-path` | **environment limit**; do not report as a DocumentDB finding |
| Sidekick pod `Pending` with `Multi-Attach` | RWO PVC across nodes | single-node k3s shouldn't hit it; check leader selector |
| `BackupStorage` never goes `Ready` | endpoint scheme, or wrong secret key names | setup error |

The third row is the one that matters. It is not a bug in the test — it is the defect the DocumentDB
addon has to design around, and seeing it inside real KubeStash machinery is stronger evidence than
seeing it from a shell.

---

## 7. Teardown

```bash
kubectl delete ns pg-docdb            # Track A
kubectl delete backupconfiguration,sidekick,snapshot,appbinding -n ddb-hands --all   # Track B wiring
kubectl delete ns ddb-hands           # everything, when you are done
helm uninstall kubestash -n kubedb    # only if you want the cluster back as it was
```

Leave `ddb-hands` up while you are still comparing — the seeded database and MinIO bucket are the
expensive parts to rebuild.
