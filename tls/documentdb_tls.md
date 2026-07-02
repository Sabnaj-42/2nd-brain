# TLS / SSL in the KubeDB Postgres Operator

A deep-dive into how TLS is implemented in `kubedb.dev/postgres`, written so you can
replicate the same feature in your **DocumentDB** operator.

> Source repo: `/home/sabnaj/go/src/kubedb.dev/postgres`
> Key files: `pkg/ops/certificates.go`, `pkg/ops/postgres.go`, `pkg/ops/reconfigure_tls.go`,
> `pkg/controller/petset.go`, `pkg/controller/secret.go`, `pkg/controller/reconciler.go`,
> `pkg/controller/appbinding.go`, and the API in `vendor/kubedb.dev/apimachinery/apis/kubedb/v1/postgres_types.go`.

---

## 1. The big picture — what TLS does here

KubeDB Postgres uses **cert-manager** to issue and rotate X.509 certificates, stores them
in Kubernetes TLS `Secret`s, mounts those secrets into the Postgres pods, and configures
PostgreSQL to serve over SSL. It supports:

1. **Server TLS** — Postgres serves encrypted connections (`ssl=on`, `sslmode` enforcement).
2. **Client/mutual TLS** — clients (and the operator itself, stash, exporter) authenticate
   with client certificates (`clientcert`/`cert` auth).
3. **gRPC TLS** — a *separate, internal* PKI used by the `pg-coordinator` sidecars to talk to
   each other over the Raft/gRPC control plane.
4. **Metrics exporter TLS** — the Prometheus exporter talks to Postgres over TLS.
5. **Day-2 TLS ops** — a `PostgresOpsRequest` of type `ReconfigureTLS` can add, update,
   rotate, or remove TLS on a running cluster.

There are two distinct knobs the user controls:

| Field (in`Postgres.spec`) | Type                       | Meaning                                                                                      |
| --------------------------- | -------------------------- | -------------------------------------------------------------------------------------------- |
| `spec.tls`                | `kmapi.TLSConfig`        | issuerRef + per-alias certificate customization.**Presence of this turns TLS on.**     |
| `spec.sslMode`            | `PostgresSSLMode`        | `disable;allow;prefer;require;verify-ca;verify-full` — how strict the server/clients are. |
| `spec.clientAuthMode`     | `PostgresClientAuthMode` | `md5;scram;cert` — how clients authenticate. `cert` = mutual TLS.                       |

---

## 2. The API types

From `vendor/kubedb.dev/apimachinery/apis/kubedb/v1/postgres_types.go`:

```go
// In PostgresSpec:
ClientAuthMode PostgresClientAuthMode `json:"clientAuthMode,omitempty"` // md5 | scram | cert
SSLMode        PostgresSSLMode        `json:"sslMode,omitempty"`        // disable|allow|prefer|require|verify-ca|verify-full
TLS            *kmapi.TLSConfig       `json:"tls,omitempty"`            // issuerRef + certificates
```

### SSL modes (`PostgresSSLMode`)

`disable`, `allow`, `prefer`, `require`, `verify-ca`, `verify-full` — these map 1:1 to
PostgreSQL's libpq sslmode semantics.

### Client auth modes (`PostgresClientAuthMode`)

- `md5` — challenge/response (default for PG < 18).
- `scram` — SCRAM-SHA-256 (requires PG ≥ 11; default for PG ≥ 18).
- `cert` — client must present a client certificate (`cert clientcert=1`); password not accepted.

### Certificate aliases (`PostgresCertificateAlias`)

This is the central enum — each alias is one logical certificate the operator manages:

```go
PostgresServerCert          = "server"            // server serving cert
PostgresClientCert          = "client"            // client/root cert (stash, users, appbinding)
PostgresArchiverCert        = "archiver"          // archiver
PostgresGRPCCaCert          = "grpc-ca"           // CA of the internal gRPC PKI
PostgresGRPCServerCert      = "grpc-server"       // coordinator gRPC server cert
PostgresGRPCClientCert      = "grpc-client"       // coordinator gRPC client cert
PostgresMetricsExporterCert = "metrics-exporter"  // exporter cert
```

> The kubebuilder enum on `spec.tls.certificates[].alias` only allows
> `server;archiver;metrics-exporter` for *user* customization; the `client` and `grpc-*`
> certs are managed automatically.

### `kmapi.TLSConfig` (the reusable building block)

From `vendor/kmodules.xyz/client-go/api/v1/certificates.go`:

```go
type TLSConfig struct {
    IssuerRef    *core.TypedLocalObjectReference `json:"issuerRef,omitempty"`   // Issuer / ClusterIssuer
    Certificates []CertificateSpec               `json:"certificates,omitempty"`
}

type CertificateSpec struct {
    Alias          string            // which logical cert (server, client, ...)
    IssuerRef      *core.TypedLocalObjectReference
    SecretName     string            // default <db-name>-<alias>-cert
    Subject        *X509Subject
    Duration       *metav1.Duration
    RenewBefore    *metav1.Duration  // deprecated, use ReconfigureTLS ops
    DNSNames       []string
    IPAddresses    []string
    URIs           []string
    EmailAddresses []string
    PrivateKey     *CertificatePrivateKey
}
```

KubeDB reuses this `TLSConfig` for **every** database (MongoDB, MySQL, Redis…), which is why
DocumentDB can reuse it too.

---

## 3. Naming helpers (apimachinery)

From `postgres_helpers.go`:

```go
// Certificate CR name and default secret name for an alias: <name>-<alias>-cert
func (p *Postgres) CertificateName(alias PostgresCertificateAlias) string {
    return meta_util.NameWithSuffix(p.Name, fmt.Sprintf("%s-cert", string(alias)))
}

// Secret name: user-provided secretName if set, else CertificateName(alias)
func (p *Postgres) GetCertSecretName(alias PostgresCertificateAlias) string {
    if p.Spec.TLS != nil {
        if name, ok := kmapi.GetCertificateSecretName(p.Spec.TLS.Certificates, string(alias)); ok {
            return name
        }
    }
    return p.CertificateName(alias)
}

// Fills in default secretName for server/client/metrics-exporter certs
func (p *Postgres) SetTLSDefaults() {
    if p.Spec.TLS == nil || p.Spec.TLS.IssuerRef == nil { return }
    p.Spec.TLS.Certificates = kmapi.SetMissingSecretNameForCertificate(p.Spec.TLS.Certificates, string(PostgresServerCert),          p.CertificateName(PostgresServerCert))
    p.Spec.TLS.Certificates = kmapi.SetMissingSecretNameForCertificate(p.Spec.TLS.Certificates, string(PostgresClientCert),          p.CertificateName(PostgresClientCert))
    p.Spec.TLS.Certificates = kmapi.SetMissingSecretNameForCertificate(p.Spec.TLS.Certificates, string(PostgresMetricsExporterCert), p.CertificateName(PostgresMetricsExporterCert))
}
```

There is also the convention for file keys inside the TLS secrets:
`TLSCACertFileName = "ca.crt"`, plus `tls.crt`, `tls.key`.

---

## 4. Who creates the certificates? (important architectural note)

> **Surprise:** in this repo the certificate-management code lives in the **`pkg/ops` package**,
> on a type called `Controller` (the ops-manager's controller), **not** the provisioner.
> The ops-manager runs a Postgres informer (`managePostgresEvent`) that reacts to every
> Postgres object and ensures its certificates exist. The provisioner only **consumes** the
> resulting secrets when building pods.

`pkg/ops/postgres.go`:

```go
func (c *Controller) managePostgresEvent(k any) error {
    // ... fetch postgres from dbInformer ...
    if cutil.IsConditionTrue(postgres.Status.Conditions, kubedb.DatabasePaused) {
        return nil // skip TLS while paused (ops requests pause the DB)
    }
    if err := c.ensureGrpcTLS(postgres); err != nil { ... }  // internal gRPC PKI
    if err := c.manageTLS(postgres); err != nil { ... }      // server/client/exporter certs
}
```

`manageTLS` (the orchestrator):

```go
func (c *Controller) manageTLS(postgres *dbapi.Postgres) error {
    if postgres.Spec.TLS == nil { return nil }                 // TLS off → nothing to do
    if !lib.IsServiceReady(...) { return nil }                 // wait for governing svc

    // Validate the referenced Issuer/ClusterIssuer exists
    switch postgres.Spec.TLS.IssuerRef.Kind {
    case cm_api.IssuerKind:        // get Issuer in namespace
    case cm_api.ClusterIssuerKind: // get ClusterIssuer
    default: return errors.New("IssuerRef.Kind must be Issuer or ClusterIssuer")
    }

    if err := c.manageServerCert(postgres); err != nil { return err }        // alias "server"
    if err := c.manageExternalClientCert(postgres); err != nil { return err } // alias "client" (stash/users)
    if err := c.manageExporterClientCert(postgres); err != nil { return err } // alias "metrics-exporter"
    return nil
}
```

---

## 5. How each certificate is created (cert-manager `Certificate` CRs)

All of these use `cm_util.CreateOrPatchCertificate(...)` to create/patch a **cert-manager
`Certificate` object**; cert-manager then issues the cert and writes the result into the
named `Secret`. The operator then sets the Postgres CR as **owner** of the secret (for GC).

### Server certificate — `ensureServerCert` (`pkg/ops/certificates.go`)

- `CommonName = db.ServiceName()`
- `DNSNames` includes: wildcard governing-service DNS (`*.<gov-svc>.<ns>.svc[.cluster]`),
  the service DNS names (`lib.ServiceDNS`), and `localhost`.
- `IPAddresses` includes `127.0.0.1`.
- `IssuerRef = lib.GetIssuerObjectRef(db.Spec.TLS, "server")`.
- `Usages = DigitalSignature, KeyEncipherment, ServerAuth, ClientAuth`.
- Honors user overrides from `spec.tls.certificates[alias=server]`: subject, duration,
  renewBefore, extra DNSNames/IPs/URIs/emails.
- `SecretName = db.GetCertSecretName("server")`.

### Client certificate — `ensureClientCert(..., alias)` (used for `client` and `metrics-exporter`)

- `CommonName = kubedb.PostgresRootUser` (for client) — i.e. the identity Postgres maps to a role.
- `Usages = DigitalSignature, KeyEncipherment, ClientAuth`.
- Optional `AdditionalOutputFormats: CombinedPEM` when `c.pemEncodeCert` is true
  (configurable on the ops Controller) — produces a combined PEM the exporter/clients can use.

### gRPC PKI — `ensureGrpcTLS` (separate self-signed CA chain)

This is fully operator-managed and independent of the user's issuer:

1. `ensureGrpcCACertificate` — a self-signed **CA** `Certificate` (`IsCA: true`) issued by a
   self-signed `Issuer` (`getOrCreateGrpcIssuer` → creates `SelfSigned` Issuer, then a `CA`
   Issuer backed by the CA secret).
2. `ensureGrpcServerCert` — gRPC server cert (CN = governing service, DNS names for the
   pods), `ServerAuth`.
3. `ensureGrpcClientCert` — gRPC client cert (CN = `pg-coordinator`), `ClientAuth`.

This gives the `pg-coordinator` sidecars mutual TLS for Raft/leader election independent of
whether the user enabled DB TLS… **note**: `ensureGrpcTLS` early-returns if `db.Spec.TLS == nil`,
so the gRPC PKI is only created when DB TLS is on.

---

## 6. How certs get into the pod (provisioner side)

### Step 1 — wait for the secrets

`pkg/controller/reconciler.go` `ReconcileNodes` calls `RequiredCertSecretNames(db)` and will
**not** build the PetSet until all required TLS secrets exist (it just drops the object back
on the queue; the secret-create event re-enqueues it):

```go
func (r *Reconciler) RequiredCertSecretNames(db *dbapi.Postgres) []string {
    var sNames []string
    if db.Spec.TLS != nil {
        sNames = append(sNames, db.GetCertSecretName(PostgresServerCert))
        sNames = append(sNames, db.GetCertSecretName(PostgresClientCert))
        if db.Spec.Monitor != nil {
            sNames = append(sNames, db.GetCertSecretName(PostgresMetricsExporterCert))
        }
        sNames = append(sNames, db.GetCertSecretName(PostgresGRPCServerCert))
        sNames = append(sNames, db.GetCertSecretName(PostgresGRPCClientCert))
    }
    return sNames
}
```

### Step 2 — mount secrets as volumes

`pkg/controller/petset.go`:

Constants (mount paths and file names):

```go
clientTlsVolumeMountPath   = "/certs/client"
serverTlsVolumeMountPath   = "/certs/server"
exporterTlsVolumeMountPath = "/certs/exporter"
serverTlsVolumeName  = "tls-volume-server"
clientTlsVolumeName  = "tls-volume-client"
exporterTlsVolumeName = "tls-volume-exporter"
gRPCServerCertVolumeName = "grpc-volume-server"
gRPCClientCertVolumeName = "grpc-volume-client"
TLS_CERT = "tls.crt"; TLS_KEY = "tls.key"; TLS_CA_CERT = "ca.crt"
```

`upsertTLSVolume(volumes, db)` adds three secret-backed volumes (server, client, exporter),
each projecting `ca.crt`, `tls.crt`, `tls.key` (remapped to server/client-specific filenames
via `KeyToPath`). `upsertGRPCVolume` does the same for the gRPC server/client secrets. These
volumes are mounted into the init container, the `postgres` container, and the
`pg-coordinator` container (see the `VolumeMounts` near `serverTlsVolumeMountPath` /
`PostgresSharedTlsVolumeMountPath`). There is also a *shared* certificates volume
(`upsertSharedCertificatesVolume`) where the init container assembles the final cert layout
under `PostgresSharedTlsVolumeMountPath`.

### Step 3 — tell Postgres to use SSL via env vars

The PetSet builder sets:

```go
// SSL on/off flag for the container entrypoint/run scripts
if db.Spec.TLS != nil { env "SSL"="ON" } else { env "SSL"="OFF" }

// SSL_MODE / CLIENT_AUTH_MODE with defaults
sslMode := db.Spec.SSLMode
if sslMode == "" {
    if db.Spec.TLS != nil { sslMode = verify-full } else { sslMode = disable }
}
env "SSL_MODE" = sslMode
env "CLIENT_AUTH_MODE" = clientAuthMode  // default md5
```

The init-container/run scripts (from the `postgres-init-docker` image) read these env vars and
the mounted certs to write `postgresql.conf` (`ssl=on`, `ssl_cert_file`, `ssl_key_file`,
`ssl_ca_file`) and `pg_hba.conf` (md5 / scram-sha-256 / cert auth rules).

### Step 4 — exporter connection string

For the monitoring exporter, the connection string is assembled with sslmode and, when
`verify-ca`/`verify-full`, `sslrootcert=.../exporter/ca.crt`; when `clientAuthMode=cert`,
also `sslcert=.../exporter/tls.crt sslkey=.../exporter/tls.key`.

### Step 5 — AppBinding (so clients/backup tools know how to connect)

`pkg/controller/appbinding.go` writes the connection info:

```go
in.Spec.ClientConfig.Service.Query = fmt.Sprintf("sslmode=%s", db.Spec.SSLMode)
in.Spec.ClientConfig.InsecureSkipTLSVerify = false
if db.Spec.TLS != nil {
    in.Spec.ClientConfig.CABundle = <ca.crt from client cert secret>
    in.Spec.TLSSecret = { Kind: Secret, Name: db.GetCertSecretName(PostgresClientCert) }
}
```

### Remote replica

A remote-replica pod consumes its *source's* `TLSSecret` (`upsertRemoteReplicaTLSVolume`)
mounted at `/certs/remote`, and uses `SOURCE_SSL` / `SOURCE_SSL_MODE` env vars to connect
upstream over TLS.

---

## 7. Validation (admission webhook)

`vendor/kubedb.dev/apimachinery/pkg/webhooks/kubedb/v1/postgres.go` enforces consistency:

```go
// cert auth requires SSL not disabled
if clientAuthMode == cert && sslMode == disable { error }
// TLS set but sslMode disabled is contradictory
if TLS != nil && sslMode == disable { error }
// sslMode set (non-disable) but no TLS block
if sslMode != "" && sslMode != disable && TLS == nil { error }
// scram requires a supported PG version
if clientAuthMode == scram { checkPgScramAuthMethodSupport(version) }
```

Defaults (`SetDefaults`/`SetTLSDefaults`): when `TLS != nil` and `sslMode == ""` →
`verify-full`; when `TLS == nil` → `disable`. `clientAuthMode == ""` → `md5` (PG < 18) or
`scram` (PG ≥ 18).

---

## 8. Day-2: ReconfigureTLS OpsRequest

`pkg/ops/reconfigure_tls.go` implements the `PostgresOpsRequest` type `ReconfigureTLS`.

Ops API type (`PostgresTLSSpec`):

```go
type PostgresTLSSpec struct {
    TLSSpec        `json:",inline"`   // embeds kmapi.TLSConfig + RotateCertificates + Remove
    SSLMode        PostgresSSLMode
    ClientAuthMode PostgresClientAuthMode
}
// TLSSpec:
//   kmapi.TLSConfig (issuerRef, certificates)
//   RotateCertificates bool  // force rotation
//   Remove bool             // strip TLS
```

The reconcile algorithm:

1. Mark ops request `Progressing`/`Running`.
2. Validate `spec.tls` present; require an issuerRef somewhere; scram needs PG ≥ 11.
3. **Pause** the Postgres (so the provisioner & cert controller stop fighting), wait for
   `DatabasePaused` condition.
4. DeepCopy the DB:
   - **Remove path** (`spec.tls.remove=true`): force `sslMode=disable`, reject
     `clientAuthMode=cert`, set `dbCopy.Spec.TLS = nil`, remember old issuerRef for cleanup.
     (Also derives `clientAuthMode` from the running container's `CLIENT_AUTH_MODE` env /
     password_encryption when not provided.)
   - **Add/Update/Rotate path**: merge `spec.tls.certificates`/issuerRef into `dbCopy`, call
     `SetTLSDefaults()`, then `manageTLS(dbCopy)` + `ensureGrpcTLS(dbCopy)` to create/patch
     the Certificate CRs. If `rotateCertificates=true`, set each Certificate's status
     condition `Issuing=true` to force cert-manager re-issuance.
5. **Wait for certs to sync** (`newSyncCertificates`): each Certificate must have
   `Ready=true`, `generation == observedGeneration`, and no lingering `Issuing` condition.
6. Build a `controller.Reconciler{ ..., SkipArchiver: true }` and call `ReconcileNodes(dbCopy)`
   to re-render the PetSets with the new SSLMode/ClientAuthMode/TLS.
7. **Restart** all pods (`CustomRestart`) so they pick up new certs/config.
8. Patch the **original** Postgres CR with the new `sslMode`, `clientAuthMode`, `tls`.
9. `cleanUpCertificates` — delete orphaned `Certificate` CRs and TLS `Secret`s that are owned
   by the DB but no longer in the allow-list (the current aliases + the three `grpc-*` certs
   are always whitelisted).
10. Resume the DB, resume paused backups, mark ops request `Successful`.

---

## 9. Cross-repo wiring (where the code physically runs)

| Concern                                                                     | Package                                          | Runs in pod           |
| --------------------------------------------------------------------------- | ------------------------------------------------ | --------------------- |
| Create/rotate Certificate CRs, gRPC PKI, react to Postgres objects          | `pkg/ops` (`Controller.managePostgresEvent`) | **ops-manager** |
| Wait for cert secrets, mount volumes, set SSL env, build PetSet, AppBinding | `pkg/controller` (provisioner `Reconciler`)  | **provisioner** |
| `ReconfigureTLS` ops handling                                             | `pkg/ops` (`postgresOpsReqController`)       | **ops-manager** |

Because ops-manager constructs a `controller.Reconciler` struct literal from another Go
module, any field it sets must be **exported** (`PgQueue`, `SkipArchiver`, etc.).

Scheme note: cert-manager types (`cm_api`, `cmmeta`) must be registered in both
`pkg/cmds/root.go` and `pkg/server/server.go`.

---

## 10. Checklist: bringing TLS to your DocumentDB operator

> **This is the generic checklist.** For the concrete, file-by-file plan mapped to the
> *actual* DocumentDB + documentdb-coordinator code, jump to **Section 12** — it tells you
> exactly which files already exist, which are missing, and what to change. Read Section 12;
> use this section as the conceptual backbone.


Mirror the structure above. Concretely:

### A. API (in your apimachinery / types)

1. Add to `DocumentDBSpec`:
   - `TLS *kmapi.TLSConfig`
   - `SSLMode <YourSSLMode>` (or the DocumentDB/Mongo equivalent of TLS modes:
     `disabled/allowTLS/preferTLS/requireTLS`)
   - `ClientAuthMode` if you want mutual-TLS / x509 auth.
2. Define a `DocumentDBCertificateAlias` enum: at minimum `server`, `client`, and (if you
   have an internal control plane) `*-ca`/`*-server`/`*-client`, plus `metrics-exporter`.
3. Add helpers: `CertificateName(alias)`, `GetCertSecretName(alias)`, `SetTLSDefaults()`
   (copy the Postgres ones almost verbatim — they're generic).
4. Add admission-webhook validations: TLS↔sslMode consistency, cert-auth needs TLS, version
   gating for any auth mode that needs it.

### B. Certificate management controller (issue certs)

5. Add a `certificates.go` with `manageTLS`, `ensureServerCert`, `ensureClientCert`
   (and `manageExporterClientCert`). Use
   `cm_util.CreateOrPatchCertificate(...)` against the cert-manager client. Copy the
   server-cert DNS/IP SAN logic (governing-svc wildcard, service DNS, localhost).
6. Set the DB object as owner of each resulting secret
   (`lib.AddOwnerReferenceToSecret`).
7. Validate the referenced `Issuer`/`ClusterIssuer` exists before issuing.
8. (Optional) If DocumentDB has an internal mesh/replication control channel like the
   pg-coordinator gRPC, build a self-signed CA PKI like `ensureGrpcTLS`.

### C. Provisioner (consume certs)

9. In `ReconcileNodes`, compute `RequiredCertSecretNames(db)` and **block PetSet creation
   until all TLS secrets exist** (return early & rely on re-enqueue on secret events).
10. In the PetSet builder, add `upsertTLSVolume` (secret-backed volumes projecting
    `ca.crt`/`tls.crt`/`tls.key`) and mount them into init + main + sidecar containers.
11. Pass SSL config into the DB via env vars (`SSL=ON/OFF`, `SSL_MODE`, `CLIENT_AUTH_MODE`)
    and make your init/run scripts configure the DB's TLS settings and auth file accordingly
    (this is the DocumentDB-/Mongo-specific part — e.g. `--tlsMode`, `--tlsCertificateKeyFile`,
    `--tlsCAFile`).
12. In the AppBinding, set `ClientConfig.CABundle`, `TLSSecret`, `InsecureSkipTLSVerify=false`,
    and the connection query (sslmode equivalent).

### D. Day-2 ops

13. Add a `ReconfigureTLS` ops type + `reconfigure_tls.go`: pause DB → merge/issue/rotate or
    remove certs → wait for cert sync → reconcile PetSets → restart pods → patch DB → clean up
    orphaned certs/secrets → resume.

### E. Plumbing

14. Register cert-manager schemes in both your root cmd and webhook server.
15. Make sure any cross-module `Reconciler` fields are exported.
16. Vendor: `github.com/cert-manager/cert-manager`, `kmodules.xyz/cert-manager-util`,
    `kmodules.xyz/client-go/api/v1` (TLSConfig).

### Prerequisite for users

- cert-manager must be installed in the cluster, and the user must create an `Issuer`/
  `ClusterIssuer` and reference it in `spec.tls.issuerRef`.

---

## 11. Minimal example (Postgres) for reference

```yaml
apiVersion: kubedb.com/v1
kind: Postgres
metadata:
  name: pg-tls
  namespace: demo
spec:
  version: "16.x"
  replicas: 3
  storageType: Durable
  storage:
    resources: { requests: { storage: 1Gi } }
  sslMode: verify-full
  clientAuthMode: cert        # mutual TLS; use md5/scram for password auth over TLS
  tls:
    issuerRef:
      apiGroup: cert-manager.io
      kind: Issuer
      name: pg-issuer
    certificates:
      - alias: server
        subject: { organizations: ["kubedb"] }
        dnsNames: ["my-extra-host.example.com"]
```

Rotate / change TLS later:

```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: PostgresOpsRequest
metadata: { name: pg-recfg-tls, namespace: demo }
spec:
  type: ReconfigureTLS
  databaseRef: { name: pg-tls }
  tls:
    rotateCertificates: true      # or: remove: true to strip TLS
    # issuerRef / certificates / sslMode / clientAuthMode can also be updated here
```
