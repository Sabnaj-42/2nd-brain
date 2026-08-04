# DocumentDB Full-TLS — step-by-step testing procedure

Every step has the **command** and the **actual result** captured from the live cluster
(2026-07-14). Raw one-shot capture: [`evidence.txt`](./evidence.txt). Architecture + diagram:
[`ARCHITECTURE.md`](./ARCHITECTURE.md).

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
# Per-surface credentials (two auth secrets):
ADMIN=$(kubectl -n demo get secret dcdb-tls-admin-auth -o jsonpath='{.data.password}' | base64 -d)  # user documentdb   → Postgres backend
USERP=$(kubectl -n demo get secret dcdb-tls-auth       -o jsonpath='{.data.password}' | base64 -d)  # user default_user → MongoDB gateway
```

---

## Phase 0 — prerequisites

### 0.1 cert-manager running
```bash
kubectl -n cert-manager get pods
```
→ `cert-manager`, `cert-manager-webhook`, `cert-manager-cainjector` all `Running` (v1.19.2).

### 0.2 operators: two StatefulSets, two commands, one image
```bash
for s in kubedb-kubedb-provisioner kubedb-kubedb-ops-manager; do
  kubectl -n kubedb get sts $s -o jsonpath="$s: {.spec.template.spec.containers[0].image} arg={.spec.template.spec.containers[0].args[0]}{'\n'}"
done
```
→
```
kubedb-kubedb-provisioner: sabnaj/documentdb-operator:dcdb-tls12 arg=operator
kubedb-kubedb-ops-manager: sabnaj/documentdb-operator:dcdb-tls12 arg=ops
```
The **ops** command runs `pkg/ops` (creates certs); the **operator** command runs `pkg/controllers`
(consumes secrets). This is the postgres-faithful split.

### 0.3 ops-manager SA can create cert-manager Certificates
```bash
kubectl auth can-i create certificates.cert-manager.io \
  --as=system:serviceaccount:kubedb:kubedb-kubedb-ops-manager -n demo
```
→ `yes`

### 0.4 init image
DocumentDBVersion `pg17-0.109.0` initContainer → `sabnaj/documentdb-init:dcdb-tls-hba2`
(patched `pg_hba` localhost-trust + `ssl=on` at bootstrap; see [`init-image-patch/`](./init-image-patch/)).

---

## Phase 1 — create

### 1.1 two-tier CA issuer (shared CA)
```bash
kubectl apply -f yaml/issuer.yaml
kubectl -n demo get issuer dcdb-ca-issuer
```
→ `dcdb-ca-issuer  True` (a `selfSigned` boot Issuer mints a CA cert → `dcdb-ca-issuer` signs all 3
leaf certs from that **one** CA, which replication `verify-full` requires).

### 1.2 apply the TLS DocumentDB
```bash
kubectl apply -f yaml/documentdb-tls.yaml
```
`spec`: `version pg17-0.109.0`, `replicas 2`, `sslMode verify-full`, `tls.issuerRef → dcdb-ca-issuer`,
`podTemplate.spec.enableServiceLinks: false`.

---

## Phase 2 — the ops controller creates certs, the provisioner waits then builds

### 2.1 ops pod creates the 3 Certificates
```bash
kubectl -n kubedb logs kubedb-kubedb-ops-manager-0 | grep -E "started processing|rotationPolicy"
kubectl -n demo get certificate
```
→ ops log shows `started processing {"key":"demo/dcdb-tls"}`; **6** Certificates + the 2 grpc
Issuers appear:
```
dcdb-tls-server-cert        True     dcdb-tls-grpc-ca-cert       True
dcdb-tls-client-cert        True     dcdb-tls-grpc-server-cert   True
dcdb-tls-gateway-cert       True     dcdb-tls-grpc-client-cert   True
# issuers: dcdb-tls-grpc-selfsigned True, dcdb-tls-grpc-issuer True
```

### 2.2 provisioner waits on the secret, then builds the PetSet
```bash
kubectl -n kubedb logs kubedb-kubedb-provisioner-0 | grep -E "waiting for TLS certificate|PetSet .* created"
```
→
```
"waiting for TLS certificate secrets" DocumentDB="demo/dcdb-tls" missing=["dcdb-tls-gateway-cert"]
"PetSet demo/dcdb-tls created" DocumentDB="demo/dcdb-tls"
```
This is the `missingCertSecrets()` gate — the provisioner never creates certs, it only consumes.

### 2.3 pods up, roles assigned
```bash
kubectl -n demo get pods -l app.kubernetes.io/instance=dcdb-tls -L kubedb.com/role
```
→ `dcdb-tls-0  2/2  Running  primary` · `dcdb-tls-1  2/2  Running  standby`

### 2.4 server cert carries the primary FQDN SAN (required for replication)
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- \
  openssl x509 -in /tls/certs/server/server.crt -noout -ext subjectAltName
```
→ includes `DNS:dcdb-tls.demo.svc.cluster.local` (the host replicas connect to under `verify-full`).

---

## Phase 3 — verify each TLS surface

### 3.1 Postgres server TLS (backend user `documentdb` via admin-auth)
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=verify-full sslrootcert=/tls/certs/server/ca.crt' \
  -c \"SELECT ssl, version, cipher FROM pg_stat_ssl WHERE pid=pg_backend_pid();\""
```
→ `t|TLSv1.3|TLS_AES_256_GCM_SHA384` ✅

### 3.2 Streaming replication over TLS
```bash
# conninfo on standby
kubectl -n demo exec dcdb-tls-1 -c documentdb -- sh -c "grep -o 'sslmode=[a-z-]*' /var/pv/data/postgresql.conf | head -1"
# replication state on primary
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=require' \
  -c 'SELECT client_addr, state, sync_state FROM pg_stat_replication;'"
# standby replay LSN advances after a write on the primary
kubectl -n demo exec dcdb-tls-1 -c documentdb -- bash -c "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=require' -c 'SELECT pg_last_wal_replay_lsn();'"
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=require' -c 'CREATE TABLE IF NOT EXISTS _tlsprobe(t timestamptz); INSERT INTO _tlsprobe VALUES (now());'"
kubectl -n demo exec dcdb-tls-1 -c documentdb -- bash -c "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=require' -c 'SELECT pg_last_wal_replay_lsn(), pg_is_in_recovery();'"
```
→ `sslmode=verify-full` · `pg_stat_replication → 10.42.0.134/32 streaming async` ·
replay LSN `0/4923130 → 0/49254B0` (advanced) · `pg_is_in_recovery = t` ✅

### 3.3 MongoDB-wire gateway TLS (gateway user `default_user` via auth)
```bash
# server cert
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 'echo | openssl s_client -connect 127.0.0.1:10260 -CAfile /tls/certs/gateway/ca.crt 2>/dev/null | openssl x509 -noout -issuer -subject'
# handshake verify + protocol
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 'echo | openssl s_client -connect 127.0.0.1:10260 -CAfile /tls/certs/gateway/ca.crt 2>/dev/null | grep -E "Verify return code|Protocol  :"'
# authenticated ping over TLS
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "mongosh 'mongodb://default_user:$USERP@127.0.0.1:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsCAFile=/tls/certs/gateway/ca.crt&tlsAllowInvalidHostnames=true' --quiet --eval 'JSON.stringify(db.runCommand({ping:1}))'"
```
→ `issuer=CN=dcdb-ca` / `subject=CN=dcdb-tls` · `Verify return code: 0 (ok)` · `TLSv1.3` ·
`{"ok":1}` ✅

### 3.4 Coordinator / ssl state
```bash
for p in dcdb-tls-0 dcdb-tls-1; do
  kubectl -n demo exec $p -c documentdb -- bash -c \
   "PGPASSWORD='$ADMIN' psql -qtAX 'host=127.0.0.1 port=9712 user=documentdb dbname=postgres sslmode=require' -c 'SHOW ssl;'"
done
kubectl -n demo logs dcdb-tls-0 -c documentdb-coordinator --tail=400 | grep -icE 'SSL error|no pg_hba|SSL is not enabled'
```
→ `on` / `on` · error count `0` ✅

### 3.5 Clean pod env
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- env | grep -ic cassandra          # → 0
kubectl -n demo exec dcdb-tls-0 -c documentdb -- env | grep -cE '^DCDB_TLS_PORT|^DCDB_PORT'  # → 0
kubectl -n demo get petset dcdb-tls -o jsonpath='{.spec.template.spec.enableServiceLinks}'   # → false
```
✅ no `cassandra-quickstart`/`DCDB_*` service-link vars.

### 3.6 Shared CA across all 3 certs
```bash
for a in server client gateway; do
  kubectl -n demo exec dcdb-tls-0 -c documentdb -- \
    openssl x509 -in /tls/certs/$a/ca.crt -noout -fingerprint -sha256
done
```
→ identical `69:B3:9E:9F:…:E8:47` for server, client, gateway ✅

### 3.7 Coordinator gRPC uses a dedicated, isolated grpc-CA
```bash
# grpc-CA the coordinator serves/verifies with (differs from the main dcdb-CA)
kubectl -n demo exec dcdb-tls-0 -c documentdb-coordinator -- \
  sh -c 'openssl x509 -in /grpc/server/ca.crt -noout -subject -fingerprint -sha256'
# grpc-server leaf is issued by the grpc-CA
kubectl -n demo exec dcdb-tls-0 -c documentdb-coordinator -- \
  sh -c 'openssl x509 -in /grpc/server/server.crt -noout -issuer -subject'
# dedicated grpc-client cert mounted
kubectl -n demo exec dcdb-tls-0 -c documentdb-coordinator -- ls /grpc/client
# no coordinator gRPC/TLS errors
kubectl -n demo logs dcdb-tls-0 -c documentdb-coordinator --tail=400 | grep -icE 'load server key pair|SSL error|tls:'
```
→ grpc-CA sha256 `E7:95:C8…35:A0` **≠** main `dcdb-CA` `69:B3:9E…E8:47` (isolated chain) ·
grpc-server `issuer=CN=dcdb-tls` (the grpc-CA) / `subject=CN=dcdb-tls-pods` ·
`/grpc/client` has `ca.crt client.crt client.key` · error count `0` ✅

---

## Result summary

| Surface | Result |
|---|---|
| Postgres server TLS | ✅ `ssl=t, TLSv1.3` under `verify-full` |
| Replication over TLS | ✅ `streaming/async`, `verify-full`, replay LSN advancing |
| MongoDB gateway TLS | ✅ our CA, `Verify code 0`, `mongosh {ok:1}` |
| Coordinator | ✅ `ssl=on` both pods, 0 SSL errors |
| Coordinator gRPC | ✅ dedicated **isolated grpc-CA** chain (`grpc-ca → grpc-server/grpc-client`), grpc-CA ≠ dcdb-CA |
| Clean env | ✅ 0 cassandra / 0 `DCDB_*` vars |
| Cert ownership | ✅ created by the **ops** controller, consumed by the provisioner |

## Teardown
```bash
kubectl -n demo delete documentdb dcdb-tls   # WipeOut removes PVCs + cascades cert secrets
```
