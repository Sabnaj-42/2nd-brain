# 2nd Brain

Personal knowledge vault — notes, test reports, and working YAML for KubeDB database
operators, Kubernetes/infra fundamentals, and personal study material.

Directory names are lowercase-kebab. Each top-level area is self-contained; shared
diagrams live in [`images/`](images/) and are referenced as `../images/<file>.png`.

---

## Databases

### [`documentdb/`](documentdb/) — KubeDB DocumentDB

The largest area. All DocumentDB work lives here.

| Path | What's in it |
|---|---|
| [`readme.md`](documentdb/readme.md), [`resource.md`](documentdb/resource.md) | Overview and reference links |
| [`clustering/`](documentdb/clustering/) | Replication, Raft, Postgres internals, `failover-writer/` test app |
| [`tls/`](documentdb/tls/) | TLS design, implementation notes, and test results |
| [`tls/reconfigure/`](documentdb/tls/reconfigure/) | `ReconfigureTLS` ops-request YAMLs + results |
| [`tls/test-tls/`](documentdb/tls/test-tls/) | End-to-end TLS test: architecture, procedure, evidence, init-image patch |
| [`tls/tls_carousel/`](documentdb/tls/tls_carousel/) | General TLS/HTTPS explainer slides (SVG + PNG + PDF) |
| [`monitoring/`](documentdb/monitoring/) | OTel collector vs. dual-exporter designs, Grafana dashboard, ServiceMonitor YAMLs |
| [`ops-request/`](documentdb/ops-request/) | Ops-request test YAMLs — HA (`ops-test-yaml/`) and standalone |
| [`autoscaler/`](documentdb/autoscaler/) | Compute + storage autoscaler testing and metrics-backend install steps |
| [`config_variable/`](documentdb/config_variable/) | Configurable variables reference tables |
| [`environment_variable/`](documentdb/environment_variable/) | Bootstrap / init / role script env dumps |
| [`gateway-separate/`](documentdb/gateway-separate/) | Standalone gateway deployment manifests |
| [`autoscale-test-yaml/`](documentdb/autoscale-test-yaml/), [`manualYaml/`](documentdb/manualYaml/), [`standaloneyaml/`](documentdb/standaloneyaml/) | Assorted working manifests |

**Test reports** — [`reports/`](documentdb/reports/)

- [`clustering-failover-test-result.md`](documentdb/reports/clustering-failover-test-result.md) — clustering / replication / failover
- [`ops-request-test-result.md`](documentdb/reports/ops-request-test-result.md) — full ops-request matrix
- [`reconfiguretls-plan.md`](documentdb/reports/reconfiguretls-plan.md) — `ReconfigureTLS` implementation plan

### [`db2/`](db2/) — IBM Db2

HADR clustering ([`db2Clustering/`](db2/db2Clustering/)), reconcile-workflow write-ups,
failover error analysis ([`FailoverError.md`](db2/FailoverError.md)), and standalone manifests.

### [`mongodb/`](mongodb/) — MongoDB

Ops-request, versioning, and custom-config YAMLs.

### [`cassandra/`](cassandra/) — Cassandra

Base manifests ([`yaml/`](cassandra/yaml/)) and ops-request tests ([`ops-request/`](cassandra/ops-request/)).

---

## Platform & fundamentals

| Area | Notes |
|---|---|
| [`kubernetes/`](kubernetes/) | Core concepts, PetSet, AppBinding, operator reconciliation loop |
| [`docker/`](docker/) | Docker basics |
| [`linux/`](linux/) | Linux fundamentals + course study guide PDF |
| [`computer-network/`](computer-network/) | Networking / OSI model |
| [`scripts/`](scripts/) | Utility scripts — [`reinstall_k3s.sh`](scripts/reinstall_k3s.sh) |
| [`images/`](images/) | Shared diagrams referenced from notes across the vault |

---

## Personal

| Area | Notes |
|---|---|
| [`gre/`](gre/) | GRE prep — [`study_plan.md`](gre/study_plan.md), verbal, quant, analytical writing, vocab PDFs |
| [`resume/`](resume/) | LaTeX resume sources ([`academic/main.tex`](resume/academic/main.tex)) |
| [`keyboard-shortcuts/`](keyboard-shortcuts/) | Editor / OS shortcut cheatsheet |
