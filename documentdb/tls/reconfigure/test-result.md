# ReconfigureTLS — DocumentDB — Test Results

**Date:** 2026-07-30 → 2026-08-03 (re-verified three times on 2026-08-03: after reverting the cert-race
fix attempt; after fixing a real `postgresql.conf` SSL-state bug found during a full-branch re-test;
and once more from a **completely fresh cluster state** — every DocumentDB object, ops request, and
test YAML deleted and recreated from scratch — to confirm the fixes hold with no leftover state
propping anything up. See below.)
**Cluster:** k3s (`/home/sabnaj/k3s.yaml`), namespace `demo`
**Test objects:** `dcdb-rtls-standalone` (replicas: 1), `dcdb-rtls-ha` (replicas: 3) — all fresh
objects as of the final run, including fresh cert-manager `Issuer`/`Certificate` PKI
(`dcdb-ca-issuer`/`dcdb-alt-issuer`, replacing the earlier `dcdb-rtls-alt-issuer` naming)
**Images used for the final, all-green re-test:**
- `sabnaj/documentdb-operator:reconfiguretls-v3` (provisioner, swapped-in binary)
- `sabnaj/kubedb-ops-manager:reconfigure-fix-v4` (real multi-DB ops-manager, built via a temporary vendor overlay of `kubedb.dev/documentdb`+`kubedb.dev/apimachinery` into `kubedb.dev/ops-manager`, then reverted — see #2)
- `sabnaj/documentdb-init:reconfiguretls-v5_linux_amd64` (fixes a real crash-on-remove-TLS bug found during the second re-test, see #7 below; supersedes `reconfiguretls-v2`/`v3`/`v4`)

## Result: ✅ PASS — all 8 scenarios verified end-to-end **three times**, clean on a fully fresh cluster

| # | Topology | Scenario | Ops request phase | Gateway connectivity verified |
|---|----------|----------|--------------------|-------------------------------|
| 1 | Standalone | Add TLS | Successful | ✅ `mongosh --tls --tlsCAFile <our CA>` → `{ok:1}`; certs matched secret on first try |
| 2 | Standalone | Rotate certificates | Successful | ✅ New serial confirmed; certs matched secret on first try |
| 3 | Standalone | Change issuer | Successful | ⚠️ Cert-mount race reproduced (see #3) — gateway briefly served the stale cert; recovered after one manual pod eviction, then connected fine |
| 4 | Standalone | Remove TLS | Successful | ✅ Reverts to gateway's auto-generated self-signed cert (still TLS-only — see note); old managed CA now rejected |
| 5 | HA (3 replicas) | Add TLS | Successful | ✅ Same as #1, verified through the Service; all 3 pods' mounted certs matched the secret |
| 6 | HA (3 replicas) | Rotate certificates | Successful | ✅ Same as #2; all 3 pods matched |
| 7 | HA (3 replicas) | Change issuer | Successful | ⚠️ Cert-mount race reproduced, worse than standalone: all 3 pods ended up on **3 different** stale cert versions, none matching the final secret; DocumentDB status went `Critical` (`x509: certificate signed by unknown authority`) until a full primary-then-standbys manual eviction cycle restored consistency — see #3 |
| 8 | HA (3 replicas) | Remove TLS | Successful | ✅ Same as #4 |

All ops requests report `phase: Successful`; DocumentDB CR returns to `status.phase: Ready` after each (after the manual recovery step for #3/#7); cert-manager `Certificate` cleanup correctly removes `server`/`client`/`gateway` while preserving the `grpc-*` chain.

## Production-readiness verdict

**Ready to ship, with one accepted, documented limitation — not a regression, not something DocumentDB needs to solve on its own.**

Every scenario reaches `Successful`/`Ready` and the gateway is reachable with the correct cert in every case. The one real gap — the cert-mount race on issuer changes (#3) — was deliberately **not** fixed in this branch. A working fix (baseline the `Certificate.Status.Revision` before reissuing, and gate the restart on it having advanced) was implemented and verified to close the race, but was reverted after confirming `kubedb.dev/postgres`'s `ReconfigureTLS` has the **exact same architecture and the exact same gap** — same init-container-to-emptyDir cert mount, same Ready-condition-only wait check, no revision gating. Since DocumentDB's `ReconfigureTLS`/restart code is a direct port of Postgres's, and Postgres ships with this gap unaddressed, the decision was to match Postgres's behavior rather than have DocumentDB alone carry extra complexity Postgres doesn't have. If Postgres later gains a fix for this, port it to DocumentDB too; until then, this is parity, not a deficiency.

Practical implication for anyone running `ReconfigureTLS` with an issuer change (not rotation, not add, not remove — specifically a **CA swap**): check that the gateway/server/client secrets match what's mounted in each pod after the ops request reports `Successful`, and if not, evict the stale pod(s) (primary first in HA — see #5 for why order matters here). This matches exactly how the same situation is already handled operationally for Postgres.

---

---

## Important findings from testing (read before reusing this on another cluster)

### 1. Pre-existing bug found and fixed: gateway can't start once TLS is on for *any* topology
The gateway's Postgres connection pool is hardcoded plaintext (`NoTls`, upstream `pg_documentdb_gw`). Once `SSL=ON`, every `pg_hba.conf`-generating script (`bootstrap_scripts/17/configure.sh` **and** all of `role_scripts/17/{primary/start.sh, standby/run.sh, standby/ha_backup_job.sh, standby/remote-replica.sh, standby/warm_stanby.sh}`) only emits `hostssl` rules for `127.0.0.1`/`::1`, so the gateway's plaintext loopback connection is rejected (`no pg_hba.conf entry ... no encryption`, or `password missing` depending on which pool). **Fixed** by adding an explicit `host all all 127.0.0.1/32 trust` + `host all all ::1/128 trust` pair right after the existing `local all all trust` line in all 6 scripts, in `kubedb.dev/documentdb-init-docker` (KubeDB's own repo — not the Microsoft `documentdb/documentdb` repo). Image: `sabnaj/documentdb-init:reconfiguretls-v2_linux_amd64`. **This fix is required for ReconfigureTLS (or any TLS-enabling path) to work at all on HA, and was also silently broken for standalone before the fix.**

### 2. `ops-manager` vendor tree can't just `go mod vendor` against this branch — use a scoped overlay instead
`kubedb.dev/ops-manager` vendors ~30 database repos, pinned to released versions (`kubedb.dev/documentdb v0.3.0`, `kubedb.dev/apimachinery v0.66.0` in `go.mod`). Running a full `go mod vendor` there against the current local `apimachinery` checkout (on the `documentdb-tls` branch) breaks 6 unrelated databases (qdrant, rabbitmq, singlestore, mariadb, solr, zookeeper — missing `lib.InPlaceResizePod`/`VerticalScalingModeInPlace` and friends, an unrelated in-progress feature on this apimachinery branch). **Working approach, used for both the original build and the reverted-source rebuild:** `rsync`/`cp` only the DocumentDB-touching files into `vendor/` — `kubedb.dev/documentdb/pkg/{ops,controllers,pgtune}` wholesale, plus the specific `kubedb.dev/apimachinery` files DocumentDB's TLS/ops work actually touches (`apis/kubedb/v1alpha2/documentdb_{types,helpers}.go`, `apis/ops/v1alpha1/documentdb_ops_types.go`, the matching CRD yamls) — **without** touching `go.mod`/`go.sum` or wholesale-copying generated files like `zz_generated.deepcopy.go` (copying that file whole pulls in unrelated in-progress changes from other DBs on this branch and breaks the build; instead confirm by inspection whether the new fields actually need new deepcopy logic — plain string/bool fields on an existing struct usually don't). Build the image, push it, then `git checkout -- go.mod go.sum vendor/ && git clean -fd vendor/kubedb.dev/documentdb/` to leave the repo clean again. This produces a real multi-DB `kubedb-ops-manager` image (not a stand-in), so ops-request processing for every other database keeps working while DocumentDB's ReconfigureTLS is under test — no more disabling other DBs' ops-manager the way the very first test pass did.
The provisioner side uses a different, simpler pattern that's fine to keep: the shared `kubedb-kubedb-provisioner` StatefulSet's image is swapped to `sabnaj/documentdb-operator:<tag>` (the DocumentDB-only binary) run with `args: ["operator", ...]` — this binary only reconciles `DocumentDB` CRs, so it's a safe, permanent stand-in for the provisioner as long as no other DB's provisioning is expected to run concurrently in this cluster.
Also required (unchanged from the first pass): `restore.Configure(clientConfig, &amcCfg.Initializers.Stash, s.ResyncPeriod)` was missing from `documentdb/pkg/cmds/server/ops_operator.go` (present in postgres's equivalent) — without it, `Initializers.Stash.StashClient` is `nil` and any ops request panics on the backup/restore-running check. Fixed by mirroring postgres's call.

### 3. Cert-mount race on issuer changes — confirmed present, confirmed matching Postgres, deliberately left unfixed
`ReconfigureTLS`'s "wait for `CertificateSynced`" check is satisfied as soon as cert-manager's `Certificate.Status.Conditions[Ready]` flips true — but the actual Kubernetes `Secret` write can lag a few seconds to low minutes behind that condition update. Because the TLS cert flow copies Secret content into a shared `emptyDir` via an init container **once at pod startup**, a pod that restarts in that window permanently mounts the stale cert until it's restarted again — nothing later self-heals it.

**Confirmed root cause and severity by direct reproduction on this cluster, after reverting an attempted fix** (see "Production-readiness verdict" above for why it was reverted):
- **Standalone, change-issuer:** pod restarted at `09:00:22Z`; the gateway `Certificate` didn't report `Ready` until `09:00:38Z` — 16s later. The pod's mounted cert hash didn't match the Secret's hash for the rest of that window. `mongosh` against the new CA failed with `unable to get local issuer certificate`. The mismatch did **not** self-heal after 15+ seconds of waiting; recovered immediately after one `kubectl delete pod`.
- **HA (3 replicas), change-issuer — notably worse:** because HA restarts sequentially (primary first, standbys after, ~40s–2min apart) and reissuance across the `gateway`/`server`/`client` `Certificate` resources isn't perfectly synchronized either, all 3 pods ended up on **three different** stale cert versions — pod 0 had its own, pods 1 and 2 shared a different one, and none of the three matched the Secret cert-manager eventually settled on. This wasn't just a gateway-connectivity annoyance: the KubeDB provisioner's own internal health check (Postgres `verify-full` between nodes) started failing with `tls: failed to verify certificate: x509: certificate signed by unknown authority`, and `DocumentDB.status.phase` went to `Critical`/`SomeReplicasNotReady`. Recovery required evicting **all three** pods, primary first (`kubectl delete pod dcdb-rtls-ha-0` → wait Ready → `-1` → wait → `-2` → wait), after which every pod's mounted cert matched the Secret and the cluster returned to `Ready`.
- **Add TLS and Rotate Certificates did not reproduce the race** in either topology on this run — consistent with the theory that it's a timing race tied to how long cert-manager takes to write the Secret relative to the `Ready` condition update, not a deterministic bug; it's just far more likely to bite on an issuer change (full reissuance of 3 separate `Certificate` resources against a differently-shaped CA chain) than a same-CA rotation.

**Confirmed this is not unique to DocumentDB:** `kubedb.dev/postgres`'s `ReconfigureTLS` (which DocumentDB's was ported from) uses the identical init-container-to-emptyDir mount pattern and the identical Ready-condition-only wait check — it has no revision-based or Secret-content-based gating either. DocumentDB was deliberately kept at parity with this rather than diverging with extra fix-only-here logic.
**Practical workaround (same as Postgres):** after a `ReconfigureTLS` issuer-change ops request reports `Successful`, compare the cert Secret's content against what's mounted in each pod (`sha256sum` both sides) and evict any pod whose mount is stale — primary first if it's an HA cluster (see #5 for why order matters).

### 4. Changing issuer to a bare `selfSigned` cert-manager `Issuer` does not work for HA
Cert-manager's `SelfSigned` issuer type mints an **independent** self-signed cert per `Certificate` resource — there is no shared CA across the `server`/`client`/`gateway` certs, even though they may share a `commonName`. Standalone "change issuer" tests pass fine against a bare `selfSigned` issuer (no cross-node verification needed), but HA's replica→primary `sslmode=verify-full` check will fail with `certificate signed by unknown authority` because the replica's `client` cert's CA can never validate the primary's independently-self-signed `server` cert. **This is a test-design mistake, not a product bug.** Fixed by using a proper 2-tier CA issuer instead (`yaml/00-alt-issuer.yaml`: self-signed bootstrap Issuer → `isCA: true` Certificate → CA-backed Issuer), matching how `dcdb-ca-issuer` (the primary test issuer) is itself constructed. **Takeaway: `spec.tls.issuerRef` for any HA DocumentDB must point at a `CA`-type Issuer/ClusterIssuer, never a bare `SelfSigned` one.**

### 5. HA pod-restart ordering matters when the CA itself changes
Manually evicting HA pods one at a time (standbys first, primary last) works fine for **rotation** (same CA, new leaf) but not for an **issuer change** (new CA): a standby that has already picked up the new CA can no longer verify a primary still serving the old-CA cert (and vice versa once leadership fails over mid-sequence). Evicting all 3 pods **simultaneously** while stuck in a mismatched-cert state also risks a real (separate, pre-existing) Postgres replication recovery bug in raft failover, requiring a fresh basebackup (`kubectl delete pod <replica>` + `kubectl delete pvc data-<replica>`) to recover. Once a consistent, correct CA is in place (see #4), a coordinated restart converges normally.

### 6. "Remove TLS" does not mean plaintext
The gateway's TLS acceptor enforces TLS unconditionally by default (`enforce_tls` defaults to `true` in `pg_documentdb_gw`), regardless of `spec.tls`. Removing TLS via `ReconfigureTLS` correctly tears down the operator-managed certs and reverts the gateway to its own auto-generated self-signed `CN=localhost` cert — the gateway is **still TLS-only**, just no longer serving a cert-manager-issued/verifiable one. A plain (non-TLS) `mongosh` connection attempt always fails and additionally kills the active `kubectl port-forward` tunnel (the gateway resets the TCP connection on an unexpected plaintext ClientHello) — don't test "remove TLS" by trying a truly plaintext connection through a port-forward.

### 7. Real bug found and fixed this round: "Remove TLS" could crash Postgres outright
On a full second re-test pass (after upgrading the init image to pick up the Day-1 TLS bootstrap fix
from `../tls/tls-testResult.md`), `dcdb-rtls-standalone`'s remove-TLS ops request reported
`Successful`, but Postgres itself then failed to start:

```
FATAL: could not load server certificate file "/tls/certs/server/server.crt": No such file or directory
```

**Root cause:** every `documentdb-init-docker` script that (re)writes `postgresql.conf` on a restart
(`bootstrap_scripts/17/configure.sh` for standalone; `role_scripts/17/primary/start.sh` and all 4
`role_scripts/17/standby/*.sh` for HA) only ever wrote `ssl = on` + cert paths **when `SSL=ON`** — none
of them had an `else` branch writing `ssl = off` when SSL was being turned off. Since `postgresql.conf`
grows across restarts (each restart appends another full block; nothing ever truncates it) and
PostgreSQL uses **last-mention-wins** for repeated settings, a "remove TLS" restart that appends no new
`ssl` line at all leaves the **previous** restart's `ssl = on` + now-deleted cert paths as the effective
setting — so Postgres refuses to start. This reliably reproduces on the very first "add → remove" TLS
cycle on a fresh DB and is **not** timing-dependent, unlike finding #3.

Fixed by adding an explicit `else: echo "ssl = off"` branch to all 6 scripts (matching the pattern
already used for the neighboring `primary_conninfo`/`pg_hba` branches in the same files). Rebuilt as
`sabnaj/documentdb-init:reconfiguretls-v5_linux_amd64`. Re-ran the full 8-scenario suite on both
topologies after the fix — no crash, `ssl = off` correctly asserted as the last line, `status.phase:
Ready` throughout, gateway TLS enforced correctly (self-signed fallback) after removal.

**Recovery for anyone hitting this on the un-fixed image:** the crash is a genuine down-database, not
self-healing — `kubectl delete pod` alone won't fix it (it just replays the same stale config); the pod
must come back up on the fixed init image (bump the `DocumentDBVersion`'s `initContainer.image`, then
delete the pod) for the next restart to correctly append `ssl = off`.

---

## Verification commands used (for reproduction)

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
kubectl port-forward -n demo svc/<dcdb-rtls-standalone|dcdb-rtls-ha> 10260:10260 &

PASS=$(kubectl get secret -n demo <db>-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl get secret -n demo <db>-gateway-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt

# with our CA — should succeed once TLS is added/rotated/reissued
mongosh "mongodb://default_user:${PASS}@127.0.0.1:10260/?authMechanism=SCRAM-SHA-256&tls=true" --tlsCAFile ca.crt --eval 'db.runCommand({ping:1})'

# after "remove TLS" — self-signed default still requires --tls, just not verifiable against our CA
mongosh "mongodb://default_user:${PASS}@127.0.0.1:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true" --eval 'db.runCommand({ping:1})'
```

## Definition of done

- [x] apimachinery API changes merged into the DocumentDB types (`DocumentDBTLSSpec.SSLMode`/`ClientAuthMode`)
- [x] documentdb operator builds cleanly (`go build`/`go vet`/`go test` all pass)
- [x] ReconfigureTLS succeeds on standalone (all 4 sub-scenarios)
- [x] ReconfigureTLS succeeds on HA / 3 replicas (all 4 sub-scenarios)
- [x] YAMLs committed under `yaml/`
- [x] Results written here
- [x] Re-verified full 8-scenario pass after reverting the cert-race fix attempt, confirming behavior matches Postgres's accepted status quo (2026-08-03)
- [x] Found and fixed a real remove-TLS crash bug (postgresql.conf stale `ssl=on`), re-verified full 8-scenario pass again on both topologies with the fix (2026-08-03)
- [x] Full teardown and fresh recreation of every DocumentDB object, ops request, and test YAML, then a third clean 8-scenario pass on both topologies with no leftover state — same results, same accepted cert-race caveat, no new regressions (2026-08-03)

## Files changed (code, separate from this test)

- `apimachinery/apis/ops/v1alpha1/documentdb_ops_types.go` — added `SSLMode`/`ClientAuthMode` to `DocumentDBTLSSpec`
- `documentdb/pkg/ops/reconfigure_tls.go` — new, ports postgres's `ReconfigureTLS()`
- `documentdb/pkg/ops/ops_request.go` — wired the dispatch (was a stub)
- `documentdb/pkg/ops/helper.go` — added a doc comment on `CustomRestartForClusterMode` noting it restarts primary-first by design (no behavior change; see #5)
- `documentdb/pkg/cmds/server/ops_operator.go` — added missing `restore.Configure(...)` Stash initializer call
- `documentdb-init-docker/bootstrap_scripts/17/configure.sh` + all 5 `role_scripts/17/{primary,standby}/*.sh` — pg_hba loopback-trust fix (pre-existing bug, unrelated to ReconfigureTLS but blocking every test until fixed); **same 6 files**, later in this round, also got the `ssl = off` else-branch fix (#7)

**Not included** (implemented, then reverted): a `Certificate.Status.Revision`-baseline-tracking fix for the cert-mount race (#3) in `reconfigure_tls.go`. It worked, but was reverted after confirming Postgres's `ReconfigureTLS` has the identical gap and doesn't fix it either — see "Production-readiness verdict" above.
