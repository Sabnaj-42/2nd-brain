# DocumentDB TLS — Full Support Test Result

**Update (2026-08-03, later the same day):** after this doc's original test pass (below), the whole
branch was re-tested once more end-to-end — both this Day-1 provisioning path **and** the separately
tested `ReconfigureTLS` day-2 path (`../documentdb/reconfiguretls/test-result.md`) — using the fixed
init image. That second pass found and fixed **one more real bug**, in the same script family as the
fix below: `postgresql.conf` never got `ssl = off` re-asserted when TLS was removed, because none of
the 6 restart/bootstrap scripts had an `else` branch — only an `if SSL==ON`. Across repeated
add/remove cycles this left a stale `ssl = on` (pointing at now-deleted cert files) as the
last-mention-wins setting, and **"Remove TLS" could crash Postgres outright** (not just this doc's
"gateway keeps working" softer symptom). Fixed in all 6 scripts, shipped as
`sabnaj/documentdb-init:reconfiguretls-v5_linux_amd64` (supersedes `v3`/`v4` below). Full details and
re-verification in `../documentdb/reconfiguretls/test-result.md` finding #7. **The verdict at the
bottom of this doc reflects the final, twice-fixed state** — read this note before trusting the
"conditional on shipping the `configure.sh` fix" framing further down, which was accurate at the time
but is now superseded by the fuller fix.

**Second update (same day, later still):** every DocumentDB object, ops request, cert-manager
Issuer/Certificate, and test YAML file was deleted and recreated completely from scratch (no leftover
state, no reused PVCs/secrets), then **both** this Day-1 path and the full `ReconfigureTLS` 8-scenario
suite were re-run end-to-end a third time. Same clean result on both: fresh standalone and HA reach
`Ready` in ~60-70s, all 6 certs/gRPC isolation/replication/gateway-mongosh checks pass, and the full
add/rotate/change-issuer/remove cycle (including the previously-crashing remove-TLS case) completes
with no crashes on either topology. No new issues found. This is the most current, most thoroughly
re-verified state of the branch.

**Date:** 2026-08-03
**Cluster:** k3s (`/home/sabnaj/k3s.yaml`), namespace `demo`
**Scope:** Does TLS work end-to-end for the KubeDB DocumentDB operator, tested by creating **fresh**
DocumentDB objects with `spec.tls` set **from the moment of creation** (Day-1 provisioning), not via
a `ReconfigureTLS` ops request (that day-2 path was already tested separately — see
`documentdb/reconfiguretls/test-result.md`). Client-facing TLS was verified with **mongosh through the
gateway** (port 10260), not `psql` — per instruction, `psql` was only used to check the internal
Postgres-engine TLS surfaces (server cert, replication), never as the "client TLS" check.

**Test objects:** `dcdb-tls-standalone` (replicas: 1), `dcdb-tls-ha` (replicas: 3), both with
`sslMode: verify-full` and `spec.tls.tls.issuerRef` → `dcdb-ca-issuer` (a two-tier CA issuer, required
for HA `verify-full` cross-node trust — a bare `selfSigned` issuer does not work for HA, see the
ReconfigureTLS test doc's finding #4 for why).

**Images used:**
- `sabnaj/documentdb-operator:reconfiguretls-v3` (provisioner)
- `sabnaj/kubedb-ops-manager:reconfigure-fix-v4` (real multi-DB ops-manager, creates the certs)
- `sabnaj/documentdb-init:reconfiguretls-v3_linux_amd64` (**new this session** — includes the bootstrap
  `ssl=on` fix, see below)

## Result: ✅ PASS on both topologies, after fixing one real bug found during this test

| # | Surface | Standalone | HA (3 replicas) |
|---|---------|------------|------------------|
| 1 | Certs created (server/client/gateway/grpc-ca/grpc-server/grpc-client) | ✅ all 6, `Ready=True` | ✅ all 6, `Ready=True` |
| 2 | PetSet gated on cert secrets existing (`missingCertSecrets`) | ✅ | ✅ |
| 3 | Postgres server TLS (`pg_stat_ssl`) | ✅ `TLSv1.3 / TLS_AES_256_GCM_SHA384` | ✅ same, on primary |
| 4 | Streaming replication over TLS (mutual, `verify-full`) | n/a (no replicas) | ✅ `pg_stat_replication` shows both standbys `streaming/async`; standby `primary_conninfo` has `sslmode=verify-full` |
| 5 | Coordinator gRPC on an **isolated** CA (≠ main CA) | ✅ (not re-verified per-object; same code path as HA) | ✅ fingerprints differ: grpc-CA `9C:31:83:5F:...`, main CA `D2:30:BF:5A:...` |
| 6 | Gateway serves the cert-manager cert (not self-signed) | ✅ `issuer=CN=dcdb-ca / subject=CN=dcdb-tls-standalone` | ✅ `issuer=CN=dcdb-ca / subject=CN=dcdb-tls-ha` |
| 7 | **mongosh, TLS + our CA + SCRAM, through the gateway Service** | ✅ `{ok:1}` | ✅ `{ok:1}`, plus a real `insertOne`/`findOne` round-trip succeeded |
| 8 | Plaintext client rejected at the gateway | ✅ (connection reset, kills the tunnel — documented gateway behavior) | ✅ same |
| 9 | `DocumentDB.status.phase` | `Ready` | `Ready` |
| 10 | No-TLS-by-default still works (regression check, using the separately-running `dcdb-rtls-standalone`) | ✅ gateway still TLS-only, auto `CN=localhost` cert | — |

---

## The bug found and fixed: fresh HA+TLS clusters never formed

**Before the fix, `dcdb-tls-ha` never left `Provisioning`.** Its status condition read:

```
Ready=False, reason=SomeReplicasNotReady: "pq: SSL is not enabled on the server"
```

and `dcdb-tls-ha-0`'s `postgresql.conf` showed `ssl = off` despite `SSL=ON`/`SSL_MODE=verify-full` on
the container env, and despite `spec.tls`/`sslMode` being set correctly on the CR. The standby
coordinators logged a hard failure trying to reach the primary cross-pod:

```
pq: no pg_hba.conf entry for host "10.42.0.53", user "documentdb", database "postgres", no encryption (28000)
```

**Root cause:** `documentdb-init-docker/bootstrap_scripts/17/configure.sh` — the script that runs
**once, at first-ever `initdb`** for any brand-new pod — never wrote `ssl = on` (or the
`ssl_cert_file`/`ssl_key_file`/`ssl_ca_file` lines) into `postgresql.conf`, even when `SSL=ON`. It only
conditionally built the `primary_conninfo` string with `sslmode=$SSL_MODE`. By contrast,
`role_scripts/17/primary/start.sh` (which runs on **restarts** of an already-initialized data
directory — e.g. after a `ReconfigureTLS` ops request) already had the correct 4 lines. This is why:

- **Standalone "looked" fine** even before the fix: its health check and the gateway's own Postgres
  connection are both loopback (`127.0.0.1`), covered by the unconditional `host ... trust` pg_hba rule
  from the earlier pg_hba fix (see `reconfiguretls/test-result.md` finding #1) — so nothing ever
  exercised the missing `ssl=on`, and the DB reported `Ready` despite Postgres itself never actually
  turning SSL on. This was a **silent, masked failure**, not a genuine pass.
- **HA hard-failed**: standby↔primary replication is cross-pod (real pod IPs, not loopback), so it hits
  the `hostssl`-only pg_hba rules `configure.sh` correctly generates for `SSL=ON` — but since Postgres
  itself never got `ssl=on`, every such connection is rejected with literally "no encryption", and the
  cluster can never form.
- **This only affects DAY-1 (fresh bootstrap) TLS.** `ReconfigureTLS` (adding TLS to an already-running
  cluster) restarts pods through `start.sh`, which already had the fix — that's why the entire prior
  ReconfigureTLS test pass (8/8 scenarios, both topologies) never hit this.

**Fix:** added the same 4 lines already present in `start.sh` to `configure.sh`, gated on
`SSL=ON`, right after the `password_encryption` line:

```bash
if [[ "${SSL:-0}" == "ON" ]]; then
    echo "ssl = on" >> "$postgresConfigFile"
    echo "ssl_cert_file = '/tls/certs/server/server.crt'" >> "$postgresConfigFile"
    echo "ssl_key_file = '/tls/certs/server/server.key'" >> "$postgresConfigFile"
    echo "ssl_ca_file = '/tls/certs/server/ca.crt'" >> "$postgresConfigFile"
fi
```

Rebuilt/pushed as `sabnaj/documentdb-init:reconfiguretls-v3_linux_amd64`, patched the
`DocumentDBVersion pg17-0.109.0`'s `initContainer.image` to point at it, deleted and recreated both
test objects. **Both reached `Ready` in ~2 minutes**, and every check in the results table above then
passed genuinely (not masked) — `ssl = on` confirmed in `postgresql.conf` on all 3 HA pods,
`pg_stat_replication` showing real streaming replication, `SHOW ssl` → `on` on every pod.

**File changed:** `documentdb-init-docker/bootstrap_scripts/17/configure.sh` (uncommitted in this
session — a 8-line, purely additive, `SSL=ON`-gated diff; no risk to non-TLS clusters).

---

## Known limitation, not a bug: `GatewayMutualTLSEnabled` is accepted but unenforced

`DocumentDBTLSConfig.GatewayMutualTLSEnabled *bool` and its helper
`DocumentDB.GatewayMutualTLSEnabled()` exist in the API (`apimachinery/apis/kubedb/v1alpha2/documentdb_{types,helpers}.go`),
but grepping the operator finds **no call site** that actually reads this helper anywhere in
`pkg/controllers` or `pkg/ops` — the only place the field name appears is a doc comment in
`reconfigure_tls.go`. This was a deliberate, already-agreed decision from earlier in this project (see
prior conversation): implementing real mutual-TLS enforcement at the gateway would require either
patching the upstream Rust gateway or adding a sidecar proxy, both declined. **The field is safe to
leave in the spec (it validates and defaults correctly) but currently has zero runtime effect** — don't
tell users it does anything yet.

---

## Final verdict (after the second fix round): **production-ready**

This is the answer to "is this branch production ready" across **both** TLS paths — Day-1 creation
(this doc) and Day-2 `ReconfigureTLS` (`../documentdb/reconfiguretls/test-result.md`) — using the final
image set (`sabnaj/documentdb-init:reconfiguretls-v5_linux_amd64`, `sabnaj/documentdb-operator:reconfiguretls-v3`,
`sabnaj/kubedb-ops-manager:reconfigure-fix-v4`):

- **Client-facing TLS (mongosh through the gateway) works correctly and unconditionally** on both
  standalone and HA, across every scenario tested in both docs: cert-manager-issued cert served,
  SCRAM-SHA-256 auth over TLS succeeds with real data round-trips, plaintext is rejected. This layer
  was never broken, in either test round.
- **Two real bugs were found in the Postgres-engine layer, both now fixed and re-verified:**
  1. Fresh TLS-from-creation deployments never got `ssl = on` written at all (this doc's original
     finding) — standalone silently masked it, HA hard-blocked cluster formation.
  2. Removing TLS via `ReconfigureTLS` could leave a stale `ssl = on` in effect and **crash Postgres
     outright** (found on the second, full-branch re-test — see the update note at the top and
     `reconfiguretls/test-result.md` finding #7).
  Both share the same root cause shape (the init-docker scripts only ever asserted `ssl = on`, never
  `ssl = off`) and the same fix shape (add the missing `else` branch). All 6 affected scripts
  (`bootstrap_scripts/17/configure.sh`, `role_scripts/17/primary/start.sh`,
  `role_scripts/17/standby/{run,remote-replica,warm_stanby,ha_backup_job}.sh`) are now fixed and
  shipped in `reconfiguretls-v5`.
- **Do not ship without `reconfiguretls-v5` (or later) as the init image.** Both bugs are on
  by-design, common, expected user actions (create a DocumentDB with TLS from the start; later remove
  TLS from a running one) — not edge cases.
- Full 8-scenario `ReconfigureTLS` suite (add/rotate/change-issuer/remove × standalone/HA) and full
  Day-1 creation suite (both topologies) were both re-run to completion after the `v5` fix, with no
  further regressions. The one remaining known gap is the cert-mount race on issuer changes
  (`reconfiguretls/test-result.md` finding #3) — deliberately left unfixed because Postgres has the
  identical, unaddressed gap; recovery is a documented single pod eviction, not a crash.
- Remaining non-blocking caveat: `GatewayMutualTLSEnabled` is spec-only, not enforced (see above) —
  fine to leave as-is, just don't advertise it as working.

## Verification commands used (for reproduction)

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml

# gateway client TLS test (mongosh, not psql)
kubectl port-forward -n demo svc/<dcdb-tls-standalone|dcdb-tls-ha> <local>:10260 &
PASS=$(kubectl get secret -n demo <db>-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl get secret -n demo <db>-gateway-cert -o jsonpath='{.data.ca\.crt}' | base64 -d > ca.crt
mongosh "mongodb://default_user:${PASS}@127.0.0.1:<local>/?authMechanism=SCRAM-SHA-256&tls=true" \
  --tlsCAFile ca.crt --eval 'db.runCommand({ping:1})'

# internal Postgres-engine TLS checks (psql, only for the backend surface, not the client edge)
ADMIN=$(kubectl get secret -n demo <db>-admin-auth -o jsonpath='{.data.password}' | base64 -d)
kubectl exec -n demo <pod>-0 -c documentdb -- bash -c \
  "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=verify-full sslrootcert=/tls/certs/server/ca.crt' -c 'SELECT ssl,version,cipher FROM pg_stat_ssl WHERE pid=pg_backend_pid();'"

# check ssl actually on in postgresql.conf (the bug this session found)
kubectl exec -n demo <pod>-N -c documentdb -- grep -i '^ssl' /var/pv/data/postgresql.conf
```

## Definition of done

- [x] Fresh standalone DocumentDB with `spec.tls` set at creation reaches `Ready`
- [x] Fresh HA (3-replica) DocumentDB with `spec.tls` set at creation reaches `Ready`
- [x] All 6 certs (server/client/gateway/grpc-ca/grpc-server/grpc-client) created and `Ready`
- [x] Postgres server TLS verified (`pg_stat_ssl`)
- [x] Streaming replication over TLS verified (HA)
- [x] Coordinator gRPC on an isolated CA verified
- [x] Gateway client TLS verified with **mongosh** (not psql) on both topologies, including a real
      data write/read round-trip
- [x] Plaintext gateway connections confirmed rejected
- [x] No-TLS-by-default regression check passed
- [x] Root-caused and fixed the `configure.sh` bootstrap SSL bug; re-verified both topologies clean
      after the fix
- [x] Documented the `GatewayMutualTLSEnabled` unenforced-field caveat
- [x] Second full-branch re-test found and fixed a related remove-TLS crash bug (missing `ssl=off`
      else-branches in all 6 init-docker scripts); re-verified Day-1 creation **and** the full
      `ReconfigureTLS` 8-scenario suite clean on `reconfiguretls-v5` — see the update note at the top
      and `../documentdb/reconfiguretls/test-result.md` finding #7
- [x] Third full re-test from a completely clean slate (every DocumentDB object, ops request,
      cert-manager Issuer/Certificate, and test YAML deleted and recreated fresh) — same clean result
      on both Day-1 creation and the full `ReconfigureTLS` suite, no new issues
- [x] Results written here

## Files changed this session

- `documentdb-init-docker/bootstrap_scripts/17/configure.sh` — added the missing `ssl=on` +
  `ssl_cert_file`/`ssl_key_file`/`ssl_ca_file` block (gated on `SSL=ON`), matching what
  `role_scripts/17/primary/start.sh` already did; **later also given an `else: ssl=off` branch** (see
  update note at top). **Uncommitted** — review and commit when ready.
- `role_scripts/17/primary/start.sh` + all 4 `role_scripts/17/standby/*.sh` — added the missing
  `else: echo "ssl = off"` branch (found via the second, full-branch re-test). **Uncommitted.**
- Images: `sabnaj/documentdb-init:reconfiguretls-v3_linux_amd64` (first fix only) →
  superseded by `reconfiguretls-v5_linux_amd64` (both fixes). The cluster's
  `DocumentDBVersion pg17-0.109.0.spec.initContainer.image` was patched live to point at `v5` (this
  patch is cluster-only, not a code change — the version CR would need the same update wherever else
  it's applied, e.g. via `make install` manifests, for the fix to ship for real).
