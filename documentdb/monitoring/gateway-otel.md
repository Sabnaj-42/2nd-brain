# Gateway OTLP — Env vars, metrics, and sidecar options

## 1. Does the official gateway image have a built-in OTLP exporter?

**Yes.** The gateway binary (`pg_documentdb_gw`) has OpenTelemetry baked in. Confirmed from source:

- `Cargo.toml` has `opentelemetry`, `opentelemetry-otlp`, `opentelemetry_sdk`, and `tracing-opentelemetry` as direct dependencies
- `metrics.rs` has the full implementation — meter providers, periodic readers, gRPC exporters
- The whole thing is **dormant by default** and wakes up when you set one env var

You don't need to build anything extra. The official image already has it.

---

## 2. Env vars to set on the gateway

**Bare minimum — just 2:**

```bash
OTEL_METRICS_ENABLED=true
OTEL_EXPORTER_OTLP_ENDPOINT=http://<your-collector>:4317
```

**Optional overrides:**

| Env Var | Default | Purpose |
|---------|---------|---------|
| `OTEL_METRIC_EXPORT_INTERVAL` | `15000` (15s) | How often to push metrics (ms) |
| `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT` | falls back to `OTEL_EXPORTER_OTLP_TIMEOUT` | gRPC timeout |
| `OTEL_SERVICE_NAME` | — | Label to identify this gateway instance |

The endpoint fallback chain is: `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` → `OTEL_EXPORTER_OTLP_ENDPOINT` → default endpoint.

---

## 3. What metrics will you get from the gateway?

All **10 metrics**:

```
db.client.operation.duration.total    — total operation time (with Postgres phase breakdown)
db.client.operations                   — operation count
db.client.request.size.total           — request payload size
db.client.response.size.total          — response payload size
db.client.documents.returned           — docs returned (Find, Aggregate, GetMore)
db.client.documents.inserted           — docs inserted
db.client.documents.updated            — docs updated
db.client.documents.deleted            — docs deleted
gateway_startup_delay_ms               — how long startup took
gateway.starts                         — restart counter
```

All labeled with `db.system.name`, `db.operation.name`, `db.collection.name`, `db.namespace`, and `error.type` on failures.

---

## 4. Do you need the OTel Collector sidecar?

**For gateway metrics: No.** The gateway pushes OTLP natively. Point it at any OTLP-compatible receiver — your own OTel Collector, a cloud backend, whatever.

**For Postgres metrics: Yes, you need something.** Postgres doesn't expose metrics on its own. Two options:

| Option | How it works | Complexity |
|--------|-------------|------------|
| **OTel Collector with sqlquery receiver** (what Microsoft does) | Sidecar runs SQL against Postgres every 30s, turns rows into metrics | Medium — need to configure OTel pipeline |
| **postgres_exporter sidecar** (what KubeDB does) | Single binary, connects to Postgres, exposes `/metrics` in Prometheus format | Low — simple flags, single binary |

---

## 5. How to get BOTH gateway and Postgres metrics?

The simplest approach — use **one OTel Collector** as the single collection point:

```
┌──────────┐
│ Postgres │──SQL──→ (OTel Collector sqlquery receiver)
└──────────┘                                              │
                                                          ├──→ :8888/metrics → Prometheus
┌──────────┐                                              │
│ Gateway  │──OTLP─→ (OTel Collector otlp receiver)
└──────────┘
```

The gateway pushes metrics via OTLP to the Collector, and the Collector also queries Postgres via SQL. The Collector merges both streams and exposes a single Prometheus endpoint. **One sidecar, not two.**

But you could also split them — `postgres_exporter` for Postgres (`:9187`) + point the gateway directly at Prometheus or cloud. No rule says you must use OTel Collector. It's just convenient because it handles both sources in one container.

---

## Quick summary for building your own operator

```
Gateway env vars (set on the gateway container):
  OTEL_METRICS_ENABLED=true
  OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
  → Gateway pushes 10 metrics via OTLP/gRPC every 15s — no extra binary needed

Postgres (no built-in metrics — you need a sidecar):
  Option A: OTel Collector with sqlquery receiver (run SQL, expose :8888/metrics)
  Option B: postgres_exporter (connect to Postgres, expose :9187/metrics)

Then Prometheus scrapes the sidecar → Grafana renders it.
```
