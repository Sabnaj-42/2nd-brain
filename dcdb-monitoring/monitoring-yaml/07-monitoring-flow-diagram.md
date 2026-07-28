# DocumentDB Monitoring — Full Flow Diagram

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                              KUBERNETES CLUSTER                              │
│                                                                              │
│  ┌─── namespace: demo ────────────────────────────────────────────────────┐ │
│  │                                                                         │ │
│  │   ┌─ Pod: dcdb-0 ───────────────────────────────────────────────────┐  │ │
│  │   │                                                                   │  │ │
│  │   │  ┌─────────────────────┐   ┌──────────────────────────────┐    │  │ │
│  │   │  │    documentdb       │   │  postgres-exporter           │    │  │ │
│  │   │  │    (main container) │   │  (sidecar)                   │    │  │ │
│  │   │  │                     │   │                              │    │  │ │
│  │   │  │  Postgres :9712 ────┼───┼─► localhost:9712             │    │  │ │
│  │   │  │  Gateway  :10260    │   │  exposes :56790/metrics ─────┼────┼──┼─┐ │
│  │   │  └─────────────────────┘   └──────────────────────────────┘    │  │ │ │
│  │   │                                                                   │  │ │ │
│  │   │  ┌──────────────────────────────┐                                │  │ │ │
│  │   │  │  otel-collector              │                                │  │ │ │
│  │   │  │  (sidecar)                   │                                │  │ │ │
│  │   │  │                              │                                │  │ │ │
│  │   │  │  sqlquery receiver ──► localhost:9712 (SQL every 30s)        │  │ │ │
│  │   │  │  exposes :8888/metrics ──────┼────────────────────────────────┼──┼─┼─┐
│  │   │  └──────────────────────────────┘                                │  │ │ │
│  │   │                                                                   │  │ │ │
│  │   │  ┌─────────────────────┐                                         │  │ │ │
│  │   │  │ Volumes             │                                         │  │ │ │
│  │   │  │ otel-collector-     │                                         │  │ │ │
│  │   │  │   config (ConfigMap)│ ← dcdb-otel-config (auto-generated)     │  │ │ │
│  │   │  └─────────────────────┘                                         │  │ │ │
│  │   └──────────────────────────────────────────────────────────────────┘  │ │ │
│  │                                                                         │ │ │
│  │   ┌─ Service: dcdb-stats ────────────────────────────────────────────┐  │ │ │
│  │   │  Selector: app.kubernetes.io/instance=dcdb                        │  │ │ │
│  │   │  Port: 56790 (pg-metrics)   ──► targets exporter container        │  │ │ │
│  │   │  Port: 8888  (otel-metrics) ──► targets otel-collector container  │  │ │ │
│  │   └──────────────────────────────────────────────────────────────────┘  │ │ │
│  │       │                                                                  │ │ │
│  └───────┼──────────────────────────────────────────────────────────────────┘ │ │
│          │                                                                      │ │
│  ┌─── namespace: monitoring ────────────────────────────────────────────────┐  │ │
│  │                                                                          │  │ │
│  │   ┌─ ServiceMonitor: dcdb-stats ─────────────────────────────────────┐   │  │ │
│  │   │  (auto-created by operator via mona.Agent)                       │   │  │ │
│  │   │  Selects: Service with kubedb.com/role=stats                     │   │  │ │
│  │   │  Endpoints:                                                      │   │  │ │
│  │   │    - port: metrics, path: /metrics, interval: 30s                │   │  │ │
│  │   │    - port: otel-metrics, path: /metrics, interval: 30s           │   │  │ │
│  │   └──────────────────────────┬───────────────────────────────────────┘   │  │ │
│  │                              │                                           │  │ │
│  │                              │ watches & discovers                       │  │ │
│  │                              ▼                                           │  │ │
│  │   ┌─ Prometheus ──────────────────────────────────────────────────────┐  │  │ │
│  │   │  Scrapes every 30s:                                                │  │  │ │
│  │   │    http://<pod-ip>:56790/metrics  ──► 911 pg_* metrics             │◄─┼──┼─┘ │
│  │   │    http://<pod-ip>:8888/metrics   ──► 29 documentdb_* metrics      │◄─┼──┼───┘
│  │   │  Stores time-series data                                           │  │  │
│  │   └──────────────────────────┬──────────────────────────────────────────┘  │  │
│  │                              │                                              │  │
│  │                              │ queries via PromQL                            │  │
│  │                              ▼                                              │  │
│  │   ┌─ Grafana ───────────────────────────────────────────────────────────┐   │  │
│  │   │  Data source: Prometheus                                             │   │  │
│  │   │  Dashboards:                                                         │   │  │
│  │   │    - Postgres connections, locks, replication, WAL, bgwriter         │   │  │
│  │   │    - Gateway documents inserted/updated/deleted/fetched              │   │  │
│  │   │    - Per-collection stats                                            │   │  │
│  │   │    - Database size, deadlocks, active connections                    │   │  │
│  │   └──────────────────────────────────────────────────────────────────────┘   │  │
│  └──────────────────────────────────────────────────────────────────────────────┘  │
│                                                                                    │
│  ┌─ DocumentDB Operator (kubedb-provisioner) ────────────────────────────────────┐  │
│  │  Reads spec.monitor on DocumentDB CR                                           │  │
│  │  Auto-creates:                                                                 │  │
│  │    1. dcdb-otel-config ConfigMap     (reconcileOTelConfigMap)                  │  │
│  │    2. Sidecar containers in PetSet   (getPostgresExporterContainer,            │  │
│  │                                        getOTelCollectorContainer)               │  │
│  │    3. dcdb-stats Service             (ensureStatsService)                      │  │
│  │    4. dcdb-stats ServiceMonitor      (manageMonitor → mona.Agent)              │  │
│  └────────────────────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────────────────┘
```

## Data Journey (step by step)

```
Step 1: Postgres generates stats
  ─────────────────────────────────
  pg_stat_database, pg_stat_activity, pg_stat_user_tables, pg_locks, etc.
  Updated continuously by PostgreSQL internally.

Step 2: Two exporters collect metrics
  ─────────────────────────────────
  ┌─ postgres-exporter (:56790)
  │  Connects to localhost:9712
  │  Runs built-in collector queries
  │  Exposes 911 metric series at :56790/metrics
  │
  └─ otel-collector (:8888)
     Connects to localhost:9712 (sqlquery receiver)
     Runs custom SQL every 30 seconds
     Exposes 29 metric series at :8888/metrics

Step 3: Stats Service aggregates
  ─────────────────────────────────
  Service dcdb-stats:56790 → targets exporter container
  Service dcdb-stats:8888  → targets otel-collector container

Step 4: ServiceMonitor discovers
  ─────────────────────────────────
  ServiceMonitor dcdb-stats selects Service by label
  Tells Prometheus: "scrape :56790/metrics and :8888/metrics every 30s"

Step 5: Prometheus scrapes and stores
  ─────────────────────────────────
  GET http://<pod-ip>:56790/metrics → 911 pg_* series
  GET http://<pod-ip>:8888/metrics  → 29 documentdb_* series

Step 6: Grafana queries and renders
  ─────────────────────────────────
  Grafana → PromQL queries → Prometheus → Charts/Dashboards
```

## Metrics by source

| Source | Port | Path | Count | Examples |
|--------|------|------|-------|----------|
| documentdb (Postgres) | 9712 | — | — | Raw PostgreSQL stats |
| postgres-exporter | 56790 | /metrics | 911 | `pg_stat_database_tup_*`, `pg_locks_count`, `pg_replication_*` |
| otel-collector (sqlquery) | 8888 | /metrics | 29 | `documentdb_gateway_documents_*`, `documentdb_gateway_connections_*` |
| Prometheus | 9090 | — | — | Time-series DB (all scraped metrics) |
| Grafana | 3000 | — | — | Dashboard visualization |

## Port summary

```
:9712  ← Postgres backend (internal)
:10260 ← Gateway (MongoDB wire protocol, external clients)
:56790 ← postgres-exporter /metrics
:8888  ← otel-collector /metrics
:9090  ← Prometheus UI
:3000  ← Grafana UI
```
