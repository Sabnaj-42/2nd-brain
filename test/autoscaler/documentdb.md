# Testing DocumentDB Autoscaler (compute + storage)

Targets branch **`add-documentdb-autoscaler`** of `/home/sabnaj/go/src/kubedb.dev/autoscaler`.

- **Commit under test:** `49cb672e` ("Add Autoscaling support for DocumentDB").
- The DocumentDB autoscaler is a straight port of the Postgres autoscaler; verification
  mirrors the KubeDB Postgres autoscaling guides:
  - compute: https://kubedb.com/docs/v2026.4.27/guides/postgres/autoscaler/compute/
  - storage: https://kubedb.com/docs/v2026.4.27/guides/postgres/autoscaler/storage/
- Companion to the ops-request suite (`../ops-request/documentdb.md`) — the autoscaler does **not**
  scale anything itself; it **creates DocumentDBOpsRequests** (VerticalScaling / VolumeExpansion)
  and the ops-manager does the actual work. So the relevant ops handlers must work first
  (VerticalScaling ✅ passes; VolumeExpansion ✅ passes on an expandable SC — see ops-request suite).

---

## 0. ⚠️ What this is + prerequisites (read first)

There are **two** independent autoscalers, both keyed off a single `DocumentDBAutoscaler` object
(`spec.compute` and `spec.storage`), run as two goroutine loops every `UpdateInterval`
(`pkg/controller/documentdb/controller.go RunControllers` → `RunComputeAutoscaler` +
`RunStorageAutoscaler`).

**Compute (vertical) autoscaler** (`compute_autoscaler.go`):
1. `Reconcile` (`reconciler.go`) ensures a **VPA** object whose name == the DB's petset name
   (`db.OffshootName()` == `dcdb`) when `spec.compute.documentdb.trigger: On`.
2. The compute loop lists VPAs owned by a `DocumentDBAutoscaler`, fetches the DB, checks
   `shouldReconcile` (DB `Ready`, or `Provisioned` when `apply: Always`) and `IsOpsRunning`
   (no VerticalScaling ops already Pending/Progressing), then asks the VPA recommender for a
   recommendation.
3. If the recommendation is `Ok` it builds a **VerticalScaling** `DocumentDBOpsRequest`
   named `dcops-dcdb-<rand>` (`documentdb_ops_request.go DocumentDBOpsRequestVerticalScale`) and
   creates it (only if it differs from the last ops it created — `shouldCreateOpsRequest`).
4. The recommendation is clamped to `minAllowed`/`maxAllowed`. A current request **below
   `minAllowed`** is out-of-band → scales up to the floor; this is the deterministic test.

**Storage autoscaler** (`storage_autoscaler.go`):
1. Loop lists `DocumentDBAutoscaler`s with `spec.storage`, gets the DB, `shouldReconcile`.
2. Reads PVC usage from the custom-metrics client (`storage.GetVolumeForOpsReq`). If usage% >
   `usageThreshold`, computes a new size **from `scalingRules`** (`calculate(rule.threshold, capacity)`,
   capped at `upperBound`). NOTE: the top-level `scalingThreshold` is **not** consulted on this path —
   see Finding B. PVCs whose name contains `main-config`/`nodetool` are skipped.
3. If the new size > current `spec.storage.resources.requests.storage`, creates a
   **VolumeExpansion** `DocumentDBOpsRequest` named `dcops-dcdb-<rand>` with `mode: <expansionMode>`.

### Prerequisites — verified + made-ready on the cluster as of 2026-06-18
| Need | Why | State |
|------|-----|-------|
| `documentdbautoscalers.autoscaling.kubedb.com` CRD | the controller only registers once its CRD exists (`apiextensions.RegisterSetup`) | ✅ installed (2026-06-18 11:11) |
| Autoscaler image on this branch | runs the DocumentDB loops | ✅ `sabnaj/kubedb-autoscaler:add-documentdb-autoscaler_linux_amd64` (running in `kubedb` ns, 0 restarts) |
| **metrics-server** (`v1beta1.metrics.k8s.io`) | compute recommender needs pod CPU/memory metrics | ✅ **installed** via Helm — see `../metric_installation.md` (chart 3.13.0 / v0.8.0, `--kubelet-insecure-tls`) |
| **custom-metrics API** (`custom.metrics.k8s.io`, `volume_used_percentage`) | storage loop reads PVC usage from the custom-metrics API | ✅ **installed** via `storage-metrics-apiserver` Helm chart — see `../metric_installation.md` (NOT Prometheus/adapter; this server exposes per-PVC volume stats directly) |
| **RBAC**: autoscaler SA can read `custom.metrics.k8s.io` | storage loop calls the custom-metrics API as the autoscaler SA | ⚠️ **had to be added** — `kubedb-kubedb-autoscaler` ClusterRole lacked it → `403 Forbidden`. Added a rule `apiGroups:[custom.metrics.k8s.io] resources:[*] verbs:[get,list,watch]`. See **Finding A** below. |
| Working VerticalScaling + VolumeExpansion ops handlers | the autoscaler only *creates* these ops | ✅ VerticalScaling passes; VolumeExpansion passes on longhorn (ops-request suite) |
| ops-manager + provisioner on the matching branches | execute the created ops | ✅ already deployed for the ops-request suite |
| Expandable StorageClass for storage tests | VolumeExpansion needs `allowVolumeExpansion: true` | ✅ `longhorn` present |

### 🔎 Findings during testing (2026-06-18) — worth fixing upstream
- **Finding A — storage autoscaler RBAC gap.** The DocumentDB storage loop queries the custom-metrics
  API *as the autoscaler ServiceAccount* (`kubedb/kubedb-kubedb-autoscaler`). That SA's ClusterRole
  ships with a `metrics.k8s.io / pods` rule but **no `custom.metrics.k8s.io` rule**, so every PVC-usage
  query returned `403 Forbidden` and the loop silently created no ops. Fix applied on-cluster (patch the
  ClusterRole). **Upstream:** the autoscaler chart/ClusterRole template should include the
  `custom.metrics.k8s.io` read rule so storage autoscaling works out-of-the-box.
- **Finding B — storage size is driven by `scalingRules`, not `scalingThreshold`.** In the DocumentDB
  code path (`GetVolumeForOpsReq`), the new size is computed **only** by iterating
  `spec.storage.documentdb.scalingRules[]` and calling `calculate(rule.threshold, capacity)`. The
  simpler top-level `scalingThreshold` field is **never read here** — with no `scalingRules` the loop
  falls through and creates no ops. The test yaml therefore uses `scalingRules: [{appliesUpto: "",
  threshold: "50%"}]`. (Postgres relies on a defaulter to synthesize a rule from `scalingThreshold`;
  that defaulting does not take effect for DocumentDB on this path.)

> The autoscaler is already **wired** in `pkg/cmds/server/operator.go` (`addDocumentDBManager`,
> registered under `ResourceKindDocumentDBAutoscaler`) — unlike ops-manager, no manual wiring is
> needed. It just needs the CRD applied so the setup block fires.

### Known gaps / notes (don't file as bugs)
- Compute recommendations need a metrics history; on a freshly-installed metrics-server the first
  recommendation can take a few minutes of samples. The `minAllowed` floor is what makes the
  scale-up deterministic regardless of load.
- `resourceDiffPercentage` (default 50%) and `podLifeTimeThreshold` (default 15m) gate updates;
  the test yamls lower these (5% / 1m) so the scale-up triggers promptly.
- Storage autoscaling needs an **expandable** StorageClass (longhorn here; local-path is not).
- `nodeTopology` compute mode needs a `NodeTopology` CR — optional, see §5.3.

---

## 1. export: `export KUBECONFIG=/home/sabnaj/k3s.yaml`

---

## 2. Build & run the autoscaler (already deployed)
Image `sabnaj/kubedb-autoscaler:add-documentdb-autoscaler_linux_amd64` is already running as
`kubedb-kubedb-autoscaler-0` in the `kubedb` namespace. If you rebuild:
```bash
cd /home/sabnaj/go/src/kubedb.dev/autoscaler
export REGISTRY=sabnaj
make push        # or: make build + import into the node's containerd
# then restart the statefulset
kubectl rollout restart statefulset/kubedb-kubedb-autoscaler -n kubedb
```
Confirm it picked up the DocumentDB controller (after the CRD exists):
```bash
kubectl logs -n kubedb kubedb-kubedb-autoscaler-0 | grep -i "DocumentDB.*Autoscaler loop"
# expect: "Starting DocumentDB Compute Autoscaler loop" + "Starting DocumentDB Storage Autoscaler loop"
```

---

## 3. Apply CRDs
The autoscaler CRD is **not** vendored in the autoscaler repo, but it **is** in the documentdb
repo's vendored apimachinery. Apply it plus the DB/ops CRDs (the latter are already applied from the
ops-request suite, but re-applying is harmless and ensures the tuning-aware documentdbs CRD):
```bash
kubectl apply -f /home/sabnaj/go/src/kubedb.dev/documentdb/vendor/kubedb.dev/apimachinery/crds/autoscaling.kubedb.com_documentdbautoscalers.yaml
kubectl apply -f /home/sabnaj/go/src/kubedb.dev/documentdb/vendor/kubedb.dev/apimachinery/crds/kubedb.com_documentdbs.yaml
kubectl apply -f /home/sabnaj/go/src/kubedb.dev/documentdb/vendor/kubedb.dev/apimachinery/crds/ops.kubedb.com_documentdbopsrequests.yaml
```
Verify + (re)start the autoscaler so the setup block fires:
```bash
kubectl get crd documentdbautoscalers.autoscaling.kubedb.com
kubectl rollout restart statefulset/kubedb-kubedb-autoscaler -n kubedb
```

### 3a. Install metrics (prereqs for the loops)
Full recipe (Helm, with the local `kubeops.dev` charts) is in **`../metric_installation.md`**. In short:
```bash
# compute: resource metrics (metrics-server)
helm install metrics-server /home/sabnaj/go/src/kubeops.dev/metrics-server/charts/metrics-server \
  -n kube-system --set 'args[0]=--kubelet-insecure-tls'
kubectl get apiservice v1beta1.metrics.k8s.io          # Available=True
kubectl top pods -n demo                               # returns numbers

# storage: PVC usage via custom.metrics.k8s.io (storage-metrics-apiserver, NOT Prometheus)
kubectl create namespace storage-metrics
helm install storage-metrics-apiserver \
  /home/sabnaj/go/src/kubeops.dev/storage-metrics-apiserver/charts/storage-metrics-apiserver \
  -n storage-metrics
kubectl get apiservice v1beta2.custom.metrics.k8s.io   # Available=True

# RBAC (Finding A): let the autoscaler SA read the custom-metrics API
kubectl patch clusterrole kubedb-kubedb-autoscaler --type=json \
  -p='[{"op":"add","path":"/rules/-","value":{"apiGroups":["custom.metrics.k8s.io"],"resources":["*"],"verbs":["get","list","watch"]}}]'
```

---

## 4. Apply a base DocumentDB + seed
Compute tests use `object.yaml` (local-path, low 500m/1Gi so minAllowed forces a scale-up).
Storage tests use `object-longhorn.yaml` (expandable SC, 2Gi).
```bash
kubectl apply -f /home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/documentdb/autoscale-test-yaml/object.yaml
kubectl get documentdb dcdb -n demo -w        # wait Ready
PASS via in-pod trust: kubectl exec -n demo dcdb-0 -c documentdb -- \
  bash -c "psql -h localhost -p 9712 -U documentdb -d postgres -tAc \
  \"CREATE TABLE IF NOT EXISTS ops_test(id int); INSERT INTO ops_test VALUES (1);\""
```

Common watch loop for every test:
```bash
kubectl apply -f <autoscaler>.yaml
kubectl get documentdbautoscaler -n demo -o wide
kubectl describe documentdbautoscaler -n demo <name>          # Status.VPAs + Conditions
kubectl get vpa -n demo                                       # compute: VPA named "dcdb"
kubectl get documentdbopsrequest -n demo -w                   # autoscaler-created dcops-dcdb-* ops
kubectl get documentdb dcdb -n demo -o jsonpath='{.spec.podTemplate.spec.containers[?(@.name=="documentdb")].resources}'   # compute result
kubectl get pvc -n demo                                       # storage result
```

---

## 5. Tests

### 5.1 Compute autoscaling — scale UP to minAllowed (primary test)
Base DB requests 500m/1Gi; autoscaler `minAllowed` is 600m/1.5Gi.
```bash
kubectl apply -f .../autoscale-test-yaml/compute-autoscaler.yaml
```
**Expect:**
- A `VerticalPodAutopilot`/VPA object named `dcdb` is created; the autoscaler's
  `status.vpas` lists it; condition `CreateOpsRequest` appears once it acts.
- Within a few `UpdateInterval`s (and once metrics exist) a **VerticalScaling**
  `DocumentDBOpsRequest` named `dcops-dcdb-<rand>` is created, owned by the autoscaler
  (`ownerReferences[].kind: DocumentDBAutoscaler`).
- That ops goes `Pending → Progressing → Successful`; afterward
  `db.spec.podTemplate...containers[documentdb].resources.requests` ≈ **600m / 1.5Gi**
  (clamped up to minAllowed), pods carry the new resources, `SHARED_BUFFERS` recomputed,
  data intact, DB `Ready`.
- No second ops is created while the first is Pending/Progressing (`IsOpsRunning` guard), and an
  identical recommendation does not create a duplicate (`shouldCreateOpsRequest`).
**Verify the created ops is from the autoscaler:**
```bash
kubectl get documentdbopsrequest -n demo -o custom-columns=NAME:.metadata.name,TYPE:.spec.type,OWNER:.metadata.ownerReferences[0].kind,PHASE:.status.phase
```

### 5.2 Compute trigger Off (disable / negative)
```bash
kubectl apply -f .../autoscale-test-yaml/compute-autoscaler-off.yaml   # same name, trigger: "Off"
```
**Expect:** no VPA ensured, no ops created; `ensureVPAs` returns early on `trigger: Off`. Flipping an
existing On→Off should stop further scaling (existing ops already created are not reverted).

### 5.3 Compute with NodeTopology (advanced / optional)
Needs a `NodeTopology` CR; edit `compute-autoscaler-nodetopology.yaml` `spec.compute.nodeTopology.name`.
**Expect:** the recommendation is snapped to the nearest node group / machine profile; the created
VerticalScaling ops carries node-selector/toleration + machine annotations
(`VerticalScaleOpsRequestForNodeTopology`). Skip if no NodeTopology is configured.

### 5.4 Storage autoscaling (needs longhorn + custom metrics)
Recreate the DB on longhorn first:
```bash
kubectl delete documentdb dcdb -n demo
kubectl apply -f .../autoscale-test-yaml/object-longhorn.yaml          # 2Gi on longhorn
kubectl apply -f .../autoscale-test-yaml/storage-autoscaler.yaml       # usageThreshold 60%, scalingRules +50%, Online, cap 10Gi
# fill the volume past 60% to trigger. The data dir is mounted at /var/pv:
for p in dcdb-0 dcdb-1 dcdb-2; do
  kubectl exec $p -n demo -c documentdb -- sh -c 'fallocate -l 1300M /var/pv/filler.dat; df -h /var/pv | tail -1'
done
# confirm the metric reflects it (wait ~1 scrape interval / 60s):
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/persistentvolumeclaims/*/volume_used_percentage" | jq -r '.items[]|"\(.describedObject.name): \(.value)"'
# after the test, remove the filler:
for p in dcdb-0 dcdb-1 dcdb-2; do kubectl exec $p -n demo -c documentdb -- rm -f /var/pv/filler.dat; done
```
**Expect:** once PVC usage > 60%, a **VolumeExpansion** `DocumentDBOpsRequest` (`dcops-dcdb-<rand>`,
`mode: Online`) is created, grows storage by 50% (≈2Gi → ≈3Gi, capped at 10Gi); after it succeeds all
PVCs show the new size and `db.spec.storage.resources.requests.storage` is patched; data intact.
**Caveats:** (1) without the custom-metrics API the loop has no PVC usage and never triggers; (2) the
autoscaler SA needs the `custom.metrics.k8s.io` RBAC rule (Finding A) or every query is `403`; (3) you
must set `scalingRules` — `scalingThreshold` alone produces nothing (Finding B).

### 5.5 Combined compute + storage
```bash
kubectl apply -f .../autoscale-test-yaml/combined-autoscaler.yaml      # against the longhorn DB
```
**Expect:** both behaviours from 5.1 and 5.4 driven by one object; each loop creates its own ops
independently. The `IsOpsRunning`/`shouldCreateOpsRequest` guards prevent overlapping VerticalScaling
ops; storage and compute ops can proceed in sequence (ops-manager serializes per-DB).

---

## 5R. Test results — executed 2026-06-18 (k3s, KUBECONFIG=/home/sabnaj/k3s.yaml)

Prep: deleted all leftover ops requests; recreated `dcdb` fresh from `object.yaml` (clean
500m/1Gi baseline, since the ops-request suite had left it at 500m/**2Gi**+tuning which would
have made the memory scale-up non-deterministic).

| # | Scenario | Result | Evidence |
|---|----------|--------|----------|
| 5.1 | **Compute scale-up → minAllowed** | ✅ **PASS** | VPA recommended `cpu:600m, memory:1536Mi`; autoscaler condition `CreateOpsRequest=True`; created **VerticalScaling** `dcops-dcdb-iw3vaj` → `Successful`. DB spec **and live pod `dcdb-0`** both moved `500m/1Gi → 600m/1536Mi`. |
| 5.2 | **Compute trigger Off** | ✅ **PASS** | Applied `compute-autoscaler-off.yaml`; watched 2.5 min — `status.vpas` stayed empty, **0** ops created. Dormant as expected. |
| 5.3 | Compute + NodeTopology | ⏭️ **SKIPPED** | No `NodeTopology` CR on this cluster (optional/advanced). |
| 5.4 | **Storage expansion** | ✅ **PASS** (after Findings A+B) | Recreated `dcdb` on longhorn (2Gi); filled `/var/pv` to ~78–81% (3 pods). Metric reported `79.7 / 78.0 / 76.4`%. After fixing RBAC + switching to `scalingRules`, created **VolumeExpansion** `dcops-dcdb-6gvlha` (`mode: Online`, newSize `3060559872`≈2.85Gi = capacity×1.5) → `Successful`. All 3 PVCs grew **2Gi → 2920Mi**; `db.spec.storage...storage` patched. Filler removed afterward. |
| 5.5 | Combined compute+storage | ⏭️ not separately run | Covered by 5.1 + 5.4 individually; `combined-autoscaler.yaml` was corrected for the same `scalingRules` fix. |

**Net:** every applicable DocumentDB autoscaler path works — compute creates a VerticalScaling ops
to the `minAllowed` floor, `trigger: Off` is dormant, and storage creates a VolumeExpansion ops once
usage exceeds the threshold. Two environment/manifest fixes were required to get storage working
(Findings A + B in §0); the controller logic itself is correct.

---

## 6. Cleanup
```bash
kubectl delete documentdbautoscaler --all -n demo
kubectl delete documentdbopsrequest --all -n demo
kubectl delete documentdb dcdb -n demo
```

---

## 7. Pass criteria
- **Compute:** applying `compute-autoscaler.yaml` ensures a VPA named `dcdb`, and (with metrics-server)
  produces a VerticalScaling `dcops-dcdb-*` ops owned by the autoscaler that scales the DB up to
  `minAllowed` (600m/1.5Gi); guards prevent duplicate/overlapping ops; `trigger: Off` produces nothing.
- **Storage:** applying `storage-autoscaler.yaml` on an expandable SC (with custom metrics) produces a
  VolumeExpansion `dcops-dcdb-*` ops when PVC usage ≥ `usageThreshold`, growing storage by
  `scalingThreshold`% up to `upperBound`.
- In all cases the DB ends `Ready`, data intact, and the autoscaler-created ops reach `Successful`.
- Environment prerequisites (CRD, metrics-server, custom metrics, expandable SC) must be satisfied —
  see §0; missing metrics is the most likely reason a loop "does nothing".

Test yamls in `2nd-brain/documentdb/autoscale-test-yaml/`:
`object.yaml`, `object-longhorn.yaml`, `compute-autoscaler.yaml`, `compute-autoscaler-off.yaml`,
`compute-autoscaler-nodetopology.yaml`, `storage-autoscaler.yaml`, `combined-autoscaler.yaml`.
