# DocumentDB TLS — architecture of the updated operator

This mirrors the **KubeDB postgres** operator: the **ops controller creates** the cert-manager
`Certificate` CRs, and the **provisioner only consumes** the resulting secrets. The two run as two
subcommands of the same `documentdb-operator` binary, deployed as two StatefulSets.

```mermaid
flowchart TB
    user([DocumentDB CR<br/>spec.tls + spec.sslMode]):::cr

    subgraph OPS["ops-manager StatefulSet — arg: <b>ops</b>"]
      opscmd["pkg/cmds/ops_operator.go (NEW)<br/>pkg/cmds/server/ops_operator.go (NEW)"]:::new
      opsctl["pkg/ops — manageDocumentDBEvent<br/>→ ensureGrpcTLS → manageTLS<br/>(watches DocumentDBs via dbInformer)"]:::same
      opscert["pkg/ops/certificates.go<br/>ensureServer/Client/GatewayCert (+FQDN SAN)<br/>ensureGrpcTLS: grpc-ca → grpc-server/client"]:::edit
      opscmd --> opsctl --> opscert
    end

    cm["cert-manager<br/>shared CA Issuer + isolated grpc-CA Issuer"]:::ext
    subgraph SECRETS["public tls secrets (shared dcdb-CA)"]
      s1[dcdb-tls-server-cert]:::sec
      s2[dcdb-tls-client-cert]:::sec
      s3[dcdb-tls-gateway-cert]:::sec
    end
    subgraph GRPC["dedicated gRPC chain (isolated grpc-CA)"]
      g0[dcdb-tls-grpc-ca-cert]:::sec
      g1[dcdb-tls-grpc-server-cert]:::sec
      g2[dcdb-tls-grpc-client-cert]:::sec
    end

    subgraph PROV["provisioner StatefulSet — arg: <b>operator</b>"]
      provcmd["pkg/cmds/server/operator.go<br/>(cert-manager client removed)"]:::edit
      recon["pkg/controllers/reconcile.go<br/>missingCertSecrets() gate — WAITS<br/>(manageTLS call removed)"]:::edit
      del["pkg/controllers/certificates.go<br/>DELETED (was the wrong place)"]:::del
      petset["pkg/controllers/tls.go + petset.go<br/>mount secrets, set SSL env (unchanged)"]:::same
      provcmd --> recon --> petset
    end

    subgraph POD["DocumentDB Pod (per replica)"]
      init["init container<br/>copy /certs → /tls (chmod 0600)"]:::same
      pg["documentdb (Postgres :9712)<br/>server + replication TLS<br/>/tls/certs/{server,client}"]:::same
      gw["gateway (Mongo wire :10260)<br/>/tls/certs/gateway"]:::same
      coord["documentdb-coordinator<br/>raft gRPC on isolated grpc-CA<br/>/grpc/server + /grpc/client"]:::same
      init --> pg & gw & coord
    end

    auth1[/"dcdb-tls-admin-auth<br/>user=documentdb"/]:::auth
    auth2[/"dcdb-tls-auth<br/>user=default_user"/]:::auth

    user --> opsctl
    user --> recon
    opscert -->|create/patch| cm
    cm --> s1 & s2 & s3
    cm --> g0 --> g1 & g2
    s1 & s2 & s3 & g1 & g2 -.->|gate waits, then mounts| petset
    petset --> POD
    g1 & g2 -->|/grpc/server, /grpc/client| coord
    auth1 -->|POSTGRES_USER/PASSWORD| pg
    auth1 -->|POSTGRES_USER/PASSWORD| coord
    auth2 -->|USERNAME/PASSWORD| gw

    classDef new fill:#1b5e20,stroke:#a5d6a7,color:#fff
    classDef edit fill:#0d47a1,stroke:#90caf9,color:#fff
    classDef del fill:#5f0000,stroke:#ef9a9a,color:#fff,stroke-dasharray:4 3
    classDef same fill:#37474f,stroke:#b0bec5,color:#fff
    classDef sec fill:#4a148c,stroke:#ce93d8,color:#fff
    classDef ext fill:#3e2723,stroke:#bcaaa4,color:#fff
    classDef cr fill:#004d40,stroke:#80cbc4,color:#fff
    classDef auth fill:#e65100,stroke:#ffcc80,color:#fff
```

Legend — 🟩 new file · 🟦 edited · 🟥 deleted · ⬛ unchanged · 🟪 tls secret · 🟧 auth secret.

## Files changed (documentdb operator repo)

| File                                                                | Change                    | Why                                                                                                                                                                                                                                                                                                                                                             |
| ------------------------------------------------------------------- | ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `pkg/ops/certificates.go`                                         | **edit**            | Creates the server/client/gateway Certificates (+FQDN SAN).**Added `ensureGrpcTLS`** (ported from postgres): a self-signed bootstrap Issuer → `grpc-ca` (isCA) → grpc-CA Issuer → `grpc-server` + `grpc-client` leaf certs. Issuers are created via the cert-manager typed clientset (the ops manager's scheme doesn't register cert-manager). |
| `pkg/ops/postgres.go`                                             | **edit**            | `manageDocumentDBEvent` now calls `ensureGrpcTLS` **before** `manageTLS` (postgres order); `NotFound` → 2s requeue.                                                                                                                                                                                                                              |
| `pkg/cmds/server/ops_operator.go`                                 | **new**             | Runs the`pkg/ops` controller (builds clients + informers, `ops.New(...)`, `Init()`, `RunControllers`). Mirrors postgres `pkg/cmds/server/ops_operator.go`.                                                                                                                                                                                            |
| `pkg/cmds/ops_operator.go`                                        | **new**             | `NewCmdOpsOperator` — the `ops` cobra subcommand.                                                                                                                                                                                                                                                                                                          |
| `pkg/cmds/root.go`                                                | **edit (+1)**       | Registers the`ops` subcommand.                                                                                                                                                                                                                                                                                                                                |
| `apimachinery .../v1alpha2/documentdb_types.go` + `_helpers.go` | **edit**            | +`grpc-ca`/`grpc-server`/`grpc-client` cert aliases + `GetGRPCIssuerName`/`GetGRPCSelfSignedIssuerName`.                                                                                                                                                                                                                                              |
| `pkg/controllers/tls.go`                                          | **edit**            | +`upsertGRPCVolumes` (grpc-server/grpc-client secret volumes, keys remapped to `server.crt`/`client.crt`/`ca.crt`); `coordinatorTLSVolumeMounts` now mounts the **dedicated** grpc volumes at `/grpc/server` + `/grpc/client` (was reusing server/client); grpc secrets added to the `requiredCertSecretNames` wait-gate.                 |
| `pkg/controllers/petset.go`                                       | **edit**            | `getVolumes` also calls `upsertGRPCVolumes`.                                                                                                                                                                                                                                                                                                                |
| `pkg/controllers/certificates.go`                                 | **deleted (−300)** | Earlier divergence: cert creation duplicated into the**provisioner**. Postgres never does this.                                                                                                                                                                                                                                                           |
| `pkg/controllers/reconcile.go`, `pkg/cmds/server/operator.go`   | **edit**            | Provisioner no longer creates certs / needs a cert-manager client; keeps only the`missingCertSecrets()` wait-gate.                                                                                                                                                                                                                                            |
| `pkg/ops/workqueue.go`, `controller.go`                         | unchanged                 | Already the faithful`dbInformer`/`dbQueue`/`RunControllers` structure.                                                                                                                                                                                                                                                                                    |

## Deployment

| StatefulSet                   | Command                          | Role                                                            |
| ----------------------------- | -------------------------------- | --------------------------------------------------------------- |
| `kubedb-kubedb-ops-manager` | `documentdb-operator ops`      | Creates the cert-manager Certificates (`pkg/ops`).            |
| `kubedb-kubedb-provisioner` | `documentdb-operator operator` | Waits for the secrets, builds the PetSet (`pkg/controllers`). |

Both run image `sabnaj/documentdb-operator:dcdb-tls12`. The `ops-manager` ServiceAccount already has
the cert-manager `Certificate`/`Issuer` create/patch RBAC.

## Dedicated gRPC CA chain (coordinator raft gRPC)

The coordinator's internal raft gRPC gets its **own isolated CA**, so it is not signed by the public
Postgres/gateway CA — full postgres parity:

```
grpc-selfsigned Issuer ──▶ grpc-ca (isCA) ──▶ grpc-issuer (CA Issuer)
                                                  ├──▶ grpc-server  (CN=<govsvc>, ServerAuth)
                                                  └──▶ grpc-client  (CN=documentdb-coordinator, ClientAuth)
```

The coordinator binary reads hardcoded `/grpc/server/{server.crt,server.key,ca.crt}`, so the
operator mounts the `grpc-server` secret there (keys remapped to those filenames) and the
`grpc-client` secret at `/grpc/client` — **no coordinator image change**. Verified isolated: the
grpc-CA fingerprint differs from the main `dcdb-CA` (see [`evidence.txt`](./evidence.txt) §4).

> Scope: this delivers the dedicated cert **chain** (postgres structure). The coordinator gRPC
> server currently sets `ClientAuth: tls.NoClientCert`, so it does not yet *enforce* mutual TLS;
> enabling `RequireAndVerifyClientCert` (and presenting `/grpc/client`) is a separate
> `documentdb-coordinator` image change. The `grpc-client` cert is already provisioned for it.

## Two auth secrets (unchanged code — the operator already does this right)

| Secret                  | User             | Consumed by                                     | Env                                       |
| ----------------------- | ---------------- | ----------------------------------------------- | ----------------------------------------- |
| `dcdb-tls-admin-auth` | `documentdb`   | Postgres backend (main container + coordinator) | `POSTGRES_USER` / `POSTGRES_PASSWORD` |
| `dcdb-tls-auth`       | `default_user` | MongoDB-wire gateway                            | `USERNAME` / `PASSWORD`               |
