# KubeDB DocumentDB — Clustering / Replication / Failover Test Report

- **Date:** 2026-06-19
- **KubeDB:** latest RC released
- **DocumentDB object:** `dcodb` (namespace `demo`)
- **Version:** `pg17-0.109.0`
- **Replicas:** 3 (`dcodb-0`, `dcodb-1`, `dcodb-2`)
- **Streaming mode:** Asynchronous · **Standby mode:** Hot · **Client auth:** scram
- **Access:** `mongosh` only (no direct PostgreSQL access used for data ops)
- **Connection (per pod, via `kubectl port-forward`):**
  `mongosh 'mongodb://default_user:***@localhost:<port>/?tls=true&tlsAllowInvalidCertificates=true'`

Port-forward mapping used during the test:

| Local port | Pod      |
|------------|----------|
| 10260      | dcodb-0  |
| 10261      | dcodb-1  |
| 10262      | dcodb-2  |

Test database/collection: `testdb.failover_test`.

---

## Summary

| # | Test | Result |
|---|------|--------|
| 1 | Insert on primary | ✅ PASS |
| 2 | Replication to all standbys | ✅ PASS |
| 3 | Standby is read-only (write rejected) | ✅ PASS |
| 4 | Failover on primary deletion | ✅ PASS |
| 5 | Standby restart (no spurious failover) | ✅ PASS |
| 6 | **No data loss in any failure case** | ✅ PASS — zero documents lost |
| 7 | **Standby auto-recovery after failover** | ❌ **FAIL — reproducible bug** |

**Overall:** Core clustering, replication, failover and durability all work correctly — **no data was ever lost**. However, a **reproducible high-availability bug** was found: after a primary failover, a standby's PostgreSQL process is shut down and **never restarted by the coordinator**, leaving that standby permanently broken while the pod still reports `2/2 Ready`. Manual pod restart is the only recovery.

---

## Test 1 — Insert on primary

Initial roles: `dcodb-1` = **primary**, `dcodb-0` / `dcodb-2` = standby.

Inserted 10 documents (`_id` 1–10) into `testdb.failover_test` on the primary (`dcodb-1`).

```
inserted: 10   →   count = 10
```

✅ **PASS** — writes accepted on primary.

---

## Test 2 — Replication to all standbys

Read `testdb.failover_test` directly from each standby:

| Pod | Role | count |
|-----|------|-------|
| dcodb-0 | standby | 10 |
| dcodb-2 | standby | 10 |

Sample document identical on both standbys:
`{"_id":1,"name":"doc-1","phase":"initial", ...}`

✅ **PASS** — data replicated to every standby.

---

## Test 3 — Standby is read-only

Attempted an `insertOne` directly against a standby (`dcodb-0`):

```
WRITE REJECTED on standby: Exceeded time limit while waiting for a new primary to be elected
```

✅ **PASS** — standbys correctly refuse writes; only the primary accepts writes.

> Note: each pod's gateway reports `hello.isWritablePrimary = true` even on standbys (a DocumentDB gateway quirk). The actual write path is still gated — writes only succeed on the true primary.

---

## Test 4 — Failover on primary deletion

Deleted the primary pod `dcodb-1` (`kubectl delete pod dcodb-1`).

- Within seconds a new primary was elected: **`dcodb-0` promoted to primary**.
- `dcodb-1` was recreated and rejoined as **standby**.
- New primary `dcodb-0` retained **all 10 documents** and accepted a new write (`_id:101`) → count = 11.
- New write replicated to the healthy standby.

✅ **PASS** — automatic failover works and a new primary accepts writes.

A second failover was also exercised in Test 5 (deleting primary `dcodb-0`): `dcodb-1` was promoted in ~1s and `dcodb-0` rejoined as standby in ~23s — clean and fast.

---

## Test 5 — Standby restart (no spurious failover)

Deleted a standby pod (`dcodb-1`) while `dcodb-0` was primary.

- Primary stayed primary — **no unnecessary failover** was triggered.
- `dcodb-1` came back and rejoined as **standby** in ~13s with a healthy PostgreSQL process.
- Data count matched the rest of the cluster (12 at that point).

✅ **PASS**

---

## Test 6 — Data loss check (durability)

Documents were added across the test (`_id`: 1–10, 101, 102, 103, 104) and the cluster was repeatedly failed over and restarted. Final state on **all three** pods:

```
count = 14
ids   = [1,2,3,4,5,6,7,8,9,10,101,102,103,104]
```

✅ **PASS — no data was lost in any pod-failure / failover scenario.** Every committed write survived, the new primary always had the complete, identical dataset, and recovered standbys re-synced to the full dataset.

---

## Test 7 — Standby auto-recovery after failover ❌ BUG (reproducible)

**Symptom:** After a primary failover, a standby (`dcodb-2` in both observed cases) ends up with its PostgreSQL backend **shut down and never restarted**, while Kubernetes still shows the pod as `2/2 Running / Ready`.

**Evidence**

Gateway (container `documentdb`) cannot reach its local PostgreSQL:
```
ERROR documentdb_gateway: Request failure: PoolError { error: Backend(Error { kind: Connect,
       cause: Some(Os { code: 111, kind: ConnectionRefused, message: "Connection refused" }) }) }
```

Coordinator (container `documentdb-coordinator`) loops indefinitely:
```
E ha_postgres.go:438] failed on health check for standby waiting for the DocumentDB process to start from initial script
E ha_postgres.go:444] failed to check if standby is running, err: ... pg_is_in_recovery:
       dial tcp 10.42.0.177:9712: connect: connection refused
```

Inside the stuck pod there is **no `postgres` process at all** — only the gateway scripts remain running. The coordinator never attempts a restart/`pg_rewind`/re-basebackup; it just health-checks forever.

**Reproducibility:** Observed after **two separate failover events** — both times the re-syncing standby (`dcodb-2`) got stuck the same way. A plain standby restart (Test 5, no failover involved) did **not** trigger it.

**Impact**
- The pod is reported `2/2 Ready`, so neither the operator nor Kubernetes self-heals it — the broken standby is masked.
- Effective replica count silently drops (e.g. 3 → 2). Redundancy is degraded; if another failure hit before manual intervention, availability would be at risk.
- **Data durability is NOT affected** — the surviving primary + healthy standby keep all data.

**Workaround / remediation (verified)**
Manually deleting the stuck pod fixes it every time:
```
kubectl delete pod dcodb-2 -n demo
```
The fresh pod starts PostgreSQL, enters streaming recovery, re-syncs, and rejoins as a healthy standby with the full dataset (verified: count returned to 14 with identical `_id`s).

**Suspected root cause:** During failover the coordinator stops the standby's PostgreSQL (to re-point/re-sync it to the newly elected primary) but the "start DocumentDB process from initial script" step is never (re)driven on an already-running pod, so the backend stays down. The readiness gate also does not account for a dead PostgreSQL backend, so the pod wrongly stays `Ready`.

---

## Final cluster state

```
dcodb-0   2/2   Running   standby
dcodb-1   2/2   Running   primary
dcodb-2   2/2   Running   standby
```
All three pods: `testdb.failover_test` count = 14, identical `_id`s. Cluster healthy.

---

## Recommendations

1. **Fix standby recovery after failover** so the coordinator restarts/re-syncs PostgreSQL automatically instead of getting stuck on "waiting for the DocumentDB process to start from initial script".
2. **Fix the readiness gate** so a pod whose PostgreSQL backend is down (port 9712 refused) is marked `NotReady` — this would let the operator/Kubernetes surface and self-heal the condition instead of masking it as `2/2 Ready`.
3. Re-test failover after the fix to confirm standbys auto-rejoin with no manual pod deletion.

---
---

# RETEST after fix — `fix-pg-rewind` coordinator image (2026-06-19)

**Verdict: ⚠️ PARTIALLY FIXED — pg_rewind now runs and succeeds, but the in-place re-syncing standby's PostgreSQL still does NOT come back up; the symptom (standby stuck after failover) reproduces.**

### Setup
- **Object:** `dc` (namespace `demo`), fresh 3-replica cluster, version `pg17-0.109.0`.
- **Coordinator image (the fix):** `souravbiswassanto/documentdb-coordinator:fix-pg-rewind_linux_amd64@sha256:edbc8c09…` (confirmed running on all 3 pods).
- **Access:** `mongosh` only, via `mongodb://default_user:***@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true` (port-forward to `svc/dc` primary; per-pod forwards for standby reads).
- Test data: `testdb.failover`.

### What works ✅
| Check | Result |
|-------|--------|
| Connect via gateway, insert + find data | ✅ inserted 10 docs, readable |
| Insert on primary → replicated to **both** standbys | ✅ count=10 on dc-0 & dc-2 |
| Pod restart → data persists | ✅ recreated pods rejoin with full data |
| **Data loss after failover** | ✅ **NONE** — new primary always had all docs; all pods reconciled to identical counts (10, then 11) |
| Post-failover replication of new writes | ✅ new write on new primary replicated to both standbys |
| **pg_rewind step (the fix)** | ✅ now runs & succeeds (was the missing piece before) |

### What is still broken ❌ (reproduced on 2 consecutive failovers)

After a failover, the standby that **stays running** and must re-sync to the newly elected primary does a pg_rewind, but its PostgreSQL is **never restarted afterward** — it stays down indefinitely while the coordinator loops the old message, and the pod still shows `2/2 Ready`.

Coordinator trail on the stuck standby (identical both times):
```
need to do re-initialization or rewind
Stopping postgres of demo/dc-2 ...
pg_rewind.go:73] requested for rewind or reinitialization. Succeeded !!!!!!!!!!!!!!
server.go:314] successfully configured recovery mode for standby server
ha_postgres.go:438] failed on health check for standby waiting for the
                    DocumentDB process to start from initial script   ← loops forever
```
- Failover #1: deleted primary `dc-1` → `dc-0` promoted. Standby `dc-2` rewound OK, then **postgres down ~8.5 min** (until manual restart). `pg_is_in_recovery` unreachable, `ps` shows 0 `postgres -D` processes.
- Failover #2: deleted primary `dc-0` → `dc-1` promoted. Standby `dc-2` again rewound OK, then **postgres down again** (75 "waiting…" log lines in 2 min), stuck.
- In both cases the **deleted/recreated** pod recovered fine (fresh pod → init script starts postgres). Only the **in-place re-syncing standby** gets stuck — exactly matching the original report's suspected root cause: *the "start DocumentDB process from initial script" step is never re-driven on an already-running pod.*

### Progress vs. original bug
- **Before the fix:** the standby never even completed the rewind/re-sync — postgres just died and stayed down.
- **After the fix:** the rewind path executes correctly and recovery mode is configured. **The remaining gap is the final step — actually (re)starting PostgreSQL after the rewind on an already-running pod.**

### Still applicable
- **No data loss** in any scenario (durability is solid).
- **Workaround unchanged & verified:** `kubectl delete pod dc-2 -n demo` → fresh pod starts postgres, re-syncs, rejoins with full data (count restored on all pods).
- **Readiness gate** still reports the postgres-down pod as `2/2 Ready` — not yet addressed.

### Remaining recommendation
After a successful in-place `pg_rewind`, the coordinator must **start PostgreSQL** (not just configure recovery mode and wait on the boot-time init script). Also mark the pod `NotReady` while port 9712 is down so the condition is visible/self-healing.

---
---

# RETEST #2 after fix — updated `init container` image (2026-06-19)

**Verdict: ❌ STILL NOT FIXED — same root cause. The in-place re-syncing standby's PostgreSQL is still never started after `pg_rewind` / recovery-mode config.**

### Setup
- **Object:** `dcdb` (namespace `demo`), fresh 3-replica HA, version `pg17-0.109.0`.
- **New init image:** `souravbiswassanto/documentdb-init:_linux_amd64@sha256:2cec5a71…` (custom build, replaces the stock `ghcr.io/kubedb/documentdb-init:0.1.0`).
- **Coordinator:** still `souravbiswassanto/documentdb-coordinator:fix-pg-rewind…@sha256:edbc8c09…`.
- **Access:** `mongosh` only, run **inside the pods** (`kubectl exec <pod> -c documentdb -- mongosh 'mongodb://default_user:***@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true'`).

### Observations

**A) Reproduced even during provisioning (no manual failover).** On the fresh cluster, a raft leader change at bring-up demoted `dcdb-2` (briefly primary) to standby. Its coordinator logged:
```
I was primary, new elected primary is not me. Terminating...
Successfully shutting down postgres ...
need to do re-initialization or rewind
No PG rewind needed!!!!!!!!!
successfully configured recovery mode for standby server
```
…and then **postgres was never started** — stuck on `waiting for the DocumentDB process to start from initial script`. `dcdb-2` sat with 0 `postgres -D` processes and its gateway returned `MongoServerError: error connecting to server` (while the pod still showed `2/2 Ready`).

**B) Reproduced again on an explicit failover (clean baseline).** After restarting `dcdb-2` to get 3 healthy nodes (all data = 10), I deleted the primary `dcdb-0`:
- `dcdb-1` → promoted to **primary** (postgres up).
- `dcdb-0` (the **deleted** pod) → recreated fresh → postgres **up**, data = 10.
- `dcdb-2` (the **in-place** re-syncing standby) → coordinator:
  ```
  need to do re-initialization or rewind
  Stopping postgres of demo/dcdb-2 ...
  requested for rewind or reinitialization. Succeeded !!!!!!!!!!!!!!
  successfully configured recovery mode for standby server
  ```
  → then stuck (`waiting for the DocumentDB process to start`, 90 lines/90s), **postgres = 0**.

### What works ✅ (unchanged)
- Connect via in-pod gateway, insert + find data.
- Insert on primary → replicated to both standbys (count = 10).
- **No data loss** — new primary `dcdb-1` = 10 and writable; fresh standby `dcdb-0` = 10.
- `pg_rewind` step still runs & succeeds.

### What's still broken ❌
- The **in-place re-syncing standby never restarts PostgreSQL** after rewind/recovery-mode config. Identical symptom and root cause as the coordinator-only retest above. The updated init image did **not** change this behavior.
- Pod still reports `2/2 Ready` with a dead postgres backend.
- Recovery still requires a manual `kubectl delete pod dcdb-2` (fresh pod → init starts postgres → re-syncs with full data).

### Conclusion
Across **three coordinator/init image iterations**, durability is solid (never lost data) and `pg_rewind` now succeeds, but the **final "start PostgreSQL after in-place rewind" step is still missing**. The deleted/recreated pod always recovers (its init runs at boot); only the standby that stays running and re-syncs in place stays down. Fix must trigger an actual PostgreSQL start once recovery mode is configured, and the readiness gate should fail while port 9712 is down.

---
---

# RETEST #3 after fix — newest `init` + `coordinator` images (2026-06-19) — ✅ FIXED

**Verdict: ✅ PASS — PostgreSQL now restarts on the standby after every failover. Bug resolved. No data loss across 3 consecutive failovers.**

### Setup
- **Object:** `dcdb` (namespace `demo`), 3-replica HA, version `pg17-0.109.0` (updated in place, not reapplied).
- **Images (the fix):**
  - init: `souravbiswassanto/documentdb-init:_linux_amd64@sha256:1258c1f7…`
  - coordinator: `souravbiswassanto/documentdb-coordinator:fix-pg-rewind_linux_amd64@sha256:babc0532…`
- **Access:** `mongosh` only, run **inside the pods** (`kubectl exec <pod> -c documentdb -- mongosh 'mongodb://default_user:***@localhost:10260/…'`).
- Seed: `testdb.failover`, 10 docs → replicated to both standbys (count=10 each).

### Three consecutive failovers (delete the primary each time)

| Failover | Killed primary | New primary | In-place re-syncing standby | Recreated pod | Result |
|----------|----------------|-------------|------------------------------|---------------|--------|
| #1 | dcdb-0 | dcdb-1 | dcdb-2: rewind → **postgres started** | dcdb-0: rewind → **postgres started** | ✅ all 3 up |
| #2 | dcdb-1 | dcdb-0 | dcdb-2: rewind → **postgres started** | dcdb-1: rewind → **postgres started** | ✅ all 3 up |
| #3 | dcdb-0 | dcdb-1 | dcdb-2: rewind → **postgres started** | dcdb-0: rewind → **postgres started** | ✅ all 3 up |

In every case the coordinator on the re-syncing standby logged the rewind + recovery-mode config **and PostgreSQL then actually started** (the `waiting for the DocumentDB process to start` message appeared only briefly during the rewind, then cleared — no permanent stall). Both the **in-place** standby (stays running) and the **deleted/recreated** pod recovered on their own, with **no manual pod restart needed**.

### Checks
- **Postgres starts after re-sync on standby:** ✅ confirmed on **every** standby across all 3 failovers (the exact bug from the original report and retests #1–#2 — now fixed).
- **Replication:** ✅ insert on primary replicates to both standbys.
- **Data loss:** ✅ **none** — after each failover all 3 pods reconciled to identical counts (10, then 11 after a post-failover write); the new primary was always writable and complete.
- **Self-healing:** ✅ standbys rejoin automatically; the readiness/stuck condition no longer occurs.

### Note
The in-place re-syncing standby's PostgreSQL is briefly down only for the duration of the `pg_rewind` (seconds to ~1–2 min depending on divergence), then comes back automatically — this is expected behavior, not the old permanent stall.

### Final state
```
dcdb-0  standby  postgres up  count=11
dcdb-1  primary  postgres up  count=11
dcdb-2  standby  postgres up  count=11
```
Cluster healthy; all data intact.

**Bottom line:** The original failover bug ("after failover PostgreSQL won't restart in the standby") is **resolved** with the `init @1258c1f7` + `coordinator fix-pg-rewind @babc0532` images. pg_rewind runs, PostgreSQL restarts on the standby, the cluster self-heals, and no data is lost.
