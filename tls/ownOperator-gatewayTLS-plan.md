# Gateway TLS in Our Own Operator — Design & Workflow Plan

**Scope of this doc:** how *our* operator enables **gateway TLS only** — the client ↔ gateway edge.
This is a logic/workflow plan, not code.

> **✅ Validated live on 2026-07-07** (see `gateway-tls-test-results.md`). Concrete facts confirmed
> against the running KubeDB `dcdb` cluster, now baked into this plan:
> - Cert mount path = **`/tls/certs/gateway/`** (`tls.crt`/`tls.key`), following the postgres
>   `/tls/certs` convention.
> - The gateway adopts a mounted cert when env **`CERT_PATH`/`KEY_FILE`** are set — its
>   `emulator_entrypoint.sh` rewrites `CertificateOptions` to `CertType: PemFile`. No image change.
> - Enforce-by-default, ~60s hot-reload, and PemFile loading all work out of the box (upstream image).
> - So the operator's whole job = **provision Secret → gate on ready → mount at `/tls/certs/gateway`
>   + set `CERT_PATH`/`KEY_FILE` on the `documentdb` container.**

**Deliberately out of scope (already handled elsewhere):**
- Postgres server TLS and streaming-replication (mutual) TLS — **we already provision and manage
  this ourselves** in the backend. Nothing in this doc touches it.
- CNPG — **we are not using CNPG.** That means the entire official "sidecar-injector plugin +
  `gatewayTLSSecret` parameter" hop does **not** exist for us. Our operator owns the Postgres pod
  template directly, so it mounts the gateway cert itself.

The result: our TLS feature is a short, self-contained pipeline that our operator runs end to end.

---

## 0. The one job

Our operator's gateway-TLS responsibility reduces to a single pipeline:

```
provision a cert Secret  →  gate on readiness  →  mount it into the gateway container  →  gateway enforces TLS
```

Everything below is just that pipeline, made robust.

The invariant that drives every design choice: **the gateway never serves plaintext-only.** TLS is
always on; the only question is *where the cert comes from*.

---

## 1. Topology (no CNPG)

Because we own the Postgres pod and manage backend/replication TLS ourselves, the picture is simpler
than the official one — there is no CNPG, no plugin, no sidecar-injector.

```
                 TLS 1.2/1.3 (MongoDB wire protocol)
  ┌──────────┐  SCRAM-SHA-256 over TLS         ┌──────────────── Postgres Pod (ours) ────────────────┐
  │ MongoDB  │ ──────────────────────────────▶ │  ┌──────────────┐  localhost, NO TLS ┌────────────┐ │
  │ driver   │        port 10260                │  │ gateway      │ ─────────────────▶ │ Postgres + │ │
  │ (client) │ ◀────────────────────────────── │  │ (sidecar)    │   loopback         │ DocumentDB │ │
  └──────────┘                                  │  └──────┬───────┘                    │ extension  │ │
                                                │         ▲ mounts /tls (ro)           └─────┬──────┘ │
                                                └─────────┼──────────────────────────────────┼────────┘
                                                          │ Secret (tls.crt/tls.key)          │
                                             ┌────────────┴────────────┐        backend + replication TLS
                                             │  OUR Operator           │        (our own PKI — separate,
                                             │  - cert reconciler       │         already done, NOT here)
                                             │  - renders the pod spec  │
                                             │    (mounts the Secret)   │
                                             └─────────────────────────┘
```

Three legs, same as before, but now **both PKIs are ours** — they're just separate:

| Leg | TLS? | Owned by | This doc? |
|-----|------|----------|-----------|
| client ↔ gateway | **Yes**, server-auth TLS 1.2/1.3 | our operator (gateway PKI) | **Yes** |
| gateway → Postgres | No, plaintext loopback (same pod) | — | no (by design) |
| Postgres ↔ Postgres (replication) | Yes, mutual TLS | our operator (backend PKI, already built) | no |

Key point: the gateway cert and the backend/replication cert are **two independent PKIs on
different CAs**. This doc only builds the first one. Keep them separate — don't share a CA between
the client edge and the replication mesh.

---

## 2. CRD surface

Add to the `DocumentDB` custom resource:

- `spec.tls.gateway.mode` — **closed enum**: `SelfSigned` (default) / `CertManager` / `Provided`.
  **No `Disabled` value** — this encodes "TLS always on" at the API level.
- `spec.tls.gateway.certManager` — `issuerRef`, extra `dnsNames`, optional `secretName`
  (used only in `CertManager` mode).
- `spec.tls.gateway.provided` — `secretName` (used only in `Provided` mode).
- `status.tls` — `{ ready: bool, secretName: string, message: string }`.
  This status block is the **contract** the pod-rendering code reads. Nothing downstream reads the
  spec directly; it reads `status.tls`.

Defaulting rule (the no-plaintext invariant, enforced in code): **missing / blank / unknown mode →
`SelfSigned`.** A stale `Disabled` left in etcd also fail-safes to `SelfSigned`.

---

## 3. Certificate reconciler (provisioning)

A reconcile loop whose only goal is to make `status.tls.ready = true` with a valid `secretName`.
The end state is identical in all three modes: **a Secret holding `tls.crt` + `tls.key`.** Branch on
mode:

### SelfSigned (default)
1. Ensure a cert-manager **self-signed Issuer** exists (named per-CR).
2. Ensure a cert-manager **Certificate** exists → target Secret `<cr>-gateway-cert-tls`,
   ~90d lifetime, ~15d renewBefore, usage = **server-auth**.
3. **SANs = the gateway Service DNS names** (`<svc>`, `<svc>.<ns>`, `<svc>.<ns>.svc`).
   Critical: a driver verifies the cert against the name it dials, so the cert's identity must be
   the Service name.
4. Watch the Certificate's `Ready` condition and mirror it into `status.tls`.

### CertManager
Same Certificate shape, but `issuerRef` points at the **user's own** Issuer/ClusterIssuer.
We don't create an issuer. **Merge** the user's `dnsNames` with our Service DNS names so verification
still works.

### Provided
No cert-manager. Just **validate** the referenced Secret exists and contains **exactly `tls.crt`
and `tls.key`**. Present → ready; missing/malformed → set a clear `status.tls.message` and requeue.

### Cross-cutting reconciler rules
- **Own/watch** the Certificate and Issuer objects so their changes re-trigger reconcile.
- While a cert is still provisioning, **requeue — do not error.** Waiting is normal.
- Write `status.tls` with conflict-retry (another controller reads it).

---

## 4. The readiness gate (most important handoff)

The code that renders the Postgres pod template must read `status.tls` and **only mount the Secret
once `ready == true` and `secretName != ""`.**

This gate is what guarantees the gateway never boots pointed at a half-written or missing Secret.
Before ready, either don't create the pod yet, or let the gateway fall back to its own auto-generated
self-signed cert — but **never mount an unready Secret and never serve plaintext-only.**

---

## 5. Service identity must exist first

The SANs in Step 3 depend on the gateway Service name, so **create (or fix the deterministic name
of) the gateway Service before issuing the cert.** Ordering: Service name → cert SANs → client
verification. If the Service is renamed or created later, the cert won't match and every TLS client
fails verification. Pin the Service name early and derive SANs from it.

---

## 6. Mount + inject (directly, no plugin)

This is where dropping CNPG simplifies everything. **Our operator renders the Postgres pod template
itself**, so it mounts the cert directly — no plugin, no parameter passing:

When `status.tls.ready`, in the pod template:
- add a **volume** sourced from the ready Secret,
- **mount it read-only at `/tls`** in the gateway container (so `tls.crt`/`tls.key` appear as files),
- tell the gateway where the cert is (cert-path `/tls/tls.crt`, key-file `/tls/tls.key`),
- ensure the gateway does **not** start its own Postgres (we run Postgres in the same pod) and only
  the primary does user creation.

End state: `tls.crt`/`tls.key` on disk at `/tls`, gateway told to use them.

---

## 7. Gateway enforces TLS at boot

Whatever gateway image we run:
- It must **enforce TLS by default** — mandatory, not opt-in.
- It must **fail-safe**: if the cert files are somehow missing, auto-generate a self-signed cert
  rather than ever serving plaintext-only.
- (Optional) single-port dual-protocol sniff for an "allow" posture, but ship **enforce-on** by default.

If we reuse the upstream gateway image, its entrypoint already turns cert-path/key-file into
file-based cert options and defaults enforce-TLS on. If we build our **own** gateway, we must
replicate: (1) load cert/key from files, (2) enforce-TLS default with self-signed fail-safe,
(3) the hot-reload watcher in Step 8.

---

## 8. Rotation / hot-reload (must be automatic)

- **cert-manager modes:** cert-manager renews before expiry → updates the Secret → kubelet refreshes
  the mounted files → the gateway's **file watcher (mtime poll, ~60s) rebuilds its TLS acceptor and
  swaps it atomically — no pod restart.** In-flight connections keep the old cert; new connections
  get the new one. Our operator does nothing at renewal time.
- **Provided mode:** rotation is the **user's** responsibility — document that they update the Secret;
  the same file-watch picks it up live.
- If we build our own gateway, the atomic watch-and-swap is **required** — otherwise renewals need
  pod restarts.

---

## 9. Failure & edge semantics to bake in

- **No-plaintext invariant** everywhere: unknown/blank/`Disabled` mode → `SelfSigned`;
  enforce-TLS defaults on; self-signed fail-safe if files missing.
- **Requeue, don't fail**, while a cert is provisioning.
- **Provided Secret must contain exactly `tls.crt`/`tls.key`** — validate and surface a clear status
  message otherwise.
- **SAN mismatch is the #1 real-world breakage** — make Service-name → SAN derivation airtight.
- **Keep the two PKIs separate** — the gateway (client-edge) CA must not be the backend/replication CA.

---

## 10. Validation checklist

1. **Provisioning:** apply the CR in each mode → the Secret appears with both keys and
   `status.tls.ready=true`.
2. **Mount:** exec into the gateway container → `/tls/tls.crt` + `/tls/tls.key` present, read-only.
3. **Client edge:** connect a MongoDB driver with TLS → handshake succeeds, cert verifies against the
   Service DNS name; a plaintext client is **rejected** in enforce mode.
4. **Rotation:** force a renewal (or shorten the cert lifetime) → gateway serves the new cert with
   **no restart** and in-flight connections aren't dropped.
5. **Isolation:** confirm gateway→Postgres is plaintext loopback, and our backend replication TLS is
   untouched and still on its own PKI.

---

## 11. Summary (one paragraph)

Add a closed-enum `spec.tls.gateway` field to the CR; write a reconciler that turns each mode
(`SelfSigned` / `CertManager` / `Provided`) into a ready `tls.crt`/`tls.key` Secret whose SANs are
the gateway Service DNS names; gate all downstream work on `status.tls.ready`; **mount that Secret
read-only at `/tls` directly in our own Postgres pod template (no CNPG, no plugin)**; boot the
gateway enforce-TLS-by-default with a file-watch hot-reload; and let cert-manager handle renewals
while our separate, already-built backend/replication PKI runs untouched.
