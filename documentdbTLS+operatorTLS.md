# DocumentDB TLS + Operator TLS — How It Actually Works (code-level)

Findings from reading two repos:

- **DB / gateway**: `github.com/documentdb/documentdb` → the gateway lives in `pg_documentdb_gw/` (Rust). This is the MongoDB-wire-protocol front door.
- **Operator**: `github.com/documentdb/documentdb-kubernetes-operator` → Go operator under `operator/src/`, plus a CNPG sidecar-injector plugin under `operator/cnpg-plugins/sidecar-injector/`.

> Paths below are repo-relative. Gateway paths start at `pg_documentdb_gw/`; operator paths start at `operator/`.

---

## 0. The big picture (topology)

```
                          TLS 1.2/1.3 (MongoDB wire protocol)
  ┌──────────────┐  SCRAM-SHA-256 / OIDC over TLS   ┌───────────────────────────── Pod ─────────────────────────────┐
  │ MongoDB      │ ───────────────────────────────▶ │  ┌───────────────────┐   localhost, NoTLS   ┌────────────────┐ │
  │ driver       │   port 10260                      │  │ documentdb-gateway │ ───────────────────▶ │ Postgres (CNPG)│ │
  │ (client)     │ ◀─────────────────────────────── │  │  (Rust sidecar)    │   port 9712/5432     │ + DocumentDB   │ │
  └──────────────┘                                   │  └───────────────────┘                      │   extension    │ │
                                                     │       ▲  mounts /tls/{tls.crt,tls.key}      └────────────────┘ │
                                                     └───────┼───────────────────────────────────────────────────────┘
                                                             │ Secret (cert-manager-issued)
                                                  ┌──────────┴───────────┐
                                                  │ DocumentDB Operator  │  provisions cert via cert-manager,
                                                  │ CertificateReconciler│  surfaces secret name to the
                                                  └──────────────────────┘  sidecar-injector plugin
```

Three connection legs:

| Leg | Transport | TLS? | Where in code |
|-----|-----------|------|---------------|
| **MongoDB driver → gateway** | TCP/Unix socket, MongoDB wire protocol | **Yes** — TLS 1.2/1.3, server-auth | `pg_documentdb_gw` gateway |
| **gateway → postgres** | TCP (or unix) to `localhost` in same pod | **No — `NoTls`** | `connection_pool.rs` |
| **pod ↔ pod** (replication, etc.) | — | (out of scope per request) | — |

The key insight: **TLS terminates at the gateway.** The gateway → Postgres hop is intentionally plaintext because both live in the same pod and talk over loopback.

---

## 1. Two gateway "fronts" (important nuance)

The same Rust gateway code is shipped two ways, and they configure TLS differently:

1. **OSS / packaged binary** `documentdb-gateway` — reads config from a JSON file and/or env vars (`DOCUMENTDB_TLS_*`). CLI only understands `run|check|--version|--help` (`documentdb_gateway/src/cli.rs`). It does **not** understand `--cert-path`/`--key-file`.
2. **Container image** (what the k8s operator runs, e.g. `ghcr.io/documentdb/documentdb-kubernetes-operator/gateway:0.110.0`) — entrypoint is `documentdb-local/scripts/emulator_entrypoint.sh`, which accepts `--cert-path`, `--key-file`, `--start-pg`, `--pg-port`, `--create-user`, then **translates them into a `SetupConfiguration.json`** that the binary reads.

This matters: the operator's sidecar-injector passes `--cert-path /tls/tls.crt --key-file /tls/tls.key` (CLI flags), and the **entrypoint script** is the thing that converts those into the `CertificateOptions` JSON the Rust binary actually consumes. The Rust CLI never sees those flags directly.

---

## 2. Client → Gateway TLS (the Rust gateway)

### 2.1 Listener + accept loop
`documentdb_gateway_core/src/lib.rs:146` `run_gateway()`:
- Binds IPv4/IPv6 TCP listeners on `gateway_listen_port()` (default **10260**) via `service::create_tcp_listeners(...)`, and optionally a Unix socket.
- `tokio::select!` accept loop (`lib.rs:178`) spawns one task per connection: `spawn_tcp_handler` → `handle_connection::<T>()`.

### 2.2 Per-connection: detect TLS, then handshake
`handle_connection()` (`lib.rs:351`):
1. Sets `TCP_NODELAY` + keepalive.
2. Decides whether the connection is TLS (`lib.rs:376`):
   ```rust
   let is_tls = if service_context.setup_configuration().enforce_tls() {
       true                                   // EnforceTls=true → every conn must be TLS
   } else {
       detect_tls_handshake(&tcp_stream, connection_id).await?   // sniff first bytes
   };
   ```
3. **`detect_tls_handshake`** (`lib.rs:273`) **peeks** (doesn't consume) the first 3 bytes and checks the TLS record header:
   - byte0 `0x16` (Handshake), byte1 `0x03` (SSL/TLS major), byte2 `0x01..0x04` (TLS 1.0–1.3).
   - This is what lets a single port serve **both** plaintext and TLS clients when `EnforceTls=false` ("allowTLS"-like behavior).
4. **TLS path** (`lib.rs:394`):
   ```rust
   let tls_acceptor = service_context.tls_provider().tls_acceptor(); // Arc<SslAcceptor>
   let ssl_session  = Ssl::new(tls_acceptor.context())?;
   let mut tls_stream = SslStream::new(ssl_session, tcp_stream)?;    // tokio_openssl
   SslStream::accept(Pin::new(&mut tls_stream)).await?;             // <-- TLS handshake
   ```
   Then wraps the `SslStream` in a `BufStream` and hands it to `service::handle_stream`. The `ConnectionContext` keeps `Some(tls_stream.ssl())` so per-connection cipher/telemetry is available.
5. **Non-TLS path** (`lib.rs:430`): same, but raw `tcp_stream`, `ssl = None`.

### 2.3 The TLS provider, acceptor, and cert hot-reload
`documentdb_gateway_core/src/service/tls.rs`:
- **`CertificateStorePaths::new`** (`tls.rs:98`) resolves where cert/key come from based on `CertInputType`:
  - `PemFile` → uses explicit `file_path` / `key_file_path` / optional `ca_path`.
  - `PemAutoGenerated` → resolves a state dir (see §2.5), **reuses** existing `cert.pem`/`pkey.pem` if present (critical for restart/upgrade so client trust-pinning survives), else shells out to OpenSSL to generate a self-signed cert and `chmod 600` the key.
- **`CertificateBundle::from_cert_store`** (`tls.rs:195`) async-reads the PEMs and parses them into OpenSSL `X509` / `PKey<Private>` / CA chain.
- **`TlsProvider::new`** (`tls.rs:285`):
  - Builds the initial `SslAcceptor`, stores it in an **`Arc<ArcSwap<SslAcceptor>>`** (lock-free atomic swap).
  - Spawns a background task (`tls.rs:306`) that every **60s** (`CERT_FILES_CHANGE_WATCH_INTERVAL`) checks the cert/key mtime and, if newer, rebuilds the acceptor and `ArcSwap::store`s it — **zero-downtime cert rotation**. In-flight connections keep their old `Arc`; new connections get the new cert. This is how cert-manager renewals get picked up without a pod restart.
  - `is_valid_certificate()` (`tls.rs:381`) sanity-checks that the public key matches the private key.

- **`create_tls_acceptor`** (`service/docdb_openssl.rs:167`) — the actual OpenSSL hardening:
  - Base profile: `SslAcceptor::mozilla_intermediate_v5` (good security/compat balance).
  - `set_min_proto_version(TLS1_2)`, `set_max_proto_version(TLS1_3)`.
  - Loads server cert + private key + CA chain from the bundle.
  - `SslMode::RELEASE_BUFFERS | ACCEPT_MOVING_WRITE_BUFFER` (cuts ~34KB/conn idle memory; the moving-write-buffer flag is required for correctness under tokio async `poll_write`).
  - `set_session_cache_mode(OFF)` but **keeps TLS 1.3 session tickets** (`set_num_tickets(1)`) — stateless resumption without a server-side cache mutex (avoids serializing handshakes under load).
- **`generate_auth_keys`** (`docdb_openssl.rs:74`) — literally shells out to `openssl genpkey -algorithm RSA` then `openssl req -x509 -days 365 -subj /CN=localhost`. Dev/self-signed only.

### 2.4 Config: how `CertificateOptions` / `EnforceTls` get set
- Config schema: `documentdb_gateway_core/src/configuration/certs.rs` — `CertInputType` (`PemFile` default, `PemAutoGenerated`) + `CertificateOptions { cert_type, file_path, key_file_path, ca_path }` (deserialized PascalCase from JSON).
- `SetupConfiguration.json` (gateway repo root, the template) ships:
  ```json
  { "PostgresPort": 9712, "GatewayListenPort": 10260,
    "CertificateOptions": { "CertType": "PemAutoGenerated" }, "UseLocalHost": false }
  ```
- `enforce_tls()` (`configuration/setup.rs:956`) **defaults to `true`** (`self.enforce_tls.unwrap_or(true)`). So out of the box TLS is mandatory.
- **Env-var overlay** (`setup.rs:380`): `DOCUMENTDB_TLS_CERT_FILE`, `DOCUMENTDB_TLS_KEY_FILE`, `DOCUMENTDB_TLS_AUTO_GENERATE` (+ `DOCUMENTDB_LISTEN_ADDR`, `DOCUMENTDB_PG_URL_FILE`, `DOCUMENTDB_TLS_STATE_DIR`). `apply_tls_overlay` (`setup.rs:764`) maps these onto `CertificateOptions`.
- **Safety fallback** (`setup.rs:409`): if it resolves to `CertType=PemFile` but both paths are `None`, it logs a warning and flips to `PemAutoGenerated` so the gateway never boots without a usable cert (issue: no-plaintext invariant).

### 2.5 Where auto-generated certs live
`documentdb_gateway_core/src/service/tls_state_dir.rs`:
- Default dir `/var/lib/documentdb-gateway/tls`, files `cert.pem` + `pkey.pem` (stable names for backup/rotation tooling).
- Override with `DOCUMENTDB_TLS_STATE_DIR`. Resolution order: env var → default → `$XDG_STATE_HOME`/`$HOME/.local/state` → per-process tempdir (last resort, ephemeral). Fallbacks log `warn!`.

---

## 3. MongoDB driver handshake + auth, over the TLS channel

Once `SslStream::accept` succeeds, the gateway speaks the MongoDB wire protocol on top of the TLS stream (`service::handle_stream`). Relevant to "how the driver connects":

- The driver opens TLS (or plain, if allowed), then sends `hello`/`isMaster`, then authenticates.
- **Auth mechanisms** (`auth.rs:349`): only **`SCRAM-SHA-256`** and **`MONGODB-OIDC`** are supported (`saslStart`/`saslContinue`).
- Pre-auth messages are size-capped (`protocol/reader.rs:101`, `MAX_PRE_AUTH_MESSAGE_SIZE_BYTES`) to limit unauthenticated memory use.
- **SCRAM is delegated to Postgres**: the gateway does **not** verify the SCRAM proof itself. It runs a SQL function via the connection pool — `query_catalog().authenticate_with_scram_sha256()` (`auth.rs:697`) — passing `username`, `auth_message`, `proof`. The DocumentDB Postgres extension stores the user credential and returns `ok` + `ServerSignature` (`auth.rs:714`). On success it sets `auth_state.set_authenticated(true)` and allocates the per-user data pool (`auth.rs:741`).
- So: **client authenticates to the gateway over TLS; the gateway authenticates the client by asking Postgres.** The client's MongoDB password ⇄ the Postgres-side stored credential.

---

## 4. Gateway → Postgres connection (no TLS)

`documentdb_gateway_core/src/postgres/conn_mgmt/connection_pool.rs`:
- `pg_configuration()` (`connection_pool.rs:53`) builds a `tokio_postgres::Config` with `.host(postgres_host_name())` (default **`localhost`**, `NodeHostName` in SetupConfiguration), `.port(postgres_port())` (default **9712**), dbname, user, optional password, and a `search_path`/timeout `options` string.
- The pool is created with **`NoTls`** (`connection_pool.rs:166`):
  ```rust
  PostgresManager::from_config(pg_config, NoTls, ManagerConfig { recycling_method })
  ```
- Two `deadpool` pools: a main pool and a `timeout_pool` using `RecyclingMethod::Clean` (resets per-request session state like `SET statement_timeout`).
- **Why no TLS here:** gateway and Postgres are co-located in the same pod and communicate over loopback; the trust boundary is the gateway. Confirmed by the operator side too — `api/preview/documentdb_types.go:382` defines `PostgresTLS struct{}` as an explicit **placeholder for a future phase** ("Phase 1: certificate provisioning only" for the gateway). There is currently no Postgres-server TLS path wired up.

---

## 5. Operator side — provisioning the gateway TLS cert

### 5.1 CRD surface (`operator/src/api/preview/documentdb_types.go`)
```go
type TLSConfiguration struct {
    Gateway         *GatewayTLS         // the only implemented one
    Postgres        *PostgresTLS        // placeholder (empty struct)
    GlobalEndpoints *GlobalEndpointsTLS // placeholder
}
type GatewayTLS struct {
    Mode        string         // enum: SelfSigned | CertManager | Provided
    CertManager *CertManagerTLS // issuerRef, dnsNames, secretName
    Provided    *ProvidedTLS    // secretName (must hold tls.crt/tls.key)
}
type TLSStatus struct { Ready bool; SecretName string; Message string }
```
`spec.tls.gateway.mode` is a closed enum. **There is no `Disabled`** — TLS is always on (a pre-#357 `Disabled` value left in etcd is fail-safed to `SelfSigned`).

### 5.2 CertificateReconciler (`operator/src/internal/controller/certificate_controller.go`)
`reconcileCertificates` (`:58`) — defaults a missing `tls`/`tls.gateway`/empty mode to **`SelfSigned`** (no-plaintext invariant, issue #356), then dispatches on mode (`:83`):

- **`SelfSigned`** → `ensureSelfSignedCert` (`:268`):
  1. Creates a cert-manager **self-signed `Issuer`** named `<ddb>-gateway-selfsigned`.
  2. Creates a cert-manager **`Certificate`** `<ddb>-gateway-cert` → secret `<ddb>-gateway-cert-tls`, `90d` duration / `15d` renewBefore, `UsageServerAuth`, DNS SANs = the gateway Service name + `.ns` + `.ns.svc`.
  3. Watches the cert's `Ready` condition; sets `Status.TLS.{Ready,SecretName,Message}`.
- **`CertManager`** → `ensureCertManagerManagedCert` (`:161`): same Certificate shape but `IssuerRef` points at the user's existing Issuer/ClusterIssuer (defaults Kind=`Issuer`, Group=`cert-manager.io`); merges user `DNSNames` with the Service DNS names; secret name defaults to `<ddb>-gateway-cert-tls`.
- **`Provided`** → `ensureProvidedSecret` (`:103`): no cert-manager. Just validates that the referenced Secret exists and contains **`tls.crt`** and **`tls.key`**; sets status `Ready` accordingly (requeues while waiting).
- `default` (`:90`): unknown/legacy mode → fall back to `SelfSigned` (never serve plaintext).

`updateTLSStatus` (`:357`) writes `Status.TLS` with `RetryOnConflict`. The controller `Owns(Certificate)` and `Owns(Issuer)` (`:376`) so cert/issuer changes re-trigger reconcile.

**Net result of this controller:** a Kubernetes Secret (cert-manager-issued or user-provided) holding `tls.crt`/`tls.key`, and `ddb.Status.TLS.{Ready=true, SecretName=...}`.

---

## 6. How the cert Secret reaches the gateway sidecar

This is the bridge between operator and gateway. Two hops:

### 6.1 Operator → plugin parameters (`operator/src/internal/cnpg/cnpg_cluster.go`)
When building the CNPG `Cluster`, the operator configures the **sidecar-injector CNPG plugin** with parameters (`cnpg_cluster.go:82`):
```go
params := { "gatewayImage": gatewayImage, "documentDbCredentialSecret": credentialSecretName, ... }
// Only surface the TLS secret once cert-manager reports the cert ready:
if documentdb.Status.TLS != nil && documentdb.Status.TLS.Ready && documentdb.Status.TLS.SecretName != "" {
    params["gatewayTLSSecret"] = documentdb.Status.TLS.SecretName   // cnpg_cluster.go:90
}
```
So the gateway only gets a real cert mounted **after** `Status.TLS.Ready == true`. (Before that, the gateway would fall back to auto-gen self-signed per §2.4 — though in the k8s flow the entrypoint drives cert selection, see §6.2.)

### 6.2 Plugin → gateway container (`operator/cnpg-plugins/sidecar-injector/internal/lifecycle/lifecycle.go`)
The plugin mutates the Postgres pod to inject the `documentdb-gateway` sidecar (`lifecycle.go:166`):
- Container `documentdb-gateway`, image = `gatewayImage`, **port 10260**.
- Env `USERNAME`/`PASSWORD` from the credential secret (used so the gateway can create/authenticate the DocumentDB user against Postgres).
- **TLS wiring** (`lifecycle.go:182`), only if `gatewayTLSSecret` param is set:
  ```go
  // 1. mount the Secret as a volume
  Volume{ Name: "gateway-tls", Secret: { SecretName: tlsSecret } }
  sidecar.VolumeMounts += { Name: "gateway-tls", MountPath: "/tls", ReadOnly: true }
  // 2. env hints
  TLS_CERT_DIR=/tls, CERT_PATH=/tls/tls.crt, KEY_FILE=/tls/tls.key
  // 3. CLI args (consumed by emulator_entrypoint.sh, see §1)
  args += ["--cert-path", "/tls/tls.crt", "--key-file", "/tls/tls.key"]
  ```
- Base args (`lifecycle.go:214`): `--start-pg false --pg-port 5432` (the gateway must **not** start its own Postgres — CNPG runs it; it connects to the in-pod Postgres). `--create-user true` only on the primary (`--create-user false` on replicas / non-target-primary, `lifecycle.go:218`).

So the Secret's `tls.crt`/`tls.key` land at `/tls/` in the gateway container, and the gateway is told to use them.

### 6.3 Entrypoint → final gateway config (`documentdb-local/scripts/emulator_entrypoint.sh`)
The container entrypoint converts those flags/env into the JSON the Rust binary reads (`emulator_entrypoint.sh:485`):
```sh
# When CERT_PATH & KEY_FILE are set -> write PemFile cert options
jq '.CertificateOptions = { "CertType":"PemFile", "FilePath":$certPath, "KeyFilePath":$keyFilePath }'
# TLS mode -> EnforceTls (emulator_entrypoint.sh:500)
requireTLS -> EnforceTls=true
allowTLS / disabled -> EnforceTls=false   # NB: "disabled" still accepts TLS; gateway has no plain-only mode
```
Then it launches `build_and_start_gateway.sh -d $configFile -P $POSTGRESQL_PORT ...`, which runs the Rust binary against the generated `SetupConfiguration_temp.json`. The binary's `CertificateStorePaths::new` then loads `/tls/tls.crt` + `/tls/tls.key` as a `PemFile` bundle (§2.3) and the 60s mtime watcher picks up future cert-manager renewals.

---

## 7. End-to-end sequence (k8s install)

1. User applies a `DocumentDB` CR (optionally `spec.tls.gateway.mode`).
2. **CertificateReconciler** provisions an Issuer + Certificate (or validates a Provided secret) → cert-manager writes Secret `<ddb>-gateway-cert-tls` with `tls.crt`/`tls.key`; sets `Status.TLS.Ready=true, SecretName=...`.
3. **documentdb_controller / cnpg_cluster** builds the CNPG `Cluster`, passing `gatewayTLSSecret=<secret>` to the sidecar-injector plugin (only once Ready).
4. CNPG creates the Postgres pod; the **sidecar-injector plugin** injects the `documentdb-gateway` container, mounts the Secret at `/tls`, sets `CERT_PATH`/`KEY_FILE` + `--cert-path/--key-file`, `--start-pg false`, `--pg-port`.
5. The gateway container's **entrypoint** writes `CertificateOptions{CertType:PemFile,...}` + `EnforceTls` into `SetupConfiguration.json` and starts the Rust binary.
6. **Gateway** boots: `TlsProvider::new` loads the PEMs, builds the Mozilla-intermediate `SslAcceptor` (TLS 1.2–1.3), starts the 60s reload watcher, binds **:10260**.
7. **MongoDB driver** connects with TLS → `detect_tls_handshake` (or `EnforceTls`) → `SslStream::accept` → wire protocol → **SCRAM-SHA-256** auth, which the gateway verifies by calling a SQL function on **localhost Postgres** (`NoTls`).
8. Authenticated queries are translated and run against the in-pod DocumentDB Postgres extension over the plaintext loopback pool.
9. cert-manager renews the cert (15d before 90d expiry) → updates the Secret → kubelet refreshes the mounted files → gateway's mtime watcher hot-swaps the `SslAcceptor` with **no restart**.

---

## 8. Key files reference

**Gateway (`documentdb`, `pg_documentdb_gw/`):**
| File | Role |
|------|------|
| `documentdb_gateway_core/src/lib.rs` | accept loop, `detect_tls_handshake`, `SslStream::accept`, TLS vs non-TLS branch |
| `documentdb_gateway_core/src/service/tls.rs` | `CertificateStorePaths`, `CertificateBundle`, `TlsProvider` (ArcSwap + 60s hot reload) |
| `documentdb_gateway_core/src/service/docdb_openssl.rs` | `create_tls_acceptor` (Mozilla intermediate, TLS1.2–1.3, tickets), `generate_auth_keys` |
| `documentdb_gateway_core/src/service/tls_state_dir.rs` | auto-gen cert location + `DOCUMENTDB_TLS_STATE_DIR` |
| `documentdb_gateway_core/src/configuration/certs.rs` | `CertInputType`, `CertificateOptions` |
| `documentdb_gateway_core/src/configuration/setup.rs` | `enforce_tls()` default-true, env overlay, PemFile→PemAutoGenerated fallback |
| `documentdb_gateway_core/src/postgres/conn_mgmt/connection_pool.rs` | gateway→PG config, **`NoTls`** |
| `documentdb_gateway_core/src/auth.rs` | SCRAM-SHA-256 / OIDC, SCRAM verified via Postgres SQL function |
| `documentdb_gateway/src/cli.rs` | OSS binary CLI (run/check) — note: no `--cert-path` |
| `SetupConfiguration.json` | gateway config template |
| `documentdb-local/scripts/emulator_entrypoint.sh` | container entrypoint translating `--cert-path/--key-file`+TLS_MODE → JSON |

**Operator (`documentdb-kubernetes-operator`, `operator/`):**
| File | Role |
|------|------|
| `src/api/preview/documentdb_types.go` | `TLSConfiguration`, `GatewayTLS`, `TLSStatus`; `PostgresTLS` is an empty placeholder |
| `src/internal/controller/certificate_controller.go` | provisions cert per mode (SelfSigned/CertManager/Provided) via cert-manager |
| `src/internal/cnpg/cnpg_cluster.go` | surfaces `gatewayTLSSecret` to the plugin once `Status.TLS.Ready` |
| `cnpg-plugins/sidecar-injector/internal/lifecycle/lifecycle.go` | injects gateway sidecar, mounts secret at `/tls`, sets env + args |
| `cnpg-plugins/sidecar-injector/internal/config/config.go` | plugin params (gatewayImage, credential secret) |

---

## 9. Gotchas / things worth remembering

- **TLS is always-on at the gateway.** `EnforceTls`/`enforce_tls()` default true; operator has no `Disabled` mode; unknown modes fail-safe to SelfSigned. `tlsMode=disabled` in the entrypoint does **not** disable TLS — the gateway has no plain-only mode, it just *also* accepts plaintext (allowTLS-like).
- **Single port, dual protocol:** when not enforcing TLS, the 3-byte peek (`0x16 0x03 0x0X`) distinguishes TLS from plaintext on the same 10260 port.
- **gateway→Postgres is plaintext by design** (`NoTls`, loopback, same pod). Postgres-server TLS is an unimplemented future phase.
- **SCRAM is not verified in the gateway** — it's delegated to a Postgres SQL function; the DocumentDB extension holds the credential.
- **Hot cert rotation** is real and important: `ArcSwap` + 60s mtime watcher swaps the `SslAcceptor` live, so cert-manager renewals don't need a pod restart. Auto-gen mode deliberately **reuses** existing cert files across restarts to preserve client trust-pinning.
- **The CLI flags the operator passes are not understood by the Rust binary** — `emulator_entrypoint.sh` is the translation layer that turns `--cert-path/--key-file` into `CertificateOptions{CertType:PemFile}` JSON.
- **Secret contract:** cert lives in a Secret with keys `tls.crt` / `tls.key`, mounted read-only at `/tls`. `Provided` mode requires exactly those two keys.
