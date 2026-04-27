# Quick Reference - PostgreSQL-Related Variables

## All 28 PostgreSQL-Related Variables

| # | Variable | Type | Default | PostgreSQL Component | Critical |
|----|----------|------|---------|----------------------|----------|
| 1 | localhost_connection_string | str | "host=localhost" | libpq Connection | ⚠️ |
| 2 | bg_worker_database_name | str | "postgres" | Background Worker | ⚠️ |
| 3 | enableDbNameValidation | bool | true | Database Validation | ✅ |
| 4 | query_plan_cache_size | int | 100 | Query Planner | ✅ |
| 5 | enableStatementTimeout | bool | true | Executor | ✅ |
| 6 | IsPgReadOnlyForDiskFull | bool | false | Storage Status | ℹ️ |
| 7 | throwDeadlockOnCRUD | bool | false | Concurrency | ✅ |
| 8 | rum_library_load_option | enum | "require..." | Index AM | ⚠️ |
| 9 | alternate_index_handler_name | str | "" | Index AM | ✅ |
| 10 | forceUseIndexIfAvailable | bool | true | Query Planner | ✅ |
| 11 | maxWriteBatchSize | int | 25000 | Transactions | ✅ |
| 12 | batchWriteSubTransactionCount | int | 512 | Sub-transactions | ✅ |
| 13 | enable_create_collection_on_insert | bool | true | DDL | ✅ |
| 14 | scramDefaultSaltLen | int | 28 | Authentication | ⚠️ |
| 15 | maxUserLimit | int | 100 | User Management | ⚠️ |
| 16 | blockedRolePrefixList | str | "" | Roles | ✅ |
| 17 | maxCursorIntermediateFileSizeMB | int | 4096 | Temp Files | ✅ |
| 18 | maxCursorFileCount | int | 5000 | Temp Files | ✅ |
| 19 | defaultCursorExpiryTimeLimitSeconds | int | 60 | Cursors | ✅ |
| 20 | defaultCursorFirstPageBatchSize | int | 101 | Result Sets | ✅ |
| 21 | bg_worker_latch_timeout | int | 1 | BG Worker Sync | ⚠️ |
| 22 | TTLPurgerLockTimeout | int | 10000 | Locking | ✅ |
| 23 | coll_stats_count_policy_threshold | int | 10000 | Statistics | ✅ |
| 24 | usePgStatsLiveTuplesForCount | bool | true | Statistics | ✅ |
| 25 | enableBackgroundWorker | bool | true | BG Worker Core | ⚠️ |
| 26 | enableBackgroundWorkerJobs | bool | true | BG Worker Jobs | ✅ |
| 27 | enableBackgroundWorkerInitJobs | bool | false | BG Worker Init | ⚠️ |
| 28 | backgroundWorkerJobTimeoutThresholdSec | int | 300 | BG Worker | ✅ |
| 29 | enableTTLJobsOnReadOnly | bool | false | Transaction Mode | ✅ |
| 30 | maxCustomCommandTimeoutLimit | int | 10800000 | Timeout | ⚠️ |

**Legend:**
- ⚠️ = Requires restart or affects PostgreSQL core behavior
- ✅ = Standard runtime variable
- ℹ️ = System-set information flag

---

## By PostgreSQL Component

### 🔌 Connection & Database (2)
```
1. localhost_connection_string
2. bg_worker_database_name
```

### 📊 Query Planner & Optimization (3)
```
1. query_plan_cache_size
2. forceUseIndexIfAvailable
3. alternate_index_handler_name
```

### 🗂️ Index Access Methods (2)
```
1. rum_library_load_option
2. alternate_index_handler_name (see Planner)
```

### 💾 Transactions & Concurrency (4)
```
1. maxWriteBatchSize
2. batchWriteSubTransactionCount
3. throwDeadlockOnCRUD
4. TTLPurgerLockTimeout
```

### 👤 Authentication & User Management (4)
```
1. scramDefaultSaltLen
2. maxUserLimit
3. blockedRolePrefixList
4. enableDbNameValidation
```

### 🔄 Background Worker (5)
```
1. enableBackgroundWorker
2. enableBackgroundWorkerJobs
3. enableBackgroundWorkerInitJobs
4. bg_worker_database_name
5. bg_worker_latch_timeout
6. backgroundWorkerJobTimeoutThresholdSec
```

### 📈 Statistics & Monitoring (2)
```
1. coll_stats_count_policy_threshold
2. usePgStatsLiveTuplesForCount
```

### 🔖 Cursor & Result Management (4)
```
1. defaultCursorExpiryTimeLimitSeconds
2. defaultCursorFirstPageBatchSize
3. maxCursorIntermediateFileSizeMB
4. maxCursorFileCount
```

### ⏱️ Execution & Timeouts (4)
```
1. enableStatementTimeout
2. maxCustomCommandTimeoutLimit
3. bg_worker_latch_timeout
4. backgroundWorkerJobTimeoutThresholdSec
```

### 🗄️ Storage & DDL (3)
```
1. IsPgReadOnlyForDiskFull
2. enable_create_collection_on_insert
3. maxCursorIntermediateFileSizeMB
```

### 📋 Read-Only Mode (1)
```
1. enableTTLJobsOnReadOnly
```

---

## Critical PostgreSQL Variables (Must Configure)

### For Production Deployments:
```ini
# Enable core PostgreSQL functionality
documentdb.enableBackgroundWorker = true
documentdb.enableBackgroundWorkerJobs = true

# Connection settings
documentdb.localhost_connection_string = "host=localhost"
documentdb.bg_worker_database_name = "postgres"

# Performance
documentdb.forceUseIndexIfAvailable = true
documentdb.query_plan_cache_size = 100-200

# Transactions
documentdb.maxWriteBatchSize = 25000
documentdb.batchWriteSubTransactionCount = 512

# Index handling
documentdb.rum_library_load_option = "require_documentdb_extended_rum"
```

---

## Restart-Required PostgreSQL Variables (⚠️)

These require PostgreSQL restart to take effect:

```
1. enableBackgroundWorker (PGC_POSTMASTER)
2. enableBackgroundWorkerInitJobs (PGC_POSTMASTER)
3. bg_worker_database_name (PGC_POSTMASTER)
4. bg_worker_latch_timeout (PGC_POSTMASTER)
5. rum_library_load_option (PGC_POSTMASTER)
6. scramDefaultSaltLen (PGC_SUSET - superuser only)
7. maxUserLimit (PGC_SUSET - superuser only)
8. maxCustomCommandTimeoutLimit (PGC_SUSET - superuser only)
```

---

## Common Configuration Scenarios

### Scenario 1: Development Setup
```ini
documentdb.localhost_connection_string = "host=localhost port=5432"
documentdb.query_plan_cache_size = 50
documentdb.maxWriteBatchSize = 10000
documentdb.enableStatementTimeout = true
```

### Scenario 2: High-Performance Production
```ini
documentdb.query_plan_cache_size = 500
documentdb.forceUseIndexIfAvailable = true
documentdb.maxWriteBatchSize = 25000
documentdb.maxCursorIntermediateFileSizeMB = 8192
documentdb.backgroundWorkerJobTimeoutThresholdSec = 600
```

### Scenario 3: Multi-Database Setup
```ini
documentdb.bg_worker_database_name = "documentdb"
documentdb.localhost_connection_string = "host=db-server port=5432"
documentdb.maxUserLimit = 200
```

### Scenario 4: Authentication-Heavy
```ini
documentdb.scramDefaultSaltLen = 32
documentdb.maxUserLimit = 500
documentdb.blockedRolePrefixList = "pg_,system_"
documentdb.enableDbNameValidation = true
```

### Scenario 5: Memory-Constrained
```ini
documentdb.maxCursorIntermediateFileSizeMB = 512
documentdb.maxCursorFileCount = 1000
documentdb.query_plan_cache_size = 50
documentdb.defaultCursorFirstPageBatchSize = 25
```

---

## PostgreSQL Version Dependencies

### PostgreSQL 18+
```
rum_library_load_option default: "require_documentdb_extended_rum"
→ Uses DocumentDB's extended RUM library by default
```

### PostgreSQL 17 and Earlier
```
rum_library_load_option default: "none"
→ Must explicitly configure RUM library loading
```

---

## Impact of Each PostgreSQL Variable

| Variable | If Too Low | If Too High | Balanced Setting |
|----------|-----------|-----------|------------------|
| query_plan_cache_size | Cache misses, replanning | Memory usage | 100-200 |
| maxWriteBatchSize | Slower writes | Large transactions | 25000 |
| batchWriteSubTransactionCount | Frequent subtrans | Long subtrans | 512 |
| maxUserLimit | User creation fails | Security risk | 100-500 |
| scramDefaultSaltLen | Weaker password hash | Slight perf impact | 28 |
| maxCursorIntermediateFileSizeMB | Disk thrashing | High memory | 4096-8192 |
| maxCursorFileCount | Cursor limit errors | Disk usage | 5000 |
| backgroundWorkerJobTimeoutThresholdSec | Jobs timeout | Long waits | 300-600 |

---

## Troubleshooting PostgreSQL-Related Issues

### Problem: Connection Errors
**Check:**
- `localhost_connection_string` - valid connection string?
- `bg_worker_database_name` - database exists?
- Port number in connection string correct?

### Problem: Query Plan Cache Issues
**Check:**
- `query_plan_cache_size` - too small?
- Increase to 200-500 for high-concurrency

### Problem: Background Worker Not Starting
**Check:**
- `enableBackgroundWorker = true`?
- Requires PostgreSQL restart to take effect
- Check PostgreSQL logs for errors

### Problem: Authentication Issues
**Check:**
- `scramDefaultSaltLen` - value 1-64?
- `maxUserLimit` - reached user limit?
- `blockedRolePrefixList` - blocking needed roles?

### Problem: Cursor/Memory Issues
**Check:**
- `maxCursorFileCount` - limit reached?
- `maxCursorIntermediateFileSizeMB` - sufficient?
- Temporary file permissions?

---

## PostgreSQL Documentation References

These DocumentDB variables control PostgreSQL features:

- **Query Planner**: PostgreSQL documentation on query planning
- **Background Workers**: PostgreSQL documentation on custom background workers
- **SCRAM**: PostgreSQL password authentication mechanisms
- **Transactions**: PostgreSQL transaction control and sub-transactions
- **Statistics**: PostgreSQL pg_stats family of tables
- **Index Access Methods**: PostgreSQL index types and handlers

