# KubeDB DocumentDB — Ops-Request Test Report

- **Date:** 2026-06-19
- **KubeDB:** latest RC released
- **Test object:** `dcdb` (namespace `demo`), provisioned from `documentdb/ops-test-yaml/object-tuning.yaml`
  (auto-tuning **enabled**: profile=oltp, storageType=ssd, maxConnections=200)
- **Version:** `pg17-0.109.0` · **replicas:** 3 (HA) · **storage:** `local-path` 5Gi
- **Container image:** `sabnaj/documentdb-local-vim:latest` (custom)
- **Access:** `mongosh` only for data ops. (`psql` used solely to read server settings like `max_connections`/`shared_buffers`, never for data.)
- Separate from the `dcodb` object used in the earlier replication/failover test.

Seed data: `opsdb.ops_test`, 5 docs (later 6).

---

## Summary

| # | Ops type | Cluster state when run | Result |
|---|----------|------------------------|--------|
| 1 | Restart | HA (3) | ✅ PASS |
| 2 | VerticalScaling | HA (3) | ✅ PASS |
| 3 | VerticalScaling + tuning | HA (3) | ✅ PASS |
| 4 | HorizontalScaling HA→standalone | HA (3)→1 | ✅ PASS |
| 5 | Reconfigure | standalone (1) | ❌ FAIL (bug) |
| 6 | RotateAuth | standalone (1) | ❌ FAIL (bug) |
| 7 | VolumeExpansion | standalone (1) | ❌ FAIL / hang (bug) |
| 8 | StorageMigration | standalone (1) | ⏳ NOT YET RUN |
| – | HorizontalScaling standalone→HA | standalone (1)→3 | ❌ FAIL (bug, attempted during recovery) |

**No data loss** was observed in any test (seed data survived every operation).

**Important caveat / confound:** every PASS happened while the cluster was HA (3 replicas); every FAIL happened **after** the HA→standalone scale-down, i.e. in standalone (1-replica) mode. Three of the four failures (RotateAuth, VolumeExpansion, standalone→HA) point at the operator being **unable to identify the primary/master pod in standalone mode**. These have NOT yet been retested on a fresh HA cluster to confirm whether they are standalone-specific or general. Reconfigure failed for a different, clearly identified reason (see below).

---

## Test 1 — Restart ✅

`kubectl apply -f restart.yaml` → opsrequest `dcdb-restart`.

- Phase: **Successful** (~3 min).
- All 3 pods cycled (rolling).
- Data intact: count = 5.

---

## Test 2 — VerticalScaling ✅

`vertical-scaling.yaml` → documentdb 500m/2Gi → **600m / 2.5Gi** (limits cpu=1 / 2.5Gi), coordinator 100m/256Mi.

- Phase: **Successful** (~3m19s).
- Verified on pod: `documentdb: req cpu=600m mem=2560Mi, lim cpu=1 mem=2560Mi`.
- Because tuning is enabled, pgtune also regenerated to the 2.5Gi tier (`shared_buffers 512MB → 640MB`).
- Data intact: count = 5.

---

## Test 3 — VerticalScaling + tuning ✅

`vertical-scaling-tuning.yaml` → documentdb **cpu=1 / 3Gi**.

- Phase: **Successful** (~2m46s).
- pgtune regenerated from new memory and **applied live**:

  | param | 2Gi (base) | 2.5Gi | 3Gi (final) |
  |-------|-----------|-------|-------------|
  | shared_buffers | 512MB | 640MB | **768MB** |
  | effective_cache_size | 1536MB | 1920MB | **2304MB** |
  | maintenance_work_mem | 128MB | 160MB | **192MB** |

- Verified projected `/etc/config/pgtune.conf` **and** live `SHOW shared_buffers` = **768MB** inside the pod.
- Data intact: count = 5.

---

## Test 4 — HorizontalScaling: HA → standalone ✅

`horizontal-scaling-ha-to-standalone.yaml` → replicas 3 → **1**.

- Phase: **Successful** (~3m16s).
- Result: only `dcdb-0` (primary) remained; `dcdb-1`, `dcdb-2` removed.
- Standalone still served reads and **accepted writes** (inserted `_id:6` → count = 6).
- Data intact: count = 6.

> All subsequent ops (5–8) ran against this standalone cluster.

---

## Test 5 — Reconfigure ❌ BUG

`reconfigure-apply.yaml` → `applyConfig: user.conf: max_connections=250` (restart: auto).

**Result: Failed** (opsrequest timed out after 10m in `Progressing`). The value never applied — `max_connections` stayed **200**.

**Root cause (confirmed):**
- The operator patched the pod's `custom-config` **projected** volume to project key **`inline.conf`** from secret `dcdb-92a30e`.
- But that secret only ever contained the key **`pgtune.conf`** — `inline.conf` was never written.
- Kubelet therefore failed the mount and the pod was stuck in `Init` forever:
  ```
  Warning  FailedMount  MountVolume.SetUp failed for volume "custom-config":
           references non-existent secret key: inline.conf
  ```
- Because this is a single-replica (standalone) DB, the stuck pod meant the **database was fully DOWN (0/2)** for the ~10 min the op ran.

**Notes**
- Manually adding `inline.conf` to the secret did **not** stick — the operator reconciled it back to just `pgtune.conf` (confirming the secret is operator-managed and the projected key is simply wrong/missing).
- After the opsrequest reached `Failed`, the operator reconciled the petset back to a valid projection (`pgtune.conf` only). Recovery required **manually force-deleting** the stuck pod; the recreated pod came up clean.
- This object has **auto-tuning enabled**, so the config secret is the pgtune secret. The `inline.conf` collision may be specific to tuning-enabled DBs — **should be retested on a non-tuned object**.
- **No data loss** (PVC retained): count = 6 after recovery.

---

## Test 6 — RotateAuth ❌ BUG

`rotate-auth.yaml` (operator-generated new password, no external secret).

**Result: Failed** (within ~8s), and **reproducible on retry**. Password unchanged.

```
UpdateCredential = True  : Successfully generated new credentials
RotateAuth       = False : could not find the primary pod of DocumentDB demo/dcdb
                           to apply the rotated credential
```

- The operator generated the new credential but then **could not locate the primary pod** to apply it, even though `dcdb-0` is labelled `kubedb.com/role=primary`, is not in recovery (`pg_is_in_recovery=f`), and is writable.
- Observation: the legacy label `kubedb-role` is **empty** on this pod (only `kubedb.com/role=primary` is set). The rotate-auth primary lookup may rely on a selector that isn't satisfied in standalone mode.
- The op **pauses the DB** first, then fails — left the DB paused/affected briefly.
- **Not yet confirmed in HA** — attempt to scale back to HA to retest was blocked by the standalone→HA bug below.
- **No data loss.**

---

## Test 7 — VolumeExpansion ❌ FAIL / HANG (bug)

`volume-expansion.yaml` → mode **Offline**, documentdb 5Gi → **10Gi**.

**Result: hung in `Progressing` (>7m45s, no progress), PVC never expanded.**

Condition trail:
```
Running        = True
VolumeExpansion = False : Offline Volume Expansion performed successfully ...
DeletePetset    = True
IsMaster        = False   ← stuck here the entire time
```

- The operator **deleted the petset**, claimed offline expansion "performed successfully", but **never patched the PVC** — `data-dcdb-0` stayed at `spec.requests=5Gi / status=5Gi`.
- It then blocked indefinitely on `IsMaster=False` (same primary/master-detection failure theme as RotateAuth, again in standalone).
- Compounding issue: the source SC `local-path` has `allowVolumeExpansion=false`, so even a correct PVC patch would be rejected — but the operator should **fail fast**, not delete the petset and hang.
- Left the cluster degraded (petset deleted; `dcdb-0` orphaned but still Running). Recovery in progress at time of writing.
- **No data loss** (pod/PVC retained).

---

## Test 8 — StorageMigration ⏳ NOT YET RUN

`storage-migration.yaml` (local-path → standard-custom) was **not reached** — testing was paused while recovering the cluster from the VolumeExpansion hang.

---

## Extra finding — HorizontalScaling standalone → HA ❌ BUG

Attempted (`horizontal-scaling-standalone-to-ha.yaml`, replicas 1→3) in order to retest RotateAuth in HA.

**Result: Failed** — the new standby's seeding job could not start:
```
basebackup-dcdb-1-...  StartError
exec: "role_scripts/standby/ha_backup_job.sh": stat role_scripts/standby/ha_backup_job.sh:
       no such file or directory
```
- The base-backup job tries to exec `role_scripts/standby/ha_backup_job.sh` via a **relative path**, and that script **does not exist anywhere in the image** (`find / -name ha_backup_job.sh` → nothing).
- So scaling a standalone DocumentDB back up to HA cannot seed new replicas.
- **Attribution caveat:** the image is a **custom** build (`sabnaj/documentdb-local-vim:latest`); the missing script could be an image-packaging gap rather than (or in addition to) an operator path bug. Worth checking against the official image.
- The op did not corrupt the existing primary (DB `spec.replicas` was never advanced past 1; `dcdb-0` kept serving).

---

## Recommendations / open items

1. **Reconfigure:** operator projects secret key `inline.conf` that it never writes into the (tuning) config secret → pod stuck mounting. Fix the key name / write the key; also retest reconfigure on a **non-tuned** object to scope it.
2. **Standalone primary/master detection:** RotateAuth ("could not find the primary pod") and VolumeExpansion ("IsMaster=False" hang) both fail to identify the primary in 1-replica mode despite correct `kubedb.com/role=primary` labelling. Retest both on a fresh **HA** cluster to confirm standalone-specificity.
3. **VolumeExpansion:** should fail fast on a non-expandable StorageClass instead of deleting the petset and hanging; and it must actually patch the PVC.
4. **standalone→HA scale-up:** base-backup job references `role_scripts/standby/ha_backup_job.sh` (relative path) which is absent from the image — fix the path or ship the script.
5. Re-run StorageMigration once the cluster is recovered.

---

## Status at time of writing

Testing **incomplete**: Tests 1–4 passed (HA); Tests 5–7 failed (standalone) with the bugs above; Test 8 (StorageMigration) not yet run. Cluster was mid-recovery from the VolumeExpansion hang (petset deleted, `dcdb-0` orphaned/Running, no data loss). This report will be updated as remaining work completes.
