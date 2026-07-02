# DocumentDB TLS + Postgres TLS — How the Workflow Actually Works

This describes the **TLS workflow** of the official DocumentDB stack — not the code, but *who talks to whom, over what, and who provisions the certs*. Two repos are involved:

- **Operator**: `github.com/documentdb/documentdb-kubernetes-operator` — the Kubernetes operator. Built **on top of CloudNativePG (CNPG)**.
- **DocumentDB / gateway**: `github.com/documentdb/documentdb` — the actual database: a MongoDB-wire-protocol **gateway** (Rust sidecar) in front of **Postgres + the DocumentDB extension**.

There are two separate TLS stories, and they are owned by two different pieces of software:

1. **Gateway TLS** — the DocumentDB operator provisions this cert; the Rust gateway uses it. (Client ↔ DB edge.)
2. **Postgres TLS** — the DocumentDB operator does **not** manage this. **CNPG** provisions and uses it automatically (Postgres server + replication).

The doc is split accordingly: an **Operator part** and a **DB part**.

---

## 0. The big picture (all TLS legs)

```
                 TLS 1.2/1.3 (MongoDB wire protocol)
  ┌──────────┐  SCRAM-SHA-256 / OIDC over TLS   ┌─────────────────── Postgres Pod (primary) ───────────────────┐
  │ MongoDB  │ ───────────────────────────────▶ │  ┌──────────────┐  localhost, NO TLS  ┌───────────────────┐  │
  │ driver   │        port 10260                 │  │ documentdb   │ ──────────────────▶ │ Postgres +        │  │
  │ (client) │ ◀─────────────────────────────── │  │ gateway      │   loopback          │ DocumentDB ext    │  │
  └──────────┘                                   │  │ (Rust car)   │                     └─────────┬─────────┘  │
                                                 │  └──────────────┘                               │            │
                                                 │        ▲ mounts gateway cert at /tls            │            │
                                                 └────────┼───────────────────────────────────────┼────────────┘
                                                          │ Secret (tls.crt/tls.key)               │ TLS (mutual)
                                             ┌────────────┴────────────┐                streaming replication
                                             │ DocumentDB Operator     │                            │
                                             │ (cert-manager provision)│                            ▼
                                             └─────────────────────────┘         ┌────────── Postgres Pod (replica) ──────────┐
                                                                                 │ Postgres + DocumentDB ext + gateway sidecar │
                                                                                 └─────────────────────────────────────────────┘
```

| Leg | Between | TLS? | Who owns the certs |
|-----|---------|------|--------------------|
| **Client ↔ gateway** | MongoDB driver ↔ Rust gateway | **Yes** (TLS 1.2/1.3, server-auth) | **DocumentDB operator** (via cert-manager) |
| **gateway → Postgres** | gateway sidecar ↔ Postgres, same pod | **No** (plaintext loopback) | — |
| **Postgres ↔ Postgres** | primary ↔ replica (streaming replication) | **Yes** (mutual TLS) | **CNPG** (auto-managed) |
| **CNPG ↔ Postgres** | CNPG instance manager ↔ its Postgres | Yes (via same CNPG PKI) | **CNPG** (auto-managed) |

**The one insight that explains everything:** *TLS terminates at the gateway.* Client traffic is encrypted up to the gateway; the gateway→Postgres hop inside the same pod is deliberately plaintext over loopback; and Postgres's *own* encrypted traffic (replication) is a completely separate PKI that CNPG runs on its own.

---

# PART A — THE OPERATOR

The operator's TLS job is narrow: **provision the gateway certificate and hand it to the sidecar.** Everything about Postgres's own TLS it simply inherits from CNPG.

## A1. What the operator provisions (gateway cert only)

The `DocumentDB` custom resource exposes `spec.tls` with three sub-sections:

- `gateway` — **the only implemented one.** Controls the client-facing gateway cert.
- `postgres` — a **placeholder** (empty). Postgres-server TLS is explicitly a "future phase"; today the operator does nothing here (CNPG covers it instead).
- `globalEndpoints` — placeholder.

So in practice, the operator's TLS surface = **gateway TLS**, and it is **always on** — there is no "disable" option. If someone leaves the mode blank or supplies an unknown value, it fail-safes to a self-signed cert rather than serving plaintext.

## A2. The three gateway-cert modes (workflow)

`spec.tls.gateway.mode` selects **where the cert comes from**:

| Mode | Workflow |
|------|----------|
| **SelfSigned** (default) | The operator asks **cert-manager** to create a self-signed issuer and a certificate for the gateway. cert-manager writes the result into a Kubernetes Secret. |
| **CertManager** | Same as above, but the certificate is signed by the **user's own** cert-manager Issuer/ClusterIssuer. The user brings a trusted CA; the operator just requests the cert against it. |
| **Provided** | No cert-manager. The user **pre-creates a Secret** containing `tls.crt`/`tls.key`; the operator only validates it exists and has the right keys. |

In all three cases the end state is identical: **a Kubernetes Secret holding `tls.crt`/`tls.key`**, and the operator records "TLS ready + secret name" in the resource's status.

The cert's identity (SAN/DNS names) is the gateway's Kubernetes Service name (plus its `.namespace` / `.namespace.svc` forms), so drivers connecting through the Service can verify it. For cert-manager modes, the cert has a fixed lifetime (~90 days) and cert-manager renews it automatically before expiry.

## A3. How the cert reaches the gateway (the hand-off)

This is the operator→DB bridge, and it is **gated on readiness**:

1. The operator waits until cert-manager reports the certificate **Ready** (or, for Provided mode, that the Secret exists).
2. Only then does the operator tell the **CNPG sidecar-injector** the name of the gateway TLS secret.
3. When CNPG builds the Postgres pod, the sidecar-injector **injects the gateway container**, and:
   - **mounts the TLS Secret** read-only at `/tls` (so `tls.crt`/`tls.key` appear as files),
   - tells the gateway to use those files and to **not** start its own Postgres (CNPG already runs Postgres in the pod).

Net effect: the gateway boots with a real, operator-provisioned cert already on disk. If the secret weren't ready, the gateway would fall back to generating its own self-signed cert — the invariant is "never serve plaintext."

## A4. What the operator does NOT do for Postgres

The operator does **not** configure `ssl=on`, does not issue a Postgres server cert, and does not set up replication certs. That entire responsibility is delegated to **CNPG** (see Part B). The operator's `spec.tls.postgres` field exists only as a placeholder for a future phase where the operator might take over that PKI.

---

# PART B — THE DATABASE (runtime)

At runtime there are three encryption boundaries. Each component uses TLS differently.

## B1. Client → Gateway (TLS terminates here)

This is the only leg an external client sees.

- The gateway listens on **port 10260** and speaks the **MongoDB wire protocol** over TLS 1.2/1.3 (server-authenticated).
- **TLS is mandatory by default.** The gateway can also run in an "allow" posture where a **single port serves both** encrypted and plaintext clients — it sniffs the first few bytes of each connection to tell a TLS handshake from a plaintext one. But out of the box, every connection must be TLS.
- After the TLS handshake, the client authenticates using **SCRAM-SHA-256** (or OIDC). Importantly, the gateway does **not** verify the SCRAM proof itself — it **asks Postgres** to verify it (the DocumentDB extension holds the stored credential). So the client authenticates *to* the gateway, but the *check* happens in Postgres.
- **Cert hot-reload:** the gateway watches its cert files (checking roughly once a minute) and swaps in a renewed cert **without a restart**. This is what lets cert-manager renewals take effect live. In-flight connections keep the old cert; new connections get the new one.

**Component's view of TLS:** the gateway is a TLS *server*. It owns the client-facing encryption and is the trust boundary for the whole system.

## B2. Gateway → Postgres (deliberately plaintext)

- The gateway connects to Postgres at **localhost** inside the same pod (loopback), using a connection pool configured with **no TLS**.
- This is intentional: the two processes share a pod and a network namespace; nothing off-host can see loopback traffic, so encrypting it would add cost with no security gain.
- All translated MongoDB queries run over this plaintext loopback pool, and SCRAM verification (from B1) also rides this channel.

**Component's view of TLS:** none — this hop is trusted by co-location.

## B3. Postgres ↔ Postgres (CNPG's own TLS)

This is the "Postgres TLS" the filename refers to, and it is entirely **CNPG's** doing — independent of the DocumentDB operator.

When CNPG creates a Postgres cluster, it **automatically** provisions its own PKI (no user action, no cert-manager required):

- a **server CA** secret (`<cluster>-ca`),
- a **server TLS cert** secret (`<cluster>-server`) — Postgres serves TLS with this,
- a **`streaming_replica` client cert** secret (`<cluster>-replication`) — used for replication auth.

CNPG then uses these certs as follows:

- **Streaming replication (primary ↔ replica) is mutual TLS.** Replicas connect to the primary with the `streaming_replica` client certificate; the primary verifies it against the client CA and maps the cert's identity to the replication role (certificate-based auth, no password).
- **The Postgres server presents its server cert** to anyone connecting over the network. (The in-pod gateway ignores this by using loopback+NoTLS, but any *cross-pod* Postgres connection — i.e. replication — is encrypted.)
- Certs are **auto-renewed** (~90-day life, renewed ~1 week before expiry). No operator involvement.
- Users *can* override any of these with their own server/client CA secrets (e.g. to plug in cert-manager), but by default CNPG self-manages them.

**Component's view of TLS:** Postgres is both a TLS server (serving replicas) and, on the replica side, a TLS client presenting a cert. This PKI is separate from the gateway's PKI — they don't share a CA.

---

## B4. Putting the two PKIs side by side

| | **Gateway PKI** | **Postgres/CNPG PKI** |
|---|---|---|
| Provisioned by | DocumentDB operator (via cert-manager) | CNPG (self-managed by default) |
| Used by | Rust gateway, for client connections | Postgres, for replication + server auth |
| Cert modes | SelfSigned / CertManager / Provided | operator-managed or user-provided secrets |
| Auth style | server-auth TLS + SCRAM (verified in PG) | **mutual** TLS (client-cert auth for replication) |
| Rotation | cert-manager renew → gateway hot-reloads | CNPG auto-renew → CNPG rolls certs |
| Trust boundary | the client↔gateway edge | inside the Postgres cluster |

The gateway→Postgres loopback hop sits *between* these two PKIs and uses neither — it's plaintext by design.

---

## C. End-to-end workflow (fresh install)

1. User applies a `DocumentDB` resource (optionally choosing a gateway TLS mode).
2. **Operator** requests the gateway cert from cert-manager (or validates a Provided secret) → a Secret with `tls.crt`/`tls.key` appears; the operator marks TLS ready.
3. **Operator** hands that secret name to the CNPG sidecar-injector (only after "ready").
4. **CNPG** creates the Postgres cluster and, on its own, provisions the Postgres server CA + server cert + `streaming_replica` cert.
5. The **sidecar-injector** injects the gateway container into each Postgres pod, mounts the gateway secret at `/tls`, and tells the gateway not to start its own Postgres.
6. **Gateway** boots, loads its cert, enforces TLS, and listens on port 10260. It begins watching the cert files for renewals.
7. **Postgres** (via CNPG) comes up serving TLS; replicas join the primary over **mutual TLS** streaming replication.
8. A **MongoDB driver** connects over TLS to the gateway → authenticates with SCRAM → the gateway verifies the SCRAM proof by calling Postgres over the **plaintext loopback** pool → queries run.
9. Over time, cert-manager renews the gateway cert (gateway hot-swaps it live) and CNPG renews the Postgres certs — both without downtime.

---

## D. Things worth remembering

- **Two independent PKIs.** The DocumentDB operator secures only the *client-facing gateway*. Postgres's own TLS (server + replication) is CNPG's, provisioned automatically, on a different CA.
- **TLS terminates at the gateway.** Client→gateway is encrypted; gateway→Postgres is plaintext loopback on purpose (same pod).
- **Gateway TLS is always on.** No "disabled" mode; unknown/blank config fail-safes to self-signed. The gateway can *additionally* accept plaintext on the same port in an "allow" posture, but never runs plaintext-only.
- **SCRAM is verified by Postgres, not the gateway.** The client authenticates over the TLS channel, but the credential check happens in the DocumentDB Postgres extension.
- **Replication is mutual TLS.** CNPG uses a `streaming_replica` client certificate — replicas prove their identity with a cert, not a password.
- **Both PKIs auto-renew** (cert-manager for the gateway with live hot-reload; CNPG for Postgres), so certificate expiry doesn't require manual intervention.
- **The operator's `spec.tls.postgres` is a placeholder** — a hook for a future phase where the operator might own the Postgres PKI instead of leaving it to CNPG.
