# DocumentDB Monitoring — Test Results

**Date:** 2026-07-24
**Cluster:** `kind-kind` (single node, amd64)
**Operator:** KubeDB DocumentDB operator (running in `kubedb` namespace)
**Goal:** Test monitoring for a DocumentDB instance **without changing the operator repo code**, using:
- **Native OpenTelemetry (OTLP)** for the **gateway** (MongoDB-wire translator), and
- **postgres_exporter** for the **backend Postgres**, collecting the **full** metric set (like KubeDB postgres), not just a liveliness `up`.

> **TL;DR**
> - ✅ **Backend Postgres via postgres_exporter — FULLY WORKING.** 526 metric families at the exporter, **483 distinct `pg_*` series in Prometheus**, scraped through a ServiceMonitor and rendered in Grafana. This is the "monitor everything, not just liveliness" outcome.
> - ❌ **Gateway native OTel — NOT AVAILABLE in the shipped image.** The gateway binary in `ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0` is compiled **without** OpenTelemetry, so `OTEL_*` env vars are silently ignored and no gateway metrics are emitted. The OTel Collector was deployed and is healthy, but the gateway sends it nothing.
> - ✅ **Full observability stack (Prometheus Operator + ServiceMonitor + Grafana) — WORKING** end-to-end for the backend.

---

## 1. Environment as found

| Item | Value |
|------|-------|
| DocumentDB CRD | `documentdbs.kubedb.com` (`v1alpha2`) — **no `spec.monitor` field** |
| DocumentDBVersion | `pg17-0.109.0` → db image `ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0` |
| Pod shape | **one `documentdb` container** runs **both** the Postgres backend (`:9712`) and the gateway (`:10260`) as two processes |
| Injection hook available | `spec.podTemplate.spec.containers[].env` (present) — used to try to inject config without code changes |
| Pre-existing monitoring | none (no Prometheus Operator, no ServiceMonitor CRD, no OTel, no Grafana) |

Because the operator has **no monitoring wiring**, everything below was attached **externally** to a running instance — no operator code was modified.

---

## 2. What was built (final architecture)

```
                        demo namespace
┌───────────────────────── DocumentDB pod (docdb-0) ─────────────────────────┐
│  documentdb container:                                                      │
│    • Postgres backend        :9712  ← SQL                                   │
│    • gateway (documentdb_gw)  :10260 (TLS)                                  │
│      (OTEL_* env injected via podTemplate, but binary has no OTel → no-op)  │
└─────────────────────────────────────────────────────────────────────────────┘
        ▲ SQL over network (docdb.demo.svc:9712)          ✗ no OTLP emitted
        │                                                  │
┌───────┴────────────┐                           ┌─────────┴──────────┐
│ postgres_exporter  │  :56790/metrics           │  OTel Collector    │  :8889/metrics
│ (standalone Deploy)│──────────┐                │ otlp :4317 (ready) │──────┐ (empty)
└────────────────────┘          │                └────────────────────┘      │
   Service: docdb-stats         │                   Service: otel-collector   │
        ▲                        │                        ▲                    │
   ServiceMonitor           ┌────┴─────────── Prometheus (kube-prometheus-stack) ───┐
   docdb-postgres  ─────────┤  scrapes both ServiceMonitor targets (both UP)        │
   ServiceMonitor           └───────────────────────────┬──────────────────────────┘
   docdb-gateway-otel ──────────────────────────────────┘
                                                         ▼
                                                     Grafana (dashboard "DocumentDB Monitoring")
```

> **Note on the exporter placement.** The plan's first choice was a co-located `postgres_exporter` **sidecar** injected via `spec.podTemplate`. The operator **stripped it** (see §4.1), so the exporter runs as a **standalone Deployment** that connects to the backend over the network (`docdb.demo.svc:9712`). Functionally identical for metric collection; the only difference is localhost vs. network + a Service hop.

---

## 3. Step-by-step procedure

### 3.1 Observability stack
```bash
kubectl create ns demo
kubectl create ns monitoring
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm install kps prometheus-community/kube-prometheus-stack -n monitoring -f kps-values.yaml
```
`kps-values.yaml` highlights: `serviceMonitorSelectorNilUsesHelmValues=false` and empty namespace selectors (so Prometheus picks up ServiceMonitors in **any** namespace), alertmanager/node-exporter/kube-state-metrics disabled, Grafana enabled (`admin/admin`).

Result: `kps-operator`, `prometheus-kps-prometheus-0` (2/2), `kps-grafana` (3/3) Running; `servicemonitors.monitoring.coreos.com` CRD installed.

### 3.2 DocumentDB instance with monitoring injected via `podTemplate`
`documentdb.yaml` (key parts): `version: "pg17-0.109.0"`, `replicas: 1`, and in `spec.podTemplate.spec.containers`:
- `documentdb` container **env** for native gateway OTel: `OTEL_METRICS_ENABLED=true`, `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.demo.svc:4317`, `OTEL_EXPORTER_OTLP_PROTOCOL=grpc`, `OTEL_SERVICE_NAME=documentdb-gateway`, `OTEL_METRIC_EXPORT_INTERVAL=5000`, `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`.
- an `exporter` sidecar container (see §4.1 — stripped by operator).

The CR was accepted; `docdb` reached **`Ready`**. The auth secret `docdb-auth` (`username=default_user`, `password`) is auto-created.

### 3.3 OTel Collector (gateway OTLP receiver)
Deployment + Service `otel-collector` in `demo`:
- receivers `otlp` (gRPC `:4317`, HTTP `:4318`), processors `memory_limiter` + `batch`, exporter `prometheus` (`:8889`) + `debug`.
- Image: `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector:0.119.0` (see §4.2 for why 0.119.0 and not 0.116.0).

Result: collector Running, logs `Everything is ready. Begin running and processing data.`

### 3.4 Standalone postgres_exporter + stats Service
Deployment `docdb-pg-exporter` + Service `docdb-stats` in `demo`:
```
/bin/postgres_exporter --log.level=info --web.listen-address=:56790 \
  --collector.postmaster --collector.long_running_transactions \
  --collector.stat_activity_autovacuum --collector.stat_statements \
  --collector.stat_wal_receiver --auto-discover-databases
DATA_SOURCE_NAME="user=default_user password=*** host=docdb.demo.svc port=9712 dbname=postgres sslmode=disable"
```
Image `quay.io/prometheuscommunity/postgres-exporter:v0.16.0`. Credentials from `docdb-auth` via `secretKeyRef`.

Result: `Established new database connection ... to=17.9.0` — connected to the DocumentDB backend and exporting.

### 3.5 ServiceMonitors
- `docdb-postgres` → selects `docdb-stats`, port `metrics`, path `/metrics`, 15s.
- `docdb-gateway-otel` → selects `otel-collector`, port `metrics` (`:8889`), path `/metrics`, 15s.
Both carry `release: kps` label.

### 3.6 Load generation (drives real metrics)
`mongosh` is present inside the `documentdb` container. The gateway requires **TLS**:
```bash
mongosh 'mongodb://default_user:***@localhost:10260/?authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true' ...
# 600 insertMany, find(limit 50), updateMany, deleteMany, countDocuments, aggregate($group)
```
`{ ok: 1 }` ping; final `count=555`; aggregate `[{dhaka:282},{paris:273}]`.

### 3.7 Grafana dashboard
ConfigMap `docdb-monitoring-dashboard` (label `grafana_dashboard: "1"`) in `monitoring`; auto-imported by the Grafana sidecar as dashboard uid `docdb-monitoring`.

---

## 4. Issues encountered & how they were resolved

### 4.1 Operator strips sidecar containers added via `podTemplate`
- Injected an `exporter` container through `spec.podTemplate.spec.containers`. After reconcile the pod had **only** the `documentdb` container; the PetSet's container list did not include `exporter`.
- **The `documentdb` container's injected `env` (the `OTEL_*` vars) WAS preserved.** So env-merge via podTemplate works, but **adding an unknown container does not** — the operator rebuilds the container list and keeps only containers it manages.
- **Resolution:** run postgres_exporter as a **standalone Deployment** over the network. (In the real operator, the sidecar would be added by operator code, so this is only a limitation of the *no-code-change* test, not of the design.)

### 4.2 Docker Hub image pulls are broken on this cluster (corrupt layers)
- `otel/opentelemetry-collector*:0.116.0` (docker.io **and** ghcr with the same digest) landed in containerd as `incomplete (1/4) 2.3KiB/76MiB`; containers crash-looped with `exec /otelcol: no such file or directory` (the binary layer never fully downloaded). `quay.io` and `ghcr.io` (kubedb) images pulled fine — the problem is specifically large layers via the shared corrupt blob.
- **Resolution:** pull a **different version** (`0.119.0`, different layer digests) on the host with `docker pull --platform linux/amd64`, `docker save`, copy into the node, `ctr -n k8s.io images import`. Verified with `ctr run … /otelcol --version → otelcol version 0.119.0`, then deployed with `imagePullPolicy: IfNotPresent`.

### 4.3 Gateway image has NO OpenTelemetry (the core finding)
- After load, the collector received **nothing** (`debug` exporter silent; `:8889/metrics` had no `db_client_*`; Prometheus `count({__name__=~"db_client.*"})` = `[]`).
- Network path is fine (`nc otel-collector.demo.svc 4317 → succeeded`), and the `OTEL_*` env vars are set on the gateway process — so the gateway is simply not emitting.
- Inspected the gateway binary (`/home/documentdb/gateway/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway`, 22 MB) with `grep -a` (positive control: `GatewayListenPort`×2, `documentdb`×71, `tracing` present):
  - **No** matches for `opentelemetry`, `otlp`, `OTEL_*`, `:4317`, `prometheus`, `exporter`, `db.client.*`, `gateway.starts`.
  - Port `56790` (the documented native `/debug/metrics`) is **not listening**, and no `debug/metrics` strings exist either.
- **Conclusion:** the `documentdb-local` (emulator) build shipped in the KubeDB catalog is compiled **without** the gateway's OpenTelemetry feature. The upstream gateway source *does* have OTel (per `gateway-otel.md`'s `Cargo.toml` analysis), but this specific image does not. Native gateway metrics require a **gateway image built with the telemetry feature enabled** (the production `documentdb` image, not `documentdb-local`).

### 4.4 postgres_exporter caveats against PG17 + non-superuser
Non-fatal collector errors (the rest of the metrics still export):
- `stat_bgwriter`: `column "checkpoints_timed" does not exist` — PG17 moved checkpoint counters from `pg_stat_bgwriter` to `pg_stat_checkpointer`; exporter v0.16.0's built-in query predates that.
- `wal`: `permission denied for function pg_ls_waldir` — `default_user` is not a full superuser / lacks the needed role grant.
- `stat_statements`: `relation "pg_stat_statements" does not exist` — extension not installed in the backend.

### 4.5 Gateway requires TLS
`tls=false` → `read ECONNRESET`. The gateway listens with an auto-generated PEM cert; `tls=true&tlsAllowInvalidCertificates=true` works.

---

## 5. Results & evidence

### 5.1 Backend Postgres (postgres_exporter) — ✅ working, full metric set
- Exporter `/metrics`: **2110 lines, 526 metric families**, including `pg_stat_database_*` (xact_commit/rollback, tup_inserted/updated/deleted/fetched/returned, blks_hit/read, numbackends, deadlocks, temp_bytes), `pg_stat_activity_*`, `pg_locks_count`, `pg_database_size_bytes`, `pg_long_running_transactions`, `pg_replication_*`, and hundreds of `pg_settings_*`. **`pg_up 1`.**
- In **Prometheus** (both queried directly and via the Grafana datasource proxy):

| Query | Value |
|-------|-------|
| `pg_up{job="docdb-stats"}` | `1` |
| distinct `pg_*` metric names | **483** |
| `sum(pg_stat_database_numbackends)` | `10` |
| `sum(pg_stat_database_tup_inserted)` | `39164` (grows with load) |
| `pg_database_size_bytes{datname="postgres"}` | `18282163` (~18 MB) |
| raw `pg_stat_database_tup_deleted` (postgres) | `2207` |
| raw `pg_stat_database_xact_commit` (postgres) | `5765` |

> DocumentDB stores its Mongo collections **inside the `postgres` database** (via its extension), so the write activity from the mongosh load shows up under `datname="postgres"` (datid=5).

- **Prometheus target** `serviceMonitor/demo/docdb-postgres/0` → **health `up`**.

### 5.2 Gateway native OTel — ❌ not available in this image
- OTel Collector deployed and healthy (OTLP gRPC `:4317`, "Everything is ready").
- **Prometheus target** `serviceMonitor/demo/docdb-gateway-otel/0` → **health `up`** (the collector's `/metrics` is scrapable) **but carries no gateway series**.
- `count({__name__=~"db_client.*|gateway.*"})` → `[]` (empty). Root cause in §4.3.

### 5.3 Prometheus Operator + Grafana — ✅ working
- Both ServiceMonitors discovered; both targets `up`.
- Grafana dashboard **"DocumentDB Monitoring"** (uid `docdb-monitoring`) imported; default datasource `Prometheus`; panel queries return live data (verified via `/api/datasources/proxy/uid/prometheus/api/v1/query`). Backend panels populate; the gateway panel is intentionally empty with a title noting the cause.

---

## 6. Can I adopt this in my DocumentDB operator?

**Yes for the backend Postgres — and it maps almost 1:1 onto the KubeDB postgres pattern. The gateway half needs an image change first.**

### 6.1 Backend Postgres via postgres_exporter — recommended, low risk
Mirror KubeDB postgres exactly:
1. **apimachinery:** add `Monitor *mona.AgentSpec` to `DocumentDBSpec` (+ `StatsService()`/`ServiceMonitorName()`/`Path()=/metrics`/`Scheme()=http` helpers). Regenerate CRD + deepcopy.
2. **DocumentDBVersion catalog:** add `Spec.Exporter.Image` (a `postgres_exporter` image).
3. **PetSet builder:** a `getMonitoringContainer` that adds the `exporter` **sidecar** (localhost `:9712`, `DATA_SOURCE_NAME` from the auth secret, reuse the existing `/tls/certs/exporter/*` plumbing when TLS is on). Because it's operator-authored, it will **not** be stripped (that was only a `podTemplate` limitation, §4.1) and can use `localhost` instead of a network hop.
4. **StatsService + ServiceMonitor:** `ensureStatsService` (`<db>-stats`) and `ensureMonitoring` via the shared `mona.Agent` (`agents.New(agent, kubeClient, PromClient)` → `CreateOrUpdate`).
5. **Wiring:** give the provisioner Reconciler a `PromClient (monitoringv1)` and call `ensureMonitoring(db)` gated on `spec.monitor != nil`.

**Two DocumentDB-specific adjustments proven by this test:**
- **Port is 9712, not 5432.** Hardcode/parameterize the DocumentDB backend port in the DSN.
- **Ship a PG17-aware exporter + a monitoring role.** Use a `postgres_exporter` new enough for PG17 (`pg_stat_checkpointer`), and grant the monitoring user `pg_monitor` (fixes the `pg_ls_waldir` permission error). Optionally enable `pg_stat_statements` in the backend for query metrics. This delivers the "monitor everything, not just liveliness" goal.

### 6.2 Gateway via native OTel — blocked until the image ships OTel
- **Blocker:** the current `documentdb-local:pg17-0.109.0` gateway binary has no OpenTelemetry compiled in. No amount of operator wiring changes that.
- **Path forward (in order of preference):**
  1. Switch the DocumentDBVersion `db.image` to a gateway build **compiled with the OTel feature** (upstream production `documentdb` image), then have the operator inject `OTEL_METRICS_ENABLED=true` + `OTEL_EXPORTER_OTLP_ENDPOINT` and run an **OTel Collector sidecar** (otlp→prometheus) + a second port on `<db>-stats` + its own ServiceMonitor. The collector piece was proven to work here; only the emitting side is missing.
  2. If a build exposes the native Prometheus `/debug/metrics` (`DOCUMENTDB_DEBUG_ADDR`, `:56790`), scrape it directly with a ServiceMonitor (no collector). Not available in this image either.
- **Interim:** ship backend-Postgres monitoring now (§6.1); add gateway metrics when the OTel-enabled image is adopted.

### 6.3 Ownership
Keep monitoring in the **provisioner** reconcile (builds PetSet + StatsService + ServiceMonitor together), exactly like KubeDB postgres — unlike TLS, which is split with ops-manager.

---

## 7. Reproduce / cleanup

Manifests used (in the session scratchpad): `kps-values.yaml`, `documentdb.yaml`, `otel-collector.yaml`, `pg-exporter.yaml`, `servicemonitors.yaml`, `grafana-dashboard.yaml`.

```bash
# Inspect
kubectl get documentdb,pods,servicemonitor,svc -n demo
kubectl exec docdb-0 -n demo -c documentdb -- wget -qO- http://docdb-stats.demo.svc:56790/metrics | head
kubectl port-forward -n monitoring svc/kps-grafana 3300:80   # admin/admin, dashboard "DocumentDB Monitoring"

# Cleanup
kubectl delete -f documentdb.yaml -f otel-collector.yaml -f pg-exporter.yaml -f servicemonitors.yaml
kubectl delete cm docdb-monitoring-dashboard -n monitoring
helm uninstall kps -n monitoring
kubectl delete ns demo monitoring
```

---

## 8. Status summary

| Component | Result |
|-----------|--------|
| DocumentDB instance (`pg17-0.109.0`, TLS gateway) | ✅ Ready |
| postgres_exporter → backend `:9712` | ✅ Connected, 526 families / 483 `pg_*` series |
| Stats Service + ServiceMonitor (postgres) | ✅ target `up` |
| Prometheus (kube-prometheus-stack) | ✅ scraping, PromQL verified |
| Grafana dashboard | ✅ imported, panels live |
| OTel Collector (otlp→prometheus) | ✅ healthy, receiving nothing |
| Gateway native OTel | ❌ image lacks OpenTelemetry |
| `podTemplate` env injection | ✅ preserved |
| `podTemplate` sidecar injection | ❌ stripped by operator (use operator-authored sidecar) |
| Custom `application_name` query on postgres_exporter | ✅ emits `documentdb_gateway_backends_*`, scraped by Prometheus |
| `mongodb_exporter` against the gateway | ⚠️ connects (`mongodb_up 1`) but yields no real metrics (gateway lacks `serverStatus`) |

---

## 9. Follow-up experiments (collecting gateway activity WITHOUT native OTel, on the 0.109 image)

Two extra approaches were tested against the running instance to get *gateway* signal from the
current image (which has no gateway metrics endpoint).

### 9.1 Custom `application_name` query on postgres_exporter — ✅ works well
Added a custom query to the exporter (ConfigMap `docdb-exporter-queries` mounted at
`/etc/pg-exporter/queries.yaml`, flag `--extend.query-path=…`). It groups `pg_stat_activity` by the
gateway's backend roles:

```sql
SELECT application_name, count(*) AS connections,
       count(*) FILTER (WHERE state='active') AS active,
       COALESCE(max(EXTRACT(epoch FROM (clock_timestamp()-query_start))) FILTER (WHERE state='active'),0)
         AS max_active_query_seconds
FROM pg_stat_activity WHERE application_name LIKE 'DocumentDBGateway%' GROUP BY application_name
```

Result — new metrics scraped into Prometheus:
```
documentdb_gateway_backends_connections{application_name="DocumentDBGateway-UserData"}       2
documentdb_gateway_backends_connections{application_name="DocumentDBGateway-SystemRequests"} 1
documentdb_gateway_backends_connections{application_name="DocumentDBGateway-PreAuthRequests"}2
documentdb_gateway_backends_active / _max_active_query_seconds  (per role)
```
The gateway opens distinctly-named backend pools (`DocumentDBGateway-UserData` for client CRUD,
`-SystemRequests`, `-PreAuthRequests`), so this cleanly attributes backend load to the gateway.
(`--extend.query-path` logs a *deprecated* warning but works on exporter v0.16.0.) This is the
recommended way to get gateway signal on the current image.

### 9.2 Percona `mongodb_exporter` against the gateway (`:10260`, TLS) — ⚠️ not viable on 0.109
The exporter **connects** (`mongodb_up{cluster_role="mongos"} 1`) but produces **only** that one
metric — all its collectors depend on `serverStatus`/`replSetGetStatus`, which the gateway rejects.

Direct command probe of the gateway (via `mongosh … runCommand`):

| Supported ✅ | Not supported ❌ |
|---|---|
| `hello`, `buildInfo`, `ping`, `hostInfo`, `getCmdLineOpts`, `connectionStatus`, `listDatabases`, `listCollections`, **`dbStats`**, **`collStats`** | **`serverStatus`**, **`replSetGetStatus`** (`Unknown request received: serverStatus`) |

**Takeaway:** off-the-shelf `mongodb_exporter` won't work here. But because `dbStats`/`collStats`
(and `listDatabases`/`listCollections`) *are* implemented, a **small custom exporter** (or an OTel
Collector polling those commands) could produce per-DB/per-collection document/size/index metrics from
the gateway today — a viable path if you want Mongo-shaped gateway metrics before adopting the ≥0.112
OTel image. Extra resources left running: Deployment `docdb-mongo-exporter` + Service
`docdb-mongo-stats` (no ServiceMonitor added, since only `mongodb_up` is meaningful).

### 9.3 Net recommendation for the current image
Use **§9.1 (postgres_exporter custom query)** for gateway signal now — it's already scraped by the
existing ServiceMonitor and needs no new component. Treat a **custom `dbStats`/`collStats` exporter**
as an optional enhancement, and reserve true gateway-internal OTLP metrics for the **≥0.112** gateway
image.
