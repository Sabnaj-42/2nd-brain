# DocumentDB Monitoring YAML Files

These YAML files configure monitoring for a DocumentDB instance with 3 containers:
- `documentdb` — main container (Postgres :9712 + Gateway :10260)
- `exporter` — postgres_exporter sidecar (:56790) — 900+ PG metrics
- `otel-collector` — OTel Collector sidecar (:8888) — 29 gateway-level metrics via SQL

## Files

| File | Purpose |
|------|---------|
| `01-otel-configmap.yaml` | OTel Collector configuration (sqlquery receiver) |
| `02-stats-service.yaml` | `<db>-stats` Service exposing both metrics ports |
| `03-documentdb-monitor-patch.yaml` | DocumentDB CR patch to enable monitoring |
| `04-servicemonitor.yaml` | ServiceMonitor for Prometheus Operator discovery |

## How to Apply

### 1. Set up OTel ConfigMap
```bash
kubectl apply -f 01-otel-configmap.yaml
```

### 2. Create Stats Service
```bash
kubectl apply -f 02-stats-service.yaml
```

### 3. Patch PetSet to add sidecar containers
```bash
kubectl scale sts -n kubedb kubedb-kubedb-provisioner --replicas=0

kubectl patch petset -n demo dcdb --type='json' -p='[
  {"op": "add", "path": "/spec/template/spec/containers/-", "value": {
    "name": "exporter",
    "image": "quay.io/prometheuscommunity/postgres-exporter:v0.17.0",
    "command": ["/bin/sh", "-c"],
    "args": ["export DATA_SOURCE_NAME=\"host=127.0.0.1 port=9712 user=${PGUSER} password=${PGPASSWORD} dbname=postgres sslmode=disable\"; /bin/postgres_exporter --web.listen-address=:56790 --web.telemetry-path=/metrics --collector.postmaster"],
    "env": [
      {"name": "PGUSER", "valueFrom": {"secretKeyRef": {"name": "dcdb-admin-auth", "key": "username"}}},
      {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "dcdb-admin-auth", "key": "password"}}}
    ],
    "ports": [{"name": "metrics", "containerPort": 56790, "protocol": "TCP"}]
  }},
  {"op": "add", "path": "/spec/template/spec/containers/-", "value": {
    "name": "otel-collector",
    "image": "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.124.0",
    "args": ["--config=/etc/otel/config.yaml"],
    "env": [
      {"name": "PGUSER", "valueFrom": {"secretKeyRef": {"name": "dcdb-admin-auth", "key": "username"}}},
      {"name": "PGPASSWORD", "valueFrom": {"secretKeyRef": {"name": "dcdb-admin-auth", "key": "password"}}}
    ],
    "ports": [{"name": "otel-metrics", "containerPort": 8888, "protocol": "TCP"}],
    "volumeMounts": [{"name": "otel-collector-config", "mountPath": "/etc/otel", "readOnly": true}]
  }},
  {"op": "add", "path": "/spec/template/spec/volumes/-", "value": {
    "name": "otel-collector-config",
    "configMap": {"name": "dcdb-otel-config"}
  }}
]'

# Trigger restart
kubectl delete pod -n demo dcdb-0

# Restore operator
kubectl scale sts -n kubedb kubedb-kubedb-provisioner --replicas=1
```

### 4. Create ServiceMonitor (for prometheus.io/operator agent)
```bash
kubectl apply -f 04-servicemonitor.yaml
```

## Verify

```bash
# Check containers
kubectl get pod -n demo dcdb-0 -o jsonpath='{.spec.containers[*].name}'
# documentdb exporter otel-collector

# Check postgres_exporter
kubectl exec -n demo dcdb-0 -c exporter -- wget -qO- http://localhost:56790/metrics | grep "^pg_" | wc -l
# 900+

# Check OTel Collector
kubectl exec -n demo dcdb-0 -c exporter -- wget -qO- http://localhost:8888/metrics | grep "^documentdb"
# 29 metrics

# Check Prometheus targets (both UP)
kubectl port-forward -n monitoring prometheus-monitoring-kube-prometheus-prometheus-0 9090:9090
curl -s 'http://localhost:9090/api/v1/targets' | grep dcdb-stats
```

## Metrics Available

| Source | Port | Count | Examples |
|--------|------|-------|---------|
| postgres_exporter | 56790 | 900+ | `pg_stat_database_tup_*`, `pg_locks_count`, `pg_replication_*`, `pg_stat_bgwriter_*` |
| OTel Collector | 8888 | 29 | `documentdb_gateway_documents_*`, `documentdb_gateway_connections_*`, `documentdb_gateway_collection_documents_*`, `documentdb_postgres_up` |
