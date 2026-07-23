# Testing DocumentDB OpsRequest (real handlers — ported from Postgres)

Targets branch **`add-reconfigure-ops`** of `/home/sabnaj/go/src/kubedb.dev/documentdb`.

- **Commit under test:** `41aaa7ee1` ("Add tuning config support to Reconfigure and
  VerticalScaling ops requests"), on top of `d5322e675` ("documentdb-reconfigure (#25)").
- **What changed since the last run (commit `7a493648b`, see §7a):** Reconfigure now
  actually *renders and applies* configuration, and both **Reconfigure** and
  **VerticalScaling** gained a structured **`tuning`** block (pgtune auto-tuning). The two
  bugs that made 5.5 a FAIL last time are addressed in code (details in §5.5). The previous
  scaffolding commit `4346803c` (all 12 handlers no-op stubs) and the
  `add-all-ops-requests` working tree are both superseded by this branch.

> **This update focuses on Reconfigure (§5.5) and VerticalScaling (§5.2)** — the two ops
> requests fixed/extended in this PR. Other sections carry forward from the 7a493648b run;
> re-verify them only if you rebuild against this branch.

---

## 0. ⚠️ What this commit actually is (read first)

This is no longer scaffolding. I read every handler in `pkg/ops/*` at this commit:

**8 OpsRequest types are fully implemented** (ported from Postgres):

| Implemented            | Entry point                            |
|------------------------|----------------------------------------|
| `UpdateVersion`        | `update_version.go` (+ `major_upgrade.go`, `upgrade_utils.go`) |
| `HorizontalScaling`    | `horizontal_scaling.go` (+ `standAlone_to_ha.go`, `ha_to_standalone.go`, up/down scaling files) |
| `VerticalScaling`      | `vertical_scaling.go`                  |
| `VolumeExpansion`      | `volume_expansion.go` (+ online/offline files) |
| `Restart`              | `restart.go`                           |
| `Reconfigure`          | `reconfigure.go` (+ `reconfigure_merger.go`) |
| `RotateAuth`           | `rotate_auth.go`                       |
| `StorageMigration`     | `storage_migration.go`                 |

**4 types now fail explicitly** instead of silently logging (`ops_request.go:264-299`):
`ReconfigureTLS`, `ReconnectStandby`, `SetRaftKeyPair`, `ForceFailOver` —
each returns `"<X> is not yet supported for DocumentDB"`. The failure helper
(`controller.go pushFailureEventDocumentDBOpsReq`) retries up to `spec.maxRetries`
(default 0 → fails on first attempt) and then sets **phase `Failed`**. That is the
expected pass result for these 4 — *not* a stuck `Pending`.

**Clustering is now real.** This branch contains the merged Clustering PR (#7):
the provisioner runs a `documentdb-coordinator` (raft) container and an init container,
so the catalog version **requires `coordinator.image` and `initContainer.image`**,
and HA (replicas ≥ 2) plus standalone↔HA scaling are testable.

**Common handler lifecycle** (all 8 implemented types):
1. `Pending` → `Progressing` (phase update + event).
2. Pause backups (Stash) and **pause the DB** — sets a pause request and waits for the
   *provisioner* to ack with the `DatabasePaused` condition. ⇒ **the provisioner must be
   built from this same commit**, otherwise every ops request hangs in `Progressing`
   logging "waiting for the pause request to be approved by Provisioner".
3. In HA, set raft key `OpsRequestProgressing` (block leader switch) before mutating.
4. Do the work via parallel-runner goroutines (conditions recorded step by step).
5. Patch the DocumentDB CR, resume DB + backups, set phase **`Successful`**.

Concurrent ops requests for the same DB are skipped/requeued every 30s; multiple
pending **Reconfigure** requests are *merged* — merged-away ones get phase **`Skipped`**
with a `ConfigurationMerged` event (`reconfigure_merger.go`).

### What's now fixed/added on this branch (was a gap at 7a493648b)
- **Inline config is now rendered into the pod.** The provisioner (`pkg/controllers/config_secret.go`
  + `petset.go`, PR #25) creates an operator-managed config secret `<db>-<uid6>` carrying
  `inline.conf` (from `spec.configuration.inline["user.conf"]`) and `pgtune.conf`, projected
  read-only at **`/etc/config/`** in the `documentdb` container (projected volume `custom-config`).
  The init scripts `include_if_exists` these files. This is the counterpart that was entirely
  missing before (old 5.5 Bug 2).
- **`Reconfigure.tuning` is now applied.** `DocumentDBConfiguration` gained a `Tuning` field;
  `copyTuningOptions` (reconfigure.go) maps `spec.configuration.tuning`
  (`profile`/`maxConnections`/`storageType`/`disableAutoTune`) onto the DB, and
  `EnsureConfigSecret` regenerates `pgtune.conf` via `pkg/pgtune`. `disableAutoTune: true`
  deletes `pgtune.conf`.
- **VerticalScaling regenerates tuning.** When the DB has `spec.configuration.tuning`, a new
  `UpdateTuningConfiguration` step recomputes `pgtune.conf` from the *new* container resources
  before the pods restart (vertical_scaling.go).
- **Reconfigure ordering fixed.** The DB is reconciled (config secret + petset volume rendered)
  in the `ReconcileDocumentDBDatabase` step **before** `CustomRestart`, so pods come up with the
  new config already mounted (old 5.5 Bug 1).

### Known gaps at this commit (don't file these as bugs)
- Read replicas / arbiter sub-specs are rejected with explicit errors (HorizontalScaling read replicas, VerticalScaling arbiter/readReplicas, VolumeExpansion arbiter).
- HorizontalScaling to `replicas: 1` is rejected when `db.spec.streamingMode: Synchronous`; `replicas: 0` is rejected.
- TLS is entirely absent (no cert handling in `manageDocumentDBEvent`).
- **UpdateVersion parses `DocumentDBVersion.spec.version` with go-version** (`utils.go isMajorVersionUpgrade`). A value like `pg17-0.109.0` **fails to parse** → the ops request errors immediately. Catalog entries used for UpdateVersion need numeric versions (e.g. `17.109.0`). See section 3.
- `StorageMigration` **requires `spec.timeout`** — fails immediately without it (`storage_migration.go:117`).

---

## 1. export: `export KUBECONFIG=/home/sabnaj/k3s.yaml`
- Now you can run all commands in my virtual machine k3s cluster.

---

## 2. Build, WIRE, and run the ops controller

There are two projects:
- `/home/sabnaj/go/src/kubedb.dev/ops-manager`  — runs the **ops-request** controllers
- `/home/sabnaj/go/src/kubedb.dev/provisioner` — runs the **provisioner** operator (DB CRUD)

### 2a. Point modules at the new commit — **apimachinery bump is now REQUIRED too**

The documentdb branch uses `kubedb.dev/apimachinery v0.65.0-rc.1.0.20260611065458-0f38d07ee1fd`.
ops-manager and provisioner currently vendor `...20260605052849-7c98b972c50e`, whose
`DocumentDB` type **lacks** `spec.halted`, `spec.configuration`, `spec.streamingMode`,
`spec.replication`, `spec.leaderElection` — the new handlers will not compile against it.

In **both** projects' `go.mod`:
```
kubedb.dev/apimachinery v0.65.0-rc.1.0.20260611065458-0f38d07ee1fd
kubedb.dev/documentdb 7a493648b04469956988da7630d2b20969a6b046
```
(ops-manager has no `kubedb.dev/documentdb` line yet — add it under the other
`kubedb.dev/*` requires; provisioner already has one with an old hash — replace it.
`go mod tidy` rewrites the hash to a pseudo-version.)

### 2b. Wire the controller into ops-manager (still REQUIRED — nothing in this repo runs `pkg/ops`)

Verified at this commit: `pkg/server/server.go` does not import `pkg/ops`, and
ops-manager master has zero documentdb references. Mirror exactly how
Cassandra/Postgres are wired in `ops-manager/pkg/controller/controller.go`:

1. Add the import:
   ```go
   documentdb "kubedb.dev/documentdb/pkg/ops"
   ```
2. Add a struct field (next to `Cassandra *cassandra.Controller`):
   ```go
   DocumentDB *documentdb.Controller
   ```
3. Construct it in `New(...)` (next to `ctrl.Cassandra = cassandra.New(...)`):
   ```go
   ctrl.DocumentDB = documentdb.New(opt, ctrl.Controller, certManagerClient, pemEncodeCert, verbosity)
   ```
4. Register the setup block (mirror the `ResourceKindCassandraOpsRequest` block):
   ```go
   apiextensions.RegisterSetup(schema.GroupKind{
       Group: ops.GroupName,
       Kind:  opsapi.ResourceKindDocumentDBOpsRequest,
   }, func(ctx context.Context, mgr manager.Manager) {
       c.DocumentDB.Init()
       _, _ = c.SecretInformer.AddEventHandler(c.DocumentDB.NewSecretWatcher())
       _, _ = c.ServiceInformer.AddEventHandler(c.DocumentDB.NewServiceWatcher())
       c.StartAndRunControllers(ctx.Done())
       c.DocumentDB.RunControllers(ctx.Done())
   })
   ```

### 2c. Build & push, then roll out — **provisioner rebuild is mandatory**

The provisioner must run this commit's `pkg/controllers` because the ops handlers depend on:
- the **pause/resume handshake** (`DatabasePaused` condition ack),
- `spec.halted` handling (standalone→HA flow halts/unhalts the DB),
- `spec.configuration` rendering into the pod (Reconfigure),
- the clustering petset (coordinator/init containers).

In both projects:
```bash
go mod tidy && go mod vendor
export REGISTRY=sabnaj
make push
```
Replace both images in the cluster (`kubedb` namespace), then confirm registration:
```bash
kubectl logs -n kubedb deploy/<ops-manager> | grep -i documentdbopsrequest
```

---

## 3. Apply CRDs + catalog versions

Apply the CRDs **from the commit's own vendored apimachinery** (they carry the new
`spec.halted` / `spec.configuration` / replication fields):
```bash
kubectl apply -f /home/sabnaj/go/src/kubedb.dev/documentdb/vendor/kubedb.dev/apimachinery/crds/kubedb.com_documentdbs.yaml
kubectl apply -f /home/sabnaj/go/src/kubedb.dev/documentdb/vendor/kubedb.dev/apimachinery/crds/ops.kubedb.com_documentdbopsrequests.yaml
kubectl apply -f /home/sabnaj/go/src/kubedb.dev/documentdb/vendor/kubedb.dev/apimachinery/crds/catalog.kubedb.com_documentdbversions.yaml
```

> ⚠️ **Reconfigure tuning needs the branch CRD.** Confirm the installed `documentdbs.kubedb.com`
> CRD exposes `spec.configuration.tuning` — older installs only have `inline`/`secretName`, and
> the apiserver then **silently prunes** `configuration.tuning` (Reconfigure with `tuning:` reports
> Successful but the field never persists; the provisioner deletes the config secret). Check:
> ```bash
> kubectl get crd documentdbs.kubedb.com -o jsonpath='{.spec.versions[0].schema.openAPIV3Schema.properties.spec.properties.configuration.properties}' | grep -o tuning
> ```
> If empty, re-apply the `kubedb.com_documentdbs.yaml` above (it carries the tuning field). Hit
> during the 2026-06-18 §5.5(d) run.

Catalog versions — clustering exists now, so **`coordinator` and `initContainer` images
are required**. Create **two** entries so UpdateVersion has a target. Note `spec.version`
is parsed by go-version in the UpdateVersion handler, so it must be numeric
(`pg17-0.109.0` ⇒ parse error ⇒ instant ops failure):

```yaml
apiVersion: catalog.kubedb.com/v1alpha1
kind: DocumentDBVersion
metadata:
  name: 'pg17-0.109.0'
spec:
  version: '17.109.0'          # numeric — required by UpdateVersion
  db:
    image: sabnaj/documentdb-local-vim:latest
  initContainer:
    image: sabnaj/documentdb-init:_linux_amd64
  coordinator:
    image: sabnaj/documentdb-coordinator:bootstrap_linux_amd64
  securityContext:
    runAsUser: 1000
---
apiVersion: catalog.kubedb.com/v1alpha1
kind: DocumentDBVersion
metadata:
  name: 'pg17-0.110.0'
spec:
  version: '17.110.0'          # same major (17) ⇒ minor update path
  db:
    image: sabnaj/documentdb-local-vim:latest   # same image is fine for plumbing test
  initContainer:
    image: sabnaj/documentdb-init:_linux_amd64
  coordinator:
    image: sabnaj/documentdb-coordinator:bootstrap_linux_amd64
  securityContext:
    runAsUser: 1000
```

> Major upgrade (`pg_upgrade` flow: sticky leader, copy old binaries, data-dir migration)
> needs a target image containing both PG majors — **not testable** with the current
> single-major images. Test the minor path only.

---

## 4. Apply a base DocumentDB

Most ops are tested against a **3-replica HA** cluster (exercises the raft/leader paths);
HorizontalScaling standalone→HA additionally needs a **standalone** one. The tuning paths
(§5.2a and §5.5(d)/(e)) need a DB with `spec.configuration.tuning` — use `object-tuning.yaml`.

```yaml
apiVersion: kubedb.com/v1alpha2
kind: DocumentDB
metadata:
  name: dcdb
  namespace: demo
spec:
  version: 'pg17-0.109.0'
  storageType: Durable
  deletionPolicy: Delete
  replicas: 3
  podTemplate:
    spec:
      containers:
        - name: documentdb
          resources:
            requests:
              cpu: 500m
              memory: 2Gi
  storage:
    storageClassName: "local-path"
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 5Gi
```
Wait for Ready, then seed a row so every op can prove data survival:
```bash
kubectl get documentdb -n demo -w
PASS=$(kubectl get secret -n demo dcdb-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n demo dcdb-0 -c documentdb -- env PGPASSWORD=$PASS \
  psql -U postgres -c "CREATE TABLE IF NOT EXISTS ops_test(id int); INSERT INTO ops_test VALUES (1);"
```

Common watch loop for **every** test below:
```bash
kubectl apply -f <ops>.yaml
kubectl get documentdbopsrequest -n demo -w        # Pending → Progressing → Successful
kubectl describe documentdbopsrequest -n demo <name>   # step-by-step Conditions
kubectl get documentdb dcdb -n demo -o yaml            # spec actually patched?
kubectl exec -n demo dcdb-0 -c documentdb -- env PGPASSWORD=$PASS \
  psql -U postgres -c "SELECT * FROM ops_test;"        # data survived
```
(Verification flow mirrors the Postgres guides: https://kubedb.com/docs/v2026.4.27/guides/postgres/)

---

## 5. Per-type functional tests

### 5.1 Restart — start here (simplest, validates the whole pause/raft/restart plumbing)
```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: DocumentDBOpsRequest
metadata: { name: dcdb-restart, namespace: demo }
spec:
  type: Restart
  databaseRef: { name: dcdb }
```
**Expect:** phase `Successful`; conditions include `RestartNodes`; all 3 pods get fresh
`startTime` (`kubectl get pods -n demo -o wide` before/after); DB back to `Ready`;
in HA the primary is restarted via the leader-aware path (raft key set/unset around it).

### 5.2 VerticalScaling
```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: DocumentDBOpsRequest
metadata: { name: dcdb-vscale, namespace: demo }
spec:
  type: VerticalScaling
  databaseRef: { name: dcdb }
  verticalScaling:
    documentdb:
      resources:
        requests: { cpu: 600m, memory: 2.5Gi }
        limits:   { cpu: "1",  memory: 2.5Gi }
    coordinator:
      resources:
        requests: { cpu: 100m, memory: 256Mi }
```
(yaml: `vertical-scaling.yaml`)
**Expect:** `Successful`; petset + pod containers carry the new resources
(`kubectl get pod dcdb-0 -n demo -o jsonpath='{.spec.containers[?(@.name=="documentdb")].resources}'`);
`db.spec.podTemplate` patched; `SHARED_BUFFERS` env recomputed from the new memory request.
**Negative:** add `arbiter:` or `readReplicas:` → fails with "not supported for DocumentDB"
(yaml: `vertical-scaling-negative.yaml`).

#### 5.2a VerticalScaling with auto-tuning regeneration (NEW on this branch)
Provision the DB **with tuning enabled** first (`object-tuning.yaml` — sets
`spec.configuration.tuning.profile: oltp`, memory 2Gi), seed data, then scale up:
```yaml
# vertical-scaling-tuning.yaml — documentdb 2Gi -> 3Gi on a tuning-enabled DB
spec:
  type: VerticalScaling
  databaseRef: { name: dcdb }
  verticalScaling:
    documentdb:
      resources:
        requests: { cpu: "1", memory: 3Gi }
        limits:   { cpu: "1", memory: 3Gi }
    coordinator:
      resources:
        requests: { cpu: 100m, memory: 256Mi }
```
**Why it matters:** when `db.spec.configuration.tuning != nil`, the handler runs the new
`UpdateTuningConfiguration` step (condition **`UpdateTuningConfiguration`**) which regenerates
`pgtune.conf` from the *new* resources **before** the pods are restarted, so the
memory-derived params follow the scaled memory (not just `SHARED_BUFFERS`).
**Verify:**
```bash
# condition present
kubectl describe documentdbopsrequest -n demo dcdb-vscale-tuning | grep UpdateTuningConfiguration
# pgtune.conf recomputed in the operator config secret (decode + look at shared_buffers etc.)
CFG=$(kubectl get documentdb dcdb -n demo -o jsonpath='{.metadata.uid}'); CFG=dcdb-${CFG: -6}
kubectl get secret -n demo $CFG -o jsonpath='{.data.pgtune\.conf}' | base64 -d
# same file mounted in the pod, values match the 3Gi tuning
kubectl exec -n demo dcdb-0 -c documentdb -- cat /etc/config/pgtune.conf
```
Expect `Successful`; `effective_cache_size`/`shared_buffers` in `pgtune.conf` larger than the
2Gi baseline; data intact. (On a non-tuned DB this step is skipped — that's the §5.2 path.)

> #### ✅ 5.2 RESULT — PASS (tested 2026-06-12)
> - `dcdb-vscale` → `Pending` → `Progressing` → **`Successful`** in ~2.5 min.
> - Pod + petset resources updated: documentdb `requests cpu=600m mem=2560Mi, limits cpu=1 mem=2560Mi`; coordinator `requests cpu=100m mem=256Mi` (was 200m).
> - `db.spec.podTemplate` patched with same values; `SHARED_BUFFERS` recomputed to `655360kB` (25% of 2560Mi) — confirms env recompute.
> - Conditions: `UpdatePetSets`, `EvictPod`, `CheckPodReady`, `CheckReplicaFunc`, `VerticalScale`, `Successful` all True; raft key set/unset around the mutation (`SetRaftKeyOpsRequestProgressing`/`UnsetRaftKeyOpsRequestProgressing`).
> - Data survived (`ops_test` row present); leader moved dcdb-1 → dcdb-0 during pod evictions (expected); DB back to `Ready`.
> - **Negative** `dcdb-vscale-arbiter` → **`Failed`** on first reconcile with event
>   `vertical scaling of arbiter is not supported for DocumentDB`. ✔
> - Note: connection details on this image — postgres listens on **port 9712**, superuser is in `dcdb-admin-auth` (user `documentdb`); `dcdb-auth` holds `default_user`. Use `psql -h localhost -p 9712 -U documentdb -d postgres`.

### 5.3 HorizontalScaling — 4 scenarios
```yaml
# (a) scale up 3 → 5
spec: { type: HorizontalScaling, databaseRef: { name: dcdb }, horizontalScaling: { replicas: 5 } }
# (b) scale down 5 → 3
spec: { type: HorizontalScaling, databaseRef: { name: dcdb }, horizontalScaling: { replicas: 3 } }
# (c) HA → standalone 3 → 1   (transfers leadership to pod-0 first, removes replication slots)
spec: { type: HorizontalScaling, databaseRef: { name: dcdb }, horizontalScaling: { replicas: 1 } }
# (d) standalone → HA 1 → 3   (halts DB, rebuilds as cluster — uses spec.halted handshake)
spec: { type: HorizontalScaling, databaseRef: { name: dcdb }, horizontalScaling: { replicas: 3 } }
```
**Expect each:** `Successful`; pod count and `db.spec.replicas` match; data survives
(c) and (d) — that's the whole point of the halt/leader-transfer choreography.
**Negative:** `replicas: 0` → fail; `replicas: 1` while `db.spec.streamingMode: Synchronous` → fail;
any `readReplicas` entry → fail.

> #### ⚠️ 5.3 RESULT — (a)(b)(c) PASS, (d) **FAIL** (tested 2026-06-12)
> - **(a) 3→5 PASS** — `Successful` in ~100s. Conditions `AddRaftNode--dcdb-3/4`, `PatchPetset`,
>   `HorizontalScaleUp`. `db.spec.replicas=5`, 5 pods Ready, data replicated to new pod dcdb-4.
> - **(b) 5→3 PASS** — `Successful` in ~150s. Conditions `RemoveRaftNode--dcdb-4/3` +
>   `DeletePvc--dcdb-4/3` (scaled-down PVCs cleaned). `db.spec.replicas=3`, data intact.
> - **(c) 3→1 (HA→standalone) PASS** — `Successful` in ~200s. Leadership transferred to dcdb-0
>   (`TransferLeaderShipToFirstNodeBeforeCoordinatorPaused`), other PVCs deleted, primary restarted.
>   After: dcdb-0 is primary (`pg_is_in_recovery=f`), **0 replication slots**, data intact, DB `Ready`.
> - **(d) 1→3 (standalone→HA) FAIL — BUG** 🐞
>   - Ops request stuck in `Progressing` indefinitely (>10 min). dcdb-1's PVC + a basebackup job
>     were created, but the job pod `basebackup-dcdb-1-*` died with **StartError**:
>     ```
>     exec: "role_scripts/standby/ha_backup_job.sh": stat role_scripts/standby/ha_backup_job.sh:
>     no such file or directory
>     ```
>   - Root cause: the handler builds the backup job with command `role_scripts/standby/ha_backup_job.sh`
>     (Postgres convention; in Postgres the init container populates `/role_scripts`). The DocumentDB
>     init image `sabnaj/documentdb-init:_linux_amd64` only ships `/init-scripts/run.sh` and
>     `/tmp/scripts/*` (`do_pg_basebackup.sh`, `copy-data.sh`, …) — it **never populates the
>     `role-scripts` emptyDir**, so the main container's exec fails before entrypoint.
>   - Also note: `db.spec.halted` was never set during the whole flow (stayed empty), and the job is
>     never retried/recreated — the ops request just hangs.
>   - Fix needed in documentdb repo: either ship `standby/ha_backup_job.sh` in the init image's
>     role-scripts copy step, or point the job at the scripts that actually exist in the image
>     (`/tmp/scripts/do_pg_basebackup.sh`-style flow).
>   - Recovery for testing: deleted ops request + DB, re-applied `object.yaml` fresh (3 replicas).

### 5.4 UpdateVersion (minor path only)
```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: DocumentDBOpsRequest
metadata: { name: dcdb-update-version, namespace: demo }
spec:
  type: UpdateVersion
  databaseRef: { name: dcdb }
  updateVersion: { targetVersion: pg17-0.110.0 }
```
**Expect:** `Successful`; conditions `UpdatePetSets` → `VersionUpdate`; petset image swapped
to the target's `db.image`, pods rolled one-by-one with `pg_isready` checks between;
`db.spec.version` patched to `pg17-0.110.0`.
**Negative:** target a `DocumentDBVersion` with `spec.deprecated: true` → fail with
"can't upgrade to a deprecated version".
**Caveat:** if the catalog still has non-numeric `spec.version` (old `pg17-0.109.0` style),
this fails at `isMajorVersionUpgrade` with a version-parse error — that's the catalog, not the handler.

> #### ❌ 5.4 RESULT — FAIL (tested 2026-06-12)
> - Catalog was fine (numeric `17.109.0` → `17.110.0`, same major). `dcdb-update-version` went
>   `Pending` → `Progressing`, `UpdatePetSets=True`, evicted dcdb-1 first — then **hung forever**:
>   `VersionUpdate=False`, `CheckReplicaFunc--dcdb-1=False`, retrying every 5s for >10 min, no timeout.
> - dcdb-1 came back 2/2 "Ready" but postgres never started: `run.sh` stuck at
>   `waiting for the role to be decided`, spamming "Permissions are greater than 0700".
>   Its coordinator looped with `rpc error: ... invalid username or password` (gRPC peer auth) and
>   `pq: permission denied to start WAL sender (42501)` against the new primary.
> - **Root cause — UpdatePetSets writes Postgres-style env, not DocumentDB's.** Diff of evicted
>   dcdb-1 vs untouched dcdb-0 (both containers):
>   - `POSTGRES_USER`/`POSTGRES_PASSWORD`: `dcdb-admin-auth` (superuser `documentdb`,
>     `rolreplication=t`) → **`dcdb-auth`** (`default_user`, **no replication privilege**) — this is
>     exactly the Postgres single-auth-secret convention; DocumentDB uses the separate admin secret.
>   - `PRIMARY_HOST`: `dcdb.demo.svc.cluster.local` → `dcdb` (short name).
>   - `PG_VERSION`: `17` → `17.110.0` (full catalog version instead of major).
>   - Plus upgrade plumbing (`OLD_BIN_DIR`) and raft envs (`PERIOD`, `ELECTION_TICK`, …) added to the
>     **db** container that the provisioner puts only on the coordinator.
> - With wrong creds the replica can't join → ops request never progresses **and never fails**
>   (secondary issue: `CheckReplicaFunc` retries indefinitely with no deadline).
> - ops-manager log signature: `update_version.go:300 ... dial tcp <pod-ip>:9712: connect: connection refused` repeating.
> - Fix needed in documentdb repo: `updatePetSet`/petset-env builder in `pkg/ops` must mirror the
>   provisioner's DocumentDB env (admin auth secret, FQDN primary host, major-only PG_VERSION).
> - **Confirmed in source** (`pkg/ops/update_version.go` ~378-440, branch `add-all-ops-requests`):
>   the `envList` uses `c.db.Spec.AuthSecret.Name` (user secret `dcdb-auth`) for
>   `EnvDocumentDBUser/Password`, `PRIMARY_HOST: c.db.ServiceName()` (short name), and
>   `PG_VERSION: targetVersion.Spec.Version` (full `17.110.0`), then `UpsertEnvVars` overwrites the
>   provisioner-set values on db + coordinator + init containers. The provisioner uses the **admin**
>   secret, the FQDN, and major-only `17`.
> - Recovery: deleted ops request + DB, re-applied `object.yaml`, reseeded data.

### 5.5 Reconfigure — inline config + structured tuning (rewritten on this branch)
Two independent config channels, both rendered by the provisioner into the operator config
secret `<db>-<uid6>` and projected read-only at **`/etc/config/`** in the `documentdb` container:

| Channel | Ops field | DB field | Secret key → mount path |
|---------|-----------|----------|-------------------------|
| Inline custom config | `configuration.applyConfig["user.conf"]` / `configSecret` | `spec.configuration.inline["user.conf"]` | `inline.conf` → `/etc/config/inline.conf` |
| Auto-tuning (pgtune) | `configuration.tuning.*` | `spec.configuration.tuning` | `pgtune.conf` → `/etc/config/pgtune.conf` |

`restart` semantics (`ReconfigureRestartTrue/False/Auto`): `Auto` is promoted to `True`
(rolling restart). `False` takes the reload path — config secret re-rendered, kubelet remounts
`/etc/config`, then the handler verifies the mount mtime moved and runs `SELECT pg_reload_conf();`
on every pod.

```yaml
# (a) applyConfig with restart  (reconfigure-apply.yaml)
spec:
  type: Reconfigure
  databaseRef: { name: dcdb }
  configuration:
    applyConfig:
      user.conf: |
        max_connections=250
---
# (b) reload-only, no pod restart  (reconfigure-reload.yaml)
spec:
  type: Reconfigure
  databaseRef: { name: dcdb }
  configuration:
    restart: "false"
    applyConfig:
      user.conf: |
        log_min_duration_statement=1000
---
# (c) removeCustomConfig  (reconfigure-remove.yaml)
spec:
  type: Reconfigure
  databaseRef: { name: dcdb }
  configuration:
    removeCustomConfig: true
---
# (d) structured tuning — NEW  (reconfigure-tuning.yaml)
spec:
  type: Reconfigure
  databaseRef: { name: dcdb }
  configuration:
    tuning:
      profile: web          # web | oltp | dw | mixed | desktop
      storageType: ssd      # ssd | hdd | san
      maxConnections: 300
---
# (e) disable auto-tuning — NEW  (reconfigure-tuning-disable.yaml; run after (d) or on object-tuning.yaml)
spec:
  type: Reconfigure
  databaseRef: { name: dcdb }
  configuration:
    tuning:
      disableAutoTune: true
```
**Verify:**
```bash
# inline path (a): the rendered file is mounted, and the value takes effect
kubectl exec -n demo dcdb-0 -c documentdb -- cat /etc/config/inline.conf       # max_connections=250
kubectl exec -n demo dcdb-0 -c documentdb -- env PGPASSWORD=$PASS \
  psql -U postgres -c "SHOW max_connections;"                                   # 250 after (a)
kubectl get documentdb dcdb -n demo -o jsonpath='{.spec.configuration}'        # inline / tuning set or cleared
# operator config secret holds the rendered keys
CFG=$(kubectl get documentdb dcdb -n demo -o jsonpath='{.metadata.uid}'); CFG=dcdb-${CFG: -6}
kubectl get secret -n demo $CFG -o jsonpath='{.data}' | jq 'keys'             # ["inline.conf"], +["pgtune.conf"] after (d)
# tuning path (d): pgtune.conf rendered + mounted
kubectl exec -n demo dcdb-0 -c documentdb -- cat /etc/config/pgtune.conf
```
- **(a)** `inline.conf` present at `/etc/config`, `SHOW max_connections` = 250, restart happened.
- **(b)** pod `startTime` must **NOT** change; condition `Reconfigure` via the reload path
  (`pg_reload_conf`), `log_min_duration_statement` = 1000.
- **(c)** `spec.configuration` cleared; `inline.conf` key gone from the secret; value back to default.
- **(d)** `pgtune.conf` appears in the secret and at `/etc/config/pgtune.conf`; `TUNING_ENABLED=true`
  env on the pod; `db.spec.configuration.tuning` patched.
- **(e)** `pgtune.conf` key removed from the secret and the mount disappears.
**Merger test** (`reconfigure-merge-1.yaml` + `reconfigure-merge-2.yaml`): apply two different
Reconfigure requests back-to-back → the merger creates a **new** `dcdb-rcfg-merged-<ts>` request
that ends `Successful` carrying the *merged* `user.conf` (`work_mem` + `maintenance_work_mem` both
present), and **both** originals end **`Skipped`** (skip event: "concurrent DocumentDBOpsRequests
is not allowed for same database, will retry after 30 seconds"). Verified 2026-06-18 — see §5.5 RETEST.
**Negative** (`reconfigure-negative.yaml`): `spec.configuration` absent → fail
("does not have a configuration").

> #### 5.5 STATUS on this branch — bugs addressed in code; needs a cluster retest
> The 2026-06-12 FAIL (commit `7a493648b`) was: (Bug 1) DB reconciled/restarted before the
> config was rendered, and (Bug 2) the provisioner had **no** path to render
> `spec.configuration.inline` into the pod. **Both are fixed on this branch:**
> - **Bug 2 fixed (PR #25, provisioner):** `pkg/controllers/config_secret.go` +
>   `petset.go` now create the operator config secret `<db>-<uid6>` (`inline.conf` /
>   `pgtune.conf`) and project it at `/etc/config/`. `opsReconciler.Reconcile` calls
>   `EnsureConfigSecret`, so every Reconfigure refreshes it.
> - **Bug 1 fixed:** in `reconfigure.go` the `ReconcileDocumentDBDatabase` step reconciles the
>   (in-memory) `dbCopy` — rendering the config secret and the petset's `custom-config` volume —
>   **before** `CustomRestart`, so pods come up with the new `/etc/config` already mounted. The
>   final block then patches `db.spec.configuration` and resumes.
> - **Tuning added (commit 41aaa7ee1):** scenarios (d)/(e) above are new — `copyTuningOptions`
>   maps `configuration.tuning` onto the DB and `pgtune.conf` is (re)generated / deleted.
>
> #### ✅ 5.5 RETEST — cluster run on branch `add-reconfigure-ops` (2026-06-18)
> Env: fresh 3-replica `dcdb` from `object.yaml` (local-path, pg17-0.109.0), ops-manager image
> `sabnaj/kubedb-ops-manager:documentdb-ops_linux_amd64`, config secret `dcdb-56ac0f`. Verified via
> `psql -h localhost -p 9712 -U documentdb -d postgres` (pg_hba trusts localhost).
>
> **(a) applyConfig `max_connections=250` (restart) → ✅ PASS** (~4m46s). The old FAIL is gone:
> - `/etc/config/inline.conf` rendered on **all 3 pods** with `max_connections=250`.
> - `SHOW max_connections` = **250 on all 3 pods** (was the silent no-op 100 before).
> - `db.spec.configuration.inline["user.conf"]` patched; config secret `dcdb-56ac0f` carries key
>   `inline.conf`. Data (`ops_test`) intact; DB `Ready`.
> - Conditions: full leader-aware rolling restart then `ReconcileDocumentDBDatabase=True`,
>   `Reconfigure=True`, `Successful=True`.
>
> **(b) reload-only `restart:"false"`, `log_min_duration_statement=1000` → ✅ PASS** (~93s):
> - Pod `startTime` **unchanged** on all 3 pods and `restartCount` stayed 0 — **no restart**.
> - `SHOW log_min_duration_statement` = `1s` (1000ms) on all pods, applied live.
> - `max_connections` still 250 (merged: `inline.conf` now holds both keys), data intact.
> - Conditions show the reload path: `ReconfigureStartTime`, `CheckMountUpdated`, `ReloadConfig`,
>   `Reconfigure`, `Successful` all True (no `CustomRestart`/leader-transfer conditions).
>
> **(c) removeCustomConfig → ✅ PASS** (~4m55s, rolling restart):
> - `db.spec.configuration` fully cleared; the owned config secret `dcdb-56ac0f` **deleted**
>   (`NotFound`); the `/etc/config` mount removed from the pods.
> - `SHOW max_connections` back to default **100** on all pods; data intact.
>
> **(d) structured tuning `profile: web, maxConnections: 300, storageType: ssd` → ✅ PASS**
> (after an environment fix — see ⚠️ below) (~4m41s, rolling restart):
> - `db.spec.configuration.tuning` persisted = `{maxConnections:300, profile:web, storageType:ssd}`.
> - Config secret (`dcdb-<uid6>`) carries `pgtune.conf`; mounted at `/etc/config/pgtune.conf`;
>   `TUNING_ENABLED=true`, `TUNING_FILE_PATH=/etc/config/pgtune.conf` env on the pod.
> - pgtune output matched inputs: `max_connections = 300`, `shared_buffers = 512MB`,
>   `effective_cache_size = 1536MB`, `random_page_cost = 1.1` / `effective_io_concurrency = 200`
>   (ssd), DB Type web, 2 GB RAM, 1 CPU. `SHOW max_connections` = **300**, `SHOW shared_buffers`
>   = **512MB** on all 3 pods. Data intact.
>
> > ⚠️ **Environment gotcha found during (d) — stale CRD prunes `configuration.tuning`.**
> > First run: the ops request requested tuning correctly and pgtune.conf was rendered/applied,
> > but `db.spec.configuration` came back **`{}`** — the field was silently dropped. Root cause:
> > the **installed** `documentdbs.kubedb.com` CRD only had `configuration.{inline,secretName}`
> > (no `tuning`), so the apiserver **pruned** `spec.configuration.tuning` on write. Because the
> > DB then had empty configuration, the provisioner's `EnsureConfigSecret` **deleted** the owned
> > config secret; the pod kept only a now-stale projected copy of `pgtune.conf` (would vanish on
> > the next restart). **Fix:** re-apply the branch's CRD
> > (`vendor/kubedb.dev/apimachinery/crds/kubedb.com_documentdbs.yaml` — it *does* contain
> > `configuration.tuning`), then recreate the DB. After that, tuning persists and the secret is
> > retained (verified above). This is a §3 setup step (apply CRDs from the vendored apimachinery),
> > **not** a handler bug — but worth calling out since inline config worked while tuning silently
> > dropped on the stale CRD.
>
> **(e) disableAutoTune: true → ✅ PASS** (~4m42s, run against the tuning-enabled DB from (d)):
> - `pgtune.conf` removed: config secret `dcdb-132250` **deleted**, `/etc/config` mount gone,
>   `TUNING_ENABLED` env cleared.
> - `SHOW max_connections` back to default **100** on all pods (tuning no longer applied).
> - `db.spec.configuration.tuning` retains the fields with `disableAutoTune: true`
>   (`{disableAutoTune:true, maxConnections:300, profile:web, storageType:ssd}` — `copyTuningOptions`
>   merges, so the intent is recorded while auto-tune is off). Data intact.
>
> **Merger (`reconfigure-merge-1` work_mem=8MB + `reconfigure-merge-2` maintenance_work_mem=128MB,
> applied back-to-back) → ✅ PASS.** Actual behaviour differs slightly from the description above:
> - The merger creates a **brand-new** ops request `dcdb-rcfg-merged-<ts>` (phase `Successful`)
>   and marks **both** originals `dcdb-reconfigure-merge-1` and `-merge-2` as **`Skipped`**
>   (not "one wins, one skipped"). Skip event on the originals: *"Skipping … concurrent
>   DocumentDBOpsRequests is not allowed for same database, will retry after 30 seconds."*
> - The merged result is correct and verified by pod exec on **all 3 pods** (`dcdb-0/1/2`):
>   `/etc/config/inline.conf` contains **both** `work_mem=8MB` and `maintenance_work_mem=128MB`, and
>   the runtime values match (`SHOW work_mem` = 8MB, `SHOW maintenance_work_mem` = 128MB on each pod).
> - Merged request `dcdb-rcfg-merged-1781768819635` carries condition `MergedFromOps=True` with
>   message `dcdb-reconfigure-merge-1, dcdb-reconfigure-merge-2`; both originals end `Skipped` with
>   reason **`ConfigurationMerged`** ("Configuration merged into newly created ops request …") —
>   confirming the dedicated merger path (`lib/reconfigure_merger.go`) handled it, not the generic
>   one-op-per-DB serialization guard (whose transient "concurrent … retry after 30s" event also
>   appears, harmlessly).
>   → Update the §5.5 "Merger test" prose: losers go `Skipped`, but a new merged request carries
>   the combined config rather than one of the originals ending `Successful`.
>
> **Negative (`reconfigure-negative.yaml`, no `configuration`) → ✅ PASS.** Phase **`Failed`** in
> ~2s; condition/event message exactly *"documentdb demo/dcdb-reconfigure-empty does not have a
> configuration"* (`Retry 1/1`, `maxRetries` default). DB untouched, stays `Ready`.
>
> **5.5 verdict — ✅ ALL PASS** (a, b, c, d, e, merger, negative) on branch `add-reconfigure-ops`.
> The 2026-06-12 FAIL is fully resolved: config is now rendered to `/etc/config` and actually takes
> effect, the reload path works without restart, tuning generates/removes `pgtune.conf`, and the
> merger combines configs. **One environment prerequisite surfaced:** the cluster's
> `documentdbs.kubedb.com` CRD must be the branch version (includes `configuration.tuning`),
> otherwise tuning is silently pruned (see (d) ⚠️). DB healthy and data intact throughout; no
> status-flapping observed this run.

### 5.6 RotateAuth — 2 scenarios
```yaml
# (a) operator-generated password
apiVersion: ops.kubedb.com/v1alpha1
kind: DocumentDBOpsRequest
metadata: { name: dcdb-rotate-auth, namespace: demo }
spec:
  type: RotateAuth
  databaseRef: { name: dcdb }
---
# (b) user-provided secret (create basic-auth secret dcdb-new-auth first: username must stay `documentdb` — the admin username; enforced by the fixed handler)
metadata: { name: dcdb-rotate-auth-ext, namespace: demo }
spec:
  type: RotateAuth
  databaseRef: { name: dcdb }
  authentication:
    secretRef: { name: dcdb-new-auth }
```
**Expect** (per the FIXED handler — RotateAuth rotates the **admin** secret `<db>-admin-auth`,
backend postgres superuser; the gateway secret `<db>-auth` is untouched):
`Successful`; conditions `UpdateCredential` → **`ApplyNewCredential`** (ALTER ROLE on primary) →
`UpdatePetSets` → `RestartNodes`; password in the **admin** auth secret changed (old creds kept
under `username.prev`/`password.prev`); psql works with the NEW password and fails with the old
one **over the network** (`-h dcdb.demo.svc` — localhost is trust); for (b)
`db.spec.adminAuthSecret.name` switches to `dcdb-new-auth` with `externallyManaged: true` and
`activeFrom` timestamp set, and the petset env re-points to the new secret.

> #### ❌ 5.6 RESULT — FAIL, leaves DB permanently NotReady (tested 2026-06-12; only (a) run)
> - `dcdb-rotate-auth` ended **`Successful`** (~3 min): conditions `UpdateCredential` →
>   `UpdatePetSets` → `RestartNodes` all True; `dcdb-auth` secret rotated with
>   `username.prev`/`password.prev` kept; all 3 pods restarted; data intact.
> - **But the real password never changed.** Over the network (scram path, since pg_hba trusts
>   localhost — note: always verify via `psql -h dcdb.demo.svc` from another pod, localhost is
>   `trust` and accepts any password): **OLD password still authenticates, NEW one is rejected.**
> - **Aftermath: DB stuck `NotReady` indefinitely** — the provisioner health check pings the gateway
>   with the rotated `dcdb-auth` creds and loops
>   `SCRAM-SHA-256 ... (AuthenticationFailed) Invalid key` (`health.go:107`). RotateAuth "success"
>   bricks the cluster's Ready condition.
> - **Root cause (source `pkg/ops/rotate_auth.go` 96-128):** `UpdateCredential` only generates the
>   new secret / stores `.prev` — there is **no `ALTER ROLE`** and no propagation into
>   postgres/gateway. The Postgres pattern (pod entrypoint applies `POSTGRES_PASSWORD` env on
>   restart) doesn't carry over: the DocumentDB petset's `POSTGRES_PASSWORD` env points to
>   **`dcdb-admin-auth`** (admin secret, not the one rotated), and the gateway's `default_user` is
>   only created at bootstrap. So restarting pods is a no-op for the rotated credential.
> - (b) external-secret scenario skipped — same broken propagation path.
> - Recovery: deleted ops request + DB, re-applied `object.yaml`, reseeded data.
>
> #### ✅ 5.6 RETEST — FIXED & PASS, both scenarios (2026-06-12, local fix in documentdb repo)
> **Fix** (uncommitted working-tree change in `kubedb.dev/documentdb` branch `add-all-ops-requests`,
> `pkg/ops/rotate_auth.go`, +109/-14): RotateAuth now rotates the **admin** secret
> (`<db>-admin-auth`, backend postgres superuser) instead of the gateway secret:
> 1. All secret plumbing switched `GetAuthSecretName()` → `GetAdminAuthSecretName()`;
>    DB patch targets `spec.adminAuthSecret` (ExternallyManaged/ActiveFrom) instead of `spec.authSecret`.
> 2. New step + condition **`ApplyNewCredential`** between `UpdateCredential` and `UpdatePetSets`:
>    execs `ALTER ROLE "documentdb" WITH PASSWORD '…'` on the current primary via pod exec in
>    **argv form (no shell)** over the pod-local trust connection (`psql -h 127.0.0.1 -p 9712`) —
>    retry-safe regardless of which password the role currently has. ALTER-first ordering means
>    restarted standbys immediately authenticate with the new `primary_conninfo` password.
> 3. External-secret path validates the username stays `documentdb` (role/conninfo/gateway assume it).
>
> Deployed by vendoring the local documentdb module into ops-manager (go.mod `replace`, test-only)
> and importing the image into the node's containerd as
> `sabnaj/kubedb-ops-manager:documentdb-ops_linux_amd64` (no registry push).
>
> **(a) operator-generated** → `Successful` in ~3 min, conditions
> `UpdateCredential → ApplyNewCredential → UpdatePetSets → RestartNodes`. Verified: admin secret
> rotated with `.prev` keys; gateway secret untouched; **new password authenticates over the
> network (scram), old one rejected** (`password authentication failed`); `spec.adminAuthSecret.activeFrom`
> set; DB `Ready`, `AcceptingConnection=True` (health-check errors only during the restart window,
> zero after); primary + 2 standbys streaming; data intact.
> **(b) external secret `dcdb-new-auth`** (username `documentdb`, password `NewExternalPass123`)
> → `Successful`; `spec.adminAuthSecret` switched to `dcdb-new-auth` with `externallyManaged: true`;
> petset env re-pointed to the new secret; prev creds stored in it; new password works over the
> network; cluster fully healthy, data intact.
> Note: coordinator peer-gRPC uses env creds captured at process start, so brief
> `invalid username or password` noise during the mixed-env rolling window is expected and harmless
> (raft transport and the exempted HealthCheck don't use it).

### 5.7 VolumeExpansion — ⚠️ needs an expandable StorageClass
`local-path` has no `allowVolumeExpansion` — the PVC patch will be rejected/stuck. Use an
expandable SC (e.g. longhorn/topolvm) for the positive test, or run it expecting retries.
```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: DocumentDBOpsRequest
metadata: { name: dcdb-volume-expansion, namespace: demo }
spec:
  type: VolumeExpansion
  databaseRef: { name: dcdb }
  volumeExpansion:
    mode: Offline        # Offline: delete petset → patch PVCs → recreate; Online: patch PVCs live
    documentdb: 10Gi
```
**Expect:** `Successful`; all PVCs show 10Gi (`kubectl get pvc -n demo`);
`db.spec.storage.resources.requests.storage` patched; condition `ReadyPetSets` true (Offline mode
recreates the petset). **Negative:** `arbiter:` quantity → fail.

> #### ◻️ 5.7 RESULT — positive path NOT TESTABLE in this env; failure handling + negative PASS (tested 2026-06-12)
> Run on a fresh DB provisioned on `standard-custom` (`allowVolumeExpansion: true`,
> `object-standard-custom.yaml`) after 5.8 — note 5.7/5.8 were run in swapped order for this.
> - **Positive (Offline, 5Gi→10Gi): blocked by environment, as the guide predicted.** Both SCs use
>   `rancher.io/local-path`, which has **no resize controller**, so `FileSystemResizePending` never
>   appears. The handler did the right things: petset deleted, replica pod dcdb-1 deleted, PVC
>   handled, then after retries ended **`Failed`** (~11 min) with
>   `FileSystemResizePending status of PVC is not true`.
> - **Failure/rollback path: PASS.** After `Failed` the handler resumed the DB, the petset and
>   dcdb-1 were recreated, all 3 pods rejoined replication, data intact on all nodes, PVCs back
>   `Bound` 5Gi, DB `Ready`. Cleanest failure recovery of the whole suite.
> - **Negative PASS:** `arbiter: 2Gi` → instant **`Failed`**, event
>   `volume expansion of arbiter is not supported for DocumentDB`. ✔
> - To test the positive path for real, install an expandable CSI (longhorn/topolvm) on the VM.
>
> #### ✅ 5.7 RETEST on Longhorn — PASS (2026-06-12, after installing Longhorn v1.12.0)
> Longhorn v1.12.0 installed (SC `longhorn`, tuned to `numberOfReplicas: 1` for the single-node
> cluster); DB recreated on it via `object-longhorn.yaml` (3 replicas, 5Gi).
> - `dcdb-volume-expansion` (Offline, 5Gi→10Gi) → **`Successful`** in ~4.5 min.
> - Conditions all True: `DeletePetset` → per-pod `IsPodDeleted`/`IsPvcData-dcdb-N Updated` (one pod
>   at a time: dcdb-1, dcdb-2, dcdb-0) → `CreatePod`/`IsPodReady` → `VolumeExpansion` →
>   `ReadyPetSets` → `Successful`.
> - All 3 PVCs `Bound` at **10Gi**; filesystem inside every pod grew to **9.8G**;
>   `db.spec.storage.resources.requests.storage` patched to 10Gi.
> - Cluster fully healthy afterwards: dcdb-1 primary with **2 standbys streaming**, `ops_test`
>   data present on all 3 nodes, DB `Ready`. (Notably the standby rejoin worked fine here —
>   the offline-expansion recreate path doesn't hit the 5.4/5.8 rejoin deadlock.)
> - With this, the VolumeExpansion handler is **fully validated**: positive path (longhorn),
>   failure rollback (local-path), and arbiter negative.

### 5.8 StorageMigration — `timeout` is REQUIRED; needs a 2nd StorageClass
```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: DocumentDBOpsRequest
metadata: { name: dcdb-storage-migration, namespace: demo }
spec:
  type: StorageMigration
  databaseRef: { name: dcdb }
  timeout: 10m                       # without this → instant failure (by design)
  migration:
    storageClassName: <target-sc>
    oldPVReclaimPolicy: Delete
```
**Expect:** `Successful`; new PVCs on `<target-sc>`; `db.spec.storage.storageClassName` patched;
data survives (the handler copies data pod-by-pod via migration jobs).
**Negative (cheap, no 2nd SC needed):** omit `timeout` → `Failed` with
"timeout is required for storageClass migration".

> #### ⚠️ 5.8 RESULT — ops Successful but cluster left degraded (tested 2026-06-12, run before 5.7 on purpose)
> Environment: migrated `local-path` → `standard-custom` (same provisioner, expansion-enabled SC).
> - **Negative PASS:** without `timeout` → instant **`Failed`**, event
>   `timeout is required for storageClass migration, without it ops request cannot proceed`. ✔
> - **Positive, the migration itself: PASS.** `Successful` in ~5 min. Full per-pod choreography
>   visible in conditions (replicas dcdb-1, dcdb-2 first, master dcdb-0 last): temp PVC
>   `data-migrate-*` → pvcmounter pod → migrator job → PV re-bind (`PatchPV`) → recreate pod.
>   All 3 PVCs ended `Bound` on `standard-custom`; `db.spec.storage.storageClassName` patched;
>   `ops_test` data present on new primary dcdb-1 and standby dcdb-0.
> - **But the failover during the master's migration is broken — cluster left 2/3:**
>   while dcdb-0 (old primary) was being migrated, **both** dcdb-1 and dcdb-2 promoted
>   (dcdb-2 log: `selected new timeline ID: 2` + `archive recovery complete` at 05:55:16, same
>   minute dcdb-1 became primary on timeline 2). dcdb-2 was then shut down by its coordinator and
>   is now deadlocked: `run.sh` at `waiting for the role to be decided`, coordinator looping
>   `failed on health check for standby waiting for the DocumentDB process to start from initial
>   script`. No postgres process on dcdb-2 >10 min later; primary has **1** standby instead of 2.
> - The DocumentDB CR still reports **`Ready`** (gateway health check only pings the primary) —
>   the degradation is invisible to the operator. `PodReady--dcdb-2=True` in conditions only
>   reflected k8s readiness, not postgres health (recurring theme: the readiness probe passes
>   while postgres is down).
> - Verdict: migration plumbing solid; the standby-rejoin/role-decision deadlock (same family as
>   the 5.4 symptom) must be fixed before this is production-safe.
> - Recovery: deleted ops request + DB; recreated for 5.7 with `storageClassName: standard-custom`
>   (saved as `object-standard-custom.yaml`) so VolumeExpansion runs on an expandable SC.

### 5.9 The 4 unsupported types — expect explicit `Failed`
```yaml
# minimal bodies; one file per type
spec: { type: ReconfigureTLS,   databaseRef: { name: dcdb }, tls: { issuerRef: { apiGroup: cert-manager.io, kind: Issuer, name: x }, certificates: [{ alias: client }] } }
spec: { type: ReconnectStandby, databaseRef: { name: dcdb } }
spec: { type: ForceFailOver,    databaseRef: { name: dcdb } }
spec: { type: SetRaftKeyPair,   databaseRef: { name: dcdb }, setRaftKeyPair: { keyPair: { k: v } } }
```
**Expect each:** phase **`Failed`** (after `spec.maxRetries`, default 0 ⇒ first reconcile),
warning event `Failed to be ready DocumentDBOpsRequest ... <Type> is not yet supported for DocumentDB`,
DB untouched and still `Ready`.

> #### ✅ 5.9 RESULT — PASS, all 4 (tested 2026-06-12)
> All four applied together; each reached **`Failed`** within ~30 s with the exact expected
> warning event:
> - `dcdb-reconfigure-tls` → `ReconfigureTLS is not yet supported for DocumentDB`
> - `dcdb-reconnect-standby` → `ReconnectStandby is not yet supported for DocumentDB`
> - `dcdb-force-failover` → `ForceFailOver is not yet supported for DocumentDB`
> - `dcdb-set-raft-key-pair` → `SetRaftKeyPair is not yet supported for DocumentDB`
>
> DB remained `Ready` and untouched throughout. ✔

---

## 6. Cleanup
```bash
kubectl delete documentdbopsrequest --all -n demo
kubectl delete documentdb dcdb -n demo
```

---

## 7a. TEST RUN SUMMARY — 2026-06-12 (initial run on commit `7a493648b`, all handlers exercised)

> **Updated after follow-ups (same day):**
> - **5.7** retested **PASS** after installing **Longhorn v1.12.0** (`longhorn` SC, 1 replica for the single-node cluster).
> - **5.6** retested **PASS (both scenarios)** after fixing `pkg/ops/rotate_auth.go` in the documentdb
>   repo (branch `add-all-ops-requests`, on top of `5e3de4748`, uncommitted) — rotate admin secret +
>   `ApplyNewCredential` ALTER ROLE step. See the retest blocks under 5.6/5.7 for details.
> - Cluster state after the run: ops-manager runs the locally-imported test image
>   `sabnaj/kubedb-ops-manager:documentdb-ops_linux_amd64` (statefulset patched to `IfNotPresent`;
>   revert to `v0.52.0-rc.1_linux_amd64` + `Always` to roll back); ops-manager's working tree has a
>   test-only `go.mod replace` to the local documentdb module; `dcdb` runs on the `longhorn` SC at
>   10Gi with `spec.adminAuthSecret` = externally-managed `dcdb-new-auth` (password `NewExternalPass123`).

| # | Type | Result | One-liner |
|---|------|--------|-----------|
| 5.1 | Restart | ✅ PASS | (run previously) |
| 5.2 | VerticalScaling | ✅ PASS | resources + SHARED_BUFFERS recomputed; negative (arbiter) ✔ |
| 5.2a | VerticalScaling + tuning | ⏳ NEW (this branch) | `UpdateTuningConfiguration` regenerates `pgtune.conf` from new resources — needs cluster retest |
| 5.3a-c | HorizontalScaling up/down/HA→standalone | ✅ PASS | raft add/remove, PVC cleanup, leader transfer, slots cleaned |
| 5.3d | HorizontalScaling standalone→HA | ❌ FAIL | basebackup job execs missing `role_scripts/standby/ha_backup_job.sh`; hangs forever |
| 5.4 | UpdateVersion (minor) | ❌ FAIL | `updatePetSet` env uses user secret/short host/full version → replica can't rejoin; hangs forever |
| 5.5 | Reconfigure | ✅ PASS (2026-06-18) | retested on `add-reconfigure-ops`: (a) inline applies (max_connections=250), (b) reload no-restart, (c) remove, (d) tuning pgtune.conf, (e) disableAutoTune, merger, negative — all pass. Needs branch CRD (tuning field) or tuning is pruned. |
| 5.6 | RotateAuth | ✅ FIXED & PASS | originally FAIL (no ALTER ROLE, DB bricked); fixed to rotate **admin** secret + exec ALTER ROLE on primary — both scenarios pass (see 5.6 retest) |
| 5.7 | VolumeExpansion | ✅ PASS (on longhorn) | 5Gi→10Gi Offline succeeded after installing Longhorn v1.12.0; earlier local-path run validated the failure-rollback path; negative (arbiter) ✔ |
| 5.8 | StorageMigration | ⚠️ PARTIAL | migration + data OK, but double-promotion during master move leaves dcdb-2 dead (2/3 cluster reported Ready) |
| 5.9 | 4 unsupported types | ✅ PASS | all `Failed` with exact "not yet supported" messages |

**Cross-cutting bugs seen repeatedly:**
1. **Standby rejoin deadlock** — `run.sh` "waiting for the role to be decided" + coordinator
   waiting for the process: hit in 5.4 and 5.8 (and arguably the 5.3d job is the same scripts-gap
   family). Any flow that recreates a standby pod off the happy path can strand it.
2. **k8s readiness ≠ postgres health** — pods report 2/2 Ready with no postgres process; ops
   handlers and the DB CR (`Ready` via gateway-only health check) both get fooled.
3. **No overall timeout in handler retry loops** — 5.3d and 5.4 hang in `Progressing` forever
   (5-second retries) instead of failing after a deadline.
4. **Status flapping** (5.5) — main reconcile and parallel restart runner overwrite each other's
   `status.conditions`/phase; watchers see a false early `Successful`.
5. Verification tip for auth tests: in-pod `psql -h localhost` is `trust` in pg_hba — always test
   credentials over the network (`-h dcdb.demo.svc`) from another pod.
6. **Coordinator peer-gRPC creds are frozen at process start** (`grpc/service/auth.go` reads
   `POSTGRES_USER`/`POSTGRES_PASSWORD` env once) — any rolling restart that changes the admin
   password produces transient `invalid username or password` between mixed-env pods. Harmless for
   RotateAuth (raft transport + HealthCheck are exempt), but worth knowing when reading logs.

**Remaining open bugs after the fixes: 5.3d (standalone→HA scripts gap), 5.4 (UpdateVersion env),
5.8 (double promotion during master migration).
5.5 (Reconfigure rendering/ordering) is now addressed in code on branch `add-reconfigure-ops`
(provisioner renders `/etc/config` + reconcile-before-restart; tuning added) — pending cluster retest;
RotateAuth (5.6) is fixed in the documentdb working tree; VolumeExpansion (5.7) was an
environment limitation, resolved by Longhorn.**

Test yamls for every scenario saved in `2nd-brain/documentdb/ops-test-yaml/` (one file per test,
incl. `object-standard-custom.yaml` used for 5.7). **New on this branch:** `object-tuning.yaml`
(tuning-enabled base DB), `reconfigure-tuning.yaml`, `reconfigure-tuning-disable.yaml`,
`vertical-scaling-tuning.yaml`.

---

## 7. Summary — pass criteria at this commit
- **Reconfigure (§5.5)** renders config to `/etc/config/{inline.conf,pgtune.conf}` via the operator
  config secret `<db>-<uid6>`; inline values actually take effect (`SHOW` reflects them); `tuning`
  generates/removes `pgtune.conf`; `restart:false` uses the `pg_reload_conf` path without changing
  pod `startTime`; merger losers end `Skipped`.
- **VerticalScaling (§5.2/5.2a)** carries new resources onto petset+pods, recomputes `SHARED_BUFFERS`,
  and (when the DB has `spec.configuration.tuning`) regenerates `pgtune.conf` from the new resources
  via the `UpdateTuningConfiguration` step.
- 8 types end **`Successful`** with the DB mutated as specified, data intact, DB `Ready` again.
- 4 types (`ReconfigureTLS`, `ReconnectStandby`, `SetRaftKeyPair`, `ForceFailOver`) end **`Failed`**
  with the "not yet supported" message — that is the correct result.
- Reconfigure merger: concurrent reconfigures merge; losers end **`Skipped`** + `ConfigurationMerged` event.
- Both operators (provisioner **and** ops-manager) must be rebuilt from commit `7a493648b`
  with apimachinery `...20260611065458-0f38d07ee1fd`, ops-manager manually wired (section 2b),
  and the new CRDs applied — otherwise everything stalls at the pause handshake.
- Environment caveats: numeric catalog `spec.version` for UpdateVersion; expandable
  StorageClass for VolumeExpansion; second StorageClass + `spec.timeout` for StorageMigration;
  major-version upgrade not testable with current images.
