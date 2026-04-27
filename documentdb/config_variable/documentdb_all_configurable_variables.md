# Complete DocumentDB Configuration Reference for Kubernetes Operator

## How to Use These Configurations

All these variables can be set in your `postgresql.conf` file when deploying DocumentDB via your Kubernetes operator.

### Method 1: Create a ConfigMap with all settings
```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: documentdb-custom-config
data:
  documentdb-custom.conf: |
    # Paste configurations from below
```

### Method 2: Append to postgresql.conf via bash script
```bash
#!/bin/bash
cat >> /var/lib/postgresql/data/postgresql.conf << 'EOF'
# Your configurations from below
EOF
```

---

## 1. BACKGROUND JOB CONFIGURATIONS (background_job_configs.c)

### TTL (Time-To-Live) Settings

```ini
# Maximum batch size for deleting expired documents (default: 1000)
documentdb.maxTTLDeleteBatchSize = 500

# Query timeout for TTL delete operations in milliseconds (default: 60000)
documentdb.TTLPurgerStatementTimeout = 120000

# Lock timeout for TTL purger in milliseconds (default: 10000)
documentdb.TTLPurgerLockTimeout = 10000

# Time budget for TTL task to purge one batch per eligible TTL index in ms (default: 20000)
documentdb.SingleTTLTaskTimeBudget = 20000

# Time budget assigned per single TTL task invocation in milliseconds (default: 60000)
documentdb.TTLTaskMaxRunTimeInMS = 90000

# Batch size for non-ordered TTL indexes (default: 10000)
documentdb.maxTTLBatchSizeUnorderedIndex = 10000

# Enable descending sort on TTL field (default: false)
documentdb.enableTTLDescSort = false

# Enable TTL metrics collection (default: true)
documentdb.enableTTLBatchObservability = true

# Force index scans for TTL tasks (disable sequential/bitmap scans) (default: true)
documentdb.forceIndexScanForTTLTask = true

# Use index hints for TTL ordered scans (default: true)
documentdb.useIndexHintsForTTLTask = true

# Keep deleting until time budget is exhausted (default: true)
documentdb.repeatPurgeIndexesForTTLTask = true

# Skip TTL indexes that are caught up (default: true)
documentdb.TTLSkipCaughtUpIndexes = true

# Skip repeat deletes for unordered indexes (default: true)
documentdb.skipRepeatDeleteForUnOrderedIndex = true

# Log TTL purger activity (default: false)
documentdb.logTTLProgressActivity = false
```

### Index Building Settings

```ini
# Maximum retry attempts for failed index builds (default: 3, range: 1-32767)
documentdb.maxIndexBuildAttempts = 5

# Schedule interval for index build cron job in seconds (default: 2, range: 1-60)
documentdb.indexBuildScheduleInSec = 3

# Eviction interval for skippable build requests in seconds (default: 1200)
documentdb.indexQueueEvictionIntervalInSec = 1200

# Maximum concurrent active index builds per user (default: 2)
documentdb.maxNumActiveUsersIndexBuilds = 3
```

### Background Worker Settings

```ini
# Enable/disable background worker (default: true) - REQUIRES RESTART
documentdb.enableBackgroundWorker = true

# Enable/disable background job execution (default: true)
documentdb.enableBackgroundWorkerJobs = true

# Enable/disable initialization background jobs (default: false) - REQUIRES RESTART
documentdb.enableBackgroundWorkerInitJobs = false

# Maximum timeout threshold for background jobs in seconds (default: 300)
documentdb.backgroundWorkerJobTimeoutThresholdSec = 600

# Database for background worker connection (default: "postgres") - REQUIRES RESTART
documentdb.bg_worker_database_name = "postgres"

# Latch timeout inside bg worker leader thread in seconds (default: 1, range: 0-200) - REQUIRES RESTART
documentdb.bg_worker_latch_timeout = 2
```

---

## 2. FEATURE FLAGS (feature_flag_configs.c)

### Vector Search Features

```ini
# Enable HNSW index type and query for vector search (default: true)
documentdb.enableVectorHNSWIndex = true

# Enable vector pre-filtering feature (default: true)
documentdb.enableVectorPreFilter = true

# Enable vector pre-filtering v2 feature (default: false)
documentdb.enableVectorPreFilterV2 = false

# Force vector index queries to be pushed (default: false)
documentdb.enable_force_push_vector_index = false

# Enable vector compression half (default: true)
documentdb.enableVectorCompressionHalf = true

# Enable vector compression product quantization (default: true)
documentdb.enableVectorCompressionPQ = true

# Enable vector default search parameter calculation (default: true)
documentdb.enableVectorCalculateDefaultSearchParam = true
```

### Schema Validation Features

```ini
# Support schema validation (default: false)
documentdb.enableSchemaValidation = false

# Support 'bypassDocumentValidation' (default: false)
documentdb.enableBypassDocumentValidation = false
```

### Authentication & Authorization Features

```ini
# Enable username/password constraints (default: true)
documentdb.enableUsernamePasswordConstraints = true

# Enable usersInfo to return privileges (default: true)
documentdb.enableUsersInfoPrivileges = true

# Enable native authentication (default: true)
documentdb.isNativeAuthEnabled = true

# Enable role CRUD operations (default: false)
documentdb.enableRoleCrud = false

# Enable db admin check for user CRUD (default: false)
documentdb.enableUsersAdminDBCheck = false

# Enable db admin check for role CRUD (default: true)
documentdb.enableRolesAdminDBCheck = true
```

### Indexing Features

```ini
# Use new composite index opclass for defaults (default: true)
documentdb.defaultUseCompositeOpClass = true

# Enable composite index planner improvements (default: false)
documentdb.enableCompositeIndexPlanner = false

# Enable new ordered cost estimator (default: true)
documentdb.enableOrderedCostEstimator = true

# Enable index-only scans (default: true)
documentdb.enableIndexOnlyScan = true

# Enable index-only scans on cost function (default: true)
documentdb.enableIndexOnlyScanOnCost = true

# Enable custom cost function for ID index (default: true)
documentdb.enableIdIndexCustomCostFunction = true

# Enable order by ID on cost function (default: false)
documentdb.enableOrderByIdOnCostFunction = false

# Enable composite parallel index scan (default: false)
documentdb.enableCompositeParallelIndexScan = false

# Enable value-only index terms (default: true)
documentdb.enableValueOnlyIndexTerms = true

# Use new unique hash equality function (default: true)
documentdb.useNewUniqueHashEqualityFunction = true

# Enable composite unique hash (default: true)
documentdb.enableCompositeUniqueHash = true

# Enable RUM new composite term generation (default: true)
documentdb.enableRumNewCompositeTermGeneration = true

# Enable composite wildcard index (default: true)
documentdb.enableCompositeWildcardIndex = true

# Create TTL indexes as composite by default (default: true)
documentdb.createTTLIndexAsCompositeByDefault = true

# Enable reduced correlated terms (default: false)
documentdb.enableCompositeReducedCorrelatedTerms = false

# Enable unique reduced correlated terms (default: false)
documentdb.enableUniqueCompositeReducedCorrelatedTerms = false

# Enable reduced terms on common sub-paths (default: true)
documentdb.enableCompositeReducedCorrelatedTermsOnCommonSubPath = true

# Enable composite shard document terms (default: true)
documentdb.enableCompositeShardDocumentTerms = true

# Enable composite wildcard skip empty entries (default: true)
documentdb.enableCompositeWildcardSkipEmptyEntries = true

# Enable per-collection planner statistics (default: false)
documentdb.enablePerCollectionPlannerStatistics = false

# Enable ordered composite operator scan (default: true)
documentdb.enableOrderedCompositeOperatorScan = true

# Enable regex prefix index bounds (default: true)
documentdb.enableRegexPrefixIndexBounds = true

# Enable extended indexes (default: false)
documentdb.enableExtendedIndexes = false

# Enable comparable terms (default: false)
documentdb.enableComparableTerms = false

# Enable order by index term (default: false)
documentdb.enableOrderByIndexTerm = false
```

### Planner Features

```ini
# Use low selectivity for lookup (default: true)
documentdb.lowSelectivityForLookup = true

# Enable expr and lookup pushdown to index (default: true)
documentdb.enableExprLookupIndexPushdown = true

# Unify partial filter expressions on index (default: true)
documentdb.unifyPfeOnIndexInfo = true

# Enable new count aggregates (default: true)
documentdb.enableNewCountAggregates = true

# Enable extended explain on analyze off (default: true)
documentdb.enableExtendedExplainOnAnalyzeOff = true

# Enable explain scan index costs (default: true)
documentdb.enableExplainScanIndexCosts = true

# Enable explain scan namespace name (default: true)
documentdb.enableExplainScanNamespaceName = true

# Enable new min/max accumulators (default: false)
documentdb.enableNewMinMaxAccumulators = false

# Enable new WithExpr accumulators (default: false)
documentdb.enableNewWithExprAccumulators = false

# Enable cursor plan before restriction path update (default: true)
documentdb.enableCursorPlanBeforeRestrictionPathUpdate = true
```

### Query & Aggregation Features

```ini
# Enable primary key cursor scan (default: false)
documentdb.enablePrimaryKeyCursorScan = false

# Enable continuation fast bitmap lookup (default: false)
documentdb.enableContinuationFastBitmapLookup = false

# Use file-based persisted cursors (default: false)
documentdb.useFileBasedPersistedCursors = false

# Fail on group ID duplicate (default: false)
documentdb.failOnGroupIdDuplicate = false

# Enable conversion streamable to single batch (default: true)
documentdb.enableConversionStreamableToSingleBatch = true

# Enable find projection after offset (default: true)
documentdb.enableFindProjectionAfterOffset = true

# Enable delayed hold portal (default: true)
documentdb.enableDelayedHoldPortal = true

# Enable ID index pushdown (default: true)
documentdb.enableIdIndexPushdown = true

# Enable $in to scalar array conversion (default: true)
documentdb.enableDollarInToScalarArrayOpExprConversion = true

# Enable foreign key lookup inline (default: true)
documentdb.enableUseForeignKeyLookupInline = true

# Enable addToSet aggregation rewrite (default: true)
documentdb.enableAddToSetAggregationRewrite = true

# Enable ID index pushdown for query operator (default: true)
documentdb.enableIdIndexPushdownForQueryOp = true

# Enable binary search for ordered move (default: true)
documentdb.enableBinarySearchForOrderedMove = true

# Inline changestream match stage (default: true)
documentdb.inlineChangeStreamMatchStage = true

# Remove match namespace filters (default: true)
documentdb.removeMatchNamespaceFilters = true

# Multiple $ positional operators not allowed (default: true)
documentdb.multipleDollarPositionalNotAllowed = true

# Enable group subquery elimination (default: true)
documentdb.enableGroupSubqueryElimination = true

# Fail on non-empty group count arg (default: false)
documentdb.failOnNonEmptyGroupCountArg = false

# Enable sort group stage (default: true)
documentdb.enableSortGroupStage = true
```

### Let Support Features

```ini
# Enable operator variables in lookup (default: false)
documentdb.EnableOperatorVariablesInLookup = false
```

### Collation Features

```ini
# Skip fail on collation (default: false)
documentdb.skipFailOnCollation = false

# Enable lookup ID join optimization on collation (default: false)
documentdb.enableLookupIdJoinOptimizationOnCollation = false

# Enable collation with non-unique ordered indexes (default: false)
documentdb.enableCollationWithNonUniqueOrderedIndexes = false

# Enable collation with new group accumulators (default: false)
documentdb.enableCollationWithNewGroupAccumulators = false
```

### DML & Write Path Features

```ini
# Enable update_bson_document command (default: true)
documentdb.enableUpdateBsonDocument = true
```

### Cluster Administration & DDL Features

```ini
# Recreate retry table on sharding (default: false)
documentdb.recreate_retry_table_on_shard = false

# Enable schema enforcement for CSFLE (default: true)
documentdb.enableSchemaEnforcementForCSFLE = true

# Use pg_stat live tuples for count (default: true)
documentdb.usePgStatsLiveTuplesForCount = true

# Enable prepare unique (default: false)
documentdb.enablePrepareUnique = false

# Enable collmod unique (default: false)
documentdb.enableCollModUnique = false

# Enable drop indexes on read-only (default: true)
documentdb.enableDropInvalidIndexesOnReadOnly = true

# Enable only collection cache invalidate (default: true)
documentdb.enableOnlyCollectionCacheInvalidateOnCollectionChanges = true

# Enable streaming cursor drain via DestReceiver (default: true)
documentdb.enableStreamingCursorDrainViaDestReceiver = true
```

### Background Job Scheduling

```ini
# Schedule index builds via background worker (default: false)
documentdb.indexBuildsScheduledOnBgWorker = false
```

---

## 3. SYSTEM CONFIGURATIONS (system_configs.c)

### Database & Connection Settings

```ini
# Localhost connection string (default: "host=localhost")
documentdb.localhost_connection_string = "host=localhost"

# Create collection on insert (default: true)
documentdb.enable_create_collection_on_insert = true

# Enforce $db matching (default: true)
documentdb.enableDbNameValidation = true

# Query plan cache size (default: 100, range: 1+)
documentdb.query_plan_cache_size = 100
```

### Write Batch Settings

```ini
# Maximum write operations in a batch (default: 25000, range: 1+)
documentdb.maxWriteBatchSize = 25000

# Size of each sub-transaction within write commands (default: 512, range: 1+)
documentdb.batchWriteSubTransactionCount = 512

# CollStats count policy change threshold (default: 10000, range: 1+)
documentdb.coll_stats_count_policy_threshold = 10000
```

### Query Optimization Settings

```ini
# Force use of index if available (default: true)
documentdb.forceUseIndexIfAvailable = true

# Determine if disk is full (default: false)
documentdb.IsPgReadOnlyForDiskFull = false

# Maximum custom command timeout in milliseconds (default: 10800000, range: 0+)
documentdb.maxCustomCommandTimeoutLimit = 10800000
```

### Geospatial Settings

```ini
# Maximum segment length in km for geospatial queries (default: 500, range: 0-6372)
documentdb.geo2dsphereSegmentMaxLength = 500

# Maximum segment vertices for geospatial queries (default: 8, range: 0-32)
documentdb.geo2dsphereSegmentMaxVertices = 8
```

### Index & Collection Settings

```ini
# Maximum indexes per collection (default: 64, range: 0-300)
documentdb.maxIndexesPerCollection = 64

# Maximum wildcard index key size (default: 200, range: 1+)
documentdb.maxWildcardIndexKeySize = 200

# Maximum schema validator size (default: 10240 bytes, range: 0-16777216)
documentdb.maxSchemaValidatorSize = 10240
```

### User & Role Settings

```ini
# Default SCRAM salt length (default: 28, range: 1-64)
documentdb.scramDefaultSaltLen = 28

# Maximum users allowed (default: 100, range: 1-500)
documentdb.maxUserLimit = 100

# List of blocked role prefixes (default: "")
documentdb.blockedRolePrefixList = ""

# Enable user CRUD (default: true)
documentdb.enableUserCrud = true
```

### Aggregation Settings

```ini
# T-Digest compression accuracy (default: 1500, range: 10-10000)
documentdb.tdigestCompressionAccuracy = 1500

# Maximum aggregation stages allowed (default: 1000, range: 1000-5000)
documentdb.aggregation_stages_limit = 1000
```

### Cursor Settings

```ini
# Default cursor first page batch size (default: 101, range: 1+)
documentdb.defaultCursorFirstPageBatchSize = 101

# Default cursor expiry time in seconds (default: 60, range: 1-3600)
documentdb.defaultCursorExpiryTimeLimitSeconds = 60

# Maximum cursor intermediate file size in MB (default: 4096, range: 1+)
documentdb.maxCursorIntermediateFileSizeMB = 4096

# Maximum cursor file count (default: 5000, range: 0+, 0 = unlimited)
documentdb.maxCursorFileCount = 5000
```

### Index & Query Settings

```ini
# Index term compression threshold (default: INT_MAX)
documentdb.index_term_compression_threshold = 2147483647

# Current operation application name to track (default: "" = track all)
documentdb.current_op_application_name = ""

# Maximum non-ordered term scan threshold (default: 500, range: -1+)
documentdb.max_non_ordered_term_scan_threshold = 500
```

### TTL & Read-Only Settings

```ini
# Enable TTL jobs on read-only (default: false)
documentdb.enableTTLJobsOnReadOnly = false
```

### Vector Settings

```ini
# Vector pre-filter iterative scan mode: off, relaxed_order, strict_order (default: relaxed_order)
documentdb.vectorPreFilterIterativeScanMode = relaxed_order

# Enable geonear force index pushdown (default: true)
documentdb.enable_force_push_geonear_index = true
```

### Explain & Diagnostics

```ini
# Enable extended explain plans (default: false)
documentdb.enableExtendedExplainPlans = false

# Enable per-statement backend timeout override (default: true)
documentdb.enableStatementTimeout = true

# Enable backend statement timeout (default: true)
documentdb.enableStatementTimeout = true
```

### Index Handler

```ini
# Alternate index handler name (default: "")
documentdb.alternate_index_handler_name = ""

# RUM library load option: none, prefer_documentdb_extended_rum, require_documentdb_extended_rum (default: require_documentdb_extended_rum on PG18+)
documentdb.rum_library_load_option = "prefer_documentdb_extended_rum"
```

### Deadlock Handling

```ini
# Throw deadlock on CRUD (default: false)
documentdb.throwDeadlockOnCRUD = false
```

---

## 4. TESTING CONFIGURATIONS (testing_configs.c)

### Collection & Index ID Testing

```ini
# Set next collection ID for testing (default: -1)
documentdb.next_collection_id = -1

# Set next collection index ID for testing (default: -1)
documentdb.next_collection_index_id = -1
```

### Recovery & Simulation Testing

```ini
# Simulate recovery state (default: false)
documentdb.simulateRecoveryState = false

# Enable generate non-exists term (default: true)
documentdb.enableGenerateNonExistsTerm = true

# Force wildcard reduced term (default: false)
documentdb.forceWildcardReducedTerm = false

# Force disable sequential scan (default: false)
documentdb.forceDisableSeqScan = false
```

### Index & Cursor Testing

```ini
# Index term truncation limit override (default: INT_MAX)
documentdb.indexTermLimitOverride = 2147483647

# Maximum worker cursor size (default: 16777216)
documentdb.maxWorkerCursorSize = 16777216

# Enable cursors on aggregation query rewrite (default: false)
documentdb.enableCursorsOnAggregationQueryRewrite = false

# Force index term truncation (default: false)
documentdb.forceIndexTermTruncation = false

# Force update index inline (default: false)
documentdb.forceUpdateIndexInline = false

# Force run diagnostic command inline (default: false)
documentdb.forceRunDiagnosticCommandInline = false

# Force index-only scan if available (default: false)
documentdb.forceIndexOnlyScanIfAvailable = false

# Force parallel scan if available (default: false)
documentdb.forceParallelScanIfAvailable = false

# Force bitmap scan for lookup (default: false)
documentdb.forceBitmapScanForLookup = false
```

### Shard Query Testing

```ini
# Use local execution for shard queries (default: true)
documentdb.useLocalExecutionShardQueries = true

# Force local execution for all shard queries (default: false)
documentdb.forceLocalExecutionShardQueries = false
```

### Unique Index Testing

```ini
# Default unique index keyhash override (default: 0)
documentdb.defaultUniqueIndexKeyhashOverride = 0
```

### Native Colocation

```ini
# Enable native colocation (default: true)
documentdb.enableNativeColocation = true
```

### Densify Testing

```ini
# Internal max allowed densify docs (default: 500000)
documentdb.test.internalQueryMaxAllowedDensifyDocs = 500000

# Internal densify max memory bytes (default: 16777216)
documentdb.test.internalDocumentSourceDensifyMaxMemoryBytes = 16777216
```

### Operation Tracking Testing

```ini
# Add SQL command to currentOp (default: false)
documentdb.currentOpAddSqlCommand = false

# Log relation indexes order (default: false)
documentdb.logRelationIndexesOrder = false

# Enable debug query text (default: false)
documentdb.enableDebugQueryText = false
```

### Advanced Index Testing

```ini
# Enable multi-index RUM join (default: false)
documentdb.enableMultiIndexRumJoin = false

# Enable large unique index keys (default: true)
documentdb.enable_large_unique_index_keys = true

# RUM fail on lost path (default: false)
documentdb.rumFailOnLostPath = false

# Force collStats data collection (default: false)
documentdb.forceCollStatsDataCollection = false

# Force group subquery elimination (default: false)
documentdb.forceGroupSubqueryElimination = false
```

### Schema & Compatibility Testing

```ini
# Enable RBAC compliant schemas (default: false)
documentdb.enableRbacCompliantSchemas = false

# Disable extended RUM explain plans (default: false)
documentdb.disableExtendedRumExplainPlans = false

# Enable data table without creation time (default: true)
documentdb.enableDataTableWithoutCreationTime = true
```

---

## Complete Example Configuration for Kubernetes Operator

```ini
# ==================== RECOMMENDED FOR PRODUCTION ====================

# === TTL Configuration ===
documentdb.maxTTLDeleteBatchSize = 500
documentdb.TTLPurgerStatementTimeout = 120000
documentdb.TTLTaskMaxRunTimeInMS = 90000
documentdb.enableTTLBatchObservability = true
documentdb.forceIndexScanForTTLTask = true

# === Index Building ===
documentdb.maxIndexBuildAttempts = 5
documentdb.indexBuildScheduleInSec = 3
documentdb.maxNumActiveUsersIndexBuilds = 3

# === Background Worker ===
documentdb.enableBackgroundWorker = true
documentdb.enableBackgroundWorkerJobs = true
documentdb.backgroundWorkerJobTimeoutThresholdSec = 600

# === Query Optimization ===
documentdb.forceUseIndexIfAvailable = true
documentdb.enableIdIndexPushdown = true

# === Vector Search (if used) ===
documentdb.enableVectorHNSWIndex = true
documentdb.enableVectorPreFilter = true
documentdb.enableVectorCompressionHalf = true
documentdb.enableVectorCompressionPQ = true

# === Write Batch ===
documentdb.maxWriteBatchSize = 25000
documentdb.batchWriteSubTransactionCount = 512

# === Cursor Settings ===
documentdb.defaultCursorFirstPageBatchSize = 101
documentdb.defaultCursorExpiryTimeLimitSeconds = 60
documentdb.maxCursorFileCount = 5000

# === Geospatial ===
documentdb.geo2dsphereSegmentMaxLength = 500

# === Aggregation ===
documentdb.aggregation_stages_limit = 1000

# === Observability ===
documentdb.enableExtendedExplainPlans = false
documentdb.enableStatementTimeout = true
```

---

## Notes for Kubernetes Operator Integration

1. **PGC_POSTMASTER** variables require PostgreSQL restart:
   - `documentdb.enableBackgroundWorker`
   - `documentdb.enableBackgroundWorkerInitJobs`
   - `documentdb.bg_worker_database_name`
   - `documentdb.bg_worker_latch_timeout`
   - `documentdb.enableRbacCompliantSchemas`
   - `documentdb.rum_library_load_option`

2. **PGC_USERSET** variables can be changed at runtime without restart (recommended for your operator).

3. Mount your ConfigMap with these settings to the PostgreSQL data directory.

4. Use environment variables in your bash script to make values dynamic based on operator inputs.

