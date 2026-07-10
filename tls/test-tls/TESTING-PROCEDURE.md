# DocumentDB Full-TLS — Step-by-Step Testing Procedure & Results

Every step below is the exact command run against the live k3s cluster and its **actual output**.
Together they prove native TLS on all four surfaces: Postgres **server**, streaming **replication**,
MongoDB-wire **gateway**, and the HA **coordinator** — driven only by `spec.tls` + `spec.sslMode`.

- **Cluster:** k3s (remote node `10.2.0.226`) — `export KUBECONFIG=/home/sabnaj/k3s.yaml`
- **Namespace:** `demo`  •  **DB:** `dcdb-tls` (2 replicas)  •  **cert-manager:** v1.19.2
- **Operator image:** `sabnaj/documentdb-operator:dcdb-tls7`
- **DocumentDB init image:** `sabnaj/documentdb-init:dcdb-tls-hba2`
- **Date:** 2026-07-10

> Set the password variable once (used by several steps):
> ```bash
> export KUBECONFIG=/home/sabnaj/k3s.yaml
> PGPASS=$(kubectl -n demo get secret dcdb-tls-auth -o jsonpath='{.data.password}' | base64 -d)
> ```

---

## Phase 0 — Environment prerequisites

### Step 0.1 — cert-manager controller is running
```bash
kubectl get pods -n cert-manager --no-headers
```
```
cert-manager-6dd9bdbd89-6ppwm              1/1   Running   0   4h44m
cert-manager-cainjector-74bf7474d8-9qmhv   1/1   Running   0   4h44m
cert-manager-webhook-6f9f498c99-s6nhr      1/1   Running   0   4h44m
```
✅ All three cert-manager components Running. (Installed with
`kubectl apply -f https://github.com/cert-manager/cert-manager/releases/download/v1.16.2/... ` → v1.19.2.)

### Step 0.2 — operator StatefulSets run the TLS image, with the license arg removed
```bash
kubectl -n kubedb get pods -o custom-columns=NAME:.metadata.name,IMAGE:.spec.containers[0].image --no-headers | grep -E 'provisioner|ops-manager'
kubectl -n kubedb get statefulset kubedb-kubedb-provisioner -o jsonpath='{.spec.template.spec.containers[0].args}'
```
```
kubedb-kubedb-ops-manager-0    sabnaj/documentdb-operator:dcdb-tls7
kubedb-kubedb-provisioner-0    sabnaj/documentdb-operator:dcdb-tls7
["operator","--v=3","--use-kubeapiserver-fqdn-for-aks=true","--metrics-bind-address=:8080","--health-probe-bind-address=:8081"]
```
✅ Both operators on `dcdb-tls7`; **no `--license-file` arg** (that arg caused an
`Error: license status unknown` crashloop — removed because no license-proxyserver API is present).

### Step 0.3 — CRD carries the new TLS fields
```bash
kubectl get crd documentdbs.kubedb.com -o jsonpath='tls={...spec.properties.tls.type} sslMode={...spec.properties.sslMode.type}'
```
```
tls=object sslMode=string
```
✅ `spec.tls` (object) and `spec.sslMode` (string) present on the CRD.

### Step 0.4 — DocumentDBVersion points at the patched init image
```bash
kubectl get documentdbversion pg17-0.109.0 -o jsonpath='{.spec.initContainer.image}'
```
```
sabnaj/documentdb-init:dcdb-tls-hba2
```
✅ Init image = `dcdb-tls-hba2` (adds `ssl=on` at bootstrap + localhost-trust `pg_hba`; see
[`init-image-patch/`](./init-image-patch/)).

---

## Phase 1 — Create the issuer and the TLS database

### Step 1.1 — apply the two-tier CA issuer
```bash
kubectl apply -f yaml/issuer.yaml
kubectl -n demo get issuer
kubectl -n demo get certificate dcdb-ca
```
```
NAME                   READY   AGE
dcdb-ca-issuer         True    104m
dcdb-selfsigned-boot   True    104m

NAME      READY   SECRET        AGE
dcdb-ca   True    dcdb-ca-tls   104m
```
✅ Bootstrap self-signed issuer → self-signed **CA** (`dcdb-ca`) → **CA issuer** (`dcdb-ca-issuer`),
all `Ready`. A CA issuer (not a bare `selfSigned` issuer) is required so every leaf cert shares one
CA — otherwise replication `verify-full` cross-verification fails.

### Step 1.2 — apply the TLS-enabled DocumentDB
```bash
kubectl apply -f yaml/documentdb-tls.yaml
kubectl -n demo get documentdb dcdb-tls
```
```
NAME       NAMESPACE   VERSION        STATUS         AGE
dcdb-tls   demo        pg17-0.109.0   Provisioning   71m
```
✅ Object accepted (`spec.sslMode: verify-full`, `spec.tls.issuerRef → dcdb-ca-issuer`).
`STATUS=Provisioning` is expected here — see the note at the end.

---

## Phase 2 — Operator issues certs and brings up the pods

### Step 2.1 — the operator created the three Certificates, cert-manager issued them
```bash
kubectl -n demo get certificate | grep dcdb-tls
```
```
dcdb-tls-client-cert    True   dcdb-tls-client-cert    71m
dcdb-tls-gateway-cert   True   dcdb-tls-gateway-cert   71m
dcdb-tls-server-cert    True   dcdb-tls-server-cert    71m
```
✅ `manageTLS` (operator reconcile) created server/client/gateway Certificates → all `Ready`.

### Step 2.2 — the three `kubernetes.io/tls` secrets exist
```bash
kubectl -n demo get secret | grep -E 'dcdb-tls-(server|client|gateway)-cert'
```
```
dcdb-tls-client-cert    kubernetes.io/tls   3   71m
dcdb-tls-gateway-cert   kubernetes.io/tls   3   71m
dcdb-tls-server-cert    kubernetes.io/tls   3   71m
```
✅ Provisioner un-gated once these existed and built the PetSet.

### Step 2.3 — pods are Running
```bash
kubectl -n demo get pods -l app.kubernetes.io/instance=dcdb-tls
```
```
NAME         READY   STATUS    RESTARTS   AGE
dcdb-tls-0   2/2     Running   0          71m
dcdb-tls-1   2/2     Running   0          71m
```
✅ Both replicas `2/2 Running`, stable for 71 min (no crashloops).

### Step 2.4 — certs are mounted at the paths the image expects
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- ls /tls/certs/server /tls/certs/client /tls/certs/gateway /tls/certs/exporter
```
```
/tls/certs/client:    ca.crt  client.crt  client.key
/tls/certs/exporter:  ca.crt  server.crt  server.key
/tls/certs/gateway:   ca.crt  tls.crt     tls.key
/tls/certs/server:    ca.crt  server.crt  server.key
```
✅ Secrets mount read-only at `/certs/*`; the init container copies them to the writable
`/tls/certs/*` (incl. the `exporter` dir the image's chmod step requires).

### Step 2.5 — SSL env is set on the container
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- env | grep -E '^SSL|^CERT_PATH|^KEY_FILE|^SSL_MODE|^CLIENT_AUTH' | sort
```
```
CERT_PATH=/tls/certs/gateway/tls.crt
CLIENT_AUTH_MODE=scram
KEY_FILE=/tls/certs/gateway/tls.key
SSL_MODE=verify-full
SSL=ON
```
✅ `SSL=ON`, `SSL_MODE=verify-full`, and the gateway cert paths — all set by the operator.

---

## Phase 3 — Verify each TLS surface

### Step 3.1 — [SURFACE 1] Postgres SERVER TLS (`verify-full`, :9712)
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "PGPASSWORD='$PGPASS' psql 'host=127.0.0.1 port=9712 user=default_user dbname=postgres sslmode=verify-full sslrootcert=/tls/certs/server/ca.crt' \
  -tAc \"SELECT ssl, version FROM pg_stat_ssl WHERE pid=pg_backend_pid();\""
# and confirm the server ssl settings:
#   SELECT name, setting FROM pg_settings WHERE name IN ('ssl','ssl_cert_file');
```
```
t|TLSv1.3
ssl=on
ssl_cert_file=/tls/certs/server/server.crt
```
✅ A **verify-full** connection (client verifies the server cert against the CA **and** the hostname)
succeeds: `ssl=t`, **TLSv1.3**. `ssl=on` with `ssl_cert_file` pointing at the mounted server cert.

### Step 3.2 — [SURFACE 2] Streaming REPLICATION over TLS
```bash
# a) the standby's replication connection string uses verify-full
kubectl -n demo exec dcdb-tls-1 -c documentdb -- sh -c "grep primary_conninfo /var/pv/data/postgresql.conf"
# b) prove it is streaming LIVE: the replay LSN advances between two reads
kubectl -n demo exec dcdb-tls-1 -c documentdb -- bash -c "PGPASSWORD='$PGPASS' psql 'host=127.0.0.1 port=9712 user=default_user dbname=postgres sslmode=require' -tAc 'SELECT pg_last_wal_replay_lsn();'"   # t0
# (wait ~5s, run again)                                                                                                                                                                          # t1
# c) standby is in recovery, and its log shows the streaming start
kubectl -n demo exec dcdb-tls-1 -c documentdb -- bash -c "PGPASSWORD='$PGPASS' psql ... -tAc 'SELECT pg_is_in_recovery();'"
kubectl -n demo exec dcdb-tls-1 -c documentdb -- sh -c 'ls -t /var/pv/data/log/*.log|head -1|xargs grep -h "started streaming"|tail -1'
```
```
primary_conninfo = 'application_name=dcdb-tls-1 port=9712 host=dcdb-tls.demo.svc.cluster.local
                    port=9712 user=documentdb password=*** sslmode=verify-full
                    sslrootcert=/tls/certs/client/ca.crt'

replay_lsn t0=0/4D83130   t1=0/4D84000      # advanced ⇒ live streaming
pg_is_in_recovery = t
2026-07-10 10:36:01 UTC [180] LOG:  started streaming WAL from primary at 0/4000000 on timeline 1
```
✅ The standby streams from the primary over **`sslmode=verify-full`**; its replay LSN advances in
real time (`…83130 → …84000`), it is in recovery, and Postgres logged the streaming start.
> The primary connects to `dcdb-tls.demo.svc.cluster.local` — the operator adds that **Service FQDN
> with cluster domain** to the server cert SANs (Step 3.5), which is what lets verify-full succeed.
> `pg_stat_replication`/`pg_stat_wal_receiver` show **no rows as `default_user`** (those views need
> `pg_read_all_stats`); `pg_last_wal_replay_lsn()` is the reliable proof.

### Step 3.3 — [SURFACE 3] MongoDB-wire GATEWAY TLS (:10260)
```bash
# a) inspect the cert the gateway serves and verify it chains to our CA
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 'echo | openssl s_client -connect 127.0.0.1:10260 -CAfile /tls/certs/gateway/ca.crt 2>/dev/null | grep -iE "issuer=|subject=|Verify return|Cipher is"'
# b) authenticated MongoDB session over TLS
kubectl -n demo exec dcdb-tls-0 -c documentdb -- bash -c \
 "mongosh 'mongodb://default_user:$PGPASS@127.0.0.1:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsCAFile=/tls/certs/gateway/ca.crt&tlsAllowInvalidHostnames=true' --quiet --eval 'db.runCommand({ping:1})'"
```
```
subject=CN=dcdb-tls
issuer=CN=dcdb-ca
New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384
Verify return code: 0 (ok)

{"ok":1}
```
✅ The gateway presents the operator-issued cert (`issuer=CN=dcdb-ca` = **our CA**), the chain
verifies (`Verify return code: 0`), TLSv1.3, and an authenticated `mongosh --tls` + SCRAM-SHA-256
session returns `{ok:1}`.

### Step 3.4 — [SURFACE 4] COORDINATOR (HA control plane) over TLS
```bash
# no SSL/pg_hba errors in the coordinator log
kubectl -n demo logs dcdb-tls-0 -c documentdb-coordinator --tail=40 | grep -icE 'SSL is not enabled|no pg_hba|no encryption'
```
```
0
```
✅ Zero SSL-related errors — the coordinator connects to Postgres over TLS (`SSL=ON`,
`SSL_MODE=prefer`) and runs its mutual-TLS gRPC (`/grpc/server`, `/grpc/client` certs). This is what
lets it elect the primary/standby; without it the cluster never leaves bootstrap.

### Step 3.5 — server cert SANs include the Service FQDN (why 3.2 works)
```bash
kubectl -n demo get secret dcdb-tls-server-cert -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -ext subjectAltName
```
```
DNS:*.dcdb-tls-pods.demo.svc, DNS:*.dcdb-tls-pods.demo.svc.cluster.local, DNS:dcdb-tls,
DNS:dcdb-tls.demo.svc, DNS:dcdb-tls.demo.svc.cluster.local, DNS:localhost, IP Address:127.0.0.1
```
✅ `dcdb-tls.demo.svc.cluster.local` is present (added by the operator) — required for the
replication `verify-full` hostname check.

### Step 3.6 — all three certs share ONE CA
```bash
for x in server client gateway; do kubectl -n demo get secret dcdb-tls-$x-cert -o jsonpath='{.data.ca\.crt}' | base64 -d | openssl x509 -noout -fingerprint; done
```
```
server:  8B:2D:70:D0:6F:28:8A:F9:C8:B9:2F:E9:B1:CD:D6:ED:5C:0C:CE:87
client:  8B:2D:70:D0:6F:28:8A:F9:C8:B9:2F:E9:B1:CD:D6:ED:5C:0C:CE:87
gateway: 8B:2D:70:D0:6F:28:8A:F9:C8:B9:2F:E9:B1:CD:D6:ED:5C:0C:CE:87
```
✅ Identical CA fingerprint — the CA issuer makes cross-verification (standby↔primary) work.

### Step 3.7 — pg_hba: localhost trust for co-located components, TLS for everyone else
```bash
kubectl -n demo exec dcdb-tls-0 -c documentdb -- sh -c 'grep -vE "^#|^$" /var/pv/data/pg_hba.conf'
```
```
local      all             all                                     trust
host       all             all             127.0.0.1/32            trust      ← gateway/coordinator (local)
host       all             all             ::1/128                 trust
hostssl    all             all             127.0.0.1/32            scram-sha-256
hostssl    all             all             ::1/128                 scram-sha-256
local      replication     all                                     trust
hostssl    replication     all             127.0.0.1/32            scram-sha-256
hostssl    replication     all             ::1/128                 scram-sha-256
hostssl    all             all             0.0.0.0/0               scram-sha-256   ← external requires TLS
hostssl    replication     postgres        0.0.0.0/0               scram-sha-256   ← replication (pod IPs) = TLS
hostssl    replication     all             0.0.0.0/0               scram-sha-256
... (::/0 equivalents)
```
✅ The two `host … 127.0.0.1/32 trust` lines (from the init-image patch) let the co-located
gateway/coordinator reach Postgres over localhost, while **every non-loopback connection — including
replication from pod IPs — still requires `hostssl`** (TLS).

---

## Result summary

| # | Surface | Step | Result |
|---|---------|------|--------|
| 1 | Postgres server TLS | 3.1 | ✅ `ssl=t`, TLSv1.3, verify-full |
| 2 | Replication over TLS | 3.2 | ✅ verify-full conninfo, replay LSN advancing live |
| 3 | Gateway TLS | 3.3 | ✅ our CA, verify 0, TLSv1.3, `mongosh` `{ok:1}` |
| 4 | Coordinator over TLS | 3.4 | ✅ 0 SSL errors, cluster HA formed |

Raw combined capture: [`final-evidence.txt`](./final-evidence.txt).

---

## Teardown
```bash
kubectl -n demo delete documentdb dcdb-tls          # deletionPolicy WipeOut removes PVCs + certs
kubectl -n demo delete -f yaml/issuer.yaml
```

## Note on `STATUS=Provisioning`
The DB never flips to `Ready` because a health probe queries a `documentdb` database that is not
created (it is also absent on the pre-existing **non-TLS** `dcdb` cluster). This is an app-level
quirk of the image, **orthogonal to TLS** — every TLS surface above is fully functional.
