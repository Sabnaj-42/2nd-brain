# DocumentDB Standalone Ops-Request Test Results (Retest with Upgraded Operators)

**Date:** 2026-07-21  
**Provisioner:** `ghcr.io/kubedb/kubedb-provisioner:v0.66.0` (official, upgraded)  
**Ops-manager:** `ghcr.io/kubedb/kubedb-ops-manager:v0.53.0` (official, upgraded)  
**Init image:** `sabnaj/documentdb-init:_linux_amd64@sha256:dd1a43...` (custom build, `bootstrap_scripts/17/run.sh`)  
**DB:** `documentdb` in namespace `demo`, version `pg17-0.109.0`, replicas 1  
**Methodology:** Fresh DB created before each test.

---

## Result Summary

| # | OpsRequest | Result | Time | Issue |
|---|-----------|--------|------|-------|
| 1 | Restart | ✅ Successful | ~20s | - |
| 2 | VerticalScaling | ✅ Successful | ~50s | - |
| 3 | RotateAuth | ❌ Failed | ~3s | Ops-manager vendored code: version parsing + credential ordering |
| 4 | Reconfigure | ⚠️ Partial | ~3min | Secret not auto-created by provisioner |
| 5 | StorageMigration | ✅ Successful | ~60s | PVC migrated local-path → standard-custom |

---

## Issue 1: RotateAuth Fails — `GetMajorPgVersion` + Credential Ordering

**Location:** Ops-manager vendored code: `vendor/kubedb.dev/documentdb/pkg/ops/database.go`  
**Functions:** `GetMajorPgVersion:381`, `checkMasterWithoutSQL:81`, `checkPgIsInRecoveryWithDNS:183`

**What happens:**
1. `checkMasterWithoutSQL` calls `GetMajorPgVersion` which tries to parse `db.Spec.Version` (`pg17-0.109.0`) as a semantic version → fails with `"invalid semantic version"`
2. Falls through to `checkMasterWithSQL` → tries to query `pg_is_in_recovery()` on Postgres
3. **But the secret was already updated** with new credentials BEFORE this check — connection fails with `"password authentication failed"`
4. Neither path can find the primary → RotateAuth fails

**Why it works for HA:** In HA mode, `checkMasterWithoutSQL` uses raft node information from the coordinator to find the primary — no version parsing needed. For standalone, there's no coordinator → the version-dependent fallback fails.

**Solution (in ops-manager's vendored code):**
- **Option A (simple):** Fix `GetMajorPgVersion` to handle DocumentDB version strings (`pg17-0.109.0` is not semver — parse the postgres major from the `pg17` prefix)
- **Option B (ordering fix):** Change `RotateAuthentication` (`rotate_auth.go:154`) to apply credentials to Postgres BEFORE updating the secret (connect with OLD cred → `ALTER USER ... PASSWORD 'new'` → update secret)
- **Option C (standalone shortcut):** For replicas==1, skip both `checkMaster` paths entirely — the only pod `documentdb-0` IS the primary. In `applyNewCredentialToPrimary` (`rotate_auth.go:385`), if `db.Spec.Replicas == 1`, just use `documentdb-0` as the primary pod directly.

---

## Issue 2: Reconfigure — EnsureConfigSecret Not Creating Secret

**Location:** Provisioner `pkg/controllers/petset.go` — `EnsureConfigSecret` reconciliation step

**What happens:**
1. Ops-manager patches DB with `configuration.inline["user.conf"]` → the v0.66.0 provisioner DOES store it on `db.spec.configuration`
2. Provisioner adds `custom-config` projected volume to PetSet template, referencing secret `documentdb-<uid6>`
3. **But the secret is never created** → pod gets stuck with `FailedMount: secret "documentdb-<uid6>" not found`
4. Manual creation of the secret unblocks the pod and the ops succeeds

**Workaround (manual):** Create the missing secret with all required keys:
```bash
DB_UID_SUFFIX=$(kubectl get documentdb documentdb -n demo -o jsonpath='{.metadata.uid}' | tail -c 7)
kubectl create secret generic "documentdb-${DB_UID_SUFFIX}" -n demo \
  --from-literal='user.conf=max_connections=250' \
  --from-literal='inline.conf=' \
  --from-literal='pgtune.conf='
```

**Solution (in provisioner):**
- Add `EnsureConfigSecret` to the provisioner reconcile loop in `pkg/controllers/petset.go`. When `configSourceNames()` returns that config is needed (inline/tuning/user-secret), the provisioner must create or update the `documentdb-<uid6>` secret with all required keys (`inline.conf`, `pgtune.conf`, `user.conf`).
- Postgres reference: look at the Postgres operator's `EnsureConfigSecret` in `kubedb.dev/postgres` for the canonical implementation pattern.

---

## Tests That Passed

### Restart ✅
Pod is evicted and restarted cleanly. Postgres comes back up, DB reaches Ready in ~20s.

### VerticalScaling ✅
Resources updated (500m/2Gi → 800m/3Gi), coordinator field omitted (standalone has no coordinator). The ops-manager handles `VerticalScaling.Coordinator == nil` gracefully. Pod evicted and recreated with new resources.

### StorageMigration ✅
Full migration sequence runs correctly:
1. Old pod + PetSet deleted, new PVC created on target SC
2. `pvcmounter` pod rsyncs data to new PVC
3. Old PVC retired, new PVC renamed to `data-documentdb-0`
4. New pod created, DB reaches Ready, data intact

**Note:** StorageMigration requires `db.Spec.Storage.StorageClassName` to be set in the DB manifest.

---

## Summary

| Issue | Severity | Location | Component |
|-------|----------|----------|-----------|
| RotateAuth: version parsing + credential ordering | 🔴 Blocks standalone auth rotation | `vendor/kubedb.dev/documentdb/pkg/ops/database.go:381`, `:183` | Ops-manager |
| Reconfigure: EnsureConfigSecret missing | 🟡 Blocks auto config mount | `pkg/controllers/petset.go` — reconciliation | Provisioner |
| RotateAuth: checkMaster pointless for standalone | 🟡 Unnecessary complexity | `vendor/.../rotate_auth.go:385` — `applyNewCredentialToPrimary` | Ops-manager |
