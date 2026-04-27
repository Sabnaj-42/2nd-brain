# PostgreSQL-Related Variables in DocumentDB

## Variables That Interact with PostgreSQL

Based on the configuration files, here are all DocumentDB variables that are directly related to PostgreSQL functionality:

---

## 1. Connection & Database Variables

### localhost_connection_string
- **Type**: String
- **Default Value**: "host=localhost"
- **Context**: PGC_SUSET (superuser only)
- **Purpose**: Sets hostname and connection parameters when connecting back to PostgreSQL itself for operations that need libpq connection
- **PostgreSQL Interaction**: Used for self-connections via libpq
- **Example Values**:
  - "host=localhost"
  - "host=127.0.0.1"
  - "host=localhost port=5433"
  - "host=db.example.com port=5432"

### bg_worker_database_name
- **Type**: String
- **Default Value**: "postgres"
- **Context**: PGC_POSTMASTER (requires restart, superuser only)
- **Purpose**: Database to which background worker will connect
- **PostgreSQL Interaction**: Specifies which PostgreSQL database the background worker uses
- **Example Values**:
  - "postgres" (system database)
  - "documentdb" (application database)
  - Any valid PostgreSQL database name

### enableDbNameValidation
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_USERSET
- **Purpose**: Enforce that $db in the command body matches the database argument
- **PostgreSQL Interaction**: Validates database name consistency in PostgreSQL

---

## 2. Query & Execution Variables

### query_plan_cache_size
- **Type**: Integer
- **Default Value**: 100
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Size of the query plan cache
- **PostgreSQL Interaction**: Controls PostgreSQL query planner cache
- **Recommended Values**:
  - 50 - small cache
  - 100 - default (balanced)
  - 200-500 - large cache

### enableStatementTimeout
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_USERSET
- **Purpose**: Enable per-statement backend timeout override in the backend
- **PostgreSQL Interaction**: Controls statement-level timeouts in PostgreSQL backend

### IsPgReadOnlyForDiskFull
- **Type**: Boolean
- **Default Value**: false
- **Context**: PGC_USERSET
- **Purpose**: Indicates if PostgreSQL is in read-only mode due to full disk
- **PostgreSQL Interaction**: Tracks PostgreSQL disk full status
- **Notes**: System-set flag, typically not user-modified

### throwDeadlockOnCRUD
- **Type**: Boolean
- **Default Value**: false
- **Context**: PGC_USERSET
- **Purpose**: Determine whether deadlock on CRUD operations should be thrown as exception or caught
- **PostgreSQL Interaction**: Controls how PostgreSQL deadlock exceptions are handled
- **Values**:
  - true - throw deadlock exceptions
  - false - catch and write to operation result

---

## 3. Index & Access Method Variables

### rum_library_load_option
- **Type**: Enum
- **Default Value**: "require_documentdb_extended_rum" (PG18+), "none" (older)
- **Range**: "none", "prefer_documentdb_extended_rum", "require_documentdb_extended_rum"
- **Context**: PGC_POSTMASTER (requires restart)
- **Purpose**: Specifies RUM library load option for DocumentDB
- **PostgreSQL Interaction**: Controls which RUM (Reverse Index Map) library PostgreSQL uses
- **Notes**: Different defaults based on PostgreSQL version (PG_VERSION_NUM)
- **Possible Values**:
  - "none" - Don't load RUM library
  - "prefer_documentdb_extended_rum" - Prefer extended RUM version
  - "require_documentdb_extended_rum" - Must use extended version

### alternate_index_handler_name
- **Type**: String
- **Default Value**: "" (empty, use default RUM)
- **Context**: PGC_USERSET
- **Purpose**: The name of the index handler to use as opposed to RUM
- **PostgreSQL Interaction**: Allows specifying alternative PostgreSQL index access methods
- **Example Values**:
  - "" - use default RUM
  - "btree" - use B-tree index
  - Custom index handler names

### forceUseIndexIfAvailable
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_USERSET
- **Purpose**: Force query planner to push to RUM index if applicable
- **PostgreSQL Interaction**: Overrides PostgreSQL query planner cost-based decisions
- **Impact**: Disables sequential scan in favor of RUM index when available

---

## 4. Transaction & Write Variables

### maxWriteBatchSize
- **Type**: Integer
- **Default Value**: 25000
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Maximum number of write operations permitted in a write batch
- **PostgreSQL Interaction**: Controls transaction batch size for PostgreSQL
- **Notes**: Limited to 25000 due to sub-transaction handling optimization

### batchWriteSubTransactionCount
- **Type**: Integer
- **Default Value**: 512
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Size of each sub-transaction within write commands
- **PostgreSQL Interaction**: Aligns with PostgreSQL sub-transaction handling
- **Notes**: Set to 512 to match Mongo spark client

### enable_create_collection_on_insert
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_USERSET
- **Purpose**: Create collection when inserting into non-existent collection
- **PostgreSQL Interaction**: Controls auto-creation of PostgreSQL tables/collections

---

## 5. Authentication & User Management Variables

### scramDefaultSaltLen
- **Type**: Integer
- **Default Value**: 28
- **Range**: 1 to 64
- **Context**: PGC_SUSET (superuser only)
- **Purpose**: Default SCRAM salt length for authentication
- **PostgreSQL Interaction**: Controls PostgreSQL SCRAM-SHA-256 password authentication
- **Impact**: Affects password security level in PostgreSQL

### maxUserLimit
- **Type**: Integer
- **Default Value**: 100
- **Range**: 1 to 500
- **Context**: PGC_SUSET (superuser only)
- **Purpose**: Maximum number of users allowed
- **PostgreSQL Interaction**: Limits PostgreSQL user/role creation

### blockedRolePrefixList
- **Type**: String (comma-separated)
- **Default Value**: "" (empty)
- **Context**: PGC_USERSET
- **Purpose**: List of role prefixes blocked from being created/deleted
- **PostgreSQL Interaction**: Prevents creation of PostgreSQL roles with certain prefixes
- **Example Values**:
  - "pg_" - block PostgreSQL system roles
  - "admin_,system_" - block multiple prefixes
  - "" - no blocked roles

---

## 6. Cursor & Memory Variables

### maxCursorIntermediateFileSizeMB
- **Type**: Integer (megabytes)
- **Default Value**: 4096 (4 GB)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Maximum size of intermediate file for cursor storage
- **PostgreSQL Interaction**: Affects PostgreSQL temporary file usage
- **Impact**: Controls spill-to-disk for large cursor results

### maxCursorFileCount
- **Type**: Integer
- **Default Value**: 5000
- **Range**: 0 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Maximum number of cursor files allowed (0 = unlimited)
- **PostgreSQL Interaction**: Limits temporary files created by PostgreSQL

### defaultCursorExpiryTimeLimitSeconds
- **Type**: Integer (seconds)
- **Default Value**: 60
- **Range**: 1 to 3600
- **Context**: PGC_USERSET
- **Purpose**: Default expiry time limit for cursor
- **PostgreSQL Interaction**: Controls cursor lifetime in PostgreSQL connections

### defaultCursorFirstPageBatchSize
- **Type**: Integer
- **Default Value**: 101
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Default batch size for first page of cursor
- **PostgreSQL Interaction**: Controls initial result set size from PostgreSQL queries

---

## 7. Lock & Concurrency Variables

### bg_worker_latch_timeout
- **Type**: Integer (seconds)
- **Default Value**: 1
- **Range**: 0 to 200
- **Context**: PGC_POSTMASTER (requires restart, superuser only)
- **Purpose**: Latch timeout inside main thread of background worker
- **PostgreSQL Interaction**: Controls PostgreSQL background worker synchronization
- **PostgreSQL Concept**: Uses PostgreSQL Latch mechanism for efficient waiting

### TTLPurgerLockTimeout
- **Type**: Integer (milliseconds)
- **Default Value**: 10000
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Lock timeout for TTL purger delete query
- **PostgreSQL Interaction**: Controls lock acquisition timeout in PostgreSQL

---

## 8. Statistics & Query Planning Variables

### coll_stats_count_policy_threshold
- **Type**: Integer
- **Default Value**: 10000
- **Range**: 1 to INT_MAX-1
- **Context**: PGC_USERSET
- **Purpose**: Document count threshold for collStats count policy change
- **PostgreSQL Interaction**: Determines when to use PostgreSQL stats vs runtime count
- **Impact**: Balances between pg_stat_all_tables and live query counts

### usePgStatsLiveTuplesForCount
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_USERSET
- **Purpose**: Use pg_stat_all_tables live tuples for count in collStats
- **PostgreSQL Interaction**: Queries PostgreSQL's built-in statistics table
- **Impact**: Uses PostgreSQL statistics for collection document count

---

## 9. Background Worker Variables

### enableBackgroundWorker
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_POSTMASTER (requires restart)
- **Purpose**: Enable/disable the extension Background worker
- **PostgreSQL Interaction**: Activates PostgreSQL dynamic background worker registration
- **Notes**: Required for TTL and index building operations

### enableBackgroundWorkerJobs
- **Type**: Boolean
- **Default Value**: true
- **Context**: PGC_USERSET
- **Purpose**: Enable/disable execution of pre-defined background worker jobs
- **PostgreSQL Interaction**: Controls job scheduling in PostgreSQL background worker

### enableBackgroundWorkerInitJobs
- **Type**: Boolean
- **Default Value**: false
- **Context**: PGC_POSTMASTER (requires restart)
- **Purpose**: Enable/disable execution of initialization background jobs
- **PostgreSQL Interaction**: Runs initialization tasks in PostgreSQL background worker

### backgroundWorkerJobTimeoutThresholdSec
- **Type**: Integer (seconds)
- **Default Value**: 300
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Purpose**: Maximum allowed timeout for background worker job
- **PostgreSQL Interaction**: Controls max execution time in PostgreSQL background process

---

## 10. Version-Dependent Variables

### PG_VERSION_NUM Check
Some variables behavior changes based on PostgreSQL version:

```
#if PG_VERSION_NUM >= 180000
  // PostgreSQL 18 and later
  rum_library_load_option defaults to: "require_documentdb_extended_rum"
#else
  // PostgreSQL 17 and earlier
  rum_library_load_option defaults to: "none"
#endif
```

---

## 11. Other PostgreSQL-Related Variables

### enableTTLJobsOnReadOnly
- **Type**: Boolean
- **Default Value**: false
- **Context**: PGC_USERSET
- **Purpose**: Enable TTL jobs on read-only nodes
- **PostgreSQL Interaction**: Overrides PostgreSQL's default_transaction_readonly for TTL jobs
- **Note**: Explicitly disabled by default to avoid WAL generation on full disks

### maxCustomCommandTimeoutLimit
- **Type**: Integer (milliseconds)
- **Default Value**: 10800000 (3 hours)
- **Range**: 0 to INT_MAX
- **Context**: PGC_SUSET (superuser only)
- **Purpose**: Maximum allowed custom command timeout limit
- **PostgreSQL Interaction**: Sets ceiling for statement timeout in PostgreSQL

---

## Summary Table - PostgreSQL-Related Variables

| Variable | Type | Default | PostgreSQL Component |
|----------|------|---------|----------------------|
| localhost_connection_string | str | "host=localhost" | libpq Connection |
| bg_worker_database_name | str | "postgres" | Background Worker |
| query_plan_cache_size | int | 100 | Query Planner |
| enableStatementTimeout | bool | true | Executor |
| IsPgReadOnlyForDiskFull | bool | false | Storage |
| throwDeadlockOnCRUD | bool | false | Concurrency Control |
| rum_library_load_option | enum | "require..." | Index Access Method |
| alternate_index_handler_name | str | "" | Index Access Method |
| forceUseIndexIfAvailable | bool | true | Query Planner |
| maxWriteBatchSize | int | 25000 | Transactions |
| batchWriteSubTransactionCount | int | 512 | Sub-transactions |
| enable_create_collection_on_insert | bool | true | DDL |
| scramDefaultSaltLen | int | 28 | Authentication |
| maxUserLimit | int | 100 | User Management |
| blockedRolePrefixList | str | "" | Roles |
| maxCursorIntermediateFileSizeMB | int | 4096 | Memory/Temp Files |
| maxCursorFileCount | int | 5000 | Temp Files |
| defaultCursorExpiryTimeLimitSeconds | int | 60 | Cursors |
| defaultCursorFirstPageBatchSize | int | 101 | Result Sets |
| bg_worker_latch_timeout | int | 1 | Background Worker |
| TTLPurgerLockTimeout | int | 10000 | Locking |
| coll_stats_count_policy_threshold | int | 10000 | Statistics |
| usePgStatsLiveTuplesForCount | bool | true | Statistics |
| enableBackgroundWorker | bool | true | Background Worker |
| enableBackgroundWorkerJobs | bool | true | Background Worker |
| enableBackgroundWorkerInitJobs | bool | false | Background Worker |
| backgroundWorkerJobTimeoutThresholdSec | int | 300 | Background Worker |
| enableTTLJobsOnReadOnly | bool | false | Transaction Mode |
| maxCustomCommandTimeoutLimit | int | 10800000 | Timeout |

---

## PostgreSQL Features Controlled by DocumentDB Variables

### 1. **Query Planner & Optimization**
- `query_plan_cache_size` - Plan cache sizing
- `forceUseIndexIfAvailable` - Index selection strategy
- `alternate_index_handler_name` - Alternative index methods

### 2. **Connection Management**
- `localhost_connection_string` - Self-connection parameters
- `bg_worker_database_name` - Worker database selection

### 3. **Transaction Control**
- `maxWriteBatchSize` - Batch transaction size
- `batchWriteSubTransactionCount` - Sub-transaction boundaries
- `throwDeadlockOnCRUD` - Deadlock handling
- `enableTTLJobsOnReadOnly` - Read-only mode override

### 4. **Authentication & Authorization**
- `scramDefaultSaltLen` - Password hashing salt
- `maxUserLimit` - User limit
- `blockedRolePrefixList` - Role restrictions

### 5. **Index Access Methods**
- `rum_library_load_option` - RUM library loading
- `alternate_index_handler_name` - Custom index handlers

### 6. **Background Workers**
- `enableBackgroundWorker` - Worker activation
- `enableBackgroundWorkerJobs` - Job execution
- `bg_worker_latch_timeout` - Worker synchronization

### 7. **Statistics & Monitoring**
- `coll_stats_count_policy_threshold` - Stats usage
- `usePgStatsLiveTuplesForCount` - Statistics integration

### 8. **Cursor & Result Management**
- `defaultCursorExpiryTimeLimitSeconds` - Cursor lifetime
- `defaultCursorFirstPageBatchSize` - Result batch size
- `maxCursorFileCount` - Temp file limits

---

## Configuration Example for PostgreSQL Tuning

```ini
# PostgreSQL Connection & Database
documentdb.localhost_connection_string = "host=localhost port=5432"
documentdb.bg_worker_database_name = "postgres"
documentdb.enableDbNameValidation = true

# Query Planning & Execution
documentdb.query_plan_cache_size = 200
documentdb.forceUseIndexIfAvailable = true
documentdb.enableStatementTimeout = true
documentdb.alternate_index_handler_name = ""

# Transactions & Batching
documentdb.maxWriteBatchSize = 25000
documentdb.batchWriteSubTransactionCount = 512
documentdb.throwDeadlockOnCRUD = false

# Authentication
documentdb.scramDefaultSaltLen = 28
documentdb.maxUserLimit = 100
documentdb.blockedRolePrefixList = "pg_"

# Background Worker
documentdb.enableBackgroundWorker = true
documentdb.enableBackgroundWorkerJobs = true
documentdb.bg_worker_latch_timeout = 1
documentdb.backgroundWorkerJobTimeoutThresholdSec = 300

# Index & RUM Library
documentdb.rum_library_load_option = "require_documentdb_extended_rum"
documentdb.alternate_index_handler_name = ""

# Statistics
documentdb.coll_stats_count_policy_threshold = 10000
documentdb.usePgStatsLiveTuplesForCount = true

# Cursors
documentdb.defaultCursorExpiryTimeLimitSeconds = 60
documentdb.defaultCursorFirstPageBatchSize = 101
documentdb.maxCursorFileCount = 5000
```

---

## Notes

1. **Restart Required**: Some variables control PostgreSQL core behavior and require restart (PGC_POSTMASTER)
2. **Superuser Only**: Some variables require superuser permissions (PGC_SUSET)
3. **Version Dependent**: rum_library_load_option behavior depends on PostgreSQL version
4. **Performance Impact**: Query planning variables significantly affect performance
5. **Authentication**: SCRAM salt length affects security level

