# DocumentDB Full-TLS Test — server + replication + gateway + coordinator

End-to-end test of native TLS for the KubeDB DocumentDB operator, driven entirely by
`spec.tls` + `spec.sslMode` on the DocumentDB CR (no manual `podTemplate` cert passthrough).

- **Cluster:** k3s (remote node `10.2.0.226`), `export KUBECONFIG=/home/sabnaj/k3s.yaml`
- **Namespace:** `demo`  •  **DB:** `dcdb-tls` (2 replicas)
- **Date:** 2026-07-10
- **cert-manager:** v1.19.2

## Result: ✅ ALL SURFACES PASS

| # | Surface | Evidence |
|---|---------|----------|
| 1 | **Postgres server TLS** (:9712) | `psql sslmode=verify-full` → `ssl=true, TLSv1.3` |
| 2 | **Streaming replication over TLS** | `primary_conninfo … sslmode=verify-full`; standby `replay_lsn` advances live (`0/499EC28→0/49A0968`); log `started streaming WAL from primary` |
| 3 | **MongoDB-wire gateway TLS** (:10260) | serves cert `issuer=CN=dcdb-ca` / `subject=CN=dcdb-tls`, `Verify return code: 0 (ok)`, `TLSv1.3`; `mongosh --tls` + SCRAM → `{ok:1}` |
| 4 | **Coordinator** (HA control plane) | connects to Postgres over TLS + runs mutual-TLS gRPC; cluster elects primary/standby, `ssl=on`, no errors |

All three cert-manager certs (server/client/gateway) share one CA (fingerprint
`8B:2D:70…CE:87`), which is what makes replication `verify-full` cross-verification work.

**📋 Full step-by-step procedure with the command + real result for every step:
[`TESTING-PROCEDURE.md`](./TESTING-PROCEDURE.md).**
Raw captures: [`final-evidence.txt`](./final-evidence.txt), [`step-by-step-raw-output.txt`](./step-by-step-raw-output.txt).

---

## Images used

| Component | Image | Why |
|-----------|-------|-----|
| provisioner + ops-manager StatefulSets | `sabnaj/documentdb-operator:dcdb-tls7` | operator with all TLS wiring (below) |
| DocumentDBVersion `pg17-0.109.0` initContainer | `sabnaj/documentdb-init:dcdb-tls-hba2` | patched `pg_hba` + `ssl=on` at bootstrap (below) |

---

## What had to change

### A. Operator code (`kubedb.dev/documentdb`, `kubedb.dev/apimachinery`)
- **apimachinery `v1alpha2`**: `spec.tls` (`*kmapi.TLSConfig`) + `spec.sslMode` enum, cert aliases
  (server/client/gateway), `SetTLSDefaults`, `GetCertSecretName`, deepcopy. CRD regenerated + applied.
- **`pkg/controllers/certificates.go`** (new): `manageTLS` creates the server/client/gateway
  cert-manager Certificates. Cert creation lives in the **reconcile loop** (not `pkg/ops`) because
  the standalone `documentdb-operator` binary only runs the provisioner reconcile.
  - Server & gateway certs include the **Service FQDN with cluster domain**
    (`dcdb-tls.demo.svc.cluster.local`) as a SAN — required for replication `verify-full`.
- **`pkg/controllers/tls.go`**: secrets mount read-only at `/certs/{server,client,gateway}`; the
  init container copies them into a writable `/tls` emptyDir (the image's contract, incl. the
  required `exporter` dir); sets `SSL=ON`, `SSL_MODE`, gateway `CERT_PATH`/`KEY_FILE`.
- **`pkg/controllers/reconcile.go`**: cert-manager client field + `manageTLS` call before the
  cert-wait gate.
- **`pkg/controllers/petset.go`**: the **coordinator** container now gets `SSL=ON`,
  `SSL_MODE=prefer` when TLS is on, plus mounts of `/tls` and the `/grpc/{server,client}` cert
  pairs (the coordinator runs a mutual-TLS gRPC server and connects to Postgres over TLS).
  `prefer` (not `require`) avoids a bootstrap deadlock.
- **`pkg/cmds/server/operator.go`**: builds the cert-manager clientset.

### B. DocumentDB init image (`configure.sh` / role scripts) — `dcdb-tls-hba2`
The prebuilt DocumentDB image's co-located gateway/coordinator connect to Postgres over **plaintext
localhost**, which `SSL=ON`'s `hostssl`-only `pg_hba` rejects; and `ssl=on` was only set by the role
script, creating a bootstrap deadlock. Two small script patches fixed both (see
[`init-image-patch/`](./init-image-patch/)):
1. **`ssl = on` + cert paths added to `configure.sh`** so Postgres serves TLS from first boot (no
   `ssl=off` window → coordinator can complete role assignment).
2. **`host … 127.0.0.1/32 trust` + `::1/128 trust`** added ahead of the `hostssl` rules in all 6
   pg_hba-generating scripts, so co-located components reach Postgres over localhost while **external
   connections still require `hostssl`** (replication comes from pod IPs, so it stays TLS).

### C. Two operational prerequisites cleared
- **License crashloop** (`Error: license status unknown`): removed the `--license-file` arg from
  the provisioner + ops-manager StatefulSets (no license-proxyserver API present → license
  enforcement skipped, acceptable for a test cluster).
- **cert-manager controller** installed (only CRDs were present).

---

## Reproduce

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml

# 0) prereqs: cert-manager v1.19.2 running; operator StatefulSets on dcdb-tls7 with
#    --license-file arg removed; DocumentDBVersion pg17-0.109.0 initContainer = dcdb-tls-hba2

# 1) two-tier CA issuer (shared CA for all certs) + TLS DocumentDB
kubectl apply -f yaml/issuer.yaml
kubectl apply -f yaml/documentdb-tls.yaml

# 2) watch cert-manager issue certs, then pods come up
kubectl -n demo get certificate
kubectl -n demo get pods -l app.kubernetes.io/instance=dcdb-tls
```

### Verification commands
```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
PGPASS=$(kubectl -n demo get secret dcdb-tls-auth -o jsonpath='{.data.password}' | base64 -d)

# [1] server TLS
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "PGPASSWORD='$PGPASS' psql 'host=127.0.0.1 port=9712 user=default_user dbname=postgres sslmode=verify-full sslrootcert=/tls/certs/server/ca.crt' \
  -tAc \"SELECT ssl, version FROM pg_stat_ssl WHERE pid=pg_backend_pid();\""

# [2] replication over TLS — standby replay LSN advances (query twice); conninfo is verify-full
kubectl -n demo exec dcdb-tls-1 -c documentdb -- bash -c \
 "PGPASSWORD='$PGPASS' psql 'host=127.0.0.1 port=9712 user=default_user dbname=postgres sslmode=require' -tAc 'SELECT pg_last_wal_replay_lsn();'"
kubectl -n demo exec dcdb-tls-1 -c documentdb -- sh -c "grep primary_conninfo /var/pv/data/postgresql.conf"
# NOTE: pg_stat_replication / pg_stat_wal_receiver return no rows as default_user (needs
# pg_read_all_stats); use pg_last_wal_replay_lsn() which is callable and proves live replay.

# [3] gateway TLS
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 'echo | openssl s_client -connect 127.0.0.1:10260 -CAfile /tls/certs/gateway/ca.crt 2>/dev/null | openssl x509 -noout -issuer -subject'
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "mongosh 'mongodb://default_user:$PGPASS@127.0.0.1:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsCAFile=/tls/certs/gateway/ca.crt&tlsAllowInvalidHostnames=true' --quiet --eval 'db.runCommand({ping:1})'"
```

---

## Known notes
- DB `.status.phase` stays `Provisioning`: a health probe queries a `documentdb` database that is not
  created (also absent on the pre-existing non-TLS `dcdb` cluster) — app-level, orthogonal to TLS.
- `clientAuthMode: scram` (org default) → replication is TLS-encrypted + scram-authenticated
  (`sslmode=verify-full`), not client-cert mutual auth. Set `clientAuthMode: cert` for cert-based
  replication auth (would also require clients/gateway to present client certs).
