# DocumentDB Full-TLS — postgres-faithful implementation + end-to-end test

Native TLS for the KubeDB **DocumentDB** operator, driven entirely by `spec.tls` + `spec.sslMode`
on the DocumentDB CR. The cert-manager `Certificate` CRs are created by the **ops controller** and
consumed by the **provisioner** — exactly how the KubeDB **postgres** operator is structured.

- **Cluster:** k3s (remote node `10.2.0.226`), `export KUBECONFIG=/home/sabnaj/k3s.yaml`
- **Namespace:** `demo`  ·  **DB:** `dcdb-tls` (2 replicas, `sslMode: verify-full`)
- **cert-manager:** v1.19.2  ·  **Date:** 2026-07-14

## Result: ✅ all four TLS surfaces pass, pod env clean, DB `Ready`

| # | Surface | Evidence (verbatim in [`evidence.txt`](./evidence.txt)) |
|---|---------|----------|
| 1 | **Postgres server TLS** (:9712) | `pg_stat_ssl` → `true TLSv1.3 TLS_AES_256_GCM_SHA384` (user `documentdb`, `sslmode=verify-full`) |
| 2 | **Streaming replication over TLS** | `pg_stat_replication` → `10.42.0.134/32 streaming async`; standby `primary_conninfo … sslmode=verify-full`; replay LSN `0/4923130 → 0/49254B0`; `pg_is_in_recovery = t` |
| 3 | **MongoDB-wire gateway TLS** (:10260) | serves `issuer=CN=dcdb-ca / subject=CN=dcdb-tls`, `Verify return code: 0`, `TLSv1.3`; `mongosh --tls` + SCRAM (`default_user`) → `{"ok":1}` |
| 4 | **Coordinator raft gRPC** | own **isolated grpc-CA** (`E7:95:C8…35:A0`) ≠ main `dcdb-CA` (`69:B3:9E…E8:47`); `/grpc/server` served by `grpc-server` cert, `/grpc/client` present; `SHOW ssl = on` both pods; **0** gRPC/SSL errors |
| — | **Clean pod env** | cassandra vars **0**, `DCDB_*` service-link vars **0** (`enableServiceLinks: false`) |
| — | **DB status** | `STATUS: Ready` (`Ready=True`, `Provisioned=True`) — operator health-check now connects over TLS (see below) |

The 3 public certs share one CA (`69:B3:9E…E8:47`, required for replication `verify-full`); the
coordinator gRPC uses a **separate** grpc-CA chain (`grpc-ca → grpc-server/grpc-client`), matching
the postgres operator.

**📐 How it works + which files changed + diagram → [`ARCHITECTURE.md`](./ARCHITECTURE.md)**
**📋 Step-by-step procedure with the command + result for every step → [`TESTING-PROCEDURE.md`](./TESTING-PROCEDURE.md)**

---

## What this fixes vs. the earlier attempt

1. **Postgres-faithful cert creation.** Cert-manager `Certificate` CRs are created by the **ops
   controller** (`pkg/ops`, run by `documentdb-operator ops`); the provisioner only **waits** for
   the secrets (`missingCertSecrets` gate) and mounts them. The earlier attempt wrongly duplicated
   `manageTLS` into `pkg/controllers/certificates.go` — that file is **deleted**.
2. **Correct per-surface credentials.** DocumentDB has two auth secrets; each surface is tested with
   the right one: `dcdb-tls-admin-auth`/`documentdb` for the Postgres backend + replication,
   `dcdb-tls-auth`/`default_user` for the MongoDB gateway. (The operator code already wired these
   correctly; only the test was wrong before.)
3. **Clean pod env.** `spec.podTemplate.spec.enableServiceLinks: false` drops the namespace's
   service-link env (the `cassandra-quickstart` / `DCDB_*` vars) from the containers.
4. **Replication SAN fix.** The **server** and **gateway** certs now include the primary Service
   FQDN `dcdb-tls.demo.svc.cluster.local`, because replicas bootstrap against `PRIMARY_HOST` under
   `sslmode=verify-full`. (Added to `pkg/ops/certificates.go`.)
5. **Dedicated gRPC CA chain (final postgres-parity gap).** The coordinator's raft gRPC now runs on
   its own isolated `grpc-ca → grpc-server/grpc-client` chain (ported `ensureGrpcTLS` from postgres)
   instead of reusing the public server/client certs — see [`ARCHITECTURE.md`](./ARCHITECTURE.md).

## Images

| Component | Image | Command |
|-----------|-------|---------|
| ops-manager StatefulSet | `sabnaj/documentdb-operator:dcdb-tls12` | `ops` → creates certs |
| provisioner StatefulSet | `sabnaj/documentdb-operator:dcdb-tls12` | `operator` → consumes secrets |
| DocumentDBVersion `pg17-0.109.0` initContainer | `sabnaj/documentdb-init:dcdb-tls-hba2` | patched `pg_hba` + `ssl=on` at bootstrap ([`init-image-patch/`](./init-image-patch/)) |

## Reproduce

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
# prereqs: cert-manager running; ops-manager sts on dcdb-tls12 with arg `ops`;
#          provisioner sts on dcdb-tls12 with arg `operator`; init image dcdb-tls-hba2.
kubectl apply -f yaml/issuer.yaml          # two-tier CA issuer (shared CA)
kubectl apply -f yaml/documentdb-tls.yaml  # TLS DocumentDB, enableServiceLinks:false

kubectl -n demo get certificate                 # 3 certs, created by the ops pod
kubectl -n demo get pods -l app.kubernetes.io/instance=dcdb-tls   # dcdb-tls-0/1 → 2/2
```

Verification commands are in [`TESTING-PROCEDURE.md`](./TESTING-PROCEDURE.md); captured output in
[`evidence.txt`](./evidence.txt).

## DB `Ready` — the health-checker TLS fix
Earlier the DB stayed `Provisioning` with
`Ready=False: pq: no pg_hba.conf entry for host … no encryption`. Root cause: the operator's own
health checker (`pkg/controllers/health.go` `getPostgresClient`, and the ops-side
`pkg/ops/pg_client.go`) connected to the backend Postgres with a **hardcoded `sslmode=disable`** —
which the `SSL=ON` `hostssl` pg_hba rejects. Fixed by making those connections TLS-aware: they now
honor `spec.sslMode` (coercing `prefer`/`allow` → `require` for lib/pq) and pass `sslrootcert` (the
server cert's CA, via `certholder`) for `verify-ca`/`verify-full`. The DB now reaches **`Ready`**
(`Ready=True`, `Provisioned=True`); `pg_stat_ssl` shows the operator's `documentdb` connections as
`ssl=t`, while the co-located coordinator/gateway keep using the `127.0.0.1` trust rule.
> (My earlier note blaming a missing `documentdb` database was incorrect — the cause was the
> plaintext health-check connection.)
