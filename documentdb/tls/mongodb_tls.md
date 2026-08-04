# TLS / SSL in the KubeDB MongoDB Operator

A deep-dive into how TLS is implemented in `kubedb.dev/mongodb`, written so you can
replicate the same feature in your **DocumentDB** operator — where clients connect with a
**MongoDB driver**, so the MongoDB TLS shape (not the Postgres one) is what matters at the
client edge.

> Source repo: `/home/sabnaj/go/src/kubedb.dev/mongodb`
> Key files: `pkg/ops/certificates.go`, `pkg/ops/mongodb.go`, `pkg/ops/reconfigure_tls.go`,
> `pkg/controller/worker/certificate.go`, `pkg/controller/worker/petset.go`,
> `pkg/controller/utils/util.go` (`InstallInitContainer`),
> `pkg/controller/worker/appbinding.go`, and the API in
> `vendor/kubedb.dev/apimachinery/apis/kubedb/v1/mongodb_types.go` +
> `mongodb_helpers.go`.

> Companion doc: `tls.md` (the Postgres operator). Read both — DocumentDB is a hybrid
> (Postgres engine inside, MongoDB wire-protocol gateway outside), so you need **both**
> mental models. See Section 11.

---

## 1. The big picture — what TLS does in MongoDB

KubeDB MongoDB uses **cert-manager** to issue and rotate X.509 certificates, stores them in
Kubernetes TLS `Secret`s, mounts those secrets into the pods, and starts `mongod`/`mongos`
with `--tlsMode` so the server speaks TLS. The defining differences from Postgres:

1. **One combined PEM file.** MongoDB does *not* take separate cert + key files like
   Postgres' `ssl_cert_file`/`ssl_key_file`. It wants a single `*.pem` containing **cert +
   private key concatenated** (`--tlsCertificateKeyFile`). The operator's init container
   builds that PEM from the cert-manager secret's `tls.crt` + `tls.key`.
2. **x.509 is also an *auth* mechanism, not just transport.** MongoDB can authenticate
   *clients* and *cluster members* by their certificate subject (`--clusterAuthMode=x509`,
   `MONGODB-X509`). So the cert subject DN matters — the client cert's O/OU must differ from
   the server cert's (a Mongo rule, enforced in `SetTLSDefaults`).
3. **sslMode names are Mongo's own:** `disabled / allowSSL / preferSSL / requireSSL`
   (mapped to `--tlsMode=disabled/allowTLS/preferTLS/requireTLS` on Mongo ≥ 4.2).
4. **Per-PetSet server certs in clusters.** In sharded / arbiter / hidden topologies each
   PetSet gets its *own* server cert secret (different DNS SANs), so the cert name carries
   the PetSet name.

Two knobs the user controls in `MongoDB.spec`:

| Field | Type | Meaning |
| ----- | ---- | ------- |
| `spec.tls` | `kmapi.TLSConfig` | issuerRef + per-alias customization. **Presence ≠ on by itself** — `sslMode` drives the server. |
| `spec.sslMode` | `SSLMode` | `disabled / allowSSL / preferSSL / requireSSL`. |
| `spec.clusterAuthMode` | `ClusterAuthMode` | `keyFile / sendKeyFile / sendX509 / x509` — how *replica/shard members* authenticate to each other. |

---

## 2. The API types

From `vendor/kubedb.dev/apimachinery/apis/kubedb/v1/mongodb_types.go`:

```go
// In MongoDBSpec:
ClusterAuthMode ClusterAuthMode  `json:"clusterAuthMode,omitempty"` // keyFile|sendKeyFile|sendX509|x509
SSLMode         SSLMode          `json:"sslMode,omitempty"`         // disabled|allowSSL|preferSSL|requireSSL
TLS             *kmapi.TLSConfig `json:"tls,omitempty"`             // issuerRef + certificates
KeyFileSecret   *core.LocalObjectReference `json:"keyFileSecret,omitempty"` // key.txt for keyFile auth modes
```

### SSL modes (`SSLMode`)

```go
SSLModeDisabled   SSLMode = "disabled"   // server does not use TLS
SSLModeAllowSSL   SSLMode = "allowSSL"   // member traffic plaintext; incoming accepts both
SSLModePreferSSL  SSLMode = "preferSSL"  // member traffic TLS; incoming accepts both
SSLModeRequireSSL SSLMode = "requireSSL" // only TLS
```

These map 1:1 to Mongo's `--sslMode`; for Mongo ≥ 4.2 the operator rewrites the `SSL`
substring to `TLS` (`requireSSL` → `requireTLS`) — see `getTLSArgs` in §6.

### Cluster auth modes (`ClusterAuthMode`)

`keyFile` (shared keyfile), `sendKeyFile`/`sendX509` (rolling-upgrade transitional), `x509`
(mutual cert auth between members — the recommended mode when TLS is on). When TLS is added
via ops, the operator forces `clusterAuthMode=x509`; when removed, back to `keyFile`.

### Certificate aliases (`MongoDBCertificateAlias`)

```go
// +kubebuilder:validation:Enum=server;client;metrics-exporter
MongoDBServerCert          = "server"            // mongod/mongos serving cert (per-PetSet in clusters)
MongoDBClientCert          = "client"            // client/root cert (stash, users, appbinding) — CN=root
MongoDBMetricsExporterCert = "metrics-exporter"  // Prometheus exporter cert
```

Note: **no separate gRPC PKI** here (unlike Postgres' `pg-coordinator`). Mongo reuses the
same server/client certs for member-to-member mutual TLS via `clusterAuthMode=x509`.

### `kmapi.TLSConfig` — the shared building block

Identical to the Postgres doc (`IssuerRef` + `[]CertificateSpec{Alias, IssuerRef,
SecretName, Subject, Duration, RenewBefore, DNSNames, IPAddresses, URIs, EmailAddresses,
PrivateKey}`). KubeDB reuses it across **every** database — which is exactly why DocumentDB
can reuse it too.

---

## 3. Naming helpers & file conventions (apimachinery)

From `mongodb_helpers.go`:

```go
const (
    TLSCACertFileName   = "ca.crt"
    MongoPemFileName    = "mongo.pem"            // server cert+key, built by init container
    MongoClientFileName = "client.pem"           // client cert+key, built by init container
    MongoCertDirectory  = "/var/run/mongodb/tls" // assembled certs live here (shared volume)
)
```

`CertificateName(alias, psName)` / `GetCertSecretName(alias, psName)` — note the **extra
`psName` argument** compared to Postgres. For `server` certs in sharded/replicaset-with-
arbiter topologies the secret name is `<petset>-server-cert`; otherwise `<db>-<alias>-cert`.
`psName` is empty for `client`/`metrics-exporter` (always one secret per DB).

```go
func (m *MongoDB) CertificateName(alias MongoDBCertificateAlias, psName string) string {
    if m.Spec.ShardTopology != nil && alias == MongoDBServerCert { // requires psName
        return meta_util.NameWithSuffix(psName, fmt.Sprintf("%s-cert", alias))
    } else if m.Spec.ReplicaSet != nil && alias == MongoDBServerCert {
        if psName == "" { return meta_util.NameWithSuffix(m.Name, ...) } // general replica
        return meta_util.NameWithSuffix(psName, ...)                     // arbiter/hidden
    }
    return meta_util.NameWithSuffix(m.Name, fmt.Sprintf("%s-cert", alias))
}
```

### `SetTLSDefaults()` — and the Mongo-specific subject rule

Fills default `secretName` for `server`/`client`/`metrics-exporter`, **and sets default
Subjects** so the **client cert's O/OU differ from the server cert's** — MongoDB rejects an
x509 client whose subject equals the server's:

```go
defaultServerOrgUnit := []string{"server"}   // OU for server cert
defaultClientOrgUnit := []string{"client"}   // OU for client cert  → must differ
// O defaults to kubedb.KubeDBOrganization for both, OU disambiguates.
```

For sharded / replicaset+arbiter topologies it deliberately **resets the server secretName
to ""** (so a distinct secret is generated per PetSet).

---

## 4. Who creates the certificates? (same architectural surprise as Postgres)

> The certificate-management code lives in the **`pkg/ops` package** on the ops-manager's
> `Controller`, **not** the provisioner. The ops-manager runs a MongoDB informer
> (`manageMongoDB`) that reacts to every MongoDB object and ensures its certs exist. The
> provisioner only **consumes** the resulting secrets when building pods.

`pkg/ops/mongodb.go`:

```go
func (c *Controller) manageMongoDB(k any) error {
    // ... fetch mongodb ...
    if cutil.IsConditionTrue(mongodb.Status.Conditions, kubedb.DatabasePaused) {
        return nil // skip TLS while paused (ops requests pause the DB)
    }
    return c.manageTLS(mongodb)
}

func (c *Controller) manageTLS(db *dbapi.MongoDB) error {
    if db.Spec.TLS == nil { return nil }
    if !lib.IsServiceReady(...) { return nil }       // wait for governing svc
    // validate IssuerRef.Kind ∈ {Issuer, ClusterIssuer}, and that it exists
    switch db.Spec.TLS.IssuerRef.Kind { case cm_api.IssuerKind: ...; case cm_api.ClusterIssuerKind: ... }

    // server certs depend on topology:
    if standalone        { manageGenericServerCert(db, "") }
    else if replicaSet   { manageCertsForReplicaset(db) }   // + arbiter/hidden PetSets
    else if shard        { manageCertsForShard(db) }        // configsvr + each shard + mongos
    manageGenericClientCert(db, MongoDBClientCert)           // stash/users
    manageGenericClientCert(db, MongoDBMetricsExporterCert)  // exporter
}
```

---

## 5. How each certificate is created (cert-manager `Certificate` CRs)

All use `cm_util.CreateOrPatchCertificate(...)` to create/patch a cert-manager `Certificate`;
cert-manager issues it and writes `ca.crt`/`tls.crt`/`tls.key` into the named secret. The
operator then sets the MongoDB CR as owner of the secret (`ensureOwnerRefToCert` →
`lib.AddOwnerReferenceToSecret`, after waiting for the secret to appear).

### Server cert — `ensureServerCert(db, stsName)` (`pkg/ops/certificates.go`)

- `CommonName = db.ServiceName()`.
- `DNSNames` = `lib.ServiceHosts(...)` (per-PetSet pod DNS) **plus** the governing-service
  wildcard `*.<gov-svc>.<ns>.svc[.cluster-domain]`, `lib.ServiceDNS`, and `localhost`.
  The governing svc is `db.GoverningServiceName(stsName)` when `stsName != ""`.
- `IPAddresses` += `127.0.0.1`.
- `Usages = DigitalSignature, KeyEncipherment, ServerAuth, ClientAuth` — **ClientAuth too**,
  because the server cert doubles as the member's *client* identity for `x509` cluster auth.
- Honors `spec.tls.certificates[alias=server]` overrides (subject/duration/DNS/IP/URI/email).

### Client cert — `ensureClientCert(db, alias)` (for `client` and `metrics-exporter`)

- `CommonName = kubedb.MongoDBRootUsername` (`"root"`) — Mongo maps this DN to the root user
  for `MONGODB-X509` auth.
- `Usages = DigitalSignature, KeyEncipherment, ClientAuth`.
- Optional `AdditionalOutputFormats: CombinedPEM` when `c.pemEncodeCert` is set on the ops
  Controller (emits a ready-made combined PEM in the secret).

There is **no gRPC/coordinator PKI** to manage (contrast Postgres §5).

---

## 6. How certs get into the pod (provisioner side)

### Step 1 — wait for the secrets — `IsCertificateSecretsCreated` (`worker/certificate.go`)

The provisioner will not build PetSets until **all** required cert secrets exist. The set is
topology-aware: configsvr + every shard (+ arbiter/hidden) + mongos for sharded;
server (+ arbiter/hidden) for replicaset; always the `client` and `metrics-exporter`
secrets. Uses `dynamic_util.ResourcesExists(...)` and relies on re-enqueue on secret events.

### Step 2 — assemble the combined PEM in an init container (`utils/util.go` `InstallInitContainer`)

This is the **central Mongo-specific mechanic**. cert-manager secrets contain *separate*
`tls.crt`/`tls.key`, but mongod wants them **concatenated**. So:

- The init container mounts the **raw** secrets read-only:
  - `client` secret → `MongoDBClientCertDirectoryPath` (`/client-cert`)
  - `server` secret (for this PetSet) → `MongoDBServerCertDirectoryPath` (`/server-cert`)
- It runs the image's `install.sh`, gated by an `SSL_MODE` env var (set to the real
  `spec.sslMode`, or `disabled` when TLS is off). The script `cat`s `tls.crt`+`tls.key`
  into `mongo.pem` (server) and `client.pem` (client) and copies `ca.crt`, writing the
  final layout into the **shared** `certdir` volume mounted at `MongoCertDirectory`
  (`/var/run/mongodb/tls`).

```go
if db.Spec.TLS != nil {
    mounts += {MongoDBClientCertDirectoryName:/client-cert, MongoDBServerCertDirectoryName:/server-cert}
    initVolumes += secret volumes for GetCertSecretName(client,"") and GetCertSecretName(server, psName)
}
// SSL_MODE env tells install.sh whether to build the PEMs
```

If `keyFileSecret` is set (keyFile cluster auth) it is mounted too.

### Step 3 — tell mongod/mongos to use TLS via args — `getTLSArgs` (`worker/certificate.go`)

```go
// Mongo >= 4.2:
--tlsMode=<requireTLS|preferTLS|allowTLS|disabled>
// when sslMode != disabled, also:
--tlsCAFile=/var/run/mongodb/tls/ca.crt
--tlsCertificateKeyFile=/var/run/mongodb/tls/mongo.pem
--tlsAllowConnectionsWithoutCertificates
// Mongo < 4.2 uses the --ssl* spellings (--sslMode/--sslCAFile/--sslPEMKeyFile/...)
```

`--tlsAllowConnectionsWithoutCertificates` lets password-auth clients connect over TLS
without presenting a client cert (so TLS-transport and x509-auth are decoupled).

### Step 4 — exporter & probes

- Exporter URI gets `?tls=true&tlsCAFile=.../ca.crt&tlsCertificateKeyFile=.../client.pem`
  (`worker/petset.go` `getExporterContainer`); the cert dir volume is mounted into the
  exporter container.
- Liveness/readiness probes build `--tls --tlsCAFile=... --tlsCertificateKeyFile=...`
  (`mongodb_helpers.go` `getCmdForProbes`), version-aware (`--ssl*` spellings pre-4.1,
  `--tlsPEMKeyFile` for the 4.1.4 exception).

### Step 5 — AppBinding (`worker/appbinding.go`)

```go
in.Spec.ClientConfig.Service = { Scheme:"mongodb", Name: db.ServiceName(), Port: port }
in.Spec.ClientConfig.InsecureSkipTLSVerify = false
caBundle, secret := getAppBindingCABundleAndSecret(db) // only when sslMode∈{require,prefer} && TLS!=nil
in.Spec.ClientConfig.CABundle = caBundle               // = ca.crt from the *client* cert secret
if caBundle != nil { in.Spec.TLSSecret = { Kind:Secret, Name: <client-cert secret> } }
in.Spec.Secret = db.Spec.AuthSecret                    // username/password
```

So a consumer reads the CA from the AppBinding and the full client PEM from `TLSSecret`.

---

## 7. Validation (admission webhook)

`vendor/.../pkg/webhooks/kubedb/v1/mongodb.go`:

```go
// x509 (or sendX509) cluster auth needs real TLS (not disabled/allowSSL):
if (clusterAuthMode == x509 || sendX509) && (sslMode == disabled || sslMode == allowSSL) { error }
// sendKeyFile + disabled is contradictory:
if clusterAuthMode == sendKeyFile && sslMode == disabled { error }
```

The recurring theme: an x509-based *auth* mode requires TLS *transport* to actually be on.

---

## 8. Day-2: ReconfigureTLS OpsRequest (`pkg/ops/reconfigure_tls.go`)

A `MongoDBOpsRequest` of type `ReconfigureTLS`. Top-level `ReconfigureTLS()` drives a
condition-gated state machine (each `RunParallel` step records a condition so a requeue
resumes where it left off). High-level flow:

1. Move ops request to `Progressing`; **pause** the MongoDB and wait for `DatabasePaused`
   (so provisioner + cert controller stop fighting).
2. DeepCopy the DB and branch on the request:
   - **Remove** (`tls.remove=true`) → `whenTLSConfigToBeRemoved`: force `sslMode=disabled`,
     `clusterAuthMode=keyFile`, `TLS=nil`, null out probes, `SetDefaults`, push PetSets
     (`newUpdateTLS`), restart pods, patch the real DB, then **delete every Certificate CR
     and its secret** under the DB's selector.
   - **Rotate / change** (`rotateCertificates` or certs/issuer changed) →
     `whenTLSConfigToBeChanged`: merge updated certs, `SetTLSDefaults`, compute which
     aliases changed, snapshot each cert's `Status.Revision` into a `revisionMap`. For
     rotation, set `CertificateConditionIssuing=true` on the relevant certs to force
     re-issue. Stash the old client-cert secret as `<db>-old-cert` (rollback/connectivity
     during transition), patch DB `spec.tls`, `manageTLS` + `Reconcile`, then **wait for
     `cert.Status.Revision` to advance** (`newCheckCertVersion`), restart pods, delete the
     `-old-cert` secret.
   - **Add** (no prior TLS) → `whenTLSConfigToBeAdded`: set `sslMode=requireSSL`,
     `clusterAuthMode=x509`, clear `keyFileSecret`, null probes, `SetDefaults`, push PetSets
     (`newUpdateTLS` → `manageTLS` + `Reconcile`, then wait until each PetSet's init
     container `SSL_MODE` env equals the target), restart pods, patch the real DB.
3. `reconfigureTLSSucceeded`: resume DB, resume paused backups, mark ops request
   `Successful`.

`newUpdateTLS.run()` is the shared worker: `manageTLS(updatedDB)` (issue/patch certs) →
`Reconcile(updatedDB, true)` (re-render PetSets) → confirm the `SSL_MODE` env propagated.

---

## 9. Cross-repo wiring

| Concern | Package | Runs in |
| ------- | ------- | ------- |
| Create/rotate Certificate CRs, react to MongoDB objects | `pkg/ops` (`Controller.manageMongoDB` / `manageTLS`) | **ops-manager** |
| Wait for secrets, assemble PEMs (init container), set `--tls*` args, AppBinding | `pkg/controller/worker` + `utils` | **provisioner** |
| `ReconfigureTLS` ops handling | `pkg/ops` (`mongoOpsReqController`) | **ops-manager** |

cert-manager schemes (`cm_api`, `cmmeta`) must be registered in the cmd/root and webhook
server. Cross-module `Reconciler` fields set by ops-manager must be exported.

---

## 10. Minimal example (MongoDB)

```yaml
apiVersion: kubedb.com/v1
kind: MongoDB
metadata: { name: mgo-tls, namespace: demo }
spec:
  version: "7.0.x"
  replicaSet: { name: rs0 }
  replicas: 3
  storageType: Durable
  storage: { resources: { requests: { storage: 1Gi } } }
  sslMode: requireSSL
  clusterAuthMode: x509          # mutual member TLS; use keyFile for password-only
  tls:
    issuerRef: { apiGroup: cert-manager.io, kind: Issuer, name: mongo-issuer }
    certificates:
      - alias: server
        subject: { organizations: ["kubedb"], organizationalUnits: ["server"] }
      - alias: client
        subject: { organizations: ["kubedb"], organizationalUnits: ["client"] } # must differ from server
```

Rotate / change later:

```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: MongoDBOpsRequest
metadata: { name: mgo-recfg-tls, namespace: demo }
spec:
  type: ReconfigureTLS
  databaseRef: { name: mgo-tls }
  tls:
    rotateCertificates: true      # or remove: true to strip TLS
```

---

## 11. Adapting this to **DocumentDB** (the important part)

### 11.1 What DocumentDB actually is (and why this changes the plan)

DocumentDB is a **hybrid**:

- **Inside the pod:** a PostgreSQL engine (the `documentdb-init-docker` scripts are pure
  Postgres — `bootstrap_scripts/17`, `role_scripts/17/{primary,standby}`, `pg_basebackup`,
  `postgresql.conf` with `ssl_cert_file`). This is the Postgres TLS model from `tls.md`.
- **At the client edge:** a **MongoDB wire-protocol gateway** (`documentdb_gateway`,
  service port `10260` = `DocumentDBGatewayPort`). Your users connect with the **MongoDB
  driver**, so *this* leg must follow the MongoDB TLS shape from this doc.

So there are **two TLS legs**, and they are independent:

```
mongo driver ──TLS(mongo)──▶ documentdb_gateway ──(localhost, plaintext today)──▶ postgres engine
   §this doc (mongodb_tls.md)                          §tls.md (postgres) — optional, internal
```

The leg your users care about, and the one that must look like MongoDB, is the
**gateway leg**.

### 11.2 Current state in your repo (verified)

- `pkg/ops/pg_client.go` and `pkg/ops/postgres.go` say *"TLS is not yet supported for
  DocumentDB; the backend postgres runs with SSL off, connect with sslmode=disable."* So the
  **Postgres leg has no operator-managed TLS yet**.
- `DocumentDBSpec` has **no `TLS` field and no `SSLMode` field** — only
  `ClientAuthMode DocDBClientAuthMode` (`scram` default, also `cert`). The PetSet hardcodes
  `SSL_MODE=disable` (`pkg/controllers/petset.go`).
- **But the gateway already serves TLS.** The health-check client
  (`pkg/controllers/client.go`) connects with `tls=true` + `InsecureSkipVerify:true` — i.e.
  the gateway presents *some* cert today (almost certainly a self-signed one baked/generated
  in the image), and the operator just skips verification.
- The apimachinery **already defines the gateway TLS surface** (so the wiring is half-done):
  ```go
  EnvDocumentDBTLSPort  = "DOCUMENTDB_LISTEN_TLS"            // enable TLS listener
  EnvDocumentDBCAPath   = "DOCUMENTDB_LISTEN_TLS_CA_FILE"
  EnvDocumentDBCertPath = "DOCUMENTDB_LISTEN_TLS_CERT_FILE"
  EnvDocumentDBKeyPath  = "DOCUMENTDB_LISTEN_TLS_KEY_FILE"
  DocumentDBServerPath         = "/etc/certs/server"         // where to mount the server cert
  DocumentDBExternalClientPath = "/etc/certs/ext"            // where to mount the client/CA
  DocumentDBTLSPort     = 27018
  ```
  Critically, the gateway takes **separate cert + key files** (`..._CERT_FILE` /
  `..._KEY_FILE`), **not** a combined `mongo.pem`. So you can feed it cert-manager's
  `tls.crt`/`tls.key` **directly** — you do **not** need MongoDB's PEM-concatenation init
  container for the gateway leg. (That's the one piece of §6 you can skip.)

### 11.3 The structural mapping (MongoDB → DocumentDB)

| MongoDB concept | DocumentDB equivalent |
| --------------- | --------------------- |
| `mongod` serves `--tlsMode`/`--tlsCertificateKeyFile` | `documentdb_gateway` serves via `DOCUMENTDB_LISTEN_TLS*` env vars |
| `mongo.pem` (combined cert+key) | **not needed** — gateway takes `..._CERT_FILE` + `..._KEY_FILE` separately → mount `tls.crt`/`tls.key` straight from the secret |
| `MongoCertDirectory` `/var/run/mongodb/tls` | `DocumentDBServerPath` `/etc/certs/server`, `DocumentDBExternalClientPath` `/etc/certs/ext` (already defined) |
| `SSLMode` (`requireSSL`...) | add a `spec.sslMode` (or reuse a simple on/off via `spec.tls != nil`) driving `DOCUMENTDB_LISTEN_TLS` |
| `clusterAuthMode=x509` (member mutual TLS) | the **Postgres replication leg** uses `clientAuthMode=cert` + the Postgres gRPC/coordinator PKI — that's the `tls.md` story, separate from the gateway |
| `MongoDBCertificateAlias{server,client,metrics-exporter}` | `DocumentDBCertificateAlias{server,client,metrics-exporter}` — same three |
| `CertificateName(alias, psName)` | DocumentDB is replicaset-style; you can drop `psName` (one server-cert secret) → use the **Postgres-style** `CertificateName(alias)` |
| init container that `cat`s tls.crt+tls.key → mongo.pem | **omit for gateway**; if you also enable Postgres-engine TLS, the Postgres init scripts already reference `/tls/certs/server/server.crt` |
| AppBinding `Scheme:"mongodb"`, CABundle from client secret | **same** — DocumentDB AppBinding already uses `Scheme:"mongodb"`; add CABundle + TLSSecret |

### 11.4 Concrete checklist for DocumentDB

**A. API (apimachinery `kubedb/v1alpha2/documentdb_types.go` + helpers)**
1. Add `TLS *kmapi.TLSConfig` to `DocumentDBSpec`. Add an SSL knob — simplest is to treat
   `spec.tls != nil` as "gateway TLS on"; or add an explicit `spec.sslMode`
   (`disabled/requireSSL`) if you want preferSSL-style behavior. You already have
   `ClientAuthMode` (`scram`/`cert`).
2. Add `DocumentDBCertificateAlias` enum: `server`, `client`, `metrics-exporter`
   (kubebuilder enum), mirroring Mongo.
3. Add helpers `CertificateName(alias)`, `GetCertSecretName(alias)`, `SetTLSDefaults()`.
   Borrow the **Postgres** versions (no `psName` — DocumentDB is single-replicaset). Keep
   the Mongo **subject rule** (client OU ≠ server OU) *only if* you enable x509-style client
   auth at the gateway.
4. Webhook validation: if `clientAuthMode=cert` then TLS must be on; `sslMode!=disabled`
   requires `tls!=nil` (copy the `tls.md` Postgres checks; they're closer to your engine).

**B. Cert management (ops-manager, new `pkg/ops/certificates.go` + hook in `pkg/ops/postgres.go`)**
5. Add `manageTLS(db)` driven from the existing DocumentDB event handler (today
   `pkg/ops/postgres.go` early-returns "no tls processing" — replace that). Validate
   issuerRef, then `ensureServerCert` + `ensureClientCert(client)` +
   `ensureClientCert(metrics-exporter)` via `cm_util.CreateOrPatchCertificate`. Copy the
   server SAN logic (governing-svc wildcard, service DNS, localhost, 127.0.0.1).
6. Set the DocumentDB CR as owner of each secret. Validate the Issuer/ClusterIssuer exists.

**C. Provisioner (`pkg/controllers/petset.go`, `reconcile.go`, `appbinding.go`)**
7. In reconcile, block PetSet creation until the cert secrets exist (re-enqueue on secret
   events) — mirror `IsCertificateSecretsCreated`.
8. In the PetSet builder, mount the **server** cert secret at `DocumentDBServerPath`
   (`/etc/certs/server`) and the **client/CA** at `DocumentDBExternalClientPath`
   (`/etc/certs/ext`). **No PEM-combining init container needed** for the gateway.
9. Replace the hardcoded gateway TLS handling: set the env vars on the gateway/`documentdb`
   container —
   ```
   DOCUMENTDB_LISTEN_TLS          = <on when tls!=nil>
   DOCUMENTDB_LISTEN_TLS_CA_FILE  = /etc/certs/ext/ca.crt
   DOCUMENTDB_LISTEN_TLS_CERT_FILE= /etc/certs/server/tls.crt
   DOCUMENTDB_LISTEN_TLS_KEY_FILE = /etc/certs/server/tls.key
   ```
   and stop relying on the self-signed gateway cert + `InsecureSkipVerify`.
10. Health-check client (`pkg/controllers/client.go`): once a real CA exists, drop
    `InsecureSkipVerify:true` and load the CA from the client cert secret (RootCAs pool),
    matching the AppBinding.
11. AppBinding (`pkg/controllers/appbinding.go`): you already use `Scheme:"mongodb"` and
    `InsecureSkipTLSVerify=false`. Add `ClientConfig.CABundle = <ca.crt from client secret>`
    and `TLSSecret = {Secret, <client-cert secret>}` when TLS is on.

**D. (Optional) Postgres-engine leg** — if you also want the *internal* gateway→postgres and
   replication traffic encrypted, that's the `tls.md` story: the init scripts already have
   `ssl_cert_file = '/tls/certs/server/server.crt'` hooks; flip `SSL_MODE` off→on in
   `petset.go` and feed the server cert there too. Independent of the gateway leg.

**E. Day-2 ops** — add a `DocumentDBOpsRequest` `ReconfigureTLS` modeled on
   `reconfigure_tls.go`: pause → add/rotate/remove (issue/patch certs, force re-issue via
   `Issuing` condition, wait for `Status.Revision` to advance) → reconcile PetSets → restart
   pods → patch DB → clean up orphaned certs/secrets → resume.

**F. Plumbing** — register cert-manager schemes in cmd/root + webhook server; vendor
   `cert-manager`, `kmodules.xyz/cert-manager-util`, `kmodules.xyz/client-go/api/v1`
   (`TLSConfig`); export any cross-module Reconciler fields. cert-manager + an
   Issuer/ClusterIssuer must exist in the cluster.

### 11.5 The one-line summary

> For DocumentDB, **follow MongoDB's *API/cert-management* structure** (aliases
> server/client/metrics-exporter, `kmapi.TLSConfig`, ops-manager issues certs, AppBinding
> exposes CABundle+TLSSecret, `ReconfigureTLS` day-2), but **skip MongoDB's PEM-combining
> init container** — the `documentdb_gateway` already accepts separate
> `DOCUMENTDB_LISTEN_TLS_CERT_FILE`/`..._KEY_FILE`, so mount cert-manager's `tls.crt`/
> `tls.key` directly. The gateway leg = MongoDB-shaped (this doc); the optional internal
> Postgres-engine leg = Postgres-shaped (`tls.md`).
```
