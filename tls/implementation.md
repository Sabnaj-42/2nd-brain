# Implementation Prompt — Full TLS in the KubeDB DocumentDB Operator

Give everything below the line to a fresh Claude Code / agent session pointed at the KubeDB repos.
It implements **the full postgres TLS stack (server + client + replication + exporter) AND the
MongoDB gateway edge TLS** in our DocumentDB operator, by **mirroring the postgres repo's TLS
structure**. It is split into a **Training Session** (study, no edits) and an **Execute Session**
(implement), followed by **Testing** and **Result** sections.

The gateway edge was already **validated live** — see `gateway-tls-test-results.md`. This task turns
that proof, plus the full postgres TLS pattern, into real operator code.

---

## Mission & guardrails

**Goal:** add `spec.tls` (+ `spec.sslMode`) to DocumentDB so the operator provisions **the same set
of certs postgres does** and wires them everywhere, following exactly how `kubedb.dev/postgres` does
TLS — and additionally wires the DocumentDB-specific **gateway** cert.

**Scope — TWO TLS layers:**

- **Layer A — Postgres TLS (mirror postgres 1:1):** the DocumentDB Postgres serves TLS; streaming
  replication is **mutual TLS** (client cert); the metrics exporter serves TLS. Certs: `server`,
  `client`, `metrics-exporter` (evaluate `grpc-*` for the coordinator too — see 1.5). Driven by an
  `SSLMode` enum exactly like postgres.
- **Layer B — Gateway edge TLS (DocumentDB-specific, validated):** the MongoDB gateway on 10260
  serves an operator-provisioned cert. Cert alias `gateway`, mounted at `/tls/certs/gateway`, adopted
  via env `CERT_PATH`/`KEY_FILE`.

> **⚠️ Overlap with existing backend TLS:** earlier we had a *separate* mechanism for backend/
> replication TLS. This task brings that under the **KubeDB cert-manager `spec.tls`** mechanism
> (like postgres). During Training, **locate the existing backend-TLS code and decide: replace it
> with the postgres-style path, or reconcile the two.** Do not leave two competing PKIs silently.

**Repos:**
- Operator: `/home/sabnaj/go/src/kubedb.dev/documentdb`
- API types: `/home/sabnaj/go/src/kubedb.dev/apimachinery`
- **Reference to copy from:** `/home/sabnaj/go/src/kubedb.dev/postgres`

**⚠️ API version rule (read before touching apimachinery) — use exactly these two, nothing else:**

- **COPY FROM (postgres reference): `apis/kubedb/v1` ONLY.** The postgres operator imports `v1`, and
  the full TLS pattern lives in **`apimachinery/apis/kubedb/v1/postgres_{types,helpers}.go`**.
  **Ignore `apis/kubedb/v1alpha1` and `apis/kubedb/v1alpha2` for postgres** — do not read or copy from
  them.
- **WRITE TO (documentdb target): `apis/kubedb/v1alpha2` ONLY.** DocumentDB is defined there and its
  operator imports `v1alpha2`, so the `TLS`/`SSLMode` fields + helpers go in
  **`apimachinery/apis/kubedb/v1alpha2/documentdb_{types,helpers}.go`**.
- Net: **copy from postgres `v1` → implement in documentdb `v1alpha2`.**

**Hard rules:**
- Mirror the **postgres structure and idioms** (naming, helpers, file layout, mount paths). Don't
  invent a new pattern.
- Change **only the DocumentDB operator + apimachinery**. Do not modify the postgres repo or the
  gateway image.
- The gateway image is unchanged — it already loads a PEM cert from files, enforces TLS by default,
  and hot-reloads on renewal (validated). Layer B is purely "hand it a cert."

**Validated facts for Layer B (from `gateway-tls-test-results.md`):**
- Gateway adopts a mounted cert when env **`CERT_PATH`** + **`KEY_FILE`** are set (entrypoint rewrites
  `SetupConfiguration` to `CertType: PemFile`).
- Gateway cert mount = **`/tls/certs/gateway/`** (`tls.crt`, `tls.key`, `ca.crt`).
- SANs must include the gateway **Service DNS names**.
- Pods are PetSet / `OnDelete` — a rollout needs pod deletes.

---

# SESSION 1 — TRAINING (STUDY ONLY, NO EDITS)

No code this session. Output = a **written mapping + design note**. Read, then produce the deliverable.

### 1.1 Postgres TLS API (apimachinery, version `v1`)
- `apimachinery/apis/kubedb/v1/postgres_types.go`
  - `TLS *kmapi.TLSConfig` field.
  - `SSLMode PostgresSSLMode` field + the **enum** (`disable`/`allow`/`prefer`/`require`/`verify-ca`/
    `verify-full`, ~line 386).
  - `PostgresCertificateAlias` values (~line 320): `server`, `client`, `metrics-exporter`,
    `archiver`, `grpc-ca`, `grpc-server`, `grpc-client`.
- `apimachinery/apis/kubedb/v1/postgres_helpers.go`
  - `SetTLSDefaults()` — sets a secret name **per alias** via `kmapi.SetMissingSecretNameForCertificate`.
  - `CertificateName(alias)` / `GetCertSecretName(alias)`.
  - SSLMode defaulting (`verify-full` when TLS set, `disable` otherwise).

### 1.2 Postgres TLS in the operator (consume + configure)
- `postgres/pkg/controller/petset.go` — the whole TLS surface:
  - Per-cert secret volumes: `tls-volume-server`/`-client`/`-exporter` (~lines 1835–1943), each from
    `GetCertSecretName(<alias>)`; the shared `PostgresSharedTlsVolumeName` mounted at
    **`/tls/certs`** (~301–342), plus per-cert mount paths `/certs/server`, `/certs/client`,
    `/certs/exporter` (~55–58).
  - How **`SSLMode` drives Postgres env / config** (`sslMode` → env at ~629, ~825, ~943) and how
    Postgres is told to serve TLS (`ssl=on`, `ssl_cert_file`/`ssl_key_file`/`ssl_ca_file`, `pg_hba`).
  - How the **exporter/monitor** consumes its cert (`~1061–1069`, exporter `sslrootcert`).
- **Replication (mutual TLS):** `postgres/pkg/ops/reconnect_standby.go` (~687) — `pg_basebackup`/
  standby uses `PGSSLMODE`, `PGSSLROOTCERT=/tls/certs/client/ca.crt`, `PGSSLCERT`, `PGSSLKEY`. This is
  how a replica presents the **client cert** to the primary.
- **Ops (reconfigure):** `postgres/pkg/ops/reconfigure_tls.go`, `postgres/pkg/ops/certificates.go` —
  how TLS is rotated/reconfigured via ops-requests (only relevant if DocumentDB has an ops-manager
  path).
- **Who creates the cert-manager `Certificate` CR** (key unknown): search the operator + vendored
  KubeDB libs (`kmodules.xyz/cert-manager-util`, any generic `certificate`/`tls` reconciler in the
  provisioner). Decide whether the **generic** reconciler turns `spec.tls.issuerRef` + `Certificates`
  into `Certificate` CRs for any DB automatically, or must be invoked. **Write the answer down.**

### 1.3 Postgres webhook (defaulting + validation)
- Find the postgres mutating/validating webhook: `SetTLSDefaults()` + `SSLMode` defaulting call, and
  the TLS validation (issuerRef required when TLS set; sslMode vs TLS consistency).

### 1.4 DocumentDB insertion points
- `apimachinery/apis/kubedb/v1alpha2/documentdb_types.go` — `DocumentDBSpec` (~86): **no `TLS`/
  `SSLMode` today.**
- `apimachinery/apis/kubedb/v1alpha2/documentdb_helpers.go` — **no TLS helpers today.**
- `documentdb/pkg/controllers/petset.go` — `getVolumes()` (~500), `getMainContainer()` (~248),
  `getMainContainerEnvs()` (~627), `getCoordinatorContainer()` (~329), `getInitContainers()` (~202).
- The documentdb webhook/defaulter (search `documentdb/pkg` + apimachinery).
- **The existing backend-TLS code** (per the overlap note): find it and characterize what it does.

### 1.5 DocumentDB-specific decisions to make (write these down)
- **How does the DocumentDB Postgres serve TLS?** Confirm how its `postgresql.conf`/`pg_hba` are
  produced (entrypoint/init) so `ssl=on` + cert paths can be injected the postgres way.
- **Does the gateway→Postgres loopback stay plaintext?** Yes — Postgres can serve TLS for replication
  while `pg_hba` still allows local/loopback trust; the gateway keeps `NoTls` on 9712. Confirm.
- **Coordinator gRPC:** decide whether the raft/gRPC coordinator port also gets TLS (`grpc-server`/
  `grpc-client` aliases) or is out of scope for v1.
- **Exporter:** does DocumentDB expose a metrics exporter that needs `metrics-exporter` TLS?
- **Cert alias set for DocumentDB** = `server`, `client`, `metrics-exporter` (postgres parity) **plus**
  `gateway` (edge). Confirm names.

### 1.6 Read the validated proof
Read `gateway-tls-test-results.md` end-to-end (Layer B target behavior).

### ✅ Session 1 deliverable
1. **File-by-file mapping**: each postgres TLS touch-point → DocumentDB equivalent (both layers).
2. **Answer to 1.2**: who creates `Certificate` CRs → scope of Execute Step 3.
3. **Decisions from 1.5**: alias set, gRPC/exporter in-or-out, loopback stays plaintext, and the
   **backend-TLS overlap resolution** (replace vs reconcile).

---

# SESSION 2 — EXECUTE (IMPLEMENT, MIRRORING POSTGRES)

Do steps in order; build/generate after each.

### Step 1 — API types (apimachinery, `v1alpha2`)
- Add `TLS *kmapi.TLSConfig` **and** `SSLMode DocumentDBSSLMode` to `DocumentDBSpec`.
- Add a `DocumentDBSSLMode` enum mirroring `PostgresSSLMode` (disable…verify-full).
- Add a `DocumentDBCertificateAlias` type with values: `server`, `client`, `metrics-exporter`,
  `gateway` (+ `grpc-*` if 1.5 said yes).

### Step 2 — API helpers (apimachinery)
Mirror postgres in `documentdb_helpers.go`:
- `SetTLSDefaults()` — call `SetMissingSecretNameForCertificate` **for every alias** (server, client,
  metrics-exporter, gateway) + default `SSLMode` (`verify-full` when TLS set, else `disable`).
- `CertificateName(alias)` / `GetCertSecretName(alias)`.
- Add cert secrets to `GetPersistentSecrets()` if postgres does.

### Step 3 — Certificate provisioning (per Session 1.2)
- If generic: register/enable DocumentDB in the shared TLS reconciler so it emits a `Certificate`
  per alias. Ensure **correct SANs per alias**:
  - `server` → Postgres pod FQDNs + governing Service DNS (mirror postgres server-cert SANs).
  - `client` → the replication client identity postgres uses (CN/OU for `streaming_replica`-style auth).
  - `gateway` → the **gateway Service DNS names**.
  - `metrics-exporter` → exporter Service DNS.
- If not generic: add certificate-ensure logic in the reconcile (issuerRef from `spec.tls`, one
  `Certificate` per alias, gate the petset on all being Ready) — mirror postgres.

### Step 4 — Postgres-side wiring (Layer A, petset)
Mirror postgres exactly:
- `getVolumes()`: add `tls-volume-server`/`-client`/`-exporter` from `GetCertSecretName(<alias>)`, and
  the shared `/tls/certs` volume.
- Postgres container: mount the certs (postgres convention), and drive **`ssl=on` + cert paths +
  pg_hba** from `SSLMode` (inject via the same env/config channel DocumentDB already uses for its
  postgresql.conf).
- **Replication:** wire the standby/basebackup path to present the **client cert**
  (`PGSSLMODE`/`PGSSLROOTCERT`/`PGSSLCERT`/`PGSSLKEY` = `/tls/certs/client/*`), mirroring
  `reconnect_standby.go`. Reconcile/replace the existing backend-TLS code per the 1.6 decision.
- **Exporter/coordinator:** wire their certs if in scope.

### Step 5 — Gateway-side wiring (Layer B, petset) — VALIDATED
- `getVolumes()`: add a `tls-volume-gateway` from `GetCertSecretName(gateway)`.
- `getMainContainer()`: read-only mount at **`/tls/certs/gateway`**.
- `getMainContainerEnvs()`: `CERT_PATH=/tls/certs/gateway/tls.crt`, `KEY_FILE=/tls/certs/gateway/tls.key`.
- Guard on `db.Spec.TLS != nil`; when unset, the gateway keeps its auto-gen self-signed cert (still TLS).

### Step 6 — Webhook
- Call `SetTLSDefaults()` in the defaulter; default `SSLMode`.
- Validate (mirror postgres): issuerRef present when TLS set; `SSLMode`/TLS consistency. No
  plaintext-only gateway mode.

### Step 7 — Codegen & build
Run generators (deepcopy, CRDs, clientset) + `make build` for apimachinery and the operator; fix drift.

### Implementation gotchas
- **Per-alias SANs** are the #1 breakage: server needs pod+Service DNS; gateway needs the gateway
  Service DNS; client needs the replication identity.
- Keep gateway PKI and Postgres/replication PKI **conceptually separate** even if the same issuer.
- Postgres serving TLS does **not** force the gateway→PG loopback to TLS — keep it plaintext/trust.
- PetSet `OnDelete`: rollout = delete pods (standbys first, primary last).

---

# TESTING (after implementation)

Prereqs: install the cert-manager **controller** (only CRDs on the cluster today) + an `Issuer`/
`ClusterIssuer` for the org CA. `export KUBECONFIG=/home/sabnaj/k3s.yaml`.

### Provisioning
1. Apply a DocumentDB with `spec.tls.issuerRef` (+ `sslMode: verify-full`), namespace `demo`.
2. Confirm the operator creates a `Certificate` **per alias** → Secrets; verify **each cert's SANs**
   (`openssl x509 -text`): server=pod/Service DNS, gateway=gateway Service DNS, client=replication id.

### Layer A — Postgres TLS
3. **Server TLS:** connect to the DocumentDB Postgres (9712) over TLS and verify against the CA
   (`psql "host=<pod> port=9712 sslmode=verify-full sslrootcert=ca.crt"`), or `openssl s_client`.
4. **Replication mutual TLS:** confirm a standby streams from the primary using the **client cert**
   (check standby logs / `pg_stat_replication`; break it by removing the client cert to prove it's
   enforced).
5. **Exporter TLS** (if in scope): metrics endpoint serves TLS.
6. **SSLMode:** `sslMode: disable` → Postgres serves no TLS; `verify-full` → enforced.

### Layer B — Gateway edge TLS (reuse `gateway-tls-test-results.md`)
7. Gateway serves our CA-signed cert (not `CN=localhost`); `SetupConfiguration` shows `CertType:
   PemFile`; `/tls/certs/gateway` mounted + `CERT_PATH`/`KEY_FILE` set.
8. `mongosh --tls --tlsCAFile <ca> --host dcdb.demo.svc --port 10260` + SCRAM → `{"ok":1}`;
   plaintext (no `--tls`) rejected.
9. **Hot-reload:** renew each cert → gateway hot-swaps with **no pod restart**; Postgres/replication
   pick up renewed certs per postgres behavior.

### Isolation & defaults
10. gateway→Postgres loopback still plaintext/trust; both PKIs behave independently.
11. DocumentDB **without** `spec.tls`: gateway still TLS (auto self-signed), Postgres per `sslMode`
    default — no regression.

---

# RESULT (fill in after testing)

| Layer | Check | Expected | Result | Notes |
|-------|-------|----------|--------|-------|
| prov | `Certificate` per alias → Secrets | server/client/exporter/gateway | ⬜ | |
| prov | Per-alias SANs correct | yes | ⬜ | |
| A | Postgres serves TLS (verify-full) | verified | ⬜ | |
| A | Replication is mutual TLS (client cert) | enforced | ⬜ | |
| A | Exporter TLS (if in scope) | serves TLS | ⬜ | |
| A | `sslMode` disable/verify-full honored | yes | ⬜ | |
| B | Gateway serves our cert, `PemFile` | yes | ⬜ | |
| B | mongosh TLS+CA+SCRAM via Service DNS | `{"ok":1}` | ⬜ | |
| B | Plaintext gateway rejected | yes | ⬜ | |
| both | Hot-reload on renewal, no restart | yes | ⬜ | |
| iso | gateway→PG loopback plaintext | unchanged | ⬜ | |
| iso | No-`spec.tls` still TLS (gateway auto) | yes | ⬜ | |

**Decisions recorded:** alias set; gRPC/exporter in-or-out; backend-TLS overlap resolution
(replace vs reconcile).

**Deviations from postgres:** (e.g.) gateway alias + `CERT_PATH`/`KEY_FILE` wiring has no postgres
analog; loopback stays plaintext.

**Files changed:**
- apimachinery: `v1alpha2/documentdb_types.go`, `v1alpha2/documentdb_helpers.go`, `constants.go`, generated code.
- operator: `documentdb/pkg/controllers/petset.go`, webhook, certificate-ensure step, replication/standby wiring.

**Verdict:** ⬜ full TLS (Postgres + gateway) implemented and verified / ⬜ blocked (reason).
