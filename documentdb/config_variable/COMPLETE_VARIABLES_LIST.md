# Complete List of All DocumentDB Customizable Variables

## Table of Contents
1. [Background Job Configurations](#background-job-configurations)
2. [Feature Flags](#feature-flags)
3. [System Configurations](#system-configurations)
4. [Testing Configurations](#testing-configurations)

---

## Background Job Configurations

### 1. maxTTLDeleteBatchSize
- **Type**: Integer
- **Default Value**: 1000
- **Range**: 1 to INT_MAX (2,147,483,647)
- **Context**: PGC_USERSET (runtime changeable)
- **Use**: Controls the maximum number of delete operations permitted while deleting a batch of expired documents
- **Possible Values**: 
  - 100 - 500 (small batches, low system load)
  - 500 - 1000 (medium batches, balanced)
  - 1000 - 5000 (large batches, high throughput)
- **Impact**: Higher values = faster TTL processing but more system load

---

### 2. logTTLProgressActivity
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Whether to log activity done by TTL purger
- **Impact**: When true, generates detailed logs about TTL operations (turned off by default to reduce noise)

---

### 3. enableTTLBatchObservability
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Whether to calculate and emit TTL batch observability metrics
- **Impact**: When true, provides metrics about TTL batch operations for monitoring

---

### 4. forceIndexScanForTTLTask
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force Index Scan for TTL task by locally disabling Sequential Scan and Bitmap Index Scan
- **Impact**: When true, ensures TTL queries use indexes (better performance)

---

### 5. useIndexHintsForTTLTask
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force ordered Index Scan via Index Hints for TTL task
- **Impact**: When true, uses hints to enforce index usage for ordered scans

---

### 6. TTLPurgerStatementTimeout
- **Type**: Integer (milliseconds)
- **Default Value**: 60000 (1 minute)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Statement timeout for TTL purger delete query
- **Possible Values**:
  - 30000 (30 seconds) - short timeout
  - 60000 (1 minute) - default
  - 120000 (2 minutes) - extended timeout
  - 300000 (5 minutes) - very long timeout

---

### 7. TTLTaskMaxRunTimeInMS
- **Type**: Integer (milliseconds)
- **Default Value**: 60000 (1 minute)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Time budget assigned for single invocation of TTL task
- **Possible Values**:
  - 30000 (30 seconds)
  - 60000 (1 minute) - default
  - 90000 (1.5 minutes)
  - 120000 (2 minutes)

---

### 8. repeatPurgeIndexesForTTLTask
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Whether to keep deleting documents in batches until TTLTaskMaxRunTimeInMS is reached per TTL task invocation
- **Impact**: When true, maximizes use of time budget for deletions

---

### 9. TTLSkipCaughtUpIndexes
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Whether to skip checking TTL index further once they are caught up during TTL task invocation cycle
- **Impact**: When true, skips already-processed indexes (optimization)

---

### 10. skipRepeatDeleteForUnOrderedIndex
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Whether to skip repeat delete and use a larger batch size for non-ordered TTL indexes
- **Impact**: When true, uses optimization for unordered indexes

---

### 11. maxTTLBatchSizeUnorderedIndex
- **Type**: Integer
- **Default Value**: 10000
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum batch size for TTL deletes on non-ordered indexes
- **Possible Values**:
  - 5000 - small batches
  - 10000 - default (balanced)
  - 20000 - large batches

---

### 12. SingleTTLTaskTimeBudget
- **Type**: Integer (milliseconds)
- **Default Value**: 20000 (20 seconds)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Time budget for TTL task to purge one batch of documents from each eligible TTL indexes once
- **Possible Values**:
  - 10000 (10 seconds)
  - 20000 (20 seconds) - default
  - 30000 (30 seconds)
  - 60000 (1 minute)

---

### 13. TTLPurgerLockTimeout
- **Type**: Integer (milliseconds)
- **Default Value**: 10000 (10 seconds)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Lock timeout for TTL purger delete query
- **Possible Values**:
  - 5000 (5 seconds)
  - 10000 (10 seconds) - default
  - 30000 (30 seconds)

---

### 14. enableTTLDescSort
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Whether to enable TTL descending sort on field
- **Impact**: When true, uses descending order for sorting TTL field

---

### 15. maxNumActiveUsersIndexBuilds
- **Type**: Integer
- **Default Value**: 2
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum number of active users Index Builds that can run concurrently
- **Possible Values**:
  - 1 (serial index building)
  - 2 - 3 (default, balanced)
  - 4 - 8 (high concurrency)

---

### 16. maxIndexBuildAttempts
- **Type**: Integer
- **Default Value**: 3
- **Range**: 1 to 32767 (SHRT_MAX)
- **Context**: PGC_USERSET
- **Use**: Maximum number of attempts to build an index for a failed requests
- **Possible Values**:
  - 1 - 2 (few retries)
  - 3 - 5 (default, reasonable)
  - 5 - 10 (many retries for unstable systems)

---

### 17. indexBuildScheduleInSec
- **Type**: Integer (seconds)
- **Default Value**: 2
- **Range**: 1 to 60
- **Context**: PGC_USERSET
- **Use**: Index build cron-job schedule interval
- **Possible Values**:
  - 1 - very frequent builds
  - 2 - 5 (default, reasonable)
  - 10 - 30 (less frequent)
  - 60 (once per minute)

---

### 18. indexQueueEvictionIntervalInSec
- **Type**: Integer (seconds)
- **Default Value**: 1200 (20 minutes)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Interval for skippable build index requests to be evicted from queue
- **Possible Values**:
  - 300 (5 minutes)
  - 1200 (20 minutes) - default
  - 3600 (1 hour)

---

### 19. enableBackgroundWorker
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_POSTMASTER (requires restart)
- **Use**: Enable/disable the extension Background worker
- **Impact**: Controls whether background jobs can run

---

### 20. enableBackgroundWorkerJobs
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable/disable the execution of pre-defined background worker jobs
- **Impact**: Controls which jobs execute in the background

---

### 21. enableBackgroundWorkerInitJobs
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_POSTMASTER (requires restart)
- **Use**: Enable/disable the execution of initialization background jobs
- **Impact**: Added in v111, pending stabilization

---

### 22. backgroundWorkerJobTimeoutThresholdSec
- **Type**: Integer (seconds)
- **Default Value**: 300 (5 minutes)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum allowed value for background worker job timeout
- **Possible Values**:
  - 60 (1 minute)
  - 300 (5 minutes) - default
  - 600 (10 minutes)
  - 1800 (30 minutes)

---

### 23. bg_worker_database_name
- **Type**: String
- **Default Value**: "postgres"
- **Context**: PGC_POSTMASTER (requires restart, superuser only)
- **Use**: Database to which background worker will connect
- **Possible Values**: Any valid PostgreSQL database name (typically "postgres" or your app database)

---

### 24. bg_worker_latch_timeout
- **Type**: Integer (seconds)
- **Default Value**: 1
- **Range**: 0 to 200
- **Context**: PGC_POSTMASTER (requires restart, superuser only)
- **Use**: Latch timeout inside main thread of background worker leader
- **Possible Values**:
  - 0 - no timeout
  - 1 - 5 (short, responsive)
  - 10 - 30 (medium)
  - 100 - 200 (long)

---

## Feature Flags

### Vector Search Features

### 25. enableVectorHNSWIndex
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable support for HNSW index type and query for vector search in BSON documents
- **Added**: v108
- **Status**: Enabled by default, unknown stabilization time

---

### 26. enableVectorPreFilter
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable vector pre-filtering feature for vector search in BSON documents index
- **Added**: v108
- **Status**: Enabled by default

---

### 27. enableVectorPreFilterV2
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable vector pre-filtering v2 feature for vector search
- **Added**: v108
- **Status**: Pending stabilization

---

### 28. enable_force_push_vector_index
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force vector index queries to always be pushed to the vector index
- **Added**: v108

---

### 29. enableVectorCompressionHalf
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable vector index compression half (16-bit floating point)
- **Added**: v108
- **Status**: Enabled by default

---

### 30. enableVectorCompressionPQ
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable vector index compression product quantization
- **Added**: v108
- **Status**: Enabled by default

---

### 31. enableVectorCalculateDefaultSearchParam
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable automatic vector index default search parameter calculation
- **Added**: v108

---

### Schema Validation Features

### 32. enableSchemaValidation
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Support schema validation on documents
- **Added**: v108
- **Status**: Pending stabilization

---

### 33. enableBypassDocumentValidation
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Support 'bypassDocumentValidation' option in commands
- **Added**: v108
- **Status**: Pending stabilization

---

### Authentication & Authorization Features

### 34. enableUsernamePasswordConstraints
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable username and password constraints validation
- **Added**: v108
- **Status**: Enabled by default

---

### 35. enableUsersInfoPrivileges
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable usersInfo command to return privileges information
- **Added**: v108
- **Status**: Enabled by default

---

### 36. isNativeAuthEnabled
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable native authentication
- **Added**: v108
- **Status**: Enabled by default

---

### 37. enableRoleCrud
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable role CRUD operations through data plane
- **Added**: v108
- **Status**: Pending stabilization

---

### 38. enableUsersAdminDBCheck
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable database admin requirement for user CRUD operations
- **Added**: v109

---

### 39. enableRolesAdminDBCheck
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable database admin requirement for role CRUD operations
- **Added**: v109
- **Status**: Enabled by default

---

### Indexing Features

### 40. defaultUseCompositeOpClass
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use new ordered index opclass for default index creation
- **Added**: v107, enabled v108

---

### 41. enableCompositeIndexPlanner
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new ordered index opclass planner improvements
- **Added**: v109
- **Status**: Pending stabilization

---

### 42. enableOrderedCostEstimator
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new ordered cost estimator for composite indexes
- **Added**: v110
- **Status**: Enabled by default

---

### 43. enableIndexOnlyScan
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable index-only scans (queries satisfied by index without table access)
- **Added**: v107, enabled v108

---

### 44. enableIndexOnlyScanOnCost
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable index-only scans on cost function vs planner
- **Added**: v111
- **Status**: Enabled by default

---

### 45. enableIdIndexCustomCostFunction
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable custom cost function for ID index
- **Added**: v109

---

### 46. enableOrderByIdOnCostFunction
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable order by ID on cost function
- **Added**: v109
- **Status**: Pending stabilization

---

### 47. enableCompositeParallelIndexScan
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable parallel index scans for composite indexes
- **Added**: v109
- **Status**: Pending stabilization

---

### 48. enableValueOnlyIndexTerms
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable index terms that are value-only (no key information)
- **Added**: v109
- **Status**: Long-term flag, tracking older clusters

---

### 49. useNewUniqueHashEqualityFunction
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use new unique hash equality implementation
- **Added**: v109

---

### 50. enableCompositeUniqueHash
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable composite index unique hash equality
- **Added**: v109

---

### 51. enableRumNewCompositeTermGeneration
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new term generation for RUM composite terms
- **Added**: v109

---

### 52. enableCompositeWildcardIndex
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable composite wildcard index support
- **Added**: v109

---

### 53. createTTLIndexAsCompositeByDefault
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Always create TTL indexes as composite indexes by default
- **Added**: v110

---

### 54. enableCompositeReducedCorrelatedTerms
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable reduced term generation for correlated composite paths
- **Added**: v109
- **Status**: Pending stabilization

---

### 55. enableUniqueCompositeReducedCorrelatedTerms
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable reduced terms for correlated composite paths on unique indexes
- **Added**: v109
- **Status**: Pending stabilization

---

### 56. enableCompositeReducedCorrelatedTermsOnCommonSubPath
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable reduced term generation on common sub-paths
- **Added**: v111

---

### 57. enableCompositeShardDocumentTerms
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable shard hash term generation for composite indexes
- **Added**: v109

---

### 58. enableCompositeWildcardSkipEmptyEntries
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Skip empty entries for composite wildcard indexes
- **Added**: v110

---

### 59. enableOrderedCompositeOperatorScan
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use single ordered scalar array operator scan for ordered indexes
- **Added**: v111

---

### 60. enableRegexPrefixIndexBounds
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable optimized regex prefix index bounds
- **Added**: v111

---

### 61. enableExtendedIndexes
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable extended indexes feature
- **Added**: v111
- **Status**: Pending stabilization

---

### 62. enableComparableTerms
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable comparable terms feature
- **Added**: v111
- **Status**: Pending stabilization

---

### 63. enableOrderByIndexTerm
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable order by index term feature
- **Added**: v111
- **Status**: Pending stabilization

---

### 64. enablePerCollectionPlannerStatistics
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable per-collection planner statistics
- **Added**: v111
- **Status**: Pending stabilization

---

### Planner Features

### 65. lowSelectivityForLookup
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use low selectivity for lookup operations
- **Added**: v108
- **Status**: Enabled by default

---

### 66. enableExprLookupIndexPushdown
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable expression and lookup pushdown to index
- **Added**: v109

---

### 67. unifyPfeOnIndexInfo
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Unify partial filter expressions on index expressions
- **Added**: v109

---

### 68. enableNewCountAggregates
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new count aggregate optimizations
- **Added**: v108

---

### 69. enableExtendedExplainOnAnalyzeOff
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable extended explain on EXPLAIN with ANALYZE off
- **Added**: v110

---

### 70. enableExplainScanIndexCosts
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Include index costs in explain output for index scans
- **Added**: v110

---

### 71. enableExplainScanNamespaceName
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Include namespace name in explain output for index scans
- **Added**: v110

---

### 72. enableNewMinMaxAccumulators
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new min and max aggregate optimizations
- **Added**: v110
- **Status**: Pending stabilization (superseded by enableNewWithExprAccumulators in v111)

---

### 73. enableNewWithExprAccumulators
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new WithExpr aggregate optimizations for min, max, sum, avg, first, last
- **Added**: v111
- **Status**: Pending stabilization

---

### 74. enableCursorPlanBeforeRestrictionPathUpdate
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable running streaming cursor plan rewrite before path replacement
- **Added**: v111

---

### Query & Aggregation Features

### 75. enablePrimaryKeyCursorScan
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable primary key cursor scan for streaming cursors
- **Added**: v109
- **Status**: Pending stabilization

---

### 76. enableContinuationFastBitmapLookup
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable skipping bitmap records without loading heap to find continuation
- **Added**: v110
- **Status**: Pending stabilization

---

### 77. useFileBasedPersistedCursors
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use file-based persisted cursors instead of in-memory
- **Added**: v108
- **Status**: Pending stabilization

---

### 78. failOnGroupIdDuplicate
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Fail when $group stage has duplicate _id
- **Added**: v111
- **Status**: Pending stabilization

---

### 79. enableConversionStreamableToSingleBatch
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable conversion of streamable queries to single batch
- **Added**: v109

---

### 80. enableFindProjectionAfterOffset
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable pushing projection as subquery after offset
- **Added**: v109

---

### 81. enableDelayedHoldPortal
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Delay holding portal until more data available to fetch
- **Added**: v108

---

### 82. enableIdIndexPushdown
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable extended _id index pushdown optimizations
- **Added**: v108

---

### 83. enableDollarInToScalarArrayOpExprConversion
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable conversion of $in with scalar array to OpExpr
- **Added**: v110

---

### 84. enableUseForeignKeyLookupInline
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use foreign key for lookup inline method
- **Added**: v111

---

### 85. enableAddToSetAggregationRewrite
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable new addToSet aggregation implementation
- **Added**: v110

---

### 86. enableIdIndexPushdownForQueryOp
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable _id index pushdown for query operators
- **Added**: v109

---

### 87. enableBinarySearchForOrderedMove
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable binary search for ordered move operations
- **Added**: v110

---

### 88. inlineChangeStreamMatchStage
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Inline $match aggregation stage with $changestreams
- **Added**: v110

---

### 89. removeMatchNamespaceFilters
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Remove $match filters on namespace when inlined with $changestreams
- **Added**: v110

---

### 90. multipleDollarPositionalNotAllowed
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Throw error when multiple $ positional operators in same path
- **Added**: v111

---

### 91. enableGroupSubqueryElimination
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Eliminate subquery migration in $group by inlining
- **Added**: v112

---

### 92. failOnNonEmptyGroupCountArg
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Fail when $count in $group has non-empty arguments
- **Added**: v111
- **Status**: Pending stabilization

---

### 93. enableSortGroupStage
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable the $sortGroup stage
- **Added**: v112

---

### Let Support Features

### 94. EnableOperatorVariablesInLookup
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable operator variables ($map.as alias) in let variable specifications
- **Added**: v109
- **Status**: Pending stabilization

---

### Collation Features

### 95. skipFailOnCollation
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Skip failing when collation specified but not supported
- **Added**: v108
- **Status**: Pending stabilization

---

### 96. enableLookupIdJoinOptimizationOnCollation
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable _id join optimization on collation
- **Added**: v109
- **Status**: Pending stabilization

---

### 97. enableCollationWithNonUniqueOrderedIndexes
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable collation for non-unique ordered indexes
- **Added**: v110
- **Status**: Pending stabilization

---

### 98. enableCollationWithNewGroupAccumulators
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable collation with new group accumulators
- **Added**: v110
- **Status**: Pending stabilization

---

### DML & Write Path Features

### 99. enableUpdateBsonDocument
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable the update_bson_document command
- **Added**: v109

---

### Cluster Administration & DDL Features

### 100. recreate_retry_table_on_shard
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Recreate retry table to match main table during sharding
- **Added**: v108
- **Status**: Pending stabilization

---

### 101. enableSchemaEnforcementForCSFLE
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable schema enforcement for CSFLE
- **Added**: v108
- **Status**: Enabled by default

---

### 102. usePgStatsLiveTuplesForCount
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use pg_stat_all_tables live tuples for count in collStats
- **Added**: v108

---

### 103. enablePrepareUnique
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable prepareUnique for collection modification
- **Added**: v109
- **Status**: Pending stabilization

---

### 104. enableCollModUnique
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable unique constraints in collection modification
- **Added**: v109
- **Status**: Pending stabilization

---

### 105. enableDropInvalidIndexesOnReadOnly
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Drop invalid indexes when database is read-only
- **Added**: v110

---

### 106. enableOnlyCollectionCacheInvalidateOnCollectionChanges
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Only invalidate collection cache (not entire database) on changes
- **Added**: v112

---

### 107. enableStreamingCursorDrainViaDestReceiver
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Use direct executor DestReceiver for streaming cursor drainage
- **Added**: v112

---

### Background Job Scheduling

### 108. indexBuildsScheduledOnBgWorker
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Schedule index builds via background worker jobs
- **Added**: v109
- **Status**: Pending stabilization

---

## System Configurations

### 109. localhost_connection_string
- **Type**: String
- **Default Value**: "host=localhost"
- **Context**: PGC_SUSET (superuser only)
- **Use**: Hostname and connection parameters when connecting back to itself
- **Possible Values**: Any valid connection string (e.g., "host=127.0.0.1", "host=localhost port=5433")

---

### 110. enable_create_collection_on_insert
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Automatically create collection when inserting into non-existent collection
- **Impact**: When true, insert operations create missing collections

---

### 111. enableDbNameValidation
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enforce that $db in command body matches database argument
- **Impact**: Validation security check

---

### 112. query_plan_cache_size
- **Type**: Integer
- **Default Value**: 100
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Size of the query plan cache
- **Possible Values**:
  - 50 - small cache
  - 100 - default
  - 200 - 500 - large cache

---

### 113. maxWriteBatchSize
- **Type**: Integer
- **Default Value**: 25000
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum number of write operations permitted in a write batch
- **Possible Values**:
  - 1000 - small batches
  - 10000 - medium
  - 25000 - default
  - 50000 - large batches

---

### 114. forceUseIndexIfAvailable
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force query planner to push to RUM index if applicable
- **Impact**: When true, uses index-based execution when possible

---

### 115. coll_stats_count_policy_threshold
- **Type**: Integer
- **Default Value**: 10000
- **Range**: 1 to (INT_MAX - 1)
- **Context**: PGC_USERSET
- **Use**: Document count threshold to change collStats policy
- **Possible Values**:
  - 5000 - switch earlier
  - 10000 - default
  - 50000 - switch later

---

### 116. batchWriteSubTransactionCount
- **Type**: Integer
- **Default Value**: 512
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Size of each sub-transaction within write commands
- **Possible Values**:
  - 100 - many small transactions
  - 512 - default (balanced with Mongo spark client)
  - 1000 - fewer larger transactions

---

### 117. IsPgReadOnlyForDiskFull
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Indicates if PostgreSQL is in read-only due to full disk
- **Impact**: System-set flag, typically not user-modified

---

### 118. geo2dsphereSegmentMaxLength
- **Type**: Real/Double (kilometers)
- **Default Value**: 500.0
- **Range**: 0.0 to 6372.0 (Earth radius)
- **Context**: PGC_USERSET
- **Use**: Maximum segment length for geospatial spherical queries
- **Possible Values**:
  - 0 - disable segmentation
  - 100 - 200 - short segments
  - 500 - default
  - 1000 - 2000 - long segments

---

### 119. geo2dsphereSegmentMaxVertices
- **Type**: Integer
- **Default Value**: 8
- **Range**: 0 to 32
- **Context**: PGC_USERSET
- **Use**: Maximum segment vertices for geospatial spherical queries
- **Possible Values**:
  - 4 - 6 - few vertices
  - 8 - default
  - 16 - 32 - many vertices

---

### 120. maxIndexesPerCollection
- **Type**: Integer
- **Default Value**: 64
- **Range**: 0 to 300
- **Context**: PGC_USERSET
- **Use**: Maximum allowed indexes for a given collection
- **Possible Values**:
  - 32 - conservative limit
  - 64 - default
  - 128 - 256 - generous limit

---

### 121. maxWildcardIndexKeySize
- **Type**: Integer
- **Default Value**: 200
- **Range**: 1 to INT32_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum wildcard index key size
- **Possible Values**:
  - 100 - small keys
  - 200 - default
  - 500 - large keys

---

### 122. maxSchemaValidatorSize
- **Type**: Integer (bytes)
- **Default Value**: 10240 (10 KB)
- **Range**: 0 to 16777216 (16 MB)
- **Context**: PGC_USERSET
- **Use**: Maximum size of schema validator
- **Possible Values**:
  - 5120 (5 KB)
  - 10240 (10 KB) - default
  - 51200 (50 KB)
  - 102400 (100 KB)

---

### 123. sharding_max_chunks
- **Type**: Integer
- **Default Value**: 128
- **Range**: 1 to 8192
- **Context**: PGC_USERSET
- **Use**: Maximum allowed chunks for shard collection operation
- **Possible Values**:
  - 64 - few chunks
  - 128 - default
  - 256 - 1024 - many chunks

---

### 124. scramDefaultSaltLen
- **Type**: Integer
- **Default Value**: 28
- **Range**: 1 to 64
- **Context**: PGC_SUSET (superuser only)
- **Use**: Default SCRAM salt length for authentication
- **Possible Values**:
  - 16 - short salt
  - 28 - default
  - 64 - maximum salt

---

### 125. throwDeadlockOnCRUD
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Throw deadlock as exception vs catching and writing to operation result
- **Impact**: Controls deadlock handling behavior

---

### 126. maxUserLimit
- **Type**: Integer
- **Default Value**: 100
- **Range**: 1 to 500
- **Context**: PGC_SUSET (superuser only)
- **Use**: Maximum number of users allowed
- **Possible Values**:
  - 50 - conservative
  - 100 - default
  - 250 - 500 - large installations

---

### 127. maxCustomCommandTimeoutLimit
- **Type**: Integer (milliseconds)
- **Default Value**: 10800000 (3 hours)
- **Range**: 0 to INT_MAX
- **Context**: PGC_SUSET (superuser only)
- **Use**: Maximum allowed custom command timeout limit
- **Possible Values**:
  - 3600000 (1 hour)
  - 10800000 (3 hours) - default
  - 86400000 (24 hours)

---

### 128. tdigestCompressionAccuracy
- **Type**: Integer
- **Default Value**: 1500
- **Range**: 10 to 10000
- **Context**: PGC_USERSET
- **Use**: Accuracy parameter of t-digest compression
- **Possible Values**:
  - 100 - 500 - less accurate, low memory
  - 1500 - default (balanced)
  - 5000 - 10000 - very accurate, high memory

---

### 129. blockedRolePrefixList
- **Type**: String (comma-separated)
- **Default Value**: "" (empty)
- **Context**: PGC_USERSET
- **Use**: List of role prefixes blocked from being created/deleted
- **Possible Values**:
  - "pg_" - block postgres system roles
  - "admin_,system_" - block multiple prefixes
  - Empty string - no blocked roles

---

### 130. current_op_application_name
- **Type**: String
- **Default Value**: "" (empty = track all)
- **Context**: PGC_USERSET
- **Use**: Application name to track for current_op command
- **Possible Values**:
  - "" - track all applications
  - "myapp" - track specific app
  - "app1,app2" - multiple apps

---

### 131. aggregation_stages_limit
- **Type**: Integer
- **Default Value**: 1000
- **Range**: 1000 to 5000
- **Context**: PGC_USERSET
- **Use**: Maximum number of aggregation stages allowed in pipeline
- **Possible Values**:
  - 1000 - default minimum
  - 2500 - middle
  - 5000 - maximum

---

### 132. index_term_compression_threshold
- **Type**: Integer (bytes)
- **Default Value**: INT_MAX (disabled)
- **Range**: 128 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Size above which index terms will be compressed
- **Possible Values**:
  - 128 - compress small terms
  - 1024 - 4096 - moderate compression
  - INT_MAX - disable compression

---

### 133. enableUserCrud
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable user CRUD operations through data plane
- **Impact**: When true, allows user creation/deletion via API

---

### 134. enableTTLJobsOnReadOnly
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable TTL jobs on read-only nodes
- **Impact**: When true, TTL jobs override read-only mode temporarily

---

### 135. enable_force_push_geonear_index
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force geonear queries to always be pushed to geospatial index
- **Impact**: Query optimization flag

---

### 136. vectorPreFilterIterativeScanMode
- **Type**: Enum
- **Default Value**: "relaxed_order"
- **Possible Values**:
  - "off" - disable iterative scan
  - "relaxed_order" - slightly out of order, better recall
  - "strict_order" - exact order by distance
- **Context**: PGC_USERSET
- **Use**: Iterative scan mode for vector pre-filtering

---

### 137. defaultCursorFirstPageBatchSize
- **Type**: Integer
- **Default Value**: 101
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Default batch size for first page of cursor
- **Possible Values**:
  - 10 - 50 - small batches
  - 101 - default
  - 500 - 1000 - large batches

---

### 138. enableExtendedExplainPlans
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable extended explain plans with additional information
- **Impact**: When true, adds details to EXPLAIN output

---

### 139. defaultCursorExpiryTimeLimitSeconds
- **Type**: Integer (seconds)
- **Default Value**: 60
- **Range**: 1 to 3600
- **Context**: PGC_USERSET
- **Use**: Default expiry time limit for cursor
- **Possible Values**:
  - 30 - 1 minute
  - 60 - default
  - 300 - 5 minutes
  - 3600 - 1 hour

---

### 140. maxCursorIntermediateFileSizeMB
- **Type**: Integer (megabytes)
- **Default Value**: 4096 (4 GB)
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum size of intermediate file for cursor
- **Possible Values**:
  - 512 - small files
  - 4096 - default
  - 10240 - 102400 - large files

---

### 141. maxCursorFileCount
- **Type**: Integer
- **Default Value**: 5000
- **Range**: 0 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum number of cursor files allowed (0 = unlimited)
- **Possible Values**:
  - 0 - unlimited
  - 1000 - 5000 - normal
  - 10000+ - very high

---

### 142. rum_library_load_option
- **Type**: Enum
- **Default Value**: "require_documentdb_extended_rum" (PG18+), "none" (older)
- **Possible Values**:
  - "none" - don't load RUM
  - "prefer_documentdb_extended_rum" - prefer extended version
  - "require_documentdb_extended_rum" - must use extended version
- **Context**: PGC_POSTMASTER (requires restart)
- **Use**: Specifies RUM library load option

---

### 143. enableStatementTimeout
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable per-statement backend timeout override
- **Impact**: When true, allows statement-level timeouts

---

### 144. alternate_index_handler_name
- **Type**: String
- **Default Value**: "" (use RUM)
- **Context**: PGC_USERSET
- **Use**: Index handler to use instead of RUM
- **Possible Values**:
  - "" - use default RUM
  - "btree" - use B-tree index
  - Custom index handler name

---

### 145. max_non_ordered_term_scan_threshold
- **Type**: Integer
- **Default Value**: 500
- **Range**: -1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum threshold for non-ordered term scans
- **Possible Values**:
  - -1 - unlimited
  - 100 - 500 - normal
  - 1000 - high threshold

---

## Testing Configurations

### 146. next_collection_id
- **Type**: Integer
- **Default Value**: -1 (UNSET)
- **Range**: -1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Set next collection ID for consistent testing
- **Possible Values**: Any integer (primarily for parallel testing)

---

### 147. next_collection_index_id
- **Type**: Integer
- **Default Value**: -1 (UNSET)
- **Range**: -1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Set next collection index ID for consistent testing
- **Possible Values**: Any integer

---

### 148. simulateRecoveryState
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Simulate database recovery state and throw error for read-write ops
- **Impact**: Testing/debugging only

---

### 149. enableGenerateNonExistsTerm
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable generating non-exists term for new documents
- **Impact**: Testing index behavior

---

### 150. indexTermLimitOverride
- **Type**: Integer
- **Default Value**: INT_MAX
- **Range**: 1 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Override for index term truncation limit (testing)
- **Impact**: Testing only

---

### 151. enableCursorsOnAggregationQueryRewrite
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Add cursors on aggregation style queries
- **Impact**: Testing cursor behavior

---

### 152. defaultUniqueIndexKeyhashOverride
- **Type**: Integer
- **Default Value**: 0 (disabled)
- **Range**: 0 to INT_MAX
- **Context**: PGC_USERSET
- **Use**: Force single keyhash result for testing hash conflicts
- **Impact**: Testing only, do not use in production

---

### 153. useLocalExecutionShardQueries
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Push local shard queries directly to shard
- **Impact**: Query execution optimization

---

### 154. forceLocalExecutionShardQueries
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force all shard queries to execute locally on shard
- **Impact**: Testing/forcing execution paths

---

### 155. forceIndexTermTruncation
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force index term truncation feature
- **Impact**: Testing feature

---

### 156. maxWorkerCursorSize
- **Type**: Integer (bytes)
- **Default Value**: 16777216 (16 MB)
- **Range**: 1 to 16777216
- **Context**: PGC_USERSET
- **Use**: Maximum size of single cursor response page in worker
- **Possible Values**:
  - 1048576 (1 MB)
  - 16777216 (16 MB) - default
  - 33554432 (32 MB) - testing large

---

### 157. enableNativeColocation
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Turn on colocation of tables in collection database
- **Impact**: Table organization optimization

---

### 158. test.internalQueryMaxAllowedDensifyDocs
- **Type**: Integer
- **Default Value**: 500000
- **Range**: 0 to INT32_MAX
- **Context**: PGC_USERSET
- **Use**: Maximum documents that can be generated using $densify
- **Possible Values**:
  - 100000 - conservative
  - 500000 - default
  - 1000000 - permissive

---

### 159. test.internalDocumentSourceDensifyMaxMemoryBytes
- **Type**: Integer (bytes)
- **Default Value**: 16777216 (16 MB)
- **Range**: 0 to 16777216
- **Context**: PGC_USERSET
- **Use**: Maximum memory for generated documents in $densify
- **Possible Values**:
  - 1048576 (1 MB)
  - 16777216 (16 MB) - default

---

### 160. forceDisableSeqScan
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force disable sequential scans on collection
- **Impact**: Force index usage

---

### 161. currentOpAddSqlCommand
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Add SQL command to current operation view
- **Impact**: Debugging/observability

---

### 162. logRelationIndexesOrder
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Log the order of indexes in relation
- **Impact**: Debugging only

---

### 163. enable_large_unique_index_keys
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable large index keys on unique indexes
- **Impact**: Key size handling

---

### 164. enableDebugQueryText
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Enable query source text while planning (debugging)
- **Impact**: Degrades performance, debugging only

---

### 165. enableMultiIndexRumJoin
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Add cursors on aggregation queries with multi-index
- **Impact**: Testing multi-index behavior

---

### 166. forceUpdateIndexInline
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force update index inline vs worker route
- **Impact**: Testing execution paths

---

### 167. forceRunDiagnosticCommandInline
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force diagnostic commands to run inline
- **Impact**: Testing only

---

### 168. forceIndexOnlyScanIfAvailable
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force index-only scan if available in plan
- **Impact**: Testing execution paths

---

### 169. forceParallelScanIfAvailable
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force parallel scan if available in plan
- **Impact**: Testing parallel execution

---

### 170. enableRbacCompliantSchemas
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_POSTMASTER (requires restart)
- **Use**: Enable RBAC-compliant schemas
- **Impact**: Schema permission model

---

### 171. disableExtendedRumExplainPlans
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Disable extended RUM explain plan overrides
- **Impact**: Explain output formatting

---

### 172. enableDataTableWithoutCreationTime
- **Type**: Boolean
- **Default Value**: true
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Create data table without creation_time column
- **Impact**: Schema compatibility testing

---

### 173. rumFailOnLostPath
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Fail query when lost path detected in RUM
- **Impact**: Testing error handling

---

### 174. forceCollStatsDataCollection
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force fetching metadata during collstats operations
- **Impact**: Testing metadata behavior

---

### 175. forceBitmapScanForLookup
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force bitmap scan for lookup
- **Impact**: Testing scan types

---

### 176. forceGroupSubqueryElimination
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force subquery elimination in $group (testing only)
- **Impact**: Testing aggregation optimization

---

### 177. forceWildcardReducedTerm
- **Type**: Boolean
- **Default Value**: false
- **Possible Values**: true, false
- **Context**: PGC_USERSET
- **Use**: Force wildcard reduced term generation
- **Impact**: Testing wildcard index feature

---

## Summary Statistics

| Metric | Count |
|--------|-------|
| Total Variables | 177+ |
| Integer Variables | ~60 |
| Boolean Variables | ~110 |
| String Variables | ~5 |
| Enum Variables | ~2 |
| Real/Double Variables | ~1 |
| Runtime Changeable (PGC_USERSET) | ~170 |
| Requires Restart (PGC_POSTMASTER) | 6 |
| Superuser Only (PGC_SUSET) | ~5 |

---

## Usage Examples

### Example 1: Set TTL Configuration
```ini
documentdb.maxTTLDeleteBatchSize = 500
documentdb.TTLPurgerStatementTimeout = 120000
documentdb.TTLTaskMaxRunTimeInMS = 90000
```

### Example 2: Performance Tuning
```ini
documentdb.forceUseIndexIfAvailable = true
documentdb.maxWriteBatchSize = 25000
documentdb.maxNumActiveUsersIndexBuilds = 3
```

### Example 3: Vector Search
```ini
documentdb.enableVectorHNSWIndex = true
documentdb.enableVectorPreFilter = true
documentdb.enableVectorCompressionHalf = true
```

### Example 4: Query Optimization
```ini
documentdb.enableIdIndexPushdown = true
documentdb.enableIndexOnlyScan = true
documentdb.lowSelectivityForLookup = true
```

---

## Notes

- Most variables are **PGC_USERSET** and can be changed without restarting PostgreSQL
- Only **6 variables** require restart (PGC_POSTMASTER)
- Ranges and defaults are based on source code analysis
- Some variables are marked as "Pending stabilization" and may change in future versions
- Testing variables should not be used in production

