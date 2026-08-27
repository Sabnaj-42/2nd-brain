# KubeDB Postgres Backup & Restore — The Full Flow

> Companion to `postgres-backup.md` (which explains the four repos conceptually). This file is the
> **flow**: which component does what, how bytes reach the bucket, and how a restore lands in the
> user's pod. All diagrams are mermaid and render on GitHub.
>
> A standalone HTML version with hand-drawn SVG figures sits next to this file:
> `postgres-backup-flow.html` — open it in a browser.

---

## Table of contents

1. [The one idea to hold onto](#1-the-one-idea-to-hold-onto)
2. [Who owns what](#2-who-owns-what)
3. [Where KubeStash plugs in](#3-where-kubestash-plugs-in)
4. [Which backup is taken when](#4-which-backup-is-taken-when)
5. [How the bytes reach the bucket](#5-how-the-bytes-reach-the-bucket)
6. [Why WAL takes two hops](#6-why-wal-takes-two-hops)
7. [How a point in time is resolved](#7-how-a-point-in-time-is-resolved)
8. [Restore, stage by stage](#8-restore-stage-by-stage)
9. [How the data lands in the pod](#9-how-the-data-lands-in-the-pod)
10. [Reference tables](#10-reference-tables)

---

## 1. The one idea to hold onto

KubeDB runs **two cadences at once**:

| | Scheduled | Continuous |
| --- | --- | --- |
| Driven by | a cron inside `BackupConfiguration` | nothing — it never stops |
| Runs as | a Job that wakes, copies, dies | a Sidekick pod that never exits |
| Produces | `base.tar`, `dump.sql`, manifests | WAL segments |
| Owned by | KubeStash | the Sidekick operator |
| Granularity | whole database, every N hours | every transaction |

Almost every confusing behaviour in this system comes from the **seam between them** — the gate, the
WAL backlog, the two separate retention policies. Keep the two cadences separate in your head and the
rest follows.

---

## 2. Who owns what

**The Postgres operator never moves a byte of backup data.** Its entire job is to translate user
intent into resources that *other* components act on — then wait, and gate.

```mermaid
graph TB
    OP["<b>KubeDB Postgres operator</b><br/><code>kubedb.dev/postgres</code><br/>reconciles, decides, gates — copies nothing"]

    BC["<b>BackupConfiguration</b><br/>core.kubestash.com<br/>sessions on a cron"]
    SK["<b>Sidekick</b><br/>apps.k8s.appscode.com"]

    J1["<b>backup Job</b><br/><code>postgres-restic-plugin</code><br/>run by KubeStash"]
    J2["<b>manifest Job</b><br/><code>kubedbmanifest-backup</code><br/>run by KubeStash"]
    J3["<b>snapshot Job</b><br/><code>postgres-csi-snapshotter-plugin</code><br/>run by KubeStash"]
    AP["<b>wal-g archiver pod</b><br/><code>postgres-archiver</code> · never exits<br/>run by the Sidekick operator, pinned to the primary"]

    D1[("restic repository<br/>…/&lt;db&gt;/full")]
    D2[("restic repository<br/>…/&lt;db&gt;/manifest")]
    D3["VolumeSnapshot<br/><i>stays in-cluster</i>"]
    D4[("wal-g native layout<br/>…/&lt;db&gt;/wal/wal_005/<br/>no restic, no encryption secret")]

    OP -- creates --> BC
    OP -- creates --> SK
    BC --> J1
    BC --> J2
    BC --> J3
    SK --> AP

    J1 -- restic --> D1
    J2 -- restic --> D2
    J3 -- "CSI API" --> D3
    AP -- wal-g --> D4
```

**Four producers, four destinations.** Three of the four end in the same bucket under different
prefixes — but only two of them are restic repositories. The WAL prefix is written by wal-g in its own
format and is *not* encrypted by the KubeStash encryption secret. The CSI route never leaves the
cluster at all.

| Repository | Ships | Runs as | Lifetime |
| --- | --- | --- | --- |
| `kubedb.dev/postgres` | the operator binary | Deployment in `kubedb` | always |
| `kubedb.dev/postgres-restic-plugin` | `backup`, `physical-backup`, `restore`, `physical-restore` | Job, one per session | minutes |
| `kubedb.dev/postgres-csi-snapshotter-plugin` | the VolumeSnapshotter driver | Job | seconds |
| `kubedb.dev/postgres-archiver` | `archive` — the wal-g pusher | Sidekick pod, and again as the WAL-replay pod on restore | forever / one-shot |
| `kubedb.dev/postgres-init-docker` | `start.sh`, `restore.sh`, `copy-data.sh` | init container; its scripts are executed by *other* pods | seconds |

> **Worth noticing.** The archiver image appears **twice** in the lifecycle — once as the long-lived
> WAL pusher during backup, once as a short-lived pod during restore that runs `/scripts/restore.sh`
> and replays WAL. Same image, opposite direction. It is the only component that both writes to and
> reads from the bucket.

---

## 3. Where KubeStash plugs in

KubeStash is not one graph, it is **three**, and they only touch at the moment a Job is built. One
chain says *where the bytes go*, one says *when to run*, one says *what binary to run*.

```mermaid
graph TB
    subgraph WHERE["STORAGE — where"]
        BS["<b>BackupStorage</b><br/>bucket, endpoint, credentials Secret"]
        RP["<b>Repository</b><br/>one restic repo at one directory"]
        SN["<b>Snapshot</b><br/>the receipt: what, when, restic id"]
        BS -- storageRef --> RP
        RP -- repository --> SN
    end

    subgraph WHEN["INVOKER — when"]
        BC["<b>BackupConfiguration</b><br/>sessions, each with a cron"]
        SE["<b>BackupSession</b><br/>one firing of one session"]
        JB["<b>Job</b><br/>does the copying, then dies"]
        BC -- "cron fires" --> SE
        SE -- spawns --> JB
    end

    subgraph WHAT["CATALOG — what"]
        AD["<b>Addon</b><br/>postgres-addon · cluster-scoped"]
        TK["<b>Task</b><br/>physical-backup, logical-backup, …"]
        FN["<b>Function</b><br/>image + argv template"]
        AD -- "backupTasks[]" --> TK
        TK -- function --> FN
    end

    BC -- "backends[]" --> BS
    BC -- "repositories[]" --> RP
    BC -- addon --> AD
    FN -- image --> JB
    JB -- writes --> SN
```

**Only the `BackupConfiguration` knows all three chains.** It is the join: it names a backend,
declares the repositories that backend should hold, and picks the addon task whose Function supplies
the image. Everything else is one chain minding its own business — which is why a broken backup is
almost always traceable to exactly one of the three.

The Function image is a **template**, not a literal:

```
ghcr.io/kubedb/postgres-restic-plugin:v0.29.0_${DB_VERSION}
availableVersions: [12.17, 14.10, 16.4, 17.2, 18.2]
```

`${DB_VERSION}` is substituted from the backup target's version. A target whose version isn't on that
list produces an image tag that doesn't exist, and the failure surfaces as `ImagePullBackOff` rather
than as anything that mentions versions.

---

## 4. Which backup is taken when

Adding `spec.archiver` flips two environment variables with different jobs:

* `WAL_BACKUP_TYPE=WALG` → the init scripts write a **real** `archive_command`
  (`petset.go:886`)
* `ARCHIVER_ENABLED=true` → creates the archive directories

So Postgres begins archiving **early** — but the process that ships those segments off the node does
not start until a full backup has already succeeded.

```mermaid
graph TB
    S1["<b>1 · User creates a PostgresArchiver</b><br/><code>archiver.kubedb.com/v1alpha1</code>"]
    S2["<b>2 · Operator patches the PetSet env</b><br/><code>WAL_BACKUP_TYPE=WALG · ARCHIVER_ENABLED=true</code>"]
    S3["<b>3 · Postgres restarts — archiving begins</b><br/><code>archive_command = 'cp %p /var/pv/wal_archive/%f'</code>"]
    S4["<b>4 · BackupConfiguration + ledger Snapshot created</b><br/><code>&lt;db&gt;-incremental-snapshot</code> · stays Running forever"]
    S5["<b>5 · First full backup fires immediately</b><br/><code>physical-backup</code> Job — does not wait for the cron"]
    S6{"<b>6 · GATE — InitialBackupSucceeded</b><br/>handleInitialBackupVerification() returns early"}
    S7["<b>7 · Sidekick created — wal-g starts pushing</b><br/><code>postgres-archiver archive --snapshot-name=…</code>"]

    ACC["<b>WAL piles up on the data volume</b><br/><code>/var/pv/wal_archive/</code><br/><br/>Postgres is archiving from step 3 on, but nothing<br/>is shipping the segments anywhere. This window is<br/>expected, not a fault — it lasts exactly as long as<br/>the first full backup takes."]
    DRAIN["<b>The backlog is drained at startup</b><br/><code>GetExistingWalFiles()</code> walks the directory before watching"]

    S1 --> S2 --> S3 --> S4 --> S5 --> S6
    S6 -- "true" --> S7
    S6 -- "false: return, requeue" --> S5

    S3 -.-> ACC
    ACC -.-> DRAIN
    S7 --> DRAIN
```

**The gap between step 3 and step 7 is the design, not a bug.** Because WAL starts before the pusher
does, the archiver cannot simply watch for new files — it walks the whole directory on startup and
pushes what it finds. That is why a restart of the sidekick is safe, and why a slow first backup shows
up as disk pressure rather than as a backup failure.

> **The failure this prevents.** If the sidekick started first and the full backup later failed, you
> would hold a pile of WAL with no base to replay it onto — useless bytes that still cost money. The
> gate guarantees the invariant every PITR system depends on: *there is always a base backup older
> than the oldest WAL segment you kept.*

**Size the data volume for the backlog, not for the steady state.**

---

## 5. How the bytes reach the bucket

Four routes that share **nothing** — not a tool, not a format, not a credential.

```mermaid
graph LR
    subgraph POD["postgres-0 pod"]
        SRV["<b>postgres server</b><br/>listening on :5432<br/><i>reached over the network —<br/>no volume mount needed</i>"]
        WD["<b>local WAL directory</b><br/><code>/var/pv/wal_archive/</code>"]
        PVC["<b>the data volume</b><br/><code>PVC data-&lt;db&gt;-0</code>"]
    end

    P1["<b>pg_dumpall</b><br/><code>postgres-restic-plugin</code> · logical-backup<br/><i>stdout piped into restic --stdin</i>"]
    P2["<b>pg_basebackup -D - -F t</b><br/><code>postgres-restic-plugin</code> · physical-backup<br/><i>stdout piped into restic --stdin</i>"]
    P3["<b>wal-g wal-push</b><br/><code>postgres-archiver</code> · the sidekick<br/><i>one segment at a time, continuously</i>"]
    P4["<b>VolumeSnapshot request</b><br/><code>postgres-csi-snapshotter-plugin</code><br/><i>reads no data — asks the CSI driver</i>"]

    subgraph BUCKET["object storage bucket"]
        B1[("<b>dump.sql</b><br/>…/&lt;db&gt;/logical")]
        B2[("<b>base.tar</b><br/>…/&lt;db&gt;/full")]
        B3[("<b>WAL segments</b><br/>…/&lt;db&gt;/wal/wal_005/")]
    end
    B4["<b>VolumeSnapshot</b><br/><i>never reaches the bucket</i>"]

    SRV -- TCP --> P1
    SRV -- TCP --> P2
    WD -- "read dir" --> P3
    PVC -- "K8s API" --> P4

    P1 -- "restic · encrypted" --> B1
    P2 -- "restic · encrypted" --> B2
    P3 -- "wal-g · compressed" --> B3
    P4 -- "CSI · stays in-cluster" --> B4
```

Nothing is staged on local disk on the way out. The two restic routes pipe their producer's stdout
straight into `restic backup --stdin`, so a 400 GB base backup never needs 400 GB of scratch space.

**The WAL prefix is not a restic repository.** It is written by wal-g in wal-g's own layout,
compressed but not encrypted with the KubeStash encryption secret, and it is the one place in the
bucket that restic cannot read. Losing the encryption secret costs you the base backups; it does not
cost you the WAL.

> **A consequence worth planning for.** Because the two chains are independent, retention is too. The
> archiver runs its *own* retention cron over the WAL prefix (`logBackup.retentionPeriod`), separate
> from the KubeStash `RetentionPolicy` that prunes restic snapshots. Set one without the other and you
> get either WAL you can't replay or base backups with nothing to replay onto them.

---

## 6. Why WAL takes two hops

Postgres never talks to object storage. That is the point.

```mermaid
graph LR
    PG["<b>Postgres</b><br/><code>archive_command</code>"]
    DIR["<b>local directory</b><br/><code>/var/pv/wal_archive/</code>"]
    SK["<b>wal-g sidekick</b><br/><code>postgres-archiver</code>"]
    OBJ[("<b>bucket</b><br/>…/wal/")]

    PG -- "cp %p<br/><b>hop 1</b>" --> DIR
    DIR -- "walk + watch" --> SK
    SK -- "wal-push<br/><b>hop 2</b>" --> OBJ
```

| | Hop 1 — `cp` to local dir | Hop 2 — `wal-g wal-push` |
| --- | --- | --- |
| Must it succeed? | **Always** | No |
| Latency | ~milliseconds | seconds, network-bound |
| If it fails | Postgres stops recycling WAL and **fills the volume** | the sidekick retries; the database is unaffected |
| Who runs it | the Postgres backend itself | a separate pod that may crash freely |

**The split exists to isolate a failure mode.** Any design that puts a network call inside
`archive_command` makes object-storage availability a hard dependency of database uptime. Splitting it
means the worst a bucket outage can do is grow a directory.

---

## 7. How a point in time is resolved

Choosing the base is a **sort, not a search**.

```
                                        recoveryTimestamp T
                                                │
   ┌────────────────────────────────────────────┼─────────────────────────┐
   │  continuous WAL — every segment, in order, no gaps                   │
   └──────────────────────────────────────────▲─┼─────────────────────────┘
                                              │ │
                                    replay ───┘ │
                                    forward     │
   ▌            ▌            ▌                  │            ▌
   │            │            │                  │            │
───┴────────────┴────────────┴──────────────────┴────────────┴────────────►  time
 base 00:00   base 06:00   base 12:00       T = 14:37     base 18:00
                            SELECTED                      newer than T
                                                          — discarded
```

The rule, in full:

1. List every `Snapshot` in the **full** repository.
2. Sort by time.
3. Take the newest one **at or before** T.

**Any older base would also be correct.** Choosing the newest one that still precedes the target is
purely an optimisation: it minimises how much WAL has to be replayed, and therefore how long the
restore takes. Correctness never depends on picking the closest — only on picking one that is *not
newer*.

Once the base is chosen, the target is handed to Postgres as a recovery parameter —
`recovery_target_lsn` when an LSN is known, `recovery_target_time` otherwise. Postgres replays until
it reaches the first commit past the target, stops **before** it, and promotes onto a new timeline.
The stopping point is a transaction boundary, never a partial write.

---

## 8. Restore, stage by stage

A restore is not one job. It is a sequence the operator drives from the outside, re-entering its
reconcile loop after every stage and refusing to advance until the previous stage reports success.

```mermaid
graph TB
    R1["<b>1 · Restore the manifest first</b><br/><code>kubedbmanifest-restore</code> · component: manifest<br/><i>Recreates the auth Secret, config Secret and archiver CR.<br/>The database cannot start without them.</i>"]
    G1{"gate<br/>RestoreSucceeded"}
    R2["<b>2 · Reconcile the database in recovery mode</b><br/><code>PITR_RESTORE=true · PITR_UNIX_TIME · HAS_VOLUME_SNAPSHOT</code><br/><i>Pods come up, but Postgres does not serve — it is<br/>waiting for its data directory to be filled.</i>"]
    G2{"gate<br/>DatabaseReplicaReady"}
    R3["<b>3 · Fill each data volume from the base backup</b><br/><i>one RestoreSession per replica · target kind PersistentVolumeClaim</i><br/><code>physical-backup-restore</code>"]
    R3B["<i>skipped entirely when the base<br/>was a VolumeSnapshot — the PVC<br/>was created from it directly</i>"]
    G3{"gate<br/>every PVC session Succeeded"}
    R4["<b>4 · Replay WAL up to the target</b><br/><i>one Sidekick per replica ·</i> <code>postgres-archiver</code> <i>running</i> <code>/scripts/restore.sh</code><br/><i>Starts Postgres locally, replays, promotes, stops.<br/>Exits when pg_is_in_recovery() turns false.</i>"]
    G4{"gate<br/>every sidekick Succeeded"}
    R5["<b>5 · Resume the replicas and serve</b><br/><i>fscopy: a Job copies PGDATA to the other replicas first</i><br/><b>Only now does the database accept connections.</b>"]

    R1 --> G1 --> R2 --> G2 --> R3 --> G3 --> R4 --> G4 --> R5
    G2 -.-> R3B -.-> G3
```

**Stage 3 is the one with a branch.** A restic base needs a Job per replica to unpack it; a
VolumeSnapshot base needs no Job at all, because the PVC was already provisioned from the snapshot
when stage 2 reconciled the PetSet. Everything downstream is identical.

---

## 9. How the data lands in the pod

This is the part that surprises people: **the restore never goes through the database.** No `psql`,
no network protocol, no import. Two separate pods mount the database's own PVC and write into it
directly, at different mount paths, before Postgres is allowed to open it.

```mermaid
graph LR
    W1["<b>1 · restore Job fills the volume</b><br/><code>postgres-restic-plugin</code> · physical-restore<br/>mounts the PVC at <code>/kubestash-data</code><br/>then: <code>restic dump | tar</code><br/><i>skipped when the base is a VolumeSnapshot</i>"]
    W2["<b>2 · WAL replay sidekick catches up</b><br/><code>postgres-archiver</code> · <code>/scripts/restore.sh</code><br/>mounts the <b>same</b> PVC at <code>/var/pv</code><br/><code>wal-g wal-fetch</code> · <code>pg_ctl start</code><br/><i>replays to the target, promotes, stops, exits</i>"]
    W3["<b>3 · Postgres starts serving</b><br/><code>postgres-docker</code> · the normal start path<br/><i>The pod was already running —<br/>it was waiting for this directory.</i>"]

    V["<b>PVC data-&lt;db&gt;-0</b><br/><code>PGDATA = /var/pv/data</code><br/>───────────────<br/><b>after 1:</b> a byte-for-byte copy of 12:00<br/><b>after 2:</b> recovered to 14:37, promoted<br/><b>after 3:</b> open for connections"]

    W1 -- writes --> V
    W2 -- rewrites --> V
    W3 -- opens --> V
```

**The same volume, mounted at two different paths by two different images.** The restic plugin writes
under `/kubestash-data`; the archiver mounts it at `/var/pv` because that is where its hardcoded paths
expect PGDATA to be. Getting either mount path wrong produces a restore that reports success and
leaves an empty directory.

> **Why the base must be physical.** WAL can only be replayed onto a byte-level copy — the LSNs in a
> segment refer to physical page positions. That is why the archiver's full backup is always
> `pg_basebackup` or a VolumeSnapshot and never `pg_dumpall`: a logical dump produces a *different*
> physical layout, and there is nothing for the WAL to attach to.

---

## 10. Reference tables

### 10.1 Tasks and what they actually run

| Task | Function | Command | Produces |
| --- | --- | --- | --- |
| `logical-backup` | `postgres-backup` | `pg_dumpall` → restic stdin | `dump.sql` |
| `physical-backup` | `postgres-physical-backup` | `pg_basebackup -D - -F t` → restic stdin | `base.tar` |
| `volume-snapshot` | `postgres-csi-snapshotter` | CSI VolumeSnapshot request | a snapshot object |
| `manifest-backup` | `kubedbmanifest-backup` | serialises the CR and Secrets | YAML in restic |
| `physical-backup-restore` | `postgres-physical-backup-restore` | `restic dump` → `tar -C` | a filled PVC |
| *(archiver only)* | *(no Function)* | `wal-g wal-push` / `wal-fetch` | WAL objects |

The last row is the one people miss: **the WAL path has no Addon, no Task and no Function.** It is not
a KubeStash job at all. KubeStash only learns about it through the ledger Snapshot the archiver writes
its bookkeeping into — which is why that Snapshot sits in `Running` forever and never completes.

### 10.2 Paths and environment

| Name | Value | Set by / meaning |
| --- | --- | --- |
| `PGDATA` | `/var/pv/data` | the data directory, on the PVC |
| WAL staging | `/var/pv/wal_archive/` | hardcoded in the archiver — hop 1's destination |
| restore mount | `/kubestash-data` | where the restic plugin mounts the target PVC |
| `WAL_BACKUP_TYPE` | `WALG` or empty | decides whether `archive_command` is real or `/bin/true` |
| `ARCHIVER_ENABLED` | `true` / `false` | creates the archive directories |
| `WALG_S3_PREFIX` | `s3://…/<db>/wal` | where wal-g writes; independent of the restic repos |
| `PITR_TIME` / `PITR_LSN` | a timestamp or LSN | becomes `recovery_target_*` during replay |

### 10.3 Two retention systems, not one

| | Base backups & manifests | WAL |
| --- | --- | --- |
| Governed by | KubeStash `RetentionPolicy` | `logBackup.retentionPeriod` on the archiver |
| Enforced by | KubeStash, after each session | a cron inside the archiver pod |
| Operates on | restic snapshots | objects under the wal-g prefix |
| Failure mode | WAL you cannot replay onto anything | bases with a gap after them |

---

*Drawn from `kubedb.dev/postgres`, `postgres-archiver`, `postgres-restic-plugin`,
`postgres-csi-snapshotter-plugin` and `postgres-init-docker`.*
