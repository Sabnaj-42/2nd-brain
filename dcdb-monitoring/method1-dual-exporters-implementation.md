# Method 1 Implementation Plan: Dual Exporter Sidecars

## Overview

Add two exporter sidecars to the DocumentDB pod following the KubeDB postgres monitoring pattern:

```
DocumentDB Pod
├── documentdb (main: Postgres :9712 + Gateway :10260)
├── postgres-exporter → localhost:9712 → port 56790 → /metrics
└── mongodb-exporter  → localhost:10260 → port 56791 → /metrics

Service <db>-stats
├── port "pg-metrics" → 56790
└── port "mongo-metrics" → 56791

ServiceMonitor → Prometheus Operator → Prometheus → Grafana
```

---

## What to Add (Following KubeDB postgres Pattern)

### Step 1: apimachinery — Add Monitor field to DocumentDBSpec

**File:** `/home/sabnaj/go/src/kubedb.dev/apimachinery/apis/kubedb/v1alpha2/documentdb_types.go`

Add the `Monitor` field (exactly like Postgres at `postgres_types.go:115`):

```go
type DocumentDBSpec struct {
    // ... existing fields ...

    // Monitor specifies the monitoring configuration for DocumentDB
    // +optional
    Monitor *mona.AgentSpec `json:"monitor,omitempty"`
}
```

Add a `StatsService()` helper method to `documentdb_helpers.go`:

```go
func (d DocumentDB) StatsService() mona.StatsAccessor {
    return &documentdbStatsService{&d}
}

type documentdbStatsService struct {
    *DocumentDB
}

func (s documentdbStatsService) ServiceName() string {
    return s.OffshootName() + "-stats"
}
func (s documentdbStatsService) ServiceMonitorName() string {
    return s.ServiceName()
}
func (s documentdbStatsService) Path() string {
    return kubedb.DefaultStatsPath  // "/metrics"
}
func (s documentdbStatsService) Scheme() string {
    return "http"
}
func (s documentdbStatsService) TLSConfig() *promapi.TLSConfig {
    return nil
}
```

Add monitoring-related constants to `apis/kubedb/constants.go`:

```go
const (
    DocumentDBPostgresExporterPort     = 56790
    DocumentDBPostgresExporterPortName = "pg-metrics"
    DocumentDBMongoExporterPort        = 56791
    DocumentDBMongoExporterPortName    = "mongo-metrics"
)
```

### Step 2: DocumentDBVersion catalog — Add Exporter images

**File:** `apis/catalog/v1alpha1/documentdb_version_types.go`

```go
type DocumentDBVersionExporter struct {
    Image string `json:"image"`
}

type DocumentDBVersionSpec struct {
    // ... existing fields ...
    PostgresExporter DocumentDBVersionExporter `json:"postgresExporter"`
    MongoExporter    DocumentDBVersionExporter `json:"mongoExporter,omitempty"`
}
```

Register images in the DocumentDBVersion CRs (e.g., `pg17-0.109.0`):
```yaml
postgresExporter:
  image: quay.io/prometheuscommunity/postgres-exporter:v0.17.0
mongoExporter:
  image: percona/mongodb_exporter:0.44.0
```

### Step 3: Exporter sidecar containers — petset.go

**File:** `pkg/controllers/petset.go`

Add `getPostgresExporterContainer()`:

```go
func (c *Reconciler) getPostgresExporterContainer(db *dbapi.DocumentDB, version *catalog.DocumentDBVersion) (core.Container, error) {
    sslMode := string(db.Spec.SSLMode)
    if sslMode == "" {
        sslMode = "disable"
    }

    cnnstr := fmt.Sprintf("user=${PG_EXPORTER_USER} password='${PG_EXPORTER_PASS}' host=%s port=%d sslmode=%s",
        kubedb.LocalHost, kubedb.DocumentDBDatabasePort, sslMode)

    if db.Spec.TLS != nil {
        if sslMode == "verify-ca" || sslMode == "verify-full" {
            cnnstr = fmt.Sprintf("%s sslrootcert=%s/exporter/ca.crt", cnnstr, kubedb.SharedTlsVolumeMountPath)
        }
        if db.Spec.ClientAuthMode == dbapi.ClientAuthModeCert {
            cnnstr = fmt.Sprintf("%s sslcert=%s/exporter/tls.crt sslkey=%s/exporter/tls.key", cnnstr, kubedb.SharedTlsVolumeMountPath)
        }
    }

    port := db.Spec.Monitor.Prometheus.Exporter.Port
    if port == 0 {
        port = kubedb.DocumentDBPostgresExporterPort // 56790
    }

    cmd := fmt.Sprintf(`export DATA_SOURCE_NAME="%s"; /bin/postgres_exporter --log.level=info --web.listen-address=:%d`,
        cnnstr, port)

    image, _ := authn.ImageWithDigest(c.Client, version.Spec.PostgresExporter.Image, utils.K8sChainOpts(db))

    container := core.Container{
        Name:            "postgres-exporter",
        Image:           image,
        ImagePullPolicy: core.PullIfNotPresent,
        Command:         []string{"/bin/sh"},
        Args:            []string{"-c", cmd},
        Ports: []core.ContainerPort{{
            Name:          kubedb.DocumentDBPostgresExporterPortName,
            ContainerPort: int32(port),
            Protocol:      core.ProtocolTCP,
        }},
        Env: []core.EnvVar{
            {
                Name: "PG_EXPORTER_USER",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        LocalObjectReference: core.LocalObjectReference{Name: db.Spec.AdminAuthSecret.Name},
                        Key: core.BasicAuthUsernameKey,
                    },
                },
            },
            {
                Name: "PG_EXPORTER_PASS",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        LocalObjectReference: core.LocalObjectReference{Name: db.Spec.AdminAuthSecret.Name},
                        Key: core.BasicAuthPasswordKey,
                    },
                },
            },
            {
                Name:  "PG_EXPORTER_WEB_TELEMETRY_PATH",
                Value: db.StatsService().Path(),
            },
        },
    }

    if db.Spec.TLS != nil {
        container.VolumeMounts = []core.VolumeMount{{
            Name:      kubedb.SharedTlsVolumeName,
            MountPath: kubedb.SharedTlsVolumeMountPath,
        }}
    }

    return container, nil
}
```

Add `getMongoExporterContainer()`:

```go
func (c *Reconciler) getMongoExporterContainer(db *dbapi.DocumentDB, version *catalog.DocumentDBVersion) (core.Container, error) {
    port := kubedb.DocumentDBMongoExporterPort // 56791
    // Override from spec if set
    if db.Spec.Monitor != nil && db.Spec.Monitor.Prometheus != nil {
        // Could add a separate port field for mongo exporter in AgentSpec
    }

    uri := fmt.Sprintf("mongodb://${MONGO_USER}:${MONGO_PASS}@%s:%d/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsInsecure=true&directConnection=true",
        kubedb.LocalHost, kubedb.DocumentDBGatewayPort)

    image, _ := authn.ImageWithDigest(c.Client, version.Spec.MongoExporter.Image, utils.K8sChainOpts(db))

    container := core.Container{
        Name:            "mongo-exporter",
        Image:           image,
        ImagePullPolicy: core.PullIfNotPresent,
        Args: []string{
            "--web.listen-address=:" + strconv.Itoa(port),
            "--web.telemetry-path=/metrics",
            "--mongodb.direct-connect",
            "--compatible-mode",
        },
        Env: []core.EnvVar{
            {
                Name: "MONGODB_URI",
                Value: uri, // with env var placeholders resolved at runtime
            },
            {
                Name: "MONGO_USER",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        LocalObjectReference: core.LocalObjectReference{Name: db.Spec.AuthSecret.Name},
                        Key: core.BasicAuthUsernameKey,
                    },
                },
            },
            {
                Name: "MONGO_PASS",
                ValueFrom: &core.EnvVarSource{
                    SecretKeyRef: &core.SecretKeySelector{
                        LocalObjectReference: core.LocalObjectReference{Name: db.Spec.AuthSecret.Name},
                        Key: core.BasicAuthPasswordKey,
                    },
                },
            },
        },
        Ports: []core.ContainerPort{{
            Name:          kubedb.DocumentDBMongoExporterPortName,
            ContainerPort: int32(port),
            Protocol:      core.ProtocolTCP,
        }},
    }

    return container, nil
}
```

Wire them in `EnsurePetSet()`:

```go
// After main container, before coordinator
if db.Spec.Monitor != nil && db.Spec.Monitor.Agent.Vendor() == mona.VendorPrometheus {
    pgExporter, err := c.getPostgresExporterContainer(db, version)
    if err == nil {
        containers = core_util.UpsertContainer(containers, pgExporter)
    }
    // Only add mongo-exporter if gateway metrics are wanted
    if db.Spec.Monitor.Prometheus != nil { // or a separate toggle
        mongoExporter, err := c.getMongoExporterContainer(db, version)
        if err == nil {
            containers = core_util.UpsertContainer(containers, mongoExporter)
        }
    }
}
```

### Step 4: StatsService — provisioner service.go

Create `ensureStatsService()` following the postgres pattern (see `/home/sabnaj/go/src/kubedb.dev/postgres/pkg/controller/service.go:236`):

```go
func (c *Reconciler) ensureStatsService(db *dbapi.DocumentDB) (kutil.VerbType, error) {
    if db.Spec.Monitor == nil || db.Spec.Monitor.Agent.Vendor() != mona.VendorPrometheus {
        return kutil.VerbUnchanged, nil
    }

    meta := metav1.ObjectMeta{
        Name:      db.StatsService().ServiceName(),
        Namespace: db.Namespace,
    }

    _, vt, err := core_util.CreateOrPatchService(ctx, c.Client, meta, func(in *core.Service) *core.Service {
        in.Labels = db.StatsServiceLabels()
        in.Spec.Selector = db.OffshootSelectors()
        in.Spec.Ports = []core.ServicePort{
            {
                Name:       kubedb.DocumentDBPostgresExporterPortName,
                Port:       56790,
                TargetPort: intstr.FromString(kubedb.DocumentDBPostgresExporterPortName),
            },
            {
                Name:       kubedb.DocumentDBMongoExporterPortName,
                Port:       56791,
                TargetPort: intstr.FromString(kubedb.DocumentDBMongoExporterPortName),
            },
        }
        return in
    }, metav1.PatchOptions{})
    return vt, err
}
```

### Step 5: Monitor controller — monitor.go

Create `pkg/controllers/monitor.go` following the postgres pattern (see `/home/sabnaj/go/src/kubedb.dev/postgres/pkg/controller/monitor.go`):

```go
func (c *Reconciler) ensureMonitoring(db *dbapi.DocumentDB) error {
    if db.Spec.Monitor == nil || db.Spec.Monitor.Agent.Vendor() != mona.VendorPrometheus {
        return nil
    }
    _, err := c.ensureStatsService(db)
    return err
}

func (c *Reconciler) manageMonitor(db *dbapi.DocumentDB) error {
    if db.Spec.Monitor == nil || db.Spec.Monitor.Agent.Vendor() != mona.VendorPrometheus {
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

### Step 6: Wiring — reconciler.go

Add `PromClient` to the `Reconciler` struct and wire it:

```go
type Reconciler struct {
    // ... existing fields ...
    PromClient pcm.MonitoringV1Interface
}

// In reconcile loop (after EnsurePetSet):
if err := c.ensureMonitoring(db); err != nil {
    return err
}
if err := c.manageMonitor(db); err != nil {
    return err
}
```

### Step 7: SetDefaults — documentdb_helpers.go

Add defaults for the monitor spec:

```go
func (d *DocumentDB) SetDefaults() {
    // ... existing ...
    if d.Spec.Monitor != nil {
        d.Spec.Monitor.SetDefaults()
        if d.Spec.Monitor.Prometheus != nil && d.Spec.Monitor.Prometheus.Exporter.Port == 0 {
            d.Spec.Monitor.Prometheus.Exporter.Port = kubedb.DocumentDBPostgresExporterPort
        }
    }
}
```

---

## Files to Create/Modify

| File | Change |
|------|--------|
| `apis/kubedb/v1alpha2/documentdb_types.go` | Add `Monitor *mona.AgentSpec` field |
| `apis/kubedb/v1alpha2/documentdb_helpers.go` | Add `StatsService()`, `StatsServiceLabels()`, `SetDefaults()` |
| `apis/kubedb/constants.go` | Add port/name constants |
| `apis/catalog/v1alpha1/documentdb_version_types.go` | Add `PostgresExporter`, `MongoExporter` to VersionSpec |
| `pkg/controllers/petset.go` | Add `getPostgresExporterContainer()`, `getMongoExporterContainer()`, wire in `EnsurePetSet()` |
| `pkg/controllers/service.go` | Add `ensureStatsService()` |
| `pkg/controllers/monitor.go` | **New file** — `ensureMonitoring()`, `manageMonitor()` |
| `pkg/controllers/reconciler.go` | Add `PromClient` field, wire monitoring in reconcile |
| `cmd/operator.go` | Initialize `PromClient` and pass to Reconciler |

---

## Verification

After implementation:
1. Set `spec.monitor.agent: prometheus.io/operator` on a DocumentDB CR
2. Verify postgres-exporter and mongo-exporter containers appear in the PetSet
3. Verify `<db>-stats` Service is created with both ports
4. Verify ServiceMonitor is created and targets are UP in Prometheus
5. Verify Postgres metrics in Grafana (494 metrics)
6. Note: mongodb_exporter will only provide `mongodb_up` — limited but useful for liveness

## ⚠️ Known Limitation

The `mongodb_exporter` only returns `mongodb_up=1` because the DocumentDB gateway doesn't fully implement MongoDB diagnostic commands (`serverStatus`, etc.). It identifies as `mongos` role. For full gateway metrics, consider Method 2 (OTel Collector with gateway OTLP) as a complementary approach.
