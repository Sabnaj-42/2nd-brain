# DocumentDB failover writer — persistent vs reconnect

Small Node.js app that inserts documents into DocumentDB through the Mongo gateway and
compares two client strategies across a primary failover.

- `MODE=persistent` — reuse one `MongoClient`, let the driver self-heal.
- `MODE=reconnect`  — on a network error, discard the client and build a new one (Postgres-style).

Both use a stable `_id` + `retryWrites=true`, so retries are idempotent (no duplicates).

## Run
```bash
npm install
export MONGO_URI='mongodb://default_user:PASS@HOST:10260/?tls=true&tlsAllowInvalidCertificates=true&retryWrites=true&serverSelectionTimeoutMS=3000&connectTimeoutMS=2000&socketTimeoutMS=2000'
MODE=reconnect  node app.js     # then kill the primary mid-run
MODE=persistent node app.js
```
(Run it from inside the cluster — e.g. a pod in the db namespace — so it connects to the
`dcdb` ClusterIP, which re-points to the new primary. A host port-forward is pinned to one
pod and dies on failover.)

## Measured results (3-replica dcdb, kill primary mid-write)
| Metric | persistent (reuse client) | reconnect (new client on error) |
|---|---|---|
| initial connect | ~50 ms | ~50 ms |
| failover recovery | ~20s … 65s … (variable; once needed careful error handling not to crash) | **~14.5s** (≈ election time, consistent) |
| duplicates / data loss | 0 / 0 | 0 / 0 |

**Conclusion: `reconnect` is faster and far more predictable.** Initial connect is identical.
After a failover, recreating the client lands you back at ~election time (~14–15s) every time,
while reusing the client is slower and highly variable (depends on driver internals, kube-proxy
conntrack, and cluster state). With older clients (e.g. mongosh) the persistent path was much
worse (~56–71s or never). Data is never lost or duplicated either way thanks to the stable `_id`.
