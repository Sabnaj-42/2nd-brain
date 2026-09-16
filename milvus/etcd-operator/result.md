# Milvus + KubeDB-own-etcd-operator test — result

**Date:** 2026-09-16 (three runs, same day)
**Branch under test:** `kubedb.dev/milvus` @ `milvus-etcd` (commit `168e1db3`)
**Etcd operator under test:** `kubedb.dev/etcd` @ `master` (commit `5cb73db9`, tag `v0.1.0-rc.2`), later patched locally (see Run 3)
**Goal:** replace the official `etcd-io/etcd-operator` dependency for Milvus meta storage with KubeDB's own `Etcd` (`kubedb.com/v1alpha2`) CRD/operator, and verify standalone Milvus provisions using it (no official etcd-operator installed).

## Result: ✅ PASSES end-to-end, after a one-function fix in `kubedb.dev/etcd`

```
$ kubectl get milvus.kubedb.com,etcd.kubedb.com -n demo
NAME                                       VERSION   STATUS   AGE
milvus.kubedb.com/milvus-standalone-etcd   2.6.11    Ready    8m27s

NAME                                          VERSION   STATUS   AGE
etcd.kubedb.com/milvus-standalone-etcd-etcd   3.5.21    Ready    8m27s
```

Milvus's meta storage is now backed entirely by KubeDB's own `Etcd` operator. The official `etcd-io/etcd-operator` was never installed in this cluster for this test. Root cause, fix, and full reproduction are below.

- **Run 1** (no real etcd operator available): failed immediately — nothing reconciled the `Etcd` CR at all.
- **Run 2** (found and deployed the real `kubedb.dev/etcd` operator, unpatched): got much further — a real etcd cluster came up, but a bug in `kubedb.dev/etcd`'s member-promotion logic meant it never grew past 2 members and never reached quorum.
- **Run 3** (this run): fixed the bug in `kubedb.dev/etcd`, rebuilt, redeployed — `Etcd` reaches `Ready`, Milvus's meta-storage health check passes, and `Milvus` itself reaches `Ready`, serving real client connections.

Milvus's own code (this branch) behaved correctly in all three runs — no changes were needed in `kubedb.dev/milvus`.

---

## Run 3 — the fix

### Root cause

`kubedb.dev/etcd`'s `pkg/controller/reconcile_membership.go` has a `clusterClient()` helper used for every cluster-administration RPC during membership changes (`MemberList`, `Status`, `MemberPromote`). It dialed the **shared client Service** (`db.PrimaryServiceDNS()`), on the documented assumption that "the Service only routes to Ready pods, so it always lands on a serving voting member — never on the learner that is being added."

That assumption is false: etcd's own `/health` handler (used as the pod's readiness probe, see `pkg/controller/petset.go`) special-cases learners — it only checks that the learner has a leader, since a learner cannot serve the handler's normal linearizable read. So a learner's pod **does** turn `Ready` and **does** join the Service's endpoints. Once a 2nd member is added as a learner:

- Every RPC issued through `clusterClient()` (which dials a fresh connection to the shared Service each call) has a chance of being routed to the learner instead of the real voting member.
- etcd answers those calls with `rpc error: code = Unavailable desc = etcdserver: rpc not supported for learner` (or, if the learner hasn't yet replicated the "auth enable" log entry, `rpc error: code = FailedPrecondition desc = etcdserver: authentication is not enabled`).
- This file treats every failure from `MemberPromote`/`Status`/`MemberList` in this path as "try again later" (by design — etcd legitimately rejects a premature promotion too), so a promotion attempt that happens to land on the learner just silently retries forever, with no distinguishable error. In this cluster it reproduced every single time across many minutes and dozens of retries — never once succeeded before the fix.
- Because the learner is never promoted, `reconcileMembership`'s "finish an in-flight scale up before starting anything else" rule (never add a 3rd member while a learner is pending) means the 3rd member is never added either. `Etcd.status` permanently reports `QuorumLost`, and `Milvus`'s `EnsureMetaStorage` health check permanently fails with `"etcd cluster not healthy"`.

### Fix

Changed `clusterClient()` to dial **ordinal 0 directly** (via the per-pod governing-service DNS name, `db.PodName(0)` / `WithPod(...)`) instead of the ambiguous round-robin Service. Ordinal 0 is a safe, stable anchor: `scaleUpOneMember` only ever adds the *next-highest* ordinal as a learner, and `scaleDownOneMember` only ever removes the *highest* ordinal, so ordinal 0 stays a full voting member for as long as the cluster has any members at all — the same reasoning the file already applies when dialing a learner directly by pod name in `promoteLearnerIfReady`/`isLearnerCaughtUp`. This is a minimal, targeted change: one function body, no new fields, no API changes, no vendor bumps.

```diff
--- a/pkg/controller/reconcile_membership.go
+++ b/pkg/controller/reconcile_membership.go
@@ -18,10 +18,8 @@ package controller

 import (
 	"context"
-	"fmt"
 	"time"

-	"kubedb.dev/apimachinery/apis/kubedb"
 	dbapi "kubedb.dev/apimachinery/apis/kubedb/v1alpha2"
 	etcdclient "kubedb.dev/db-client-go/etcd"

@@ -276,13 +274,27 @@ func (r *EtcdReconciler) isLearnerCaughtUp(ctx context.Context, db *dbapi.Etcd,
 	return ratio >= learnerPromotionRatio, nil
 }

-// clusterClient dials the cluster through the client Service. The Service only
-// routes to Ready pods, so it always lands on a serving voting member -- never
-// on the learner that is being added.
+// clusterClient dials ordinal 0 directly instead of the shared client Service.
+// The Service was assumed to only ever route to a voting member, on the theory
+// that a learner never turns Ready -- but etcd's /health handler special-cases
+// learners (it only checks that they have a leader, since they cannot serve a
+// linearizable read), so a learner's pod does turn Ready and does join the
+// Service's endpoints. Once that happens, every admin RPC issued against the
+// Service (MemberList, Status, MemberPromote, ...) has a chance of being
+// routed to the learner instead, which etcd answers with "rpc not supported
+// for learner" -- and this file treats that as "try again later" everywhere,
+// so a promotion that keeps landing on the learner never makes progress and
+// the cluster never gets its next member.
+//
+// Ordinal 0 does not have this problem: scaleUpOneMember only ever adds the
+// next-highest ordinal as a learner, and scaleDownOneMember only ever removes
+// the highest ordinal, so ordinal 0 stays a full voting member for as long as
+// the cluster has any members at all -- it is a stable anchor to dial
+// directly, the same way promoteLearnerIfReady already dials the learner
+// directly by pod name instead of going through the Service.
 func (r *EtcdReconciler) clusterClient(ctx context.Context, db *dbapi.Etcd) (*etcdclient.Client, error) {
-	url := fmt.Sprintf("%s://%s:%d", db.Scheme(), db.PrimaryServiceDNS(), kubedb.EtcdClientPort)
 	return etcdclient.NewKubeDBClientBuilder(r.KBClient, db).
-		WithURL(url).
+		WithPod(db.PodName(0)).
 		WithContext(ctx).
 		GetEtcdClient()
 }
```

Verified with `gofmt -l`, `go vet ./pkg/controller/...`, and `go build ./...` (all clean) before rebuilding the image.

### Verification

Rebuilt (`make container push REGISTRY=sabnaj git_tag=""`), redeployed the standalone `kubedb-provisioner-etcd` release, re-ran the exact same test (`yaml/04-standalone-milvus.yaml`, `spec.metaStorage` omitted). This time:

```
I ... reconcile_membership.go:234] etcd demo/milvus-standalone-etcd-etcd: promoted learner milvus-standalone-etcd-etcd-1 to a voting member
```

— logged within seconds of the learner being added (previously: never, across the entire run-2 observation window). The 3rd member (`milvus-standalone-etcd-etcd-2`) was then added and promoted the same way, and:

```
Etcd:   "The Etcd: demo/milvus-standalone-etcd-etcd is successfully provisioned."   (status.phase: Ready)
Milvus: "Internal etcd is ready and healthy"   (dependency.go log — meta-storage health check passed)
Milvus: "The Milvus: demo/milvus-standalone-etcd is ready."   (status.phase: Ready)
```

Milvus's own `demo/milvus-standalone-etcd-0` pod came up, formed a single-node Milvus cluster, and started accepting client connections (`root` auth secret present and readable), all backed by the KubeDB-managed `Etcd`.

### A related, not-yet-fixed rough edge (found while verifying, did not block this test)

While the fix above was converging, `pkg/controller/health.go`'s **separate** periodic health-check client (`etcdHealthCheckFunc`, its own `GetEtcdClient()` call with no `WithPod`/`WithURL`) showed the same symptom: it configures a client against **every** desired-replica endpoint (including not-yet-promoted learners), so its initial connection/auth handshake can also land on a learner and fail with the same `"rpc not supported for learner"` / `"authentication is not enabled"` errors. In this run it was transient — the health check retries frequently and only needs one lucky attempt (helped by `votingMemberEndpoints()`, which already exists in that file specifically to narrow *later* calls to voting members only, just not the *first* one) — so `Etcd` still reached `Ready` within about 15–20 seconds of the last member being promoted. It didn't block this test, but the same class of fix (anchor the *initial* health-check client to `db.PodName(0)` too) would make `Ready` reporting less noisy and is worth doing as a follow-up in `kubedb.dev/etcd`.

---

## Run 2 — with the unpatched real `kubedb.dev/etcd` operator (kept for history)

### Setup

1. Built `kubedb.dev/etcd` (`make container push REGISTRY=sabnaj`) and deployed it as its own standalone release (`kubedb-provisioner-etcd`), alongside the standalone `milvus-operator` from run 1. Both watch different CRDs (`Etcd` vs `Milvus`) so there's no double-reconciliation conflict between them — only the shared combined `kubedb-kubedb-provisioner` needed to stay paused (same as run 1) since *it* still watches `Milvus`.

2. **Build issue found and fixed:** the first build crash-looped with exit 0 immediately after "starting manager", never even starting its CRD watch. Root cause: `kubedb.dev/etcd`'s `git` HEAD sits exactly on tag `v0.1.0-rc.2`, and `hack/build.sh` auto-sets `ENFORCE_LICENSE=true` for any build made from an exact tag. With `ENFORCE_LICENSE=true`, the binary calls `go.bytebuilders.dev/license-verifier`'s `VerifyLicensePeriodically` at startup, which — because there's no real license file wired into this test install and the cluster has no license-proxy server — fails, and `handleLicenseVerificationFailure` sends the process a real `SIGTERM` (see `vendor/go.bytebuilders.dev/license-verifier/kubernetes/lib.go`), causing the immediate graceful-looking shutdown. (Milvus's own `operator.go` never calls `VerifyLicensePeriodically` at all, which is why the same empty-license setup worked fine for it in run 1.)
   - **Fix:** rebuilt with `make container push REGISTRY=sabnaj git_tag=""` to force `version_strategy=commit_hash` instead of `tag`, which keeps `ENFORCE_LICENSE=false`. Also had to manually delete the stale `.go/bin/linux_amd64/etcd-operator.stamp` build-cache stamp first — the Makefile's stamp rule only depends on directory existence, not on ldflag/env changes, so a first attempt to "rebuild" silently reused the old (license-enforced) binary. Also needed `imagePullPolicy: Always` on the redeploy since the image tag was reused and the node had already cached the old (broken) image under that tag.

3. **Second missing CRD found:** once the operator actually started, it immediately hit `no matches for kind "EtcdArchiver" in version "archiver.kubedb.com/v1alpha1"` on every reconcile of the `Etcd` CR. Applied `vendor/kubedb.dev/apimachinery/crds/archiver.kubedb.com_etcdarchivers.yaml` (`yaml/00b-etcdarchiver-crd.yaml`) to clear this — same "vendored-but-not-installed" pattern as the `Etcd` CRD itself.

### What happened once both CRDs existed and the operator ran cleanly

Reapplied `04-standalone-milvus.yaml`. This time the whole chain moved much further:

1. Milvus's `EnsureMetaStorage` created the `Etcd` CR (as in run 1).
2. `kubedb.dev/etcd`'s controller picked it up and actually provisioned real resources: `Service`, headless `Service`, `ServiceAccount`, `Role`, `RoleBinding`, a real `basic-auth` `Secret` (`milvus-standalone-etcd-etcd-auth`), a `ConfigMap`, an `AppBinding`, and a `PetSet`.
3. Pod `milvus-standalone-etcd-etcd-0` came up and briefly reported `AllReplicasReady` / `AcceptingConnection` (i.e. a single-member etcd cluster was genuinely healthy for a moment).
4. Milvus's own health check then got **past** the "auth secret not found" error from run 1 and started making real gRPC calls to the etcd cluster (`MemberList`, `Authenticate`) — proof the two operators are wired together correctly on the Milvus side.
5. The `Etcd` controller then scaled the `PetSet` to a 2nd pod (`milvus-standalone-etcd-etcd-1`), added it as a **learner** (standard etcd bootstrap pattern) — and then got stuck. It never promoted the learner to a full voting member, and never created a 3rd pod (`PetSet.status.replicas` stayed at `2`, never reached the desired `3`).
6. Because a learner cannot serve most etcd RPCs and there's no 3rd member either, the cluster permanently reports `QuorumLost`: `"has lost its Raft quorum: 3 of 3 members are not answering"` (even though 2 pods were `Running`/`Ready`).
7. `Milvus` stayed at `status.phase: Provisioning`, failing with `"etcd cluster not healthy"`.

This is exactly the bug fixed in Run 3 above.

---

## Run 1 — no etcd-reconciling operator existed at all (original finding, kept for history)

### What was verified as working correctly

1. `EnsureMetaStorage` (`pkg/controller/dependency.go`) correctly builds a `kubedb.com/v1alpha2` `Etcd` object instead of the old `go.etcd.io/etcd-operator` `EtcdCluster`, with correct name, owner reference, version-string-stripping, and defaults for an unset `spec.metaStorage`.
2. The operator correctly refuses to proceed to `EnsureServices`/`EnsureNodes` until meta storage is healthy — no Milvus PetSet/Service/Secret/PVC gets created prematurely.
3. Once the `Etcd` CRD is registered, the health check correctly detects the missing auth secret and cleanly reports `"etcd cluster not healthy"`, requeuing with backoff (no crash loop, no panic).

### What was missing at the time

At the start of run 1, `/home/sabnaj/go/src/kubedb.dev/etcd` was not yet known to this session. Searched the whole `kubedb` GitHub org and both branches of the combined `kubedb.dev/provisioner` mono-repo and found no `Etcd`-reconciling controller anywhere, so the `Etcd` CR this branch creates just sat there forever, un-reconciled. **This is now resolved**: `kubedb.dev/etcd` is that operator, and with the run-3 fix it works end-to-end.

---

## Build note: don't try to rebuild the combined `kubedb-provisioner` for this

Tried (in run 1) to rebuild the cluster's actual combined `kubedb-provisioner` binary (from the sibling `kubedb.dev/provisioner` repo) with a local `replace kubedb.dev/milvus => ...` pointing at this branch. `go mod tidy`/`vendor` succeeded (bumped `kubedb.dev/apimachinery` via MVS to this branch's newer pseudo-version), but the **build failed** — several other already-migrated-to-newer-apimachinery-incompatible DB controllers broke:
```
vendor/kubedb.dev/rabbitmq/pkg/controllers/...: rs.db.Owner undefined
vendor/kubedb.dev/zookeeper/pkg/controller/...: rs.db.Owner undefined
vendor/kubedb.dev/weaviate/pkg/controller/...: rs.db.Owner undefined
```
Bumping `apimachinery` for Milvus's (or now Etcd's) sake will require those three (at least) to be updated too before the combined provisioner can build. Reverted that change; all runs instead used standalone `milvus-operator` / `etcd-operator` deployments (each their own `kubedb-provisioner` chart release, watching only their own CRD), with the shared combined provisioner's `kubedb-kubedb-provisioner` StatefulSet temporarily scaled to 0 during each test run (to stop it double-reconciling `Milvus`) and scaled back to 1 immediately after.

## Cluster hygiene notes (unrelated to either branch, found along the way)

- The cluster's `minio-operator` pod had lost its leader-election lease at `2026-09-16T01:48Z` and its main reconcile loop had been dead for ~7.5 hours before this session started (pre-existing, unrelated issue). Restarted it (`kubectl rollout restart deploy/minio-operator -n minio-operator` + deleted the stale `Lease`) to get MinIO tenant provisioning working again — this also fixes reconciliation for the pre-existing `myminio` (kubestash) tenant, which had the same problem.
- MinIO operator only supports **one Tenant per namespace**, so a new dedicated `milvus-minio` namespace was created (the existing `demo` namespace already has `myminio` for kubestash).

## What's left in the cluster (kept as reusable prerequisites)

- Namespace `milvus-minio` with a healthy `milvus-minio` Tenant (bucket `mlv-release`).
- Secret `milvus-storage-config` in `demo` (points at the above tenant).
- CRD `etcds.kubedb.com` and CRD `etcdarchivers.archiver.kubedb.com`.
- `EtcdVersion` catalog entry `3.5.21` (placeholder `db.image`/`exporter.image`, matches `MilvusVersion 2.6.11`'s `etcdVersion`).

Removed after the test: the `Milvus` CR (`WipeOut` deletion policy, cascade-deleted its `Etcd` CR and, transitively, the etcd `PetSet`/pods/secrets/PVCs), both standalone operator releases (`helm uninstall kubedb-provisioner`, `helm uninstall kubedb-provisioner-etcd`), and the shared `kubedb-kubedb-provisioner` StatefulSet was scaled back to 1 replica. The cluster's other databases (cassandra, db2, documentdb, etc.) were not touched and stayed running throughout (one pod, `cass-ui-rack-r0-0`, had an unrelated single kubelet-level "pod sandbox changed" restart during the test window — not caused by any action taken here, and it recovered on its own).

## Next steps

1. **Upstream the fix**: the `reconcile_membership.go` diff above lives only in this local checkout of `/home/sabnaj/go/src/kubedb.dev/etcd` — it needs to be committed and pushed/PR'd to the real `kubedb.dev/etcd` repo to land for anyone else.
2. **Optional follow-up hardening**: apply the same "anchor to ordinal 0" pattern to `health.go`'s `etcdHealthCheckFunc` initial client construction, to remove the residual (non-blocking) health-check flakiness noted above.
3. Once upstreamed, re-run this same test (`yaml/00`–`04`, plus `yaml/00b-etcdarchiver-crd.yaml`) against an unpatched `kubedb.dev/etcd` build to confirm the fix reproduces cleanly from a fresh clone.
4. Separately (not blocking this branch): `docs/guides/milvus/quickstart/prerequisites.md` still documents installing the *official* `etcd-io/etcd-operator` — needs updating once `kubedb.dev/etcd` is stable and released.
