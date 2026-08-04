# DocumentDB Monitoring Summary — Actual Exported Metrics

Based on live metrics from `dcdb-0` pod running `sabnaj/documentdb-operator:monitoring-final`.

---

## Exporter 1: postgres_exporter

| | |
|---|---|
| Source | **Postgres backend** (`localhost:9712`) |
| Image | `quay.io/prometheuscommunity/postgres-exporter:v0.17.0` |
| Port | `:56790/metrics` |
| Total metric lines | **~1213** |
| Unique metric names | **~280** |

### Metrics by category (actual)

| Category | Count | Sample Metrics |
|----------|-------|---------------|
| Database activity | 23 | `pg_stat_database_tup_inserted`, `pg_stat_database_tup_updated`, `pg_stat_database_tup_deleted`, `pg_stat_database_tup_fetched`, `pg_stat_database_xact_commit`, `pg_stat_database_xact_rollback`, `pg_stat_database_deadlocks`, `pg_stat_database_numbackends`, `pg_stat_database_blks_hit`, `pg_stat_database_blks_read`, `pg_stat_database_conflicts_confl_lock`, `pg_stat_database_conflicts_confl_deadlock` |
| Per-table (collection) stats | 18 | `pg_stat_user_tables_n_tup_ins`, `pg_stat_user_tables_n_tup_upd`, `pg_stat_user_tables_n_tup_del`, `pg_stat_user_tables_n_live_tup`, `pg_stat_user_tables_n_dead_tup`, `pg_stat_user_tables_seq_scan`, `pg_stat_user_tables_idx_scan`, `pg_stat_user_tables_last_analyze`, `pg_stat_user_tables_size_bytes` |
| Per-table I/O | 8 | `pg_statio_user_tables_heap_blocks_hit`, `pg_statio_user_tables_heap_blocks_read`, `pg_statio_user_tables_idx_blocks_hit`, `pg_statio_user_tables_idx_blocks_read` |
| Locks | 1 | `pg_locks_count` (by `datname`, `mode`) |
| Replication | 3 | `pg_replication_is_replica`, `pg_replication_lag_seconds`, `pg_replication_last_replay_seconds` |
| WAL | 2 | `pg_wal_segments`, `pg_wal_size_bytes` |
| BG Writer | 4 | `pg_stat_bgwriter_buffers_alloc_total`, `pg_stat_bgwriter_buffers_clean_total`, `pg_stat_bgwriter_maxwritten_clean_total` |
| Archiver | 3 | `pg_stat_archiver_archived_count`, `pg_stat_archiver_failed_count`, `pg_stat_archiver_last_archive_age` |
| Connections | 2 | `pg_stat_activity_count`, `pg_stat_activity_max_tx_duration` |
| Database size | 1 | `pg_database_size_bytes` |
| Roles | 1 | `pg_roles_connection_limit` |
| Postmaster | 1 | `pg_postmaster_start_time_seconds` |
| Settings | ~200 | `pg_settings_max_connections`, `pg_settings_shared_buffers_bytes`, `pg_settings_effective_cache_size_bytes`, `pg_settings_work_mem_bytes`, `pg_settings_wal_buffers_bytes`, `pg_settings_autovacuum`, `pg_settings_statement_timeout_seconds`, `pg_settings_lock_timeout_seconds`, etc. |
| DocumentDB-specific settings | ~150 | `pg_settings_documentdb_enableSchemaValidation`, `pg_settings_documentdb_enableVectorHNSWIndex`, `pg_settings_documentdb_maxWriteBatchSize`, `pg_settings_documentdb_enableTTLBatchObservability`, `pg_settings_documentdb_enableUniqueCompositeReducedCorrelatedTerms`, `pg_settings_documentdb_TTLTaskMaxRunTimeInMS`, etc. |
| Exporter health | 4 | `pg_exporter_last_scrape_error`, `pg_exporter_last_scrape_duration_seconds`, `pg_exporter_scrapes_total`, `pg_up`, `pg_static` |

---

## Exporter 2: otel-collector (sqlquery receiver)

| | |
|---|---|
| Source | **Postgres backend** (`localhost:9712`) via custom SQL queries every 30s |
| Image | `ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.124.0` |
| Port | `:8888/metrics` |
| Total metric series | **30** (14 unique names × labels) |

### All metrics (actual, current values)

**Health:**
| Metric | Value | Source (SQL) |
|--------|-------|-------------|
| `documentdb_postgres_up` | 1 | `SELECT 1 AS up` |
| `documentdb_gateway_up` | 1 (>0 = up, 0 = down) | `count(*) FROM pg_stat_activity WHERE usename='default_user'` |

**Connections (MongoDB clients via gateway → Postgres):**
| Metric | Value | Source (SQL) |
|--------|-------|-------------|
| `documentdb_gateway_connections_total` | 16 | `count(*) FROM pg_stat_activity WHERE backend_type='client backend'` |
| `documentdb_gateway_connections_active` | 1 | `count(*) FILTER (WHERE state='active')` |
| `documentdb_gateway_connections_idle` | 15 | `count(*) FILTER (WHERE state='idle')` |
| `documentdb_gateway_connections_waiting` | 0 | `count(*) FILTER (WHERE wait_event_type='Lock')` |

**Operations per database (total, all time):**
| Metric | Value | Source (SQL) |
|--------|-------|-------------|
| `documentdb_gateway_operations_commits` | 115,863 | `xact_commit FROM pg_stat_database` |
| `documentdb_gateway_operations_rollbacks` | 6 | `xact_rollback FROM pg_stat_database` |
| `documentdb_gateway_documents_inserted` | 30,324 | `tup_inserted FROM pg_stat_database` |
| `documentdb_gateway_documents_updated` | 29,602 | `tup_updated FROM pg_stat_database` |
| `documentdb_gateway_documents_deleted` | 3,522 | `tup_deleted FROM pg_stat_database` |
| `documentdb_gateway_documents_fetched` | 6,814,592 | `tup_fetched FROM pg_stat_database` |
| `documentdb_gateway_deadlocks` | 0 | `deadlocks FROM pg_stat_database` |
| `documentdb_gateway_database_size_bytes` | 20.7 MB | `pg_database_size()` |

**Per-collection stats (each labeled with `db` + `collection`):**

Collections: `documents_1`-`documents_6`, `retry_1`-`retry_6`, `retryable_writes`

| Metric | Example (collection `documents_2`) |
|--------|-------------------------------------|
| `documentdb_gateway_collection_documents_inserted` | 1 |
| `documentdb_gateway_collection_documents_updated` | 0 |
| `documentdb_gateway_collection_documents_deleted` | 0 |
| `documentdb_gateway_collection_documents_fetched` | 714 |

---

## Source summary

```
┌──────────────────────────────────────────────────────────┐
│  ALL METRICS COME FROM POSTGRES (:9712)                  │
│                                                          │
│  ┌─ postgres_exporter (:56790) ───────────────────────┐  │
│  │  • ~280 unique metric names, 1213 data points       │  │
│  │  • Database activity, locks, replication, WAL       │  │
│  │  • Background writer, archiver stats                │  │
│  │  • Per-table (collection) stats + I/O               │  │
│  │  • ~200 PG settings + ~150 DocumentDB settings      │  │
│  │  • Connection activity                              │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  ┌─ otel-collector (:8888) ───────────────────────────┐  │
│  │  • 29 metric series from custom SQL queries         │  │
│  │  • Gateway-level aggregates (docs, ops, deadlocks)  │  │
│  │  • Per-collection document counts                   │  │
│  │  • Connection counts (active/idle/total/waiting)    │  │
│  │  • Database size, liveness check                    │  │
│  └────────────────────────────────────────────────────┘  │
│                                                          │
│  Gateway (:10260) ──► NOT directly monitored             │
│    • mongodb_exporter: only mongodb_up=1                 │
│    • Native OTel: not compiled in current image          │
│    • Gateway activity INFERRED from Postgres stats       │
└──────────────────────────────────────────────────────────┘
```
