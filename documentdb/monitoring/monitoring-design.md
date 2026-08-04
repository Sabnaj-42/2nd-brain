# DocumentDB Monitoring Design — Path 1: postgres_exporter Sidecar + OTel sqlquery

## Architecture

```
DocumentDB Pod
├── documentdb (main: Postgres :9712 + Gateway :10260)
├── postgres-exporter → localhost:9712 → port 56790 /metrics
└── otel-collector    → localhost:9712 → port 8888  /metrics (sqlquery receiver)

Service <db>-stats
├── port "pg-metrics"  → 56790 (postgres-exporter)
└── port "otel-metrics" → 8888  (otel-collector)

ServiceMonitor → Prometheus Operator → Prometheus → Grafana
```

---

## Component 1: postgres_exporter sidecar

### What it does

Collects **500+ standard PostgreSQL metrics** by connecting to the backend Postgres on `localhost:9712`.

### Metrics collected (sample)

| Category          | Metrics                                                                                  |
| ----------------- | ---------------------------------------------------------------------------------------- |
| Database activity | `pg_stat_database_tup_fetched/inserted/updated/deleted`, commits, rollbacks, deadlocks |
| Connections       | `pg_stat_activity_count` by state (active, idle, idle in transaction, waiting)         |
| Locks             | `pg_locks_count` by mode (accessshare, exclusive, rowshare, etc.)                      |
| Replication       | `pg_replication_is_replica`, `pg_replication_lag_seconds`, WAL positions             |
| BG Writer         | `pg_stat_bgwriter_buffers_clean`, checkpoint timings, buffers allocated                |
| Database size     | `pg_database_size_bytes` per database                                                  |
| Settings          | `pg_settings_*` (hundreds of PG configuration values)                                  |
| Exporter health   | `pg_exporter_last_scrape_error`, `pg_exporter_scrapes_total`                         |

### Container spec

```go
func (c *Reconciler) getPostgresExporterContainer(db *dbapi.DocumentDB, version *catalog.DocumentDBVersion) core.Container {
    sslMode := "disable"
    if db.Spec.SSLMode != "" {
        sslMode = string(db.Spec.SSLMode)
    }

    // Build libpq connection string
    cnnstr := fmt.Sprintf(
        "host=%s port=%d user=${PGUSER} password=${PGPASSWORD} dbname=postgres sslmode=%s",
        kubedb.LocalHost,
        kubedb.DocumentDBDatabasePort, // 9712
        sslMode,
    )

    // TLS: add sslrootcert when verify-ca or verify-full
    if db.Spec.TLS != nil {
        if sslMode == "verify-ca" || sslMode == "verify-full" {
            cnnstr += fmt.Sprintf(" sslrootcert=%s/exporter/ca.crt", exporterTlsVolumeMountPath)
        }
        if db.Spec.ClientAuthMode == dbapi.ClientAuthModeCert {
            cnnstr += fmt.Sprintf(" sslcert=%s/exporter/tls.crt sslkey=%s/exporter/tls.key", exporterTlsVolumeMountPath)
        }
    }

    port := db.Spec.Monitor.Prometheus.Exporter.Port
    if port == 0 {
        port = kubedb.DocumentDBPostgresExporterPort // 56790
    }

    cmd := fmt.Sprintf(
        `/bin/postgres_exporter --web.listen-address=:%d --web.telemetry-path=%s --collector.postmaster`,
        port,
        kubedb.DefaultStatsPath, // "/metrics"
    )

    image := version.Spec.PostgresExporter.Image // from DocumentDBVersion catalog

    return core.Container{
        Name:            kubedb.ContainerExporterName, // "exporter"
        Image:           image,
        ImagePullPolicy: core.PullIfNotPresent,
        Command:         []string{"/bin/sh", "-c"},
        Args:            []string{fmt.Sprintf("export DATA_SOURCE_NAME=\"%s\"; %s", cnnstr, cmd)},
        Ports: []core.ContainerPort{{
            Name:          mona.PrometheusExporterPortName, // "metrics"
            ContainerPort: int32(port),
            Protocol:      core.ProtocolTCP,
        }},
        Env: []core.EnvVar{
            {
                Name: "PGUSER",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        Name: db.Spec.AdminAuthSecret.Name, // "dcdb-admin-auth"
                        Key:  core.BasicAuthUsernameKey,    // "username"
                    },
                },
            },
            {
                Name: "PGPASSWORD",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        Name: db.Spec.AdminAuthSecret.Name,
                        Key:  core.BasicAuthPasswordKey, // "password"
                    },
                },
            },
        },
        Resources: db.Spec.Monitor.Prometheus.Exporter.Resources,
        SecurityContext: db.Spec.Monitor.Prometheus.Exporter.SecurityContext,
    }
}
```

---

## Component 2: OTel Collector sidecar (sqlquery receiver)

### What it does

Runs custom SQL queries against Postgres every 30 seconds. Converts row results into Prometheus metrics. Shows gateway-level activity through Postgres stats.

### Metrics collected (17 out of the box, infinitely extensible)

| Metric                                               | Source                                             | Type  | Maps to Gateway OTel?                                         |
| ---------------------------------------------------- | -------------------------------------------------- | ----- | ------------------------------------------------------------- |
| `documentdb_postgres_up`                           | `SELECT 1`                                       | Gauge | —                                                            |
| `documentdb_gateway_connections_total`             | `pg_stat_activity`                               | Gauge | —                                                            |
| `documentdb_gateway_connections_active`            | `pg_stat_activity`                               | Gauge | —                                                            |
| `documentdb_gateway_connections_idle`              | `pg_stat_activity`                               | Gauge | —                                                            |
| `documentdb_gateway_connections_waiting`           | `pg_stat_activity`                               | Gauge | —                                                            |
| `documentdb_gateway_documents_inserted`            | `pg_stat_database` (per-DB)                      | Gauge | ✅`db.client.documents.inserted`                            |
| `documentdb_gateway_documents_updated`             | `pg_stat_database` (per-DB)                      | Gauge | ✅`db.client.documents.updated`                             |
| `documentdb_gateway_documents_deleted`             | `pg_stat_database` (per-DB)                      | Gauge | ✅`db.client.documents.deleted`                             |
| `documentdb_gateway_documents_fetched`             | `pg_stat_database` (per-DB)                      | Gauge | ⚠️`db.client.documents.returned` (approximate)            |
| `documentdb_gateway_collection_documents_inserted` | `pg_stat_user_tables` (**per-collection**) | Gauge | ✅`db.client.documents.inserted` + `db.collection.name`   |
| `documentdb_gateway_collection_documents_updated`  | `pg_stat_user_tables` (**per-collection**) | Gauge | ✅`db.client.documents.updated` + `db.collection.name`    |
| `documentdb_gateway_collection_documents_deleted`  | `pg_stat_user_tables` (**per-collection**) | Gauge | ✅`db.client.documents.deleted` + `db.collection.name`    |
| `documentdb_gateway_collection_documents_fetched`  | `pg_stat_user_tables` (**per-collection**) | Gauge | ⚠️`db.client.documents.returned` + `db.collection.name` |
| `documentdb_gateway_operations_commits`            | `pg_stat_database`                               | Gauge | —                                                            |
| `documentdb_gateway_operations_rollbacks`          | `pg_stat_database`                               | Gauge | —                                                            |
| `documentdb_gateway_deadlocks`                     | `pg_stat_database`                               | Gauge | —                                                            |
| `documentdb_gateway_database_size_bytes`           | `pg_database_size()`                             | Gauge | —                                                            |

Labels: `datname` (database-level) or `db` + `collection` (collection-level).

### Adding more metrics: edit the ConfigMap SQL, no code changes needed.

### Container spec

```go
func (c *Reconciler) getOTelCollectorContainer(db *dbapi.DocumentDB) core.Container {
    return core.Container{
        Name:  "otel-collector",
        Image: "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.124.0",
        Args:  []string{"--config=/etc/otel/config.yaml"},
        Env: []core.EnvVar{
            {
                Name: "PGPASSWORD",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        Name: db.Spec.AdminAuthSecret.Name,
                        Key:  core.BasicAuthPasswordKey,
                    },
                },
            },
        },
        Ports: []core.ContainerPort{{
            Name:          kubedb.DocumentDBOTelMetricsPortName,
            ContainerPort: kubedb.DocumentDBOTelMetricsPort, // 8888
            Protocol:      core.ProtocolTCP,
        }},
        VolumeMounts: []core.VolumeMount{{
            Name:      "otel-collector-config",
            MountPath: "/etc/otel",
            ReadOnly:  true,
        }},
        Resources: core.ResourceRequirements{
            Requests: core.ResourceList{
                core.ResourceCPU:    resource.MustParse("50m"),
                core.ResourceMemory: resource.MustParse("48Mi"),
            },
            Limits: core.ResourceList{
                core.ResourceCPU:    resource.MustParse("200m"),
                core.ResourceMemory: resource.MustParse("128Mi"),
            },
        },
    }
}
```

### OTel ConfigMap reconciler

```go
func (c *Reconciler) getOTelConfigMapName(db *dbapi.DocumentDB) string {
    return db.OffshootName() + "-otel-config"
}

func (c *Reconciler) reconcileOTelConfigMap(db *dbapi.DocumentDB) error {
    config := fmt.Sprintf(`
receivers:
  sqlquery:
    driver: postgres
    datasource: "host=127.0.0.1 port=%d user=${env:PGUSER} password=${env:PGPASSWORD} dbname=postgres sslmode=disable"
    queries:
      - sql: "SELECT 1 AS up"
        metrics:
          - metric_name: "documentdb_postgres_up"
            value_column: "up"
            data_type: gauge
      - sql: "SELECT count(*) AS total, count(*) FILTER (WHERE state='active') AS active, count(*) FILTER (WHERE state='idle') AS idle, count(*) FILTER (WHERE wait_event_type='Lock') AS waiting FROM pg_stat_activity WHERE backend_type='client backend'"
        metrics:
          - metric_name: "documentdb_gateway_connections_total"
            value_column: "total"
            data_type: gauge
          - metric_name: "documentdb_gateway_connections_active"
            value_column: "active"
            data_type: gauge
          - metric_name: "documentdb_gateway_connections_idle"
            value_column: "idle"
            data_type: gauge
          - metric_name: "documentdb_gateway_connections_waiting"
            value_column: "waiting"
            data_type: gauge
      - sql: "SELECT datname, xact_commit AS commits, xact_rollback AS rollbacks, tup_inserted AS inserts, tup_updated AS updates, tup_deleted AS deletes, tup_fetched AS reads, deadlocks FROM pg_stat_database WHERE datname NOT IN ('template0','template1')"
        metrics:
          - metric_name: "documentdb_gateway_operations_commits"
            value_column: "commits"
            data_type: gauge
            attribute_columns: ["datname"]
          - metric_name: "documentdb_gateway_operations_rollbacks"
            value_column: "rollbacks"
            data_type: gauge
            attribute_columns: ["datname"]
          - metric_name: "documentdb_gateway_documents_inserted"
            value_column: "inserts"
            data_type: gauge
            attribute_columns: ["datname"]
          - metric_name: "documentdb_gateway_documents_updated"
            value_column: "updates"
            data_type: gauge
            attribute_columns: ["datname"]
          - metric_name: "documentdb_gateway_documents_deleted"
            value_column: "deletes"
            data_type: gauge
            attribute_columns: ["datname"]
          - metric_name: "documentdb_gateway_documents_fetched"
            value_column: "reads"
            data_type: gauge
            attribute_columns: ["datname"]
          - metric_name: "documentdb_gateway_deadlocks"
            value_column: "deadlocks"
            data_type: gauge
            attribute_columns: ["datname"]
      # Per-collection metrics (maps to gateway OTLP: db.client.documents.*)
      - sql: "SELECT schemaname AS db, relname AS collection, n_tup_ins AS inserted, n_tup_upd AS updated, n_tup_del AS deleted, seq_tup_read + idx_tup_fetch AS fetched FROM pg_stat_user_tables WHERE schemaname NOT IN ('documentdb_api','documentdb_api_catalog','pg_catalog','information_schema','cron','public')"
        metrics:
          - metric_name: "documentdb_gateway_collection_documents_inserted"
            value_column: "inserted"
            data_type: gauge
            attribute_columns: ["db", "collection"]
          - metric_name: "documentdb_gateway_collection_documents_updated"
            value_column: "updated"
            data_type: gauge
            attribute_columns: ["db", "collection"]
          - metric_name: "documentdb_gateway_collection_documents_deleted"
            value_column: "deleted"
            data_type: gauge
            attribute_columns: ["db", "collection"]
          - metric_name: "documentdb_gateway_collection_documents_fetched"
            value_column: "fetched"
            data_type: gauge
            attribute_columns: ["db", "collection"]
      # Database-level aggregate metrics
      - sql: "SELECT datname, pg_database_size(datname) AS size_bytes FROM pg_database WHERE datname NOT IN ('template0','template1')"
        metrics:
          - metric_name: "documentdb_gateway_database_size_bytes"
            value_column: "size_bytes"
            data_type: gauge
            attribute_columns: ["datname"]
    collection_interval: 30s

processors:
  memory_limiter:
    check_interval: 1s
    limit_percentage: 80
    spike_limit_percentage: 25
  batch:
    send_batch_size: 1024
    timeout: 5s

exporters:
  prometheus:
    endpoint: "0.0.0.0:%d"

service:
  telemetry:
    metrics:
      level: none
  pipelines:
    metrics:
      receivers: [sqlquery]
      processors: [memory_limiter, batch]
      exporters: [prometheus]
`, kubedb.DocumentDBDatabasePort, kubedb.DocumentDBOTelMetricsPort)

    cm := &corev1.ConfigMap{
        ObjectMeta: metav1.ObjectMeta{
            Name:      c.getOTelConfigMapName(db),
            Namespace: db.Namespace,
        },
        Data: map[string]string{"config.yaml": config},
    }

    _, err := controllerutil.CreateOrUpdate(ctx, c.Client, cm, func() error {
        cm.Data["config.yaml"] = config
        return controllerutil.SetControllerReference(db, cm, c.Scheme)
    })
    return err
}
```

---

## Component 3: StatsService

A `<db>-stats` Service exposing both exporter ports.

```go
func (c *Reconciler) ensureStatsService(db *dbapi.DocumentDB) (kutil.VerbType, error) {
    if db.Spec.Monitor == nil || db.Spec.Monitor.Agent.Vendor() != mona.VendorPrometheus {
        return kutil.VerbUnchanged, nil
    }

    meta := metav1.ObjectMeta{
        Name:      db.StatsService().ServiceName(), // "<db>-stats"
        Namespace: db.Namespace,
    }

    _, vt, err := core_util.CreateOrPatchService(ctx, c.Client, meta, func(in *core.Service) *core.Service {
        in.Labels = db.OffshootLabels()
        in.Labels[kubedb.LabelRole] = kubedb.RoleStats
        in.Spec.Selector = db.OffshootSelectors()
        in.Spec.Ports = []core.ServicePort{
            {
                Name:       kubedb.DocumentDBPostgresExporterPortName, // "pg-metrics"
                Port:       kubedb.DocumentDBPostgresExporterPort,     // 56790
                TargetPort: intstr.FromString(mona.PrometheusExporterPortName),
            },
            {
                Name:       kubedb.DocumentDBOTelMetricsPortName, // "otel-metrics"
                Port:       kubedb.DocumentDBOTelMetricsPort,     // 8888
                TargetPort: intstr.FromString(kubedb.DocumentDBOTelMetricsPortName),
            },
        }
        return in
    }, metav1.PatchOptions{})
    return vt, err
}
```

---

## Component 4: ServiceMonitor

Created via the shared `mona.Agent` (from `kmodules.xyz/monitoring-agent-api`), exactly like KubeDB postgres:

```go
func (c *Reconciler) manageMonitor(db *dbapi.DocumentDB) error {
    if db.Spec.Monitor == nil {
        return nil
    }
    agent, err := agents.New(db.Spec.Monitor.Agent, c.Client, c.PromClient)
    if err != nil {
        return err
    }
    _, err = agent.CreateOrUpdate(db.StatsService(), db.Spec.Monitor)
    return err
}
```

The `agent.CreateOrUpdate` creates a `ServiceMonitor` selecting the `<db>-stats` Service, with one endpoint per port. Prometheus Operator discovers it and starts scraping.

---

## Component 5: Wiring in the reconcile loop

```go
func (c *Reconciler) reconcile(db *dbapi.DocumentDB) error {
    // ... existing steps (services, auth, rbac, config)...

    // 1. Reconcile OTel ConfigMap
    if db.Spec.Monitor != nil {
        if err := c.reconcileOTelConfigMap(db); err != nil {
            return err
        }
    }

    // 2. Ensure PetSet (with exporter + otel sidecar containers)
    if err := c.ensurePetSet(db); err != nil {
        return err
    }

    // 3. Ensure StatsService
    if err := c.ensureMonitoring(db); err != nil {
        return err
    }

    // 4. Create/update ServiceMonitor
    if err := c.manageMonitor(db); err != nil {
        return err
    }

    // ... rest of reconcile...
}
```

---

## Component 6: PetSet builder changes

In `ensurePetSet()`, add both sidecars when monitoring is enabled:

```go
if db.Spec.Monitor != nil && db.Spec.Monitor.Agent.Vendor() == mona.VendorPrometheus {
    // postgres_exporter
    pgExporter, err := c.getPostgresExporterContainer(db, version)
    if err == nil {
        containers = core_util.UpsertContainer(containers, pgExporter)
    }
    // otel-collector
    otelCollector := c.getOTelCollectorContainer(db)
    containers = core_util.UpsertContainer(containers, otelCollector)

    // Add OTel ConfigMap volume
    volumes = core_util.UpsertVolume(volumes, core.Volume{
        Name: "otel-collector-config",
        VolumeSource: core.VolumeSource{
            ConfigMap: &core.ConfigMapVolumeSource{
                LocalObjectReference: core.LocalObjectReference{
                    Name: c.getOTelConfigMapName(db),
                },
            },
        },
    })
}
```

---

## API Changes

### DocumentDBSpec (apis/kubedb/v1alpha2/documentdb_types.go)

```go
type DocumentDBSpec struct {
    // ... existing fields ...
  
    // Monitor specifies the monitoring configuration
    // +optional
    Monitor *mona.AgentSpec `json:"monitor,omitempty"`
}
```

### DocumentDBVersion (apis/catalog/v1alpha1/documentdb_version_types.go)

```go
type DocumentDBVersionSpec struct {
    // ... existing fields ...
  
    // PostgresExporter image for the postgres_exporter sidecar
    PostgresExporter DocumentDBVersionExporter `json:"postgresExporter"`
}

type DocumentDBVersionExporter struct {
    Image string `json:"image"`
}
```

### Constants (apis/kubedb/constants.go)

```go
const (
    DocumentDBPostgresExporterPort     = 56790
    DocumentDBPostgresExporterPortName = "pg-metrics"
    DocumentDBOTelMetricsPort          = 8888
    DocumentDBOTelMetricsPortName      = "otel-metrics"
    DocumentDBOTelCollectorImage       = "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.124.0"
)
```

### StatsAccessor (apis/kubedb/v1alpha2/documentdb_helpers.go)

```go
func (d DocumentDB) StatsService() mona.StatsAccessor {
    return &documentdbStatsService{&d}
}

type documentdbStatsService struct {
    *DocumentDB
}

func (s documentdbStatsService) ServiceName() string        { return s.OffshootName() + "-stats" }
func (s documentdbStatsService) ServiceMonitorName() string { return s.ServiceName() }
func (s documentdbStatsService) Path() string               { return kubedb.DefaultStatsPath }
func (s documentdbStatsService) Scheme() string             { return "http" }
func (s documentdbStatsService) TLSConfig() *promapi.TLSConfig { return nil }
```

### SetDefaults (apis/kubedb/v1alpha2/documentdb_helpers.go)

```go
func (d *DocumentDB) SetDefaults() {
    if d.Spec.Monitor != nil {
        d.Spec.Monitor.SetDefaults()
        if d.Spec.Monitor.Prometheus != nil {
            if d.Spec.Monitor.Prometheus.Exporter.Port == 0 {
                d.Spec.Monitor.Prometheus.Exporter.Port = kubedb.DocumentDBPostgresExporterPort
            }
        }
    }
}
```

---

## Reconciliation Order (following KubeDB postgres exactly)

```
Reconcile()
  │
  ├─ 1. ensureServices()         — primary + governing service
  ├─ 2. ensureAuthSecret()       — MongoDB auth secret
  ├─ 3. ensureAdminAuthSecret()  — Postgres admin secret  
  ├─ 4. reconcileOTelConfigMap() — creates <db>-otel-config (NEW)
  ├─ 5. ensurePetSet()           — adds exporter + otel-collector sidecars (MODIFIED)
  ├─ 6. ensureStatsService()     — creates <db>-stats Service (NEW)
  ├─ 7. manageMonitor()          — creates ServiceMonitor (NEW)
  └─ 8. ensureAppBinding()       — AppCatalog entry
```

---

## Exact mapping to KubeDB postgres pattern

| Postgres source                   | Function/Struct                       | DocumentDB equivalent                                                | Difference                                                            |
| --------------------------------- | ------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `petset.go:1059`                | `getMonitoringContainer()`          | `getPostgresExporterContainer()` + `getOTelCollectorContainer()` | 2 containers instead of 1. Port 9712.`AdminAuthSecret`.             |
| `service.go:236`                | `ensureStatsService()`              | `ensureStatsService()`                                             | 2 ports (pg-metrics:56790, otel-metrics:8888).                        |
| `monitor.go:37`                 | `ensureMonitoring()`                | `ensureMonitoring()`                                               | Identical — gate on`Monitor != nil && Vendor == VendorPrometheus`. |
| `monitor.go:105`                | `manageMonitor()`                   | `manageMonitor()`                                                  | Identical — handles agent type transitions.                          |
| `monitor.go:64`                 | `addOrUpdateMonitor()`              | `addOrUpdateMonitor()`                                             | Identical — delegates to`mona.Agent.CreateOrUpdate()`.             |
| `monitor.go:50`                 | `newMonitorController()`            | `newMonitorController()`                                           | Identical —`agents.New(agent, k8sClient, promClient)`.             |
| `monitor.go:72`                 | `deleteMonitor()`                   | `deleteMonitor()`                                                  | Identical.                                                            |
| `reconciler.go:42`              | `Reconciler` struct                 | `Reconciler` struct                                                | Same`PromClient pcm.MonitoringV1Interface` field.                   |
| `postgres.go:178`               | Reconcile order                       | Same order in DocumentDB                                             | Plus`reconcileOTelConfigMap()` before `ensurePetSet()`.           |
| —                                | —                                    | `reconcileOTelConfigMap()`                                         | **New** — generates `<db>-otel-config` ConfigMap.            |
| `postgres_helpers.go`           | `StatsService()`, `SetDefaults()` | Same in`documentdb_helpers.go`                                     | Different ports.                                                      |
| `postgres_types.go:115`         | `Monitor *mona.AgentSpec`           | Same in`documentdb_types.go`                                       | Same type.                                                            |
| `postgres_version_types.go:117` | `Exporter.PostgresVersionExporter`  | `PostgresExporter` in `documentdb_version_types.go`              | Same pattern.                                                         |

## Key differences from KubeDB postgres

| Aspect             | KubeDB postgres                           | DocumentDB                                                      |
| ------------------ | ----------------------------------------- | --------------------------------------------------------------- |
| DB port            | 5432                                      | **9712**                                                  |
| Auth secret        | `db.Spec.AuthSecret`                    | `db.Spec.AdminAuthSecret`                                     |
| Auth user          | `POSTGRES_SOURCE_USER` from auth secret | `documentdb` (superuser from admin-auth)                      |
| Sidecars           | 1 (postgres_exporter)                     | **2** (postgres_exporter + otel-collector)                |
| OTel ConfigMap     | None                                      | **`<db>-otel-config`** (new reconciler)                 |
| StatsService ports | 1 port (`metrics:56790`)                | **2 ports** (`pg-metrics:56790`, `otel-metrics:8888`) |

## Files to create/modify

| File                                                  | Action                                                           | Based on                          |
| ----------------------------------------------------- | ---------------------------------------------------------------- | --------------------------------- |
| `apis/kubedb/v1alpha2/documentdb_types.go`          | Add`Monitor *mona.AgentSpec`                                   | `postgres_types.go:115`         |
| `apis/kubedb/v1alpha2/documentdb_helpers.go`        | Add`StatsService()`, `SetDefaults()`                         | `postgres_helpers.go:287-327`   |
| `apis/kubedb/constants.go`                          | Add 4 port constants                                             | `kubedb/constants.go`           |
| `apis/catalog/v1alpha1/documentdb_version_types.go` | Add`PostgresExporter`                                          | `postgres_version_types.go:117` |
| `pkg/controllers/reconciler.go`                     | Add`PromClient pcm.MonitoringV1Interface`                      | `postgres/reconciler.go:42`     |
| `pkg/controllers/petset.go`                         | Add 2 container builders, OTel volume, wire in`EnsurePetSet()` | `postgres/petset.go:1059`       |
| `pkg/controllers/service.go`                        | Add`ensureStatsService()`                                      | `postgres/service.go:236`       |
| `pkg/controllers/otel_config.go`                    | **Create** — OTel ConfigMap reconciler                    | New                               |
| `pkg/controllers/monitor.go`                        | **Create** — full monitor controller                      | `postgres/monitor.go:37-133`    |
| `cmd/operator.go`                                   | Init`PromClient`, pass to Reconciler                           | postgres operator startup         |

---

## Verification

1. Create a DocumentDB with `spec.monitor.agent: prometheus.io/operator`:

```yaml
spec:
  monitor:
    agent: prometheus.io/operator
    prometheus:
      exporter:
        port: 56790
        resources:
          requests: {cpu: 50m, memory: 64Mi}
          limits:   {cpu: 200m, memory: 128Mi}
```

2. Verify PetSet has 3 containers: `documentdb`, `exporter`, `otel-collector`
3. Verify `<db>-otel-config` ConfigMap exists
4. Verify `<db>-stats` Service has both `pg-metrics:56790` and `otel-metrics:8888`
5. Verify ServiceMonitor `<db>-stats` exists and Prometheus shows both targets UP
6. Query Prometheus:

   - `pg_stat_database_tup_fetched` → 500+ metrics from postgres_exporter
   - `documentdb_gateway_documents_inserted` → 13+ metrics from OTel Collector
7. Import Grafana dashboard showing both metric families
