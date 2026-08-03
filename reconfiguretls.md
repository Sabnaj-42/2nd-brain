# Implement `ReconfigureTLS` OpsRequest for DocumentDB

## Goal

Implement the `ReconfigureTLS` ops request for the KubeDB DocumentDB operator, following the
existing Postgres implementation as the reference pattern, and verify it end-to-end on a live
cluster for both standalone and HA (3 replicas) topologies.

## Scope

| # | Deliverable | Repo |
|---|-------------|------|
| 1 | API types / helpers for DocumentDB `ReconfigureTLS` | `/home/sabnaj/go/src/kubedb.dev/apimachinery` |
| 2 | Ops request reconciler + TLS reconfigure logic | `/home/sabnaj/go/src/kubedb.dev/documentdb` |
| 3 | Test YAMLs + test results | `/home/sabnaj/go/src/kubedb.dev/provisioner/reconfiguretls/` |

## Reference material

**Primary pattern to follow — Postgres:**
- `/home/sabnaj/go/src/kubedb.dev/postgres`
- `/home/sabnaj/go/src/kubedb.dev/apimachinery` — confirm *which* Postgres API directory the
  Postgres operator actually imports before mirroring it for DocumentDB.

**Target codebase to understand first:**
- `/home/sabnaj/go/src/kubedb.dev/documentdb` — explore the current components, ops request
  structure, and conventions already in place. Match them; do not invent a new layout.

**Docs:**
- https://kubedb.com/docs/v2026.6.19/guides/postgres/ — how Reconfigure TLS is exercised for
  Postgres. Use this as the template for the DocumentDB test procedure.

## Implementation steps

1. Explore `documentdb` to map its existing ops request flow (add / remove / rotate cert paths,
   webhook validation, phase transitions).
2. Read the Postgres `ReconfigureTLS` implementation end-to-end as the reference.
3. Add / update the DocumentDB `ReconfigureTLS` API in `apimachinery`, mirroring Postgres.
4. Implement the ops request logic in the `documentdb` operator.
5. Make the operator build pass.

## Testing

**Cluster access:**
```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
```

**Deploy the change:**
1. Build the operator image and push it.
2. Update the image in the `kubedb` namespace for both:
   - provisioner — `/home/sabnaj/go/src/kubedb.dev/provisioner`
   - ops-manager — `/home/sabnaj/go/src/kubedb.dev/ops-manager`

**Run the tests:**
1. Deploy a DocumentDB object (existing DocumentDB YAMLs live in
   `/home/sabnaj/go/src/kubedb.dev/provisioner`).
2. Create `/home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/documentdb/reconfiguretls/yaml/` and keep all ReconfigureTLS test
   YAMLs there.
3. Create `/home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/documentdb/reconfiguretls/test-result.md` and record the results of every run there.
4. Test **both** topologies:
   - Standalone
   - HA — `replicas: 3`

**Cover these cases** (per the Postgres guide):
- Add TLS to a running non-TLS DocumentDB
- Rotate certificates
- Update the issuer / certificate spec
- Remove TLS

### Verifying the connection

**Important:** verification is done through the **MongoDB-compatible gateway**, *not* by
connecting to the backend Postgres directly. Every TLS assertion must be made against the
gateway endpoint — that is the surface ReconfigureTLS is expected to change.

Connect with `mongosh`:

```bash
mongosh 'mongodb://default_user:<PASSWORD>@127.0.0.1:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsCAFile=/tls/certs/gateway/ca.crt'
```

- Replace `<PASSWORD>` with the value from the corresponding auth secret for the DocumentDB
  object under test (it changes per instance — read it from the secret, don't hardcode).
- Port-forward the gateway to `127.0.0.1:10260` first.
- `tlsCAFile` points at the gateway CA — re-read it after each ops request, since rotate /
  issuer-change cases replace it.
- For the **remove TLS** case, drop `tls=true` and `tlsCAFile` and confirm the plain connection
  succeeds; for the **add TLS** case, confirm the plain connection now fails.

## Definition of done

- [ ] `apimachinery` API changes merged into the DocumentDB types
- [ ] `documentdb` operator builds cleanly
- [ ] ReconfigureTLS ops request succeeds on standalone
- [ ] ReconfigureTLS ops request succeeds on HA (3 replicas)
- [ ] YAMLs committed under `/home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/documentdb/reconfiguretls/yaml/`
- [ ] Results written to `/home/sabnaj/go/src/github.com/sabnaj-42/2nd-brain/documentdb/reconfiguretls/test-result.md`

## Notes / open questions

- Verify the exact `apimachinery` package path used by the DocumentDB operator import before
  editing — Postgres and DocumentDB may not share the same API version directory.
