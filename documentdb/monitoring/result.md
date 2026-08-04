# DocumentDB Monitoring — Test Results

**Date:** 2026-07-27
**Cluster:** K3s (`export KUBECONFIG=/home/sabnaj/k3s.yaml`)
**DocumentDB instance:** `dcdb` in `demo` namespace, version `pg17-0.109.0`, 1 replica
**Postgres port:** 9712 | **Gateway port:** 10260 | **TLS:** disabled on spec, SCRAM auth

---

## Prerequisites: Monitoring Stack

**Installed:** `kube-prometheus-stack` in `monitoring` namespace
- Prometheus Operator + Prometheus + Grafana + Node Exporter + kube-state-metrics
- ServiceMonitor/PodMonitor/PrometheusRule CRDs: ✅
- Grafana: `admin` / `admin123`, accessible via port-forward `monitoring-grafana:3000`

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm upgrade --install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.adminPassword=admin123 \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

---

## Method 1: Dual Exporters (postgres_exporter + mongodb_exporter)

### Architecture

```
DocumentDB Pod (dcdb-0)                     Standalone Exporters
┌────────────────────────┐                 ┌─────────────────────┐
│ documentdb container   │                 │ postgres-exporter   │
│  Postgres :9712 ───────┼─── SQL ────────→│  :9187/metrics  ✅  │
│  Gateway  :10260 ──────┼─── MongoDB ────→│ mongodb-exporter    │
│                        │    wire          │  :9216/metrics  ⚠️  │
└────────────────────────┘                 └─────────────────────┘
                                                    │
                                          ServiceMonitors → Prometheus → Grafana
```

### 1A: postgres_exporter — ✅ SUCCESS

**Image:** `quay.io/prometheuscommunity/postgres-exporter:v0.17.0`
**Connection:** `postgresql://documentdb:<pass>@dcdb.demo.svc.cluster.local:9712/postgres?sslmode=disable`
**Auth secret:** `dcdb-admin-auth` (username: `documentdb`)

**Result:** Fully working. **494 PostgreSQL metrics** collected, including:

| Category | Sample Metrics |
|----------|---------------|
| Database stats | `pg_stat_database_tup_fetched`, `pg_stat_database_tup_inserted`, `pg_stat_database_tup_updated`, `pg_stat_database_tup_deleted` |
| Database size | `pg_database_size_bytes` |
| Connections | `pg_database_connection_limit` |
| Locks | `pg_locks_count` (by mode + database) |
| Replication | `pg_replication_is_replica`, `pg_replication_lag_seconds`, `pg_replication_last_replay_seconds` |
| BG Writer | `pg_stat_bgwriter_buffers_clean`, `pg_stat_bgwriter_checkpoint_write_time` |
| Roles | `pg_roles_connection_limit` |

**Prometheus target:** `http://10.42.0.76:9187/metrics` — ✅ **UP**

**Deployment manifest:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: pg-exporter-secret
  namespace: demo
stringData:
  data-source-name: "postgresql://documentdb:<pass>@dcdb.demo.svc.cluster.local:9712/postgres?sslmode=disable"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres-exporter
  labels:
    app: postgres-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: postgres-exporter
  template:
    metadata:
      labels:
        app: postgres-exporter
    spec:
      containers:
      - name: postgres-exporter
        image: quay.io/prometheuscommunity/postgres-exporter:v0.17.0
        args:
        - "--web.listen-address=:9187"
        - "--web.telemetry-path=/metrics"
        env:
        - name: DATA_SOURCE_NAME
          valueFrom:
            secretKeyRef:
              name: pg-exporter-secret
              key: data-source-name
        ports:
        - name: metrics
          containerPort: 9187
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-exporter
  labels:
    app: postgres-exporter
spec:
  selector:
    app: postgres-exporter
  ports:
  - name: metrics
    port: 9187
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: postgres-exporter
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app: postgres-exporter
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
```

### 1B: mongodb_exporter — ⚠️ PARTIAL SUCCESS

**Image:** `percona/mongodb_exporter:0.44.0`
**Connection:** `mongodb://default_user:<pass>@dcdb.demo.svc.cluster.local:10260/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsInsecure=true&directConnection=true`
**Auth secret:** `dcdb-auth` (username: `default_user`)

**Result:** Connects successfully but only 1 metric collected.

| Metric | Value | Notes |
|--------|-------|-------|
| `mongodb_up` | 1 | ✅ Gateway is reachable |
| `mongodb_connections` | — | ❌ Not available |
| `mongodb_op_counters_total` | — | ❌ Not available |
| `mongodb_network_bytes_total` | — | ❌ Not available |
| `mongodb_memory_usage` | — | ❌ Not available |

**Root cause:** The DocumentDB gateway identifies itself as `mongos` (MongoDB router role). The exporter's default collectors (`serverStatus`, `diagnosticdata`, `replicasetstatus`) depend on commands that the gateway doesn't fully implement. The `mongos` role only supports a subset of MongoDB diagnostic commands.

**Key findings:**
1. 🔐 The gateway **requires TLS** (`tls=true`) even when `spec.tls` is not set — the gateway auto-detects the TLS cert and enables it
2. 🔗 The gateway **accepts MongoDB wire protocol connections** with `directConnection=true`
3. 🏷️ The gateway identifies as **`mongos`** cluster role
4. ⚠️ Only `mongodb_up` and `mongodb_version` are available — detailed operational metrics are NOT exposed via the MongoDB wire protocol

**Deployment manifest:**
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: mongo-exporter-secret
  namespace: demo
stringData:
  mongodb-uri: "mongodb://default_user:<pass>@dcdb.demo.svc.cluster.local:10260/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsInsecure=true&directConnection=true"
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mongodb-exporter
  labels:
    app: mongodb-exporter
spec:
  replicas: 1
  selector:
    matchLabels:
      app: mongodb-exporter
  template:
    metadata:
      labels:
        app: mongodb-exporter
    spec:
      containers:
      - name: mongodb-exporter
        image: percona/mongodb_exporter:0.44.0
        args:
        - "--web.listen-address=:9216"
        - "--web.telemetry-path=/metrics"
        - "--mongodb.direct-connect"
        - "--compatible-mode"
        env:
        - name: MONGODB_URI
          valueFrom:
            secretKeyRef:
              name: mongo-exporter-secret
              key: mongodb-uri
        ports:
        - name: metrics
          containerPort: 9216
---
apiVersion: v1
kind: Service
metadata:
  name: mongodb-exporter
  labels:
    app: mongodb-exporter
spec:
  selector:
    app: mongodb-exporter
  ports:
  - name: metrics
    port: 9216
---
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: mongodb-exporter
  labels:
    release: monitoring
spec:
  selector:
    matchLabels:
      app: mongodb-exporter
  endpoints:
  - port: metrics
    interval: 30s
    path: /metrics
```

---

## Method 2: OTel Collector (sqlquery + OTLP)

### Architecture

```
DocumentDB Pod (dcdb-0)              OTel Collector (standalone Deployment)
┌────────────────────────┐          ┌──────────────────────────┐
│ documentdb container   │          │ otel-collector           │
│  Postgres :9712 ───────┼─ SQL ──→│  sqlquery receiver  ✅    │
│  Gateway  :10260 ──────┼─ OTLP ─→│  otlp receiver (port 4317)│
│  (OTEL not enabled ❌)  │          │  prometheus exporter :8888│
└────────────────────────┘          └──────────────────────────┘
                                               │
                                     ServiceMonitor → Prometheus → Grafana
```

### 2A: sqlquery receiver (Postgres metrics via SQL) — ✅ SUCCESS

**Image:** `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.124.0`
**Config:** `${env:PGPASSWORD}` substitution for auth from Kubernetes Secret

**Result:** 3 custom Postgres metrics collected:

| Metric | Query | Current Value |
|--------|-------|---------------|
| `documentdb_postgres_up` | `SELECT 1 AS up` | 1 |
| `documentdb_postgres_connections` | `SELECT count(*) FROM pg_stat_activity` | 15 |
| `documentdb_postgres_locks` | `SELECT count(*) FROM pg_locks` | 2 |

**Extensibility:** Add more metrics by adding SQL queries to the ConfigMap — no operator code changes needed.

### 2B: Gateway OTLP (native metrics) — ❌ NOT TESTABLE without operator changes

**Blocked by:** The operator reverts any manual PetSet changes within seconds. Setting `OTEL_METRICS_ENABLED=true` and `OTEL_EXPORTER_OTLP_ENDPOINT` on the gateway container requires patching the PetSet template, but the DocumentDB operator's reconcile loop overwrites the patch.

**To enable:** The operator code must be modified to:
1. Read gateway OTLP config from `spec.monitor`
2. Inject `OTEL_METRICS_ENABLED=true` and `OTEL_EXPORTER_OTLP_ENDPOINT` env vars into the `documentdb` container in `petset.go`

**Expected metrics (from source code analysis):** 10 metrics would become available:
- `db.client.operation.duration.total` (with Postgres phase breakdown)
- `db.client.operations`
- `db.client.request.size.total` / `db.client.response.size.total`
- `db.client.documents.returned` / `.inserted` / `.updated` / `.deleted`
- `gateway_startup_delay_ms` / `gateway.starts`

---

## Summary: What Works and What Doesn't

| Method | Source | Status | Metrics Count | Ready for Operator? |
|--------|--------|--------|---------------|---------------------|
| postgres_exporter | Postgres backend | ✅ Fully working | 494 metrics | ✅ Yes |
| mongodb_exporter | Gateway (MongoDB wire) | ⚠️ Only `mongodb_up` | 1 metric | ❌ Not useful |
| OTel sqlquery | Postgres backend | ✅ Fully working | 3 custom metrics (extensible) | ✅ Yes |
| OTel OTLP | Gateway native | ❌ Blocked (needs operator changes) | 0 (10 expected) | ❌ Needs code changes |

### Final Scores by Use Case

| Use Case | Best Method | Metrics Available | Complexity |
|----------|------------|-------------------|------------|
| **Monitor Postgres only** | postgres_exporter | 494 PG metrics (connections, locks, WAL, bgwriter, replication, DB/table stats) | Low |
| **Monitor Postgres with custom queries** | OTel sqlquery | Configurable SQL metrics + PG exporter combo | Medium |
| **Monitor Gateway** | mongodb_exporter | Only `mongodb_up` (liveness check only) | Low |
| **Monitor Gateway (full metrics)** | Gateway OTLP (Method 2B) | 10 native metrics (duration, ops, docs, startup) — **requires operator code change** | High |
| **Monitor Both (full)** | postgres_exporter + Gateway OTLP | 494 PG + 10 gateway metrics — **requires operator code change** | High |

---

## Grafana Dashboard

Access Grafana at `http://localhost:3000` (after port-forward):
```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
```
Credentials: `admin` / `admin123`

Prometheus data sources are pre-configured. Import dashboard JSON from `grafana-dashboard.json` (see implementation plan files).
