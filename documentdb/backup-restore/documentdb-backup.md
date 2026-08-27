# DocumentDB Backup & Restore — Research Notes

> **Scope.** How Microsoft's DocumentDB does backup today, every possible way *we* could back up
> DocumentDB, hands-on runbooks for each, how the wider OSS community handles it, and finally what
> KubeDB/KubeStash should adopt.
>
> **Status.** Research + runbooks. Nothing here has been executed against a live cluster yet —
> commands are derived from source, not from a recorded session. Section 7 is deliberately left as
> *options for discussion*, not a committed design.
>
> **Date.** 2026-08-05

---

## ⚠️ Read this first — the name collision

Most web results for *"DocumentDB backup"* are about **Amazon DocumentDB**, a completely unrelated
AWS product with its own continuous-backup/PITR story. This document is about
**Microsoft DocumentDB** ([github.com/documentdb/documentdb](https://github.com/documentdb/documentdb)) —
the open-source, MongoDB-wire-compatible database built on PostgreSQL, open-sourced January 2025.
Do not mix the two when researching.

---

## Table of contents

1. [What DocumentDB actually is](#1-what-documentdb-actually-is)
2. [How Microsoft takes backups today](#2-how-microsoft-takes-backups-today)
3. [Every possible way to back up DocumentDB](#3-every-possible-way-to-back-up-documentdb)
4. [Hands-on demo runbooks](#4-hands-on-demo-runbooks)
5. [Community comparison](#5-community-comparison)
6. [How KubeStash works](#6-how-kubestash-works)
7. [What should KubeStash adopt? (for discussion)](#7-what-should-kubestash-adopt--for-discussion)

---

## 1. What DocumentDB actually is

**DocumentDB is not a new storage engine.** It is PostgreSQL plus a set of extensions, plus a Rust
gateway that speaks the MongoDB wire protocol. This single fact determines every backup option we have.

### 1.1 The component stack

| Component                      | What it is                                                                                                      | Source                                                                       |
| ------------------------------ | --------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| `pg_documentdb_core`         | Introduces the native`bson` datatype + comparison/hash operators                                              | [repo](https://github.com/documentdb/documentdb/tree/main/pg_documentdb_core) |
| `pg_documentdb`              | Public API surface — CRUD, aggregation, index management. Extension name is`documentdb`                      | [repo](https://github.com/documentdb/documentdb/tree/main/pg_documentdb)      |
| `pg_documentdb_gw`           | **Rust** gateway (Tokio + `bson 2.15` + `deadpool-postgres`) translating MongoDB wire protocol → SQL | [repo](https://github.com/documentdb/documentdb/tree/main/pg_documentdb_gw)   |
| `pg_documentdb_extended_rum` | Forked RUM index access method                                                                                  | repo                                                                         |
| `pg_documentdb_distributed`  | Citus-based multi-node variant (not used by either k8s operator)                                                | `internal/`                                                                |

The extension dependency chain, verbatim from
[`pg_documentdb/documentdb.control`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb/documentdb.control):

```ini
comment = 'API surface for DocumentDB for PostgreSQL'
default_version = '0.117-0'
module_pathname = '$libdir/pg_documentdb'
relocatable = false
superuser = true
requires = 'documentdb_core, pg_cron, tsm_system_rows, vector, postgis'
```

> **This line matters for restore portability.** Any target you restore a logical dump into must
> already have **pg_cron, pgvector, PostGIS and tsm_system_rows** available, plus a *compatible
> version* of the `documentdb` extension itself.

**PostgreSQL versions:** PG 17 and 18 are Tier 1 (CI-built and tested). PG 15/16 are build-on-demand;
PG 15 is extension-only — `documentdb-setup` rejects it because gateway setup requires PG 16+
([packaging/README.md](https://github.com/documentdb/documentdb/blob/main/packaging/README.md)).

### 1.2 Where the data physically lives

From [`pg_documentdb/Makefile`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb/Makefile),
the schema names are compile-time substitutions:

| Schema                      | Contents                                                                                                  |
| --------------------------- | --------------------------------------------------------------------------------------------------------- |
| `documentdb_core`         | The`bson` type and its operators                                                                        |
| `documentdb_api`          | Public commands —`insert`, `find_cursor_first_page`, `create_collection`, `shard_collection`, … |
| `documentdb_api_internal` | Internal helpers, cursors, index internals                                                                |
| `documentdb_api_catalog`  | **The catalog**                                                                                     |
| `documentdb_data`         | **The actual documents**                                                                            |

The catalog, from
[`collection_metadata--0.10-0.sql`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb/sql/schema/collection_metadata--0.10-0.sql):

```sql
CREATE TABLE __API_CATALOG_SCHEMA__.collections (
    database_name   text   not null,
    collection_name text   not null,
    collection_id   bigint not null unique default ..._get_next_collection_id(),
    shard_key       __CORE_SCHEMA__.bson,
    collection_uuid uuid,
    PRIMARY KEY (database_name, collection_name), ...
);
```

Index metadata lives in `documentdb_api_catalog.collection_indexes`. And per
[`src/metadata/collection.c`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb/src/metadata/collection.c):

```c
/* table name is: documents_<collection id> */
...
/* like ApiDataSchemaName.documents_1_111 and the parsed value will be 1.
   table is documents_1 (parent table). */
```

**So: one MongoDB collection = one PostgreSQL heap table `documentdb_data.documents_<collection_id>`,**
with shard child tables `documents_<id>_<shard_id>`, holding `bson` values indexed by GIN/RUM/HNSW.

### 1.3 Ports and identities in KubeDB's operator

Verified against `vendor/kubedb.dev/apimachinery/apis/kubedb/constants.go`:

| Constant                                              | Name            | Value                                        |
| ----------------------------------------------------- | --------------- | -------------------------------------------- |
| `DocumentDBGatewayPort` / `DocumentDBDefaultPort` | `gateway`     | **10260** (MongoDB wire)               |
| `DocumentDBDatabasePort`                            | `postgres`    | **9712** (PostgreSQL)                  |
| `DocumentDBCoordinatorPort`                         | `coordinator` | 2380                                         |
| `DocumentDBMetricsPort`                             | —              | 56790                                        |
| `DocumentDBDefaultUsername`                         | —              | `default_user` → secret `<db>-auth`     |
| `DocumentDBAdminUsername`                           | —              | `documentdb` → secret `<db>-admin-auth` |
| `DefaultDocumentDBDatabase`                         | —              | `sampledb`                                 |
| `DocumentDBDataDir`                                 | —              | `/var/pv` (PGDATA lives under here)        |

> Note the port choice: upstream `documentdb-local` puts Postgres on 5432; **KubeDB moves it to 9712**.
> Every runbook below uses 9712.

### 1.4 The two consequences that drive everything

1. **Every PostgreSQL backup tool applies.** `pg_dump`, `pg_basebackup`, wal-g, barman, pgBackRest,
   PITR — all work in principle, because the bytes on disk are an ordinary PGDATA directory.
2. **No Mongo-native consistency mechanism exists.** `hello`/`isMaster` returns `"msg": "isdbgrid"` —
   DocumentDB advertises itself as a **mongos / sharded cluster**, not a replica set. There is no
   `local.oplog.rs`, no `applyOps`, no `replSetGetStatus`. Oplog support is a *closed* feature request
   ([#81](https://github.com/documentdb/documentdb/issues/81)), blocked on capped collections
   ([#342](https://github.com/documentdb/documentdb/issues/342)). Replica-set topology is
   [#445](https://github.com/documentdb/documentdb/issues/445), open.

> ### 🔑 The fork in the road
>
> **Postgres-shaped backup can give us PITR. Mongo-shaped backup can never give us even a consistent
> multi-collection dump**, because `mongodump --oplog` / `mongorestore --oplogReplay` are impossible.

---

## 2. How Microsoft takes backups today

There are three separate answers, and it is important not to blur them.

### 2a. The engine repo (`documentdb/documentdb`) — **nothing**

I searched the repo's issues, PRs, wiki, and the docs site for every backup-related term:

| Term              | Hits in`documentdb/documentdb`                                                                     |
| ----------------- | ---------------------------------------------------------------------------------------------------- |
| `pg_dump`       | **0**                                                                                          |
| `pg_basebackup` | **0**                                                                                          |
| `barman`        | **0**                                                                                          |
| `pgBackRest`    | **0**                                                                                          |
| `backup`        | 5,**none about backup as a feature** (durability testing, alpine packaging, one-command setup) |
| `restore`       | 9, all incidental (test infra, entrypoint fixes)                                                     |
| `mongodump`     | 3, incidental                                                                                        |
| `WAL`           | 4, incidental                                                                                        |

- Top-level markdown: `README`, `CHANGELOG`, `CONTRIBUTING`, `GOVERNANCE`, `MAINTAINERS`, `SECURITY`,
  `packaging/README`, RFCs 0003/0005/0006. **No backup doc.**
- [Wiki](https://github.com/documentdb/documentdb/wiki): Home, Components, Contributing, Functions,
  Regression Tests Guide, Vector Search. **No backup page, no compatibility page, no limitations page.**
- [documentdb.io/docs](https://documentdb.io/docs/): the "Architecture under the hood" page is
  literally a *coming soon* stub. **No backup section.**

**This is a finding, not a research gap.** The engine ships no backup guidance at all — not even a note
that `documentdb_data` tables are `pg_dump`-able, nor a warning about extension-version compatibility
on restore. The entire backup story has been pushed down into the Kubernetes operator.

Relevant open issue: [#688 — &#34;documentdb-local: no end-to-end coverage for lifecycle, durability, and
default security posture&#34;](https://github.com/documentdb/documentdb/issues/688). Durability is
*untested* in the local image.

### 2b. The Kubernetes operator — **CSI VolumeSnapshot, and only that**

[`documentdb/documentdb-kubernetes-operator`](https://github.com/documentdb/documentdb-kubernetes-operator)
wraps **CloudNativePG**. From their
[architecture overview](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/operator-public-documentation/preview/architecture/overview.md):

> "It builds on [CloudNative-PG](https://cloudnative-pg.io/) for PostgreSQL management while adding the
> DocumentDB Gateway for MongoDB-compatible access."

Architecture facts:

- CNPG runs in `cnpg-system` and ships as a **Helm dependency** of the DocumentDB chart —
  *"Do I need to install CloudNativePG separately? **No.**"* ([FAQ](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/operator-public-documentation/preview/faq.md))
- The gateway sidecar is injected by a **CNPG-I plugin** (`operator/cnpg-plugins/sidecar-injector/`), an admission webhook.
- Extension binaries are mounted into an upstream CNPG Postgres image via a Kubernetes **ImageVolume** —
  hence the **Kubernetes ≥ 1.35** requirement (1.33/1.34 need the `ImageVolume` feature gate).
- The operator is **preview / not production-recommended**, per its own FAQ.

**CRDs** — API group `documentdb.io/preview`:

| Kind                | Resource             | Notes                   |
| ------------------- | -------------------- | ----------------------- |
| `DocumentDB`      | `dbs`              | shortName`documentdb` |
| `Backup`          | `backups`          |                         |
| `ScheduledBackup` | `scheduledbackups` |                         |

> The Nov-2025 launch blog shows `documentdb.microsoft.com/v1` / `kind: DocumentDBCluster`. **That is
> stale.** Current is `documentdb.io/preview` / `kind: DocumentDB`.

**The entire CNPG backup wiring**, from `operator/src/internal/cnpg/cnpg_cluster.go`:

```go
Backup: &cnpgv1.BackupConfiguration{
    VolumeSnapshot: &cnpgv1.VolumeSnapshotConfiguration{
        SnapshotOwnerReference: "backup", // snapshots deleted when Backup resource is deleted
    },
    Target: cnpgv1.BackupTarget("primary"),
},
```

That's it. A sweep of all 741 files in the operator repo for `barman|objectstore|s3|minio|wal` matched
only `03_documentdb_wal_replica.yaml` — which is **cross-cluster WAL *replication*** (multi-region
streaming replication), *not* WAL archiving for PITR.

**The `Backup` CRD**, verbatim from
[`backup_types.go`](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/operator/src/api/preview/backup_types.go):

```go
// +kubebuilder:validation:XValidation:rule="oldSelf == self",message="BackupSpec is immutable once set"
type BackupSpec struct {
	// Cluster specifies the DocumentDB cluster to backup.
	// +kubebuilder:validation:Required
	Cluster cnpgv1.LocalObjectReference `json:"cluster"`

	// RetentionDays specifies how many days the backup should be retained.
	// +optional
	RetentionDays *int `json:"retentionDays,omitempty"`
}
```

Two fields. That is the whole API surface.

**Their own documentation states the limitation plainly**
([backup-and-restore.md](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/operator-public-documentation/preview/operations/backup-and-restore.md)):

> "Each backup captures a snapshot of the primary instance's persistent volume, which can later be used
> to bootstrap a new DocumentDB cluster. **Any writes that occurred after the snapshot and before a
> failure are not captured — these backups do not provide point-in-time recovery (PITR).**"

**Hard limits:**

| Limit          | Detail                                                                                                                                                                                                                              |
| -------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Storage target | CSI VolumeSnapshot only —**no object storage**, no S3/GCS/Azure Blob                                                                                                                                                         |
| WAL archiving  | **None**                                                                                                                                                                                                                      |
| PITR           | **None**                                                                                                                                                                                                                      |
| Scope          | Primary instance only; namespace-scoped                                                                                                                                                                                             |
| Restore        | **In-place restore is not supported** — must create a new cluster                                                                                                                                                            |
| Retention      | 1–365 days, default 30.**"There is no 'keep forever' option."**                                                                                                                                                              |
| Export         | None —*"Export backups externally for permanent archival"* (manually)                                                                                                                                                            |
| Platform       | [Design doc](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/designs/backup-and-restore-design.md): *"Currently, we only support **AKS** with the **`disk.csi.azure.com`** CSI driver."* |

Retention precedence: `Backup.spec.retentionDays` > `ScheduledBackup.spec.retentionDays` >
`DocumentDB.spec.backup.retentionDays` > 30 days. Expiry = `stoppedAt + retentionDays × 24h`.

**Second recovery path — retained PersistentVolume.** `StorageConfiguration.PersistentVolumeReclaimPolicy`
defaults to `Retain`, so a deleted cluster's PV survives and can be re-bootstrapped via
`bootstrap.recovery.persistentVolume.name`. This recovers data *up to the moment of deletion* — fresher
than the last snapshot. See [restore-deleted-cluster.md](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/operator-public-documentation/preview/operations/restore-deleted-cluster.md).

**Why the wrapper CRD exists at all** (from their design doc):

> "In this phase, our Backup resource acts as a wrapper around CNPG Backup. We maintain our own CRD to
> support future enhancements: **Next phase: Multi-region backup support; Future: Multi-node backup capabilities**"

**Open issues worth tracking:**

| Issue                                                                          | Title                                               | Why it matters                                                                                                                                                                                                                                                     |
| ------------------------------------------------------------------------------ | --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [#87](https://github.com/documentdb/documentdb-kubernetes-operator/issues/87)   | Backup/Restore Phase2 —**PITR** (OPEN)       | Body:*"Let's implement PITR through wal archiving in Azure Blob Storage."* → PITR is unimplemented, and the plan is Azure-Blob-specific rather than the CNPG barman-cloud plugin                                                                                |
| [#434](https://github.com/documentdb/documentdb-kubernetes-operator/issues/434) | Backups carry no version metadata (OPEN)            | `BackupStatus` records only phase/timestamps/message — **no schema version, no engine image**. Restore is a physical CNPG recovery, so the installed `documentdb` extension schema is restored as-is with no compatibility validation. See also PR #440 |
| [#196](https://github.com/documentdb/documentdb-kubernetes-operator/issues/196) | Multi-region backup/restore (OPEN)                  |                                                                                                                                                                                                                                                                    |
| [#139](https://github.com/documentdb/documentdb-kubernetes-operator/issues/139) | Backup/restore commands in kubectl extension (OPEN) |                                                                                                                                                                                                                                                                    |
| [#86](https://github.com/documentdb/documentdb-kubernetes-operator/issues/86)   | Backup/Restore with disk snapshot Phase1 (CLOSED)   | = what actually shipped                                                                                                                                                                                                                                            |
| [CNPG #6009](https://github.com/cloudnative-pg/cloudnative-pg/issues/6009)      | No retention policy for volume snapshots            | Their design doc cites this as a known gap                                                                                                                                                                                                                         |

### 2c. Azure's managed service — 35-day continuous PITR

DocumentDB is the engine behind **Azure Cosmos DB for MongoDB vCore**, which Microsoft has rebranded
**"Azure DocumentDB"** (docs moved to `learn.microsoft.com/azure/documentdb/`).

| Property   | Value                                                                             |
| ---------- | --------------------------------------------------------------------------------- |
| Model      | Automatic, continuous, snapshot-based,**with PITR**                         |
| Retention  | **35 days** active clusters / 7 days deleted clusters                       |
| Durability | Snapshots across three availability zones in AZ-enabled regions                   |
| Encryption | AES-256                                                                           |
| Restore    | Restore-to-new-cluster (portal → Settings →*Point In Time Restore*)           |
| Caveat     | MS explicitly notes it*"doesn't provide a complete disaster recovery solution"* |

Sources: [overview](https://learn.microsoft.com/en-us/documentdb/overview) ·
[how-to-restore-cluster](https://docs.azure.cn/en-us/cosmos-db/mongodb/vcore/how-to-restore-cluster) ·
[migrate with native tools](https://learn.microsoft.com/en-us/azure/documentdb/how-to-migrate-native-tools)

> ### 💡 The gap
>
> Azure gives **35-day continuous PITR**. The open-source operator gives **snapshot-only, no PITR**.
> That entire delta lives in Azure's closed-source control plane — and it is exactly the gap
> KubeDB/KubeStash can credibly fill, because we already have the wal-g machinery for Postgres.

---

## 3. Every possible way to back up DocumentDB

### 3.0 The comparison table

| # | Method                                              | Layer                    | PITR         | Consistency                     | Portable                                             | Verdict                                        |
| - | --------------------------------------------------- | ------------------------ | ------------ | ------------------------------- | ---------------------------------------------------- | ---------------------------------------------- |
| 1 | `pg_dump` / `pg_dumpall`                        | Postgres logical         | ✗           | **Full** (MVCC snapshot)  | ✓ cross-version, cross-cluster, cross-storage-class | **Strong baseline**                      |
| 2 | `mongodump` / `mongorestore` via gateway :10260 | Mongo logical            | ✗           | **Per-collection only**   | ✓ cross-engine (real MongoDB!)                      | User-familiar; no cross-collection consistency |
| 3 | `pg_basebackup`                                   | Postgres physical        | ✗ alone     | Crash-consistent                | Same major version                                   | Base layer for#4                               |
| 4 | **wal-g / barman WAL archiving**              | Postgres physical + logs | **✓** | **Transactionally exact** | Same major version                                   | **The only real PITR**                   |
| 5 | CSI VolumeSnapshot                                  | Block device             | ✗           | Crash-consistent                | Same CSI driver / storage class                      | What Microsoft ships                           |
| 6 | Manifest backup (CR + Secrets)                      | K8s metadata             | n/a          | n/a                             | ✓                                                   | Complement,**not** a backup              |

### 3.1 `pg_dump` / `pg_dumpall` — Postgres logical

**How it works.** Connect to PostgreSQL on **:9712** as the `documentdb` superuser and dump the
`documentdb_data` + `documentdb_api_catalog` schemas (or the whole database). Output is SQL or a custom-format
archive containing `bson` values serialized as bytea/text.

**Consistency:** full — `pg_dump` runs in a repeatable-read transaction, so you get one MVCC snapshot
across *every* collection. This is strictly better than anything `mongodump` can offer here.

**What it misses:** nothing data-wise. But restore has real preconditions.

> ⚠️ **Restore preconditions.** The target must have:
>
> 1. The **same or compatible `documentdb` extension version** (`default_version = 0.117-0` today).
>    A dump taken at extension 0.109 restored into 0.117 has *not been validated by anyone* — this is
>    exactly the class of problem tracked in
>    [documentdb-kubernetes-operator#434](https://github.com/documentdb/documentdb-kubernetes-operator/issues/434).
> 2. `pg_cron`, `pgvector`, `postgis`, `tsm_system_rows` installed (per `documentdb.control`).
> 3. `shared_preload_libraries` including `pg_documentdb_core` / `pg_documentdb`.

**Verdict:** the most portable and most consistent logical option. Should be the default `logical-backup` task.

### 3.2 `mongodump` / `mongorestore` — Mongo logical over the gateway

**How it works.** Connect to the gateway on **:10260** with a normal MongoDB client and dump.

**Does it work?** Almost certainly yes for plain dumps — but note this carefully:

> **It is undocumented and untested upstream.** GitHub search for `mongodump`/`mongorestore` in the
> operator repo returns **0 results**; the engine repo has 3 incidental hits. There are **no e2e or
> functional tests** exercising either tool.

The commands `mongodump` needs *are* dispatched by the gateway
([`processor/process.rs`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/documentdb_gateway_core/src/processor/process.rs)):
`ListDatabases`, `ListCollections`, `ListIndexes`, `Find`, `GetMore`, `KillCursors`, `Aggregate`,
`DbStats`, `CollStats`, `BuildInfo`, `Hello`/`IsMaster`, `GetParameter`, `Explain`.

The commands `mongorestore` needs are dispatched too: `Insert`, `Create`, `CreateIndexes`, `Drop`,
`DropDatabase`, `Update`, `Delete`, `CollMod`, `RenameCollection`.

Anything else returns `ErrorCode::CommandNotSupported` → `"Command '{}' not supported."`

> ❌ **`--oplog` and `--oplogReplay` will NOT work.** No `replSetGetStatus`, no `local.oplog.rs`, no
> `applyOps` handler. Oplog support is closed as won't-do
> ([#81](https://github.com/documentdb/documentdb/issues/81)). **Therefore there is no way to get a
> consistent point-in-time logical dump across collections via the Mongo path.** Each collection is
> dumped at a different instant.

**Wire protocol.** From
[`configuration/version.rs`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/documentdb_gateway_core/src/configuration/version.rs):

```rust
pub enum Version { FourTwo, Five, Six, Seven, Eight }
// as_str():            "4.2.0","5.0.0","6.0.0","7.0.0","8.0.0"
// max_wire_protocol():  8,      13,     17,     21,     25
```

Per open issue [#697](https://github.com/documentdb/documentdb/issues/697) the version is *effectively
hardcoded to 7.0.0 / wire version 21* because the config variable lacks GUC backing.

`hello` returns `"msg": "isdbgrid"` — **drivers treat DocumentDB as a sharded cluster (mongos)**, which
is also why `--oplog` is meaningless to them, and why `?replicaSet=rs0` connection strings fail.

**Verdict:** valuable for **migration and portability** (dump from DocumentDB → restore into real
MongoDB, or vice versa). Not a credible primary backup method, because of the consistency gap.

### 3.3 `pg_basebackup` — Postgres physical

**How it works.** Streams a byte-level copy of PGDATA (`/var/pv`) from the primary over the replication
protocol. Crash-consistent; restores fast because there's no SQL replay.

**Constraint:** same PostgreSQL major version, same architecture. Not portable across storage classes
in the way a logical dump is, but far more portable than a CSI snapshot (it's just a tarball).

**Interesting note:** this repo already runs `pg_basebackup` in a Job for HA bootstrap —
`pkg/ops/standAlone_to_ha.go:266-402`, script `role_scripts/17/standby/ha_backup_job.sh`. The pattern of
"run a Job reusing the DB image/env/mounts" is already proven here.

**Verdict:** on its own, a faster-restore alternative to logical dump. Its real value is as the **base
layer for #4**.

### 3.4 wal-g / barman WAL archiving — **the only real PITR**

**How it works.** Two moving parts:

1. A **base backup** (either `pg_basebackup` or a CSI VolumeSnapshot), taken on a schedule.
2. **Continuous WAL archiving** — Postgres's `archive_command` ships every completed WAL segment to
   object storage as it's produced.

To restore to any timestamp T: fetch the newest base backup at-or-before T, then replay WAL forward to
exactly T (`recovery_target_time`).

**This is the only method that gives transactionally-exact point-in-time recovery**, and it is precisely
what Microsoft's operator lacks
([issue #87](https://github.com/documentdb/documentdb-kubernetes-operator/issues/87), open).

**How close is KubeDB already?** Closer than you'd think. The `documentdb-init-docker` image carries
**dormant wal-g scaffolding inherited from postgres-init-docker**:

| File                                                                                                            | What's already there                                                                                                                                                                                            |
| --------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `scripts/restore.sh`                                                                                          | Full`wal-g backup-fetch $PGDATA $WALG_BASE_BACKUP_NAME`, `restore_command = 'wal-g wal-fetch %f %p'`, `recovery_target_time` / `recovery_target_lsn`, promote-on-`-0`. **Needs no change.**     |
| `scripts/run.sh`                                                                                              | Already handles`PITR_RESTORE`, `PITR_UNIX_TIME`, `PITR_REPLICATION_STRATEGY`; creates `$ARCHIVE_PATH` / `$ARCHIVE_STATUS_PATH` / `$LAST_ARCHIVED_FILE_INFO_DIR` when `ARCHIVER_ENABLED == "true"` |
| `bootstrap_scripts/17/configure.sh`, `role_scripts/17/primary/start.sh`, `role_scripts/17/standby/run.sh` | Already set`archive_mode = always`, but hardcode `archive_command = 'cp %p /var/pv/wal_archive/%f'` or `'/bin/true'` — **needs a wal-g `wal-push` branch**                                       |

And the env-var constants are already declared in `apis/kubedb/constants.go:1731-1737`:
`EnvArchiverEnabled = "ARCHIVER_ENABLED"`, `EnvArchivePath = "ARCHIVE_PATH"`,
`EnvArchiverCompletePath = "LAST_ARCHIVED_FILE_INFO_DIR"`.

> ⚠️ **The one real blocker:** the `documentdb-local` image has **no wal-g binary**. KubeDB's Postgres
> design solves this by injecting wal-g as a separate **sidekick container**
> (`archiverapi.WalgContainerName = "wal-g"`) that shares the data PVC. Same approach applies here.

**Verdict:** the differentiator. This is what would put KubeDB ahead of Microsoft's own operator.

### 3.5 CSI VolumeSnapshot — block-level

**How it works.** Ask the CSI driver for a `VolumeSnapshot` of the PVC. Instant, no data leaves the
cluster, no load on the database.

**Consistency:** crash-consistent only. Postgres recovers on startup by replaying WAL from its last
checkpoint — this is safe, and is exactly what Microsoft relies on.

**Constraints:** locked to the same CSI driver and storage class. No off-cluster copy. No cross-cloud
portability.

**Verdict:** cheapest to implement (KubeDB already has `*-csi-snapshotter-plugin` for Postgres), gives
parity with Microsoft immediately, and doubles as the base-backup layer for #4.

### 3.6 Manifest backup — Kubernetes metadata

**How it works.** Dump the KubeDB CR itself plus its auth Secret, config Secret, init script and
Archiver CR as YAML into the repository.

**This is not a data backup.** It's what lets you recreate the *cluster* on restore — without it, a
restored data volume has no matching `DocumentDB` object, no credentials, no TLS issuer.

**The good news:** KubeStash's `kubedbmanifest-backup` / `kubedbmanifest-restore` plugin is **shared
across every KubeDB engine** and is reusable verbatim. Only one small upstream API addition is needed
(see §7).

**Verdict:** mandatory complement to any of #1–#5. Never a standalone answer.

---

## 4. Hands-on demo runbooks

> All runbooks assume a KubeDB DocumentDB named `docdb` in namespace `demo`.
> **Nothing below has been executed yet** — commands are derived from source. Expect to adjust TLS flags
> depending on your `spec.sslMode` / `spec.tls` settings.

### 4.0 Setup — get credentials and a port-forward

```bash
export NS=demo DB=docdb

# Admin (superuser) — this is the one with Postgres superuser rights
export PGUSER=$(kubectl get secret -n $NS ${DB}-admin-auth -o jsonpath='{.data.username}' | base64 -d)
export PGPASSWORD=$(kubectl get secret -n $NS ${DB}-admin-auth -o jsonpath='{.data.password}' | base64 -d)

# Application user
export MONGO_USER=$(kubectl get secret -n $NS ${DB}-auth -o jsonpath='{.data.username}' | base64 -d)
export MONGO_PW=$(kubectl get secret -n $NS ${DB}-auth -o jsonpath='{.data.password}' | base64 -d)

echo "admin=$PGUSER  app=$MONGO_USER"
# Expected:  admin=documentdb  app=default_user
```

Seed some data so the demos have something to move:

```bash
kubectl port-forward -n $NS svc/$DB 10260:10260 &

mongosh "mongodb://$MONGO_USER:$MONGO_PW@localhost:10260/?directConnection=true&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true" \
  --eval 'db.getSiblingDB("sampledb").orders.insertMany(
      Array.from({length:1000},(_,i)=>({_id:i, item:"widget-"+i, qty:i%17})))'
```

---

### Demo 1 — `pg_dump` (Postgres logical) ✅ recommended baseline

```bash
kubectl port-forward -n $NS svc/$DB 9712:9712 &

# Full cluster dump — captures roles + all databases
pg_dumpall -h localhost -p 9712 -U "$PGUSER" > /tmp/docdb-all.sql

# Or just the DocumentDB payload, custom format (compressed, parallel-restorable)
pg_dump -h localhost -p 9712 -U "$PGUSER" -d postgres -Fc \
        -n documentdb_data -n documentdb_api_catalog \
        -f /tmp/docdb.dump
```

**Expected:**

```
pg_dump: last built-in OID is 16383
pg_dump: reading extensions
pg_dump: reading schemas
...
$ ls -lh /tmp/docdb.dump
-rw-r--r-- 1 user user 2.1M /tmp/docdb.dump
```

Confirm the payload is really there:

```bash
pg_restore -l /tmp/docdb.dump | grep -c 'documents_'
# Expected: one entry per collection (TABLE DATA documents_<id>)
```

**Restore:**

```bash
pg_restore -h localhost -p 9712 -U "$PGUSER" -d postgres --clean --if-exists /tmp/docdb.dump
```

> **Gotchas**
>
> - Use the **`documentdb` admin user**, not `default_user` — the app user is not a superuser and will
>   fail on `documentdb_api_catalog`.
> - The target must already have the `documentdb` extension **at a compatible version**, plus
>   `pg_cron`, `vector`, `postgis`, `tsm_system_rows`. Restoring into a bare Postgres will fail.
> - Prefer `-Fc` (custom) over plain SQL — `bson` values as plain SQL text are large and slow to reload.
> - Don't dump `documentdb_api` / `documentdb_api_internal` — those are extension-owned objects,
>   recreated by `CREATE EXTENSION`.

---

### Demo 2 — `mongodump` over the gateway

```bash
kubectl port-forward -n $NS svc/$DB 10260:10260 &

mongodump --uri "mongodb://$MONGO_USER:$MONGO_PW@localhost:10260/?\
directConnection=true&authMechanism=SCRAM-SHA-256&tls=true\
&tlsAllowInvalidCertificates=true" \
  --archive=/tmp/docdb.archive
```

**Expected:**

```
writing sampledb.orders to archive '/tmp/docdb.archive'
done dumping sampledb.orders (1000 documents)
```

**Restore:**

```bash
mongorestore --uri "mongodb://$MONGO_USER:$MONGO_PW@localhost:10260/?\
directConnection=true&authMechanism=SCRAM-SHA-256&tls=true\
&tlsAllowInvalidCertificates=true" \
  --archive=/tmp/docdb.archive --drop
```

> **Gotchas**
>
> - ❌ **`--oplog` fails.** There is no oplog and no replica set — `hello` returns `"msg": "isdbgrid"`.
>   Adding `--oplog` will error or be silently useless. **Each collection is dumped at a different
>   instant** — this dump is *not* point-in-time consistent.
> - `?replicaSet=rs0` in the URI will not connect. Use `directConnection=true`.
> - `--tlsAllowInvalidCertificates` is needed unless you mount the KubeDB CA. The operator's own health
>   check does exactly this (`pkg/controllers/client.go` sets `InsecureSkipVerify: true`).
> - Unsupported commands surface as `Command '<x>' not supported.` — if a mongodump flag triggers one,
>   that's the cause.
> - **This path is untested upstream.** Treat any success as your own finding, not a guarantee.

---

### Demo 3 — `pg_basebackup` (physical)

```bash
kubectl port-forward -n $NS svc/$DB 9712:9712 &

pg_basebackup -h localhost -p 9712 -U "$PGUSER" \
              -D /tmp/docdb-base -Ft -z -Xs -P -v
```

**Expected:**

```
pg_basebackup: initiating base backup, waiting for checkpoint to complete
pg_basebackup: write-ahead log start point: 0/3000028 on timeline 1
   1234567/1234567 kB (100%), 1/1 tablespace
pg_basebackup: base backup completed
```

> **Gotchas**
>
> - Needs a replication-capable role and a free replication slot. Check `max_wal_senders`.
> - `-Xs` (stream WAL) is important — without it the backup may not be self-consistent.
> - Restoring means replacing `/var/pv` wholesale, then letting Postgres recover. This is a
>   **cluster-level** operation, not a per-database one.
> - Same PG major version only (17 here, per `DocumentDBVersion.spec.postgresVersion`).

---

### Demo 4 — CSI VolumeSnapshot (the Microsoft-equivalent path, done manually)

```yaml
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: docdb-snap-1
  namespace: demo
spec:
  volumeSnapshotClassName: csi-hostpath-snapclass   # your driver's class
  source:
    persistentVolumeClaimName: data-docdb-0
```

```bash
kubectl apply -f snap.yaml
kubectl get volumesnapshot -n demo -w
```

**Expected:**

```
NAME           READYTOUSE   SOURCEPVC      RESTORESIZE   AGE
docdb-snap-1   true         data-docdb-0   10Gi          22s
```

**Restore** — pre-create the PVC from the snapshot, then point a new DocumentDB at it:

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: data-docdb-restored-0
  namespace: demo
spec:
  dataSource:
    name: docdb-snap-1
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
  accessModes: [ReadWriteOnce]
  resources:
    requests: {storage: 10Gi}
```

> **Gotchas**
>
> - Requires a CSI driver with snapshot support, the `VolumeSnapshot` CRDs, and a
>   `VolumeSnapshotClass`. Microsoft only auto-creates one on AKS/`disk.csi.azure.com`.
> - Crash-consistent only — Postgres replays WAL on startup to reach a consistent state. Safe, but you
>   lose everything written after the snapshot.
> - The PVC name must match what the PetSet expects, or the new DB will provision a fresh empty volume.
> - Snapshots are namespace- and cluster-local. **No off-site copy.**

---

### Demo 5 — Microsoft's operator path, side by side

For comparison, this is the whole Microsoft experience:

```yaml
# On-demand backup
apiVersion: documentdb.io/preview
kind: Backup
metadata:
  name: my-backup
  namespace: default
spec:
  cluster:
    name: my-documentdb-cluster
  retentionDays: 30
---
# Scheduled backup
apiVersion: documentdb.io/preview
kind: ScheduledBackup
metadata:
  name: nightly-backup
  namespace: default
spec:
  cluster:
    name: my-documentdb-cluster
  schedule: "0 2 * * *"     # robfig/cron format
  retentionDays: 14
---
# Restore — a NEW cluster; in-place restore is not supported
apiVersion: documentdb.io/preview
kind: DocumentDB
metadata:
  name: my-restored-cluster
  namespace: default
spec:
  nodeCount: 1
  instancesPerNode: 1
  resource:
    storage: {pvcSize: 10Gi}
  exposeViaService: {serviceType: ClusterIP}
  bootstrap:
    recovery:
      backup:
        name: my-backup
```

```bash
kubectl get backup my-backup -n default -o jsonpath='{.status.phase}'
# Expected: completed
```

> **Gotchas**
>
> - `BackupSpec` is **immutable** (CEL: `oldSelf == self`) — you cannot edit retention after creation
>   on the `Backup` object itself.
> - Backup must be `completed` *and* the underlying `VolumeSnapshot` must still exist.
> - `bootstrap.recovery.backup` and `bootstrap.recovery.persistentVolume` are mutually exclusive (CEL-validated).
> - No PITR. Whatever was written after the snapshot is gone.

---

### Demo 6 — KubeStash (what it *would* look like)

> 🚧 **This does not work today.** There is no `documentdb-addon`. The manifests below are what the
> user experience should be once §7 is implemented — included so the shape can be reviewed now.

```yaml
apiVersion: storage.kubestash.com/v1alpha1
kind: BackupStorage
metadata:
  name: s3-storage
  namespace: demo
spec:
  storage:
    provider: s3
    s3:
      endpoint: s3.amazonaws.com
      bucket: kubedb-backups
      region: us-east-1
      prefix: documentdb
      secretName: s3-creds
  usagePolicy:
    allowedNamespaces: {from: All}
  default: true
---
apiVersion: storage.kubestash.com/v1alpha1
kind: RetentionPolicy
metadata:
  name: demo-retention
  namespace: demo
spec:
  maxRetentionPeriod: "30d"
  successfulSnapshots: {last: 10}
  failedSnapshots: {last: 2}
---
apiVersion: core.kubestash.com/v1alpha1
kind: BackupConfiguration
metadata:
  name: docdb-backup
  namespace: demo
spec:
  target:
    apiGroup: kubedb.com
    kind: DocumentDB          # ← needs featureGates.DocumentDB in the catalog chart
    namespace: demo
    name: docdb
  backends:
    - name: s3-backend
      storageRef: {namespace: demo, name: s3-storage}
      retentionPolicy: {namespace: demo, name: demo-retention}
  sessions:
    - name: frequent-backup
      scheduler:
        schedule: "*/30 * * * *"
        jobTemplate: {backoffLimit: 1}
      repositories:
        - name: s3-docdb-repo
          backend: s3-backend
          directory: /documentdb
          encryptionSecret: {name: encrypt-secret, namespace: demo}
      addon:
        name: documentdb-addon        # ← does not exist yet
        tasks:
          - name: logical-backup
          - name: manifest-backup
---
apiVersion: core.kubestash.com/v1alpha1
kind: RestoreSession
metadata:
  name: docdb-restore
  namespace: demo
spec:
  target:
    apiGroup: kubedb.com
    kind: DocumentDB
    namespace: demo
    name: docdb-restored
  dataSource:
    repository: s3-docdb-repo
    snapshot: latest
    encryptionSecret: {name: encrypt-secret, namespace: demo}
  addon:
    name: documentdb-addon
    tasks:
      - name: logical-backup-restore
```

And the PITR shape, modeled on `PostgresArchiver`:

```yaml
apiVersion: archiver.kubedb.com/v1alpha1
kind: DocumentDBArchiver          # ← CRD does not exist yet
metadata:
  name: docdb-archiver
  namespace: demo
spec:
  pause: false
  databases:
    namespaces: {from: Selector, selector: {matchLabels: {kubernetes.io/metadata.name: demo}}}
  encryptionSecret: {name: encrypt-secret, namespace: demo}
  retentionPolicy: {name: demo-retention, namespace: demo}
  fullBackup:
    driver: VolumeSnapshotter
    task:
      params: {volumeSnapshotClassName: longhorn-snapshot-vsc}
    scheduler:
      successfulJobsHistoryLimit: 1
      failedJobsHistoryLimit: 1
      schedule: "30 * * * *"
  manifestBackup:
    scheduler:
      schedule: "30 * * * *"
  backupStorage:
    ref: {name: s3-storage, namespace: demo}
---
# Restore to an exact timestamp
apiVersion: kubedb.com/v1alpha2
kind: DocumentDB
metadata:
  name: docdb-pitr
  namespace: demo
spec:
  version: pg17-0.109.0
  init:
    waitForInitialRestore: true
    archiver:
      recoveryTimestamp: "2026-08-05T11:05:00Z"
      encryptionSecret: {name: encrypt-secret, namespace: demo}
      fullDBRepository: {name: docdb-full, namespace: demo}
      manifestRepository: {name: docdb-manifest, namespace: demo}
```

> Note: `spec.init.archiver` **already exists** in the generated DocumentDB CRD today
> (`crds/kubedb.com_documentdbs.yaml`), because `DocumentDBSpec` embeds the shared `InitSpec`. It's the
> *implementation* behind it that's missing, not the API field.

---

## 5. Community comparison

### 5.1 CloudNativePG is the real reference point

Since DocumentDB *is* a CNPG cluster underneath, the community's actual backup discourse is CNPG's.
CNPG offers two backup methods, and DocumentDB only wires up one of them:

| CNPG capability                                            | CNPG supports                                   | DocumentDB operator uses                                                                                          |
| ---------------------------------------------------------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------- |
| `volumeSnapshot` (CSI)                                   | ✓                                              | **✓ — this is all they use**                                                                              |
| `barmanObjectStore` / barman-cloud plugin (S3/GCS/Azure) | ✓ (plugin is the recommended path since v1.26) | ✗                                                                                                                |
| Continuous WAL archiving                                   | ✓                                              | ✗                                                                                                                |
| PITR (`recoveryTarget.targetTime`)                       | ✓                                              | ✗                                                                                                                |
| Retention policies on object store                         | ✓                                              | ✗ (and no snapshot retention either —[CNPG #6009](https://github.com/cloudnative-pg/cloudnative-pg/issues/6009)) |

> **The striking thing:** DocumentDB inherits a mature, battle-tested Postgres backup stack from CNPG
> and *deliberately uses only its weakest tier*. Their own PITR issue
> ([#87](https://github.com/documentdb/documentdb-kubernetes-operator/issues/87)) proposes writing
> Azure-Blob-specific WAL archiving rather than adopting CNPG's barman-cloud plugin.

Refs: [CNPG backup docs](https://cloudnative-pg.io/documentation/current/backup/) ·
[EDB on CNPG volume-snapshot DR](https://www.enterprisedb.com/postgresql-disaster-recovery-with-kubernetes-volume-snapshots-using-cloudnativepg)

### 5.2 How KubeDB/KubeStash already does this for other engines

| Engine                  | Logical                         | Physical          | Snapshot | Manifest | PITR                                               |
| ----------------------- | ------------------------------- | ----------------- | -------- | -------- | -------------------------------------------------- |
| **Postgres**      | `pg_dumpall`/`pg_dump`      | `pg_basebackup` | CSI      | ✓       | **✓ wal-g `wal-push`/`wal-fetch`**      |
| **MongoDB**       | `mongodump --archive --oplog` | —                | CSI      | ✓       | **✓ wal-g `oplog-push`/`oplog-replay`** |
| **MySQL/MariaDB** | mysqldump                       | —                | CSI      | ✓       | ✓ binlog                                          |
| **DocumentDB**    | ✗                              | ✗                | ✗       | ✗       | ✗                                                 |

Note that MongoDB's PITR relies on **oplog-push** — a mechanism DocumentDB structurally cannot provide.
Postgres's PITR relies on **wal-push** — which DocumentDB *can* provide, because it is Postgres.
This asymmetry is the single most important input to §7.

### 5.3 Community content on DocumentDB backup specifically — thin

DocumentDB was open-sourced Jan 2025 and the operator shipped Nov 2025, so there is very little.

- [Microsoft OSS blog — &#34;DocumentDB goes cloud-native&#34;](https://opensource.microsoft.com/blog/2025/11/05/documentdb-goes-cloud-native-introducing-the-documentdb-kubernetes-operator/) (2025-11-05) — announces the CNPG/CNPG-I architecture and **does not discuss backup at all**.
- [Abhishek Gupta on DEV — cloud-native intro](https://dev.to/abhirockzz/documentdb-goes-cloud-native-introducing-the-documentdb-kubernetes-operator-3ji9) and [HA/failover](https://dev.to/abhirockzz/documentdb-on-kubernetes-resilient-highly-available-databases-with-automatic-failover-ak7) — HA, not backup.
- DeepWiki (auto-generated, but the most detailed third-party writeup of the backup path):
  [on-demand backups](https://deepwiki.com/documentdb/documentdb-kubernetes-operator/6.1-on-demand-backups) ·
  [volume snapshot classes](https://deepwiki.com/documentdb/documentdb-kubernetes-operator/6.5-volume-snapshot-classes) ·
  [backup/restore issues](https://deepwiki.com/documentdb/documentdb-kubernetes-operator/13.3-backup-and-restore-issues)
- [Japanese hands-on walkthrough](https://zenn.dev/tzkoba/articles/f34277f9663ce8) — actually pokes at
  `documentdb_api_catalog` / `documentdb_data` in psql. Useful for confirming the schema layout.

**Bottom line: nobody has published a validated DocumentDB backup methodology.** There is a real
opportunity to be first, and equally a real obligation to test our own claims.

---

## 6. How KubeStash works

Concepts needed to evaluate §7. All types verified in
`vendor/kubestash.dev/apimachinery/` (v0.28.0, already vendored in the documentdb repo).

### 6.1 The CRD graph

```
BackupStorage  (bucket/PVC + credential Secret + usagePolicy + default flag)
     ▲ storageRef
Repository  (appRef + storageRef + path + encryptionSecret)  ──►  Snapshot  (one per backup run)
     ▲                                                              │ .status.components{dump,wal,manifest,volumesnapshot}
BackupConfiguration
  .spec.target       → TypedObjectReference (apiGroup/kind/ns/name of the DB)
  .spec.backends[]   → {name, storageRef, retentionPolicy}
  .spec.sessions[]   → {name, scheduler(cron), addon{name, tasks[]}, repositories[]}
     │  operator creates one CronJob per session
     ▼
BackupSession (one per trigger) ──► resolve Addon → Task → Function ──► backup Job
                                    └► create a Snapshot per Repository

RestoreSession
  .spec.dataSource{repository | snapshot | pitr.targetTime | components[] }
  .spec.addon{name, tasks[]}
  .spec.manifestOptions{mongoDB | postgres | mySQL | …}
```

Three API groups: `storage.kubestash.com/v1alpha1`, `core.kubestash.com/v1alpha1`,
`addons.kubestash.com/v1alpha1` (Addon and Function are **cluster-scoped**).

### 6.2 Addon → Task → Function

An `Addon` declares tasks; a `Function` is essentially a container template:

```go
type Task struct {
    Name       string                     // e.g. "logical-backup"
    Function   string                     // name of a Function CR
    Driver     apis.Driver                // Restic | WalG | VolumeSnapshotter | Medusa | …
    Executor   TaskExecutor               // Job | Sidecar | EphemeralContainer | MultiLevelJob
    Singleton  bool
    Parameters []apis.ParameterDefinition
    VolumeTemplate []VolumeTemplate
    VolumeMounts   []core.VolumeMount
}
```

**Standard task names** (from `apis/constant.go` — use these exact strings):
`logical-backup`, `logical-backup-restore`, `manifest-backup`, `manifest-restore`,
`volume-snapshot`, `volume-snapshot-restore`, `volume-clone`.

**Resolution flow:** CronJob fires → creates `BackupSession` → operator creates a `Snapshot` per
`Repository`, resolves Addon→Task→Function, renders `Function.spec.args` by substituting
`${var:=default}` placeholders from built-ins + `Task.parameters` merged with
`session.addon.tasks[].params`, and builds the Job.

**The `${DB_VERSION}` trick.** Functions can pin a per-version client image:

```yaml
availableVersions: ["12.17", "14.10", "16.4", "17.2", "18.2"]
image: ghcr.io/kubedb/postgres-restic-plugin:v0.29.0_${DB_VERSION}
```

`DB_VERSION` is `KeyDBVersion` in `apis/constant.go`. This is how the right `pg_dump`/`mongodump` major
version ships inside the plugin image.

### 6.3 The streaming model — no staging volume

KubeStash pipes the dump straight into restic on stdin:

```go
opt.backupOptions.StdinFileName = PgDumpFile
opt.backupOptions.StdinPipeCommands = append(opt.backupOptions.StdinPipeCommands, *session.cmd)
resticWrapper, err := restic.NewResticWrapperFromShell(opt.setupOptions, session.sh)
```

Effectively `pg_dumpall | restic backup --stdin --stdin-filename=dump.sql`. **The backup Job never needs
a volume large enough to hold the dump** — only an emptyDir `kubestash-tmp-volume` at `/kubestash-tmp`
for restic scratch/cache.

> On drivers: the `apis.Driver` enum is `Restic | WalG | Medusa | VolumeSnapshotter | Solr | ClickHouseBackup | Neo4jAdmin`. **There is no `Kopia` value** — KubeStash uses a
> [forked restic](https://github.com/kubestash/restic) shipped in plugin images.

### 6.4 How the plugin gets credentials — the AppBinding

The operator does **not** inject DB credentials. Given `--namespace` + `--backupsession`, the plugin:

1. Reads `BackupSession` → `BackupConfiguration` → `.spec.target`
2. Looks up the **AppBinding** of the same name/namespace, which yields
   `.spec.clientConfig.service.{name,port,scheme}`, `.spec.secret` (auth), `.spec.tlsSecret` /
   `clientConfig.caBundle`, and `.spec.parameters` (topology info — e.g. MongoDB's `configServer` +
   `replicaSets` map)
3. Reads `BackupStorage` + its Secret for backend credentials, `Repository.spec.path` for the prefix,
   and `encryptionSecret` for `RESTIC_PASSWORD`

> ⚠️ **This is a concrete gap for DocumentDB.** Today `pkg/controllers/appbinding.go` sets only
> `Type`, `AppRef`, `Version`, `ClientConfig.Service` (scheme `mongodb`, port 10260) and `Secret`.
> There is **no `Spec.Parameters`, no `ClientConfig.CABundle`, no `Spec.TLSSecret`** — a plugin would
> have nothing to work with for TLS.

### 6.5 The Archiver / PITR layer — lives in the DB operator, not KubeStash

This is the part people get wrong. The continuous-log side is **not** a KubeStash Job.

- `*Archiver` CRDs live in group **`archiver.kubedb.com/v1alpha1`** (`PostgresArchiver`,
  `MongoDBArchiver`, `MySQLArchiver`, `MariaDBArchiver`, `MSSQLServerArchiver`, `ClickHouseArchiver` —
  six engines, **no DocumentDBArchiver**).
- The wal-g container runs as a **`kubeops.dev/sidekick` `Sidekick` CR** that leader-elects onto one pod
  of the DB, created and managed by the **database operator**.
- A long-lived `Snapshot` named `<db>-incremental-snapshot` acts as the **log-progress ledger** —
  wal-g patches `status.components["wal"|"oplog"].logStats` with start/end/LSN and success/failure
  counts. This is how PITR resolves *"which base backup + which log range covers timestamp T"*.

The reconcile sequence (from `kubedb.dev/mongodb/pkg/controller/archiving/backup/walg-backup.go`):

```go
EnsureBackupConfiguration(db, archiver)   // created with Paused: true
CreateFullBackupRepository(db, archiver)
CreateWalgSideKick(db, archiver)
archiving.EnsureIncSnapshot(kbClient, db)
running := archiving.EnsureSnapshotRunning(...)
if !running { requeue }
ResumeBackupConfiguration(db, archiver)   // only unpause once wal-g is actually pushing
```

Postgres wal-g container args (`kubedb.dev/postgres/pkg/controller/sidekick.go`):

```go
Name: archiverapi.WalgContainerName,   // "wal-g"
Args: []string{"archive",
    fmt.Sprintf("--snapshot-namespace=%s", db.Namespace),
    fmt.Sprintf("--snapshot-name=%s", GetIncSnapshotName(db.Name))},
```

**Restore choreography:** manifest restore (recreate Secrets/CR) → full restore (pre-create PVCs with
`pvc.Spec.DataSource` pointing at the VolumeSnapshot) → log replay via an **init container**
(`wal-fetch` for PG, `oplog-replay` for Mongo, `binlog-fetch` for MySQL) → `spec.init.waitForInitialRestore`
gates the DB from serving until `DataRestored` flips.

**Reference implementations on disk:**

- `kubedb.dev/mongodb/pkg/controller/archiving/**` — cleanest package layout, best template
- `kubedb.dev/postgres/pkg/controller/{archiver,sidekick,backup_configuration,snapshot,restoresession,restore}.go`

### 6.6 Where addon manifests actually live

Not in the plugin repo — in **`kubedb.dev/installer`**:

```
kubedb.dev/installer/
├── catalog/kubestash/
│   ├── raw/<app>/                    # ← hand-edited source of truth
│   │   ├── <app>-addon.yaml
│   │   ├── <app>-backup-function.yaml
│   │   ├── <app>-restore-function.yaml
│   │   └── <app>-csi-snapshotter-function.yaml   (optional)
│   └── fmt/main.go                   # generator raw/ → charts/, holds the appToKind map
└── charts/kubedb-kubestash-catalog/
    ├── values.yaml                   # featureGates{<Kind>: true}, proxies, distro
    └── templates/<app>/*.yaml        # ← GENERATED, never hand-edit
```

17 apps exist today: `cassandra clickhouse druid elasticsearch kubedbmanifest kubedbverifier mariadb mongodb mssqlserver mysql neo4j opensearch postgres qdrant redis singlestore zookeeper`.
**`documentdb` is not among them.**

`postgres-addon.yaml` declares 4 backup tasks (`logical-backup`, `physical-backup`, `volume-snapshot`,
`manifest-backup`) and 3 restore tasks (`logical-backup-restore`, `physical-backup-restore`,
`manifest-restore`). **`qdrant/` is the smallest complete example** (3 files, no `${DB_VERSION}`) and is
the best template for a first DocumentDB addon.

---

## 7. What should KubeStash adopt? — *for discussion*

> This section is deliberately framed as options + trade-offs, not a committed design. The concrete gap
> list below is included so effort can be estimated during the discussion.

### 7.1 The options

|                              | **A. Postgres-shaped**                                                                         | **B. Mongo-shaped**                                   | **C. VolumeSnapshot only**     | **D. Hybrid (C+manifest → A → B)** |
| ---------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------- | ------------------------------------ | ------------------------------------------ |
| Tooling                      | `pg_dump`/`psql`, `pg_basebackup`, wal-g                                                       | `mongodump --archive` on :10260                           | CSI snapshotter plugin               | all of them                                |
| **PITR**               | **✓**                                                                                         | ✗ (structurally impossible)                                | ✗                                   | **✓**                               |
| Cross-collection consistency | ✓                                                                                                   | ✗                                                          | ✓ (crash-consistent)                | ✓                                         |
| Reuses                       | `kubedb.dev/postgres` archiver + sidekick, wal-g scaffolding already in `documentdb-init-docker` | `kubedb.dev/mongodb` addon shape                          | existing`*-csi-snapshotter-plugin` | both                                       |
| Portability                  | cross-cluster, cross-storage-class                                                                   | cross-*engine* (real MongoDB!)                            | same CSI driver only                 | all                                        |
| Effort                       | **M**                                                                                          | **S**                                                 | **S**                          | **L** (but phased)                   |
| Risk                         | low — proven path                                                                                   | **medium** — untested upstream, silent inconsistency | low                                  | low                                        |
| Parity with MS               | **exceeds**                                                                                    | below                                                       | equal                                | **exceeds**                          |

### 7.2 Recommendation — **D, phased**

**Phase 1 — parity, fast.** `volume-snapshot` + `manifest-backup`/`manifest-restore` tasks. Reuses the
existing CSI snapshotter and the shared `kubedbmanifest-*` plugin verbatim. This matches everything
Microsoft ships, and is mostly manifest work plus one upstream API field.

**Phase 2 — the differentiator.** `logical-backup` (`pg_dump`/`pg_restore`) plus the wal-g archiver for
PITR. The reasoning is decisive: **DocumentDB is PostgreSQL, so the entire `PostgresArchiver` machinery
already sitting on disk gives us PITR nearly for free — and PITR is exactly what Microsoft's operator
lacks** ([their issue #87](https://github.com/documentdb/documentdb-kubernetes-operator/issues/87), open).
The `documentdb-init-docker` image already contains working wal-g restore logic; only `archive_command`
and a wal-g sidekick container are missing.

**Phase 3 — optional.** A Mongo-logical task, positioned honestly as a **migration/portability** tool
(DocumentDB ↔ MongoDB), *not* as a backup. It must be documented as per-collection-consistent only.

**Why not B as primary:** it can never produce a consistent multi-collection dump. Shipping it as the
main backup path would be shipping a silent correctness bug.

**Why not C alone:** it locks users to one CSI driver, gives no off-site copy, and leaves us at exact
parity with a preview-quality operator rather than ahead of it.

### 7.3 Concrete gaps to close

All rows verified against source before writing.

| #  | File                                                                                                                       | Change                                                                                                                                                                                                                                                                                                                                                 |
| -- | -------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| 1  | `kubedb.dev/apimachinery/apis/kubedb/v1alpha2/documentdb_types.go`                                                       | Add`Archiver *Archiver` to `DocumentDBSpec`. **Note:** `Init *InitSpec` already exists at the end of the spec, so `spec.init.archiver` is already in the generated CRD (`crds/kubedb.com_documentdbs.yaml`) — only the `spec.archiver` ref is missing. Compare `postgres_types.go:160-162`, `mongodb_types.go:159-161`.         |
| 2  | `kubedb.dev/apimachinery/apis/catalog/v1alpha1/documentdb_version_types.go`                                              | Add`Archiver ArchiverSpec`. Spec today has only `Version`, `EndOfLife`, `DB`, `Coordinator`, `InitContainer`, `Deprecated`, `UpdateConstraints`, `SecurityContext`, `PostgresVersion`, `UI`, `GitSyncer` — **no archiver, no stash addon block**. Compare `postgres_version_types.go:93`.                             |
| 3  | `kubedb.dev/apimachinery/apis/catalog/v1alpha1/types.go:52`                                                              | Extend the closed kubebuilder enum:`Enum=mongodb-addon;postgres-addon;mysql-addon;mariadb-addon;mssqlserver-addon;clickhouse-addon` → add `documentdb-addon`                                                                                                                                                                                      |
| 4  | `kubedb.dev/apimachinery/apis/archiver/v1alpha1/documentdbarchiver_types.go`                                             | **New CRD**, modeled on `postgresarchiver_types.go` (`Databases`, `Pause`, `RetentionPolicy`, `FullBackup`, `LogBackup`, `ManifestBackup`, `EncryptionSecret`, `BackupStorage`, `DeletionPolicy`). Register in SchemeBuilder + add generated CRD YAML.                                                                       |
| 5  | `kubestash.dev/apimachinery` `apis/core/v1alpha1/restoresession_types.go`                                              | Add`DocumentDB *KubeDBManifestOptions` to `ManifestRestoreOptions`. **Upstream change — this blocks manifest restore.** Today the struct has typed fields only for Workload, MongoDB, Postgres, MySQL, ClickHouse, MariaDB, MSSQLServer, Druid, ZooKeeper, Singlestore, Redis, RedisSentinel. Requires a version bump past v0.28.0.         |
| 6  | `kubedb.dev/installer/catalog/kubestash/raw/documentdb/`                                                                 | **New** Addon + Function YAMLs. Also add `"documentdb": "DocumentDB"` to the `appToKind` map in `catalog/kubestash/fmt/main.go`, and `featureGates.DocumentDB` to `charts/kubedb-kubestash-catalog/values.yaml`, then run the generator. Model on `raw/qdrant/` (simplest) or `raw/postgres/` (full-featured).                     |
| 7  | `kubedb.dev/documentdb/pkg/controllers/archiving/`                                                                       | **New package.** Mirror `kubedb.dev/mongodb/pkg/controller/archiving/{common,providers,snapshot}.go` + `backup/{backup_configuration,sidekick,walg-backup}.go` + `restore/{restoresession,restore,walg-restore}.go`. Reuse `kubedb.dev/apimachinery/pkg/archiver/archiver.go` (`GetCorrespondingArchiver`, `SyncStorageCredSecret`). |
| 8  | `kubedb.dev/documentdb/pkg/controllers/petset.go:1033`                                                                   | Replace the hardcoded`{Name: "ARCHIVER_ENABLED", Value: "false"}` with an archiver-derived value, and add `ARCHIVE_PATH` / `ARCHIVE_STATUS_PATH` / `LAST_ARCHIVED_FILE_INFO_DIR` / PITR envs to the **main** container — they currently sit only on the coordinator.                                                                    |
| 9  | `kubedb.dev/documentdb/pkg/controllers/appbinding.go`                                                                    | Add`Spec.Parameters`, `ClientConfig.CABundle`, and TLS secret refs. Addon plugins resolve all connection details from the AppBinding (§6.4) and currently have no TLS material to work with.                                                                                                                                                      |
| 10 | `documentdb-init-docker` — `role_scripts/17/{primary/start.sh,standby/run.sh}`, `bootstrap_scripts/17/configure.sh` | `archive_mode = always` is already set, but `archive_command` hardcodes `cp %p /var/pv/wal_archive/%f` or `/bin/true`. Needs a wal-g `wal-push` branch. **`scripts/restore.sh` already speaks wal-g fully and needs no change.**                                                                                                     |
| 11 | DB image                                                                                                                   | `documentdb-local` ships **no wal-g binary**. Inject wal-g as a separate sidekick container (`archiverapi.WalgContainerName = "wal-g"`) sharing the data PVC — same pattern as Postgres — or rebuild the DB image.                                                                                                                         |
| 12 | `kubedb.dev/documentdb/pkg/controllers/{manager,rbac}.go`, `pkg/server/server.go`                                      | `Owns`/`Watches` for `BackupConfiguration`, `RestoreSession`, `Sidekick`; RBAC verbs for `snapshots`/`backupconfigurations`/`repositories`; register kubestash + archiver + sidekick schemes.                                                                                                                                          |
| 13 | `kubedb.dev/documentdb/pkg/cmds/server/operator.go:271-290`                                                              | The reconciler is constructed without`amc.Initializers` — a RestoreSession initializer needs wiring for `spec.init.waitForInitialRestore` to work. Also note `DocumentDBStatus` has no `DataRestored` handling anywhere in the operator.                                                                                                      |

**Already in place, no work needed:**

- `kubestash.dev/apimachinery` v0.28.0 and `kubeops.dev/sidekick` are **already vendored** — the types
  are importable today without touching `go.mod`.
- `kubedb.dev/apimachinery/pkg/lib/kubestash.go` already provides
  `kubeStashBackupOrRestoreRunningForDB` / `pauseKubeStashBackupConfiguration` /
  `resumeKubeStashBackupConfiguration`, and the `lib.*` wrappers used throughout `pkg/ops/` already
  handle KubeStash BackupConfigurations. **Ops-request pause/resume needs no change.**
- `spec.init.archiver` (with `recoveryTimestamp`, `fullDBRepository`, `manifestRepository`,
  `encryptionSecret`, `manifestOptions`) is already in the generated CRD.

### 7.4 Open questions for the team

1. **Schema-version metadata.** Should our `Snapshot` record the `documentdb` extension version and the
   DB image? Microsoft has this exact bug open
   ([#434](https://github.com/documentdb/documentdb-kubernetes-operator/issues/434)). Recording it costs
   almost nothing and prevents a silent-corruption class of restore failure. **Recommend yes.**
2. **Which auth does the plugin use?** Postgres superuser `documentdb` on :9712 (needed for `pg_dump`
   of `documentdb_api_catalog`) vs. `default_user` on the gateway :10260. Phase 2 requires the former.
3. **Do we ship a Mongo-logical task at all?** It's the most user-familiar interface and genuinely
   useful for migration — but it cannot be consistent. If we ship it, the docs must say so loudly.
4. **`${DB_VERSION}` or not?** DocumentDB versions are `pg17-0.109.0` — a compound of PG major and
   extension version. Does the plugin image need to be pinned per version (Postgres pattern) or can it
   be version-agnostic (qdrant pattern)? Depends on whether `pg_dump` 17 handles all supported servers.
5. **Sharded/distributed DocumentDB.** The Citus-based `pg_documentdb_distributed` variant isn't used by
   either operator today. If KubeDB adopts it later, backup becomes a per-shard problem (the MongoDB
   addon's `maxConcurrency` + per-shard Sidekick pattern would apply).
6. **Extension restore ordering.** A logical restore must `CREATE EXTENSION` before loading
   `documentdb_data`. Worth validating early in Phase 2 — this is the single most likely place for the
   `pg_dump` path to break.

---

## Appendix — key file paths

| Path                                                                                                 | What                                                                                                       |
| ---------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `kubedb.dev/documentdb/pkg/controllers/{petset,appbinding,client,service,secret}.go`               | Provisioner internals;`ARCHIVER_ENABLED=false` at `petset.go:1033`                                     |
| `kubedb.dev/apimachinery/apis/kubedb/v1alpha2/documentdb_types.go`                                 | `DocumentDBSpec` (has `Init`, lacks `Archiver`)                                                      |
| `kubedb.dev/apimachinery/apis/catalog/v1alpha1/{types,documentdb_version_types}.go`                | `ArchiverSpec`, `AddonType` enum (line 52), `DocumentDBVersionSpec`                                  |
| `kubedb.dev/apimachinery/apis/archiver/v1alpha1/`                                                  | `*Archiver` CRDs, `FullBackupOptions`, `LogBackupOptions`, `const.go` (wal-g commands + env names) |
| `kubedb.dev/mongodb/pkg/controller/archiving/**`                                                   | **Best reference implementation**                                                                    |
| `kubedb.dev/postgres/pkg/controller/{archiver,sidekick,backup_configuration,snapshot,restore}.go`  | Postgres archiver                                                                                          |
| `kubedb.dev/installer/catalog/kubestash/raw/{postgres,mongodb,qdrant,kubedbmanifest}/`             | Addon + Function manifests (source of truth)                                                               |
| `kubedb.dev/installer/catalog/kubestash/fmt/main.go`                                               | raw→chart generator,`appToKind` map                                                                     |
| `kubedb.dev/installer/catalog/kubedb/raw/documentdb/documentdb-0.109.0.yaml`                       | Current`DocumentDBVersion` — needs `spec.archiver`                                                    |
| `documentdb/vendor/kubestash.dev/apimachinery/apis/`                                               | KubeStash types (v0.28.0, vendored)                                                                        |
| `documentdb-init-docker/scripts/{run,restore}.sh`, `role_scripts/17/`, `bootstrap_scripts/17/` | Dormant wal-g / PITR scaffolding                                                                           |

### External references

**DocumentDB engine**

- [documentdb/documentdb](https://github.com/documentdb/documentdb) · [wiki](https://github.com/documentdb/documentdb/wiki) · [docs site](https://documentdb.io/docs/)
- [`documentdb.control`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb/documentdb.control) · [`collection_metadata--0.10-0.sql`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb/sql/schema/collection_metadata--0.10-0.sql) · [`processor/process.rs`](https://github.com/documentdb/documentdb/blob/main/pg_documentdb_gw/documentdb_gateway_core/src/processor/process.rs)
- Issues: [#81 oplog (closed)](https://github.com/documentdb/documentdb/issues/81) · [#342 capped collections](https://github.com/documentdb/documentdb/issues/342) · [#445 replica set](https://github.com/documentdb/documentdb/issues/445) · [#697 wire version](https://github.com/documentdb/documentdb/issues/697) · [#698 compatibility triage](https://github.com/documentdb/documentdb/issues/698) · [#688 durability untested](https://github.com/documentdb/documentdb/issues/688)

**Kubernetes operator**

- [documentdb-kubernetes-operator](https://github.com/documentdb/documentdb-kubernetes-operator) · [docs site](https://documentdb.io/documentdb-kubernetes-operator/)
- [backup-and-restore.md](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/operator-public-documentation/preview/operations/backup-and-restore.md) · [design doc](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/designs/backup-and-restore-design.md) · [restore-deleted-cluster.md](https://github.com/documentdb/documentdb-kubernetes-operator/blob/main/docs/operator-public-documentation/preview/operations/restore-deleted-cluster.md)
- Issues: [#87 PITR](https://github.com/documentdb/documentdb-kubernetes-operator/issues/87) · [#434 no version metadata](https://github.com/documentdb/documentdb-kubernetes-operator/issues/434) · [#196 multi-region](https://github.com/documentdb/documentdb-kubernetes-operator/issues/196)

**CloudNativePG**

- [backup docs](https://cloudnative-pg.io/documentation/current/backup/) · [#6009 snapshot retention](https://github.com/cloudnative-pg/cloudnative-pg/issues/6009)

**KubeStash / KubeDB**

- [architecture](https://kubestash.com/docs/v2026.7.10/concepts/what-is-kubestash/architecture/) · [Addon CRD](https://kubestash.com/docs/v2026.7.10/concepts/crds/addon/) · [Function CRD](https://kubestash.com/docs/v2026.7.10/concepts/crds/function/)
- [KubeDB Postgres logical backup](https://kubedb.com/docs/v2025.10.17/guides/postgres/backup/kubestash/logical/) · [PostgresArchiver / PITR](https://kubedb.com/docs/v2025.10.17/guides/postgres/pitr/archiver/)
- [stashed/postgres](https://github.com/stashed/postgres) · [stashed/mongodb](https://github.com/stashed/mongodb) (public plugin references)

**Azure managed service**

- [overview](https://learn.microsoft.com/en-us/documentdb/overview) · [restore cluster](https://docs.azure.cn/en-us/cosmos-db/mongodb/vcore/how-to-restore-cluster) · [compatibility](https://learn.microsoft.com/en-us/azure/documentdb/compatibility-features)
