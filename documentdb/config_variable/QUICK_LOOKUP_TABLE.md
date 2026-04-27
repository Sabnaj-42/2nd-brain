# Quick Lookup Table - All Customizable Variables

## All 177+ Variables in Quick Reference Format

| # | Variable Name | Type | Default | Range | Context | Use |
|----|---------------|------|---------|-------|---------|-----|
| 1 | maxTTLDeleteBatchSize | int | 1000 | 1 to INT_MAX | USERSET | TTL batch size for deletions |
| 2 | logTTLProgressActivity | bool | false | true/false | USERSET | Log TTL purger activity |
| 3 | enableTTLBatchObservability | bool | true | true/false | USERSET | Emit TTL metrics |
| 4 | forceIndexScanForTTLTask | bool | true | true/false | USERSET | Force index scans for TTL |
| 5 | useIndexHintsForTTLTask | bool | true | true/false | USERSET | Use index hints for TTL |
| 6 | TTLPurgerStatementTimeout | int | 60000 | 1 to INT_MAX | USERSET | TTL query timeout (ms) |
| 7 | TTLTaskMaxRunTimeInMS | int | 60000 | 1 to INT_MAX | USERSET | TTL task time budget (ms) |
| 8 | repeatPurgeIndexesForTTLTask | bool | true | true/false | USERSET | Repeat deletes until budget |
| 9 | TTLSkipCaughtUpIndexes | bool | true | true/false | USERSET | Skip caught-up indexes |
| 10 | skipRepeatDeleteForUnOrderedIndex | bool | true | true/false | USERSET | Skip repeat for unordered |
| 11 | maxTTLBatchSizeUnorderedIndex | int | 10000 | 1 to INT_MAX | USERSET | Max batch for unordered TTL |
| 12 | SingleTTLTaskTimeBudget | int | 20000 | 1 to INT_MAX | USERSET | Time per TTL batch (ms) |
| 13 | TTLPurgerLockTimeout | int | 10000 | 1 to INT_MAX | USERSET | Lock timeout for TTL (ms) |
| 14 | enableTTLDescSort | bool | false | true/false | USERSET | Enable TTL desc sort |
| 15 | maxNumActiveUsersIndexBuilds | int | 2 | 1 to INT_MAX | USERSET | Concurrent index builds |
| 16 | maxIndexBuildAttempts | int | 3 | 1 to 32767 | USERSET | Retry attempts for builds |
| 17 | indexBuildScheduleInSec | int | 2 | 1 to 60 | USERSET | Index build schedule (sec) |
| 18 | indexQueueEvictionIntervalInSec | int | 1200 | 1 to INT_MAX | USERSET | Build queue eviction (sec) |
| 19 | enableBackgroundWorker | bool | true | true/false | POSTMASTER | Enable background worker |
| 20 | enableBackgroundWorkerJobs | bool | true | true/false | USERSET | Enable background jobs |
| 21 | enableBackgroundWorkerInitJobs | bool | false | true/false | POSTMASTER | Enable init jobs |
| 22 | backgroundWorkerJobTimeoutThresholdSec | int | 300 | 1 to INT_MAX | USERSET | Job timeout threshold (sec) |
| 23 | bg_worker_database_name | str | "postgres" | any db name | POSTMASTER | Background worker database |
| 24 | bg_worker_latch_timeout | int | 1 | 0 to 200 | POSTMASTER | Latch timeout (sec) |
| 25 | enableVectorHNSWIndex | bool | true | true/false | USERSET | Enable HNSW vector index |
| 26 | enableVectorPreFilter | bool | true | true/false | USERSET | Enable vector pre-filter |
| 27 | enableVectorPreFilterV2 | bool | false | true/false | USERSET | Enable v2 pre-filter |
| 28 | enable_force_push_vector_index | bool | false | true/false | USERSET | Force vector index push |
| 29 | enableVectorCompressionHalf | bool | true | true/false | USERSET | Half compression |
| 30 | enableVectorCompressionPQ | bool | true | true/false | USERSET | Product quantization compression |
| 31 | enableVectorCalculateDefaultSearchParam | bool | true | true/false | USERSET | Auto search param calc |
| 32 | enableSchemaValidation | bool | false | true/false | USERSET | Enable schema validation |
| 33 | enableBypassDocumentValidation | bool | false | true/false | USERSET | Allow bypass validation |
| 34 | enableUsernamePasswordConstraints | bool | true | true/false | USERSET | Enable auth constraints |
| 35 | enableUsersInfoPrivileges | bool | true | true/false | USERSET | Return privileges in usersInfo |
| 36 | isNativeAuthEnabled | bool | true | true/false | USERSET | Enable native auth |
| 37 | enableRoleCrud | bool | false | true/false | USERSET | Enable role CRUD |
| 38 | enableUsersAdminDBCheck | bool | false | true/false | USERSET | Check admin for users |
| 39 | enableRolesAdminDBCheck | bool | true | true/false | USERSET | Check admin for roles |
| 40 | defaultUseCompositeOpClass | bool | true | true/false | USERSET | Use composite opclass |
| 41 | enableCompositeIndexPlanner | bool | false | true/false | USERSET | Composite planner |
| 42 | enableOrderedCostEstimator | bool | true | true/false | USERSET | Ordered cost estimator |
| 43 | enableIndexOnlyScan | bool | true | true/false | USERSET | Index-only scans |
| 44 | enableIndexOnlyScanOnCost | bool | true | true/false | USERSET | Index-only on cost |
| 45 | enableIdIndexCustomCostFunction | bool | true | true/false | USERSET | ID index cost function |
| 46 | enableOrderByIdOnCostFunction | bool | false | true/false | USERSET | Order by ID cost |
| 47 | enableCompositeParallelIndexScan | bool | false | true/false | USERSET | Parallel composite scan |
| 48 | enableValueOnlyIndexTerms | bool | true | true/false | USERSET | Value-only terms |
| 49 | useNewUniqueHashEqualityFunction | bool | true | true/false | USERSET | New unique hash |
| 50 | enableCompositeUniqueHash | bool | true | true/false | USERSET | Composite unique hash |
| 51 | enableRumNewCompositeTermGeneration | bool | true | true/false | USERSET | RUM term generation |
| 52 | enableCompositeWildcardIndex | bool | true | true/false | USERSET | Composite wildcard |
| 53 | createTTLIndexAsCompositeByDefault | bool | true | true/false | USERSET | TTL as composite |
| 54 | enableCompositeReducedCorrelatedTerms | bool | false | true/false | USERSET | Reduced correlated terms |
| 55 | enableUniqueCompositeReducedCorrelatedTerms | bool | false | true/false | USERSET | Unique reduced terms |
| 56 | enableCompositeReducedCorrelatedTermsOnCommonSubPath | bool | true | true/false | USERSET | Common subpath reduction |
| 57 | enableCompositeShardDocumentTerms | bool | true | true/false | USERSET | Shard document terms |
| 58 | enableCompositeWildcardSkipEmptyEntries | bool | true | true/false | USERSET | Skip empty entries |
| 59 | enableOrderedCompositeOperatorScan | bool | true | true/false | USERSET | Ordered operator scan |
| 60 | enableRegexPrefixIndexBounds | bool | true | true/false | USERSET | Regex prefix bounds |
| 61 | enableExtendedIndexes | bool | false | true/false | USERSET | Extended indexes |
| 62 | enableComparableTerms | bool | false | true/false | USERSET | Comparable terms |
| 63 | enableOrderByIndexTerm | bool | false | true/false | USERSET | Order by index term |
| 64 | enablePerCollectionPlannerStatistics | bool | false | true/false | USERSET | Per-collection stats |
| 65 | lowSelectivityForLookup | bool | true | true/false | USERSET | Low selectivity lookup |
| 66 | enableExprLookupIndexPushdown | bool | true | true/false | USERSET | Expr lookup pushdown |
| 67 | unifyPfeOnIndexInfo | bool | true | true/false | USERSET | Unify PFE on index |
| 68 | enableNewCountAggregates | bool | true | true/false | USERSET | New count aggregates |
| 69 | enableExtendedExplainOnAnalyzeOff | bool | true | true/false | USERSET | Extended explain |
| 70 | enableExplainScanIndexCosts | bool | true | true/false | USERSET | Explain index costs |
| 71 | enableExplainScanNamespaceName | bool | true | true/false | USERSET | Explain namespace |
| 72 | enableNewMinMaxAccumulators | bool | false | true/false | USERSET | New min/max |
| 73 | enableNewWithExprAccumulators | bool | false | true/false | USERSET | New WithExpr |
| 74 | enableCursorPlanBeforeRestrictionPathUpdate | bool | true | true/false | USERSET | Cursor plan order |
| 75 | enablePrimaryKeyCursorScan | bool | false | true/false | USERSET | Primary key scan |
| 76 | enableContinuationFastBitmapLookup | bool | false | true/false | USERSET | Fast bitmap lookup |
| 77 | useFileBasedPersistedCursors | bool | false | true/false | USERSET | File-based cursors |
| 78 | failOnGroupIdDuplicate | bool | false | true/false | USERSET | Fail on group duplicate |
| 79 | enableConversionStreamableToSingleBatch | bool | true | true/false | USERSET | Streamable conversion |
| 80 | enableFindProjectionAfterOffset | bool | true | true/false | USERSET | Projection after offset |
| 81 | enableDelayedHoldPortal | bool | true | true/false | USERSET | Delayed portal hold |
| 82 | enableIdIndexPushdown | bool | true | true/false | USERSET | ID index pushdown |
| 83 | enableDollarInToScalarArrayOpExprConversion | bool | true | true/false | USERSET | $in conversion |
| 84 | enableUseForeignKeyLookupInline | bool | true | true/false | USERSET | Foreign key inline |
| 85 | enableAddToSetAggregationRewrite | bool | true | true/false | USERSET | AddToSet rewrite |
| 86 | enableIdIndexPushdownForQueryOp | bool | true | true/false | USERSET | ID query pushdown |
| 87 | enableBinarySearchForOrderedMove | bool | true | true/false | USERSET | Binary search move |
| 88 | inlineChangeStreamMatchStage | bool | true | true/false | USERSET | Inline changestream |
| 89 | removeMatchNamespaceFilters | bool | true | true/false | USERSET | Remove namespace |
| 90 | multipleDollarPositionalNotAllowed | bool | true | true/false | USERSET | Multi $ positional |
| 91 | enableGroupSubqueryElimination | bool | true | true/false | USERSET | Group subquery elim |
| 92 | failOnNonEmptyGroupCountArg | bool | false | true/false | USERSET | Fail group count |
| 93 | enableSortGroupStage | bool | true | true/false | USERSET | Sort group stage |
| 94 | EnableOperatorVariablesInLookup | bool | false | true/false | USERSET | Operator vars in let |
| 95 | skipFailOnCollation | bool | false | true/false | USERSET | Skip collation fail |
| 96 | enableLookupIdJoinOptimizationOnCollation | bool | false | true/false | USERSET | ID join on collation |
| 97 | enableCollationWithNonUniqueOrderedIndexes | bool | false | true/false | USERSET | Collation non-unique |
| 98 | enableCollationWithNewGroupAccumulators | bool | false | true/false | USERSET | Collation group |
| 99 | enableUpdateBsonDocument | bool | true | true/false | USERSET | update_bson_document |
| 100 | recreate_retry_table_on_shard | bool | false | true/false | USERSET | Recreate retry table |
| 101 | enableSchemaEnforcementForCSFLE | bool | true | true/false | USERSET | CSFLE enforcement |
| 102 | usePgStatsLiveTuplesForCount | bool | true | true/false | USERSET | Use pg_stats count |
| 103 | enablePrepareUnique | bool | false | true/false | USERSET | Prepare unique |
| 104 | enableCollModUnique | bool | false | true/false | USERSET | CollMod unique |
| 105 | enableDropInvalidIndexesOnReadOnly | bool | true | true/false | USERSET | Drop invalid on RO |
| 106 | enableOnlyCollectionCacheInvalidateOnCollectionChanges | bool | true | true/false | USERSET | Collection cache only |
| 107 | enableStreamingCursorDrainViaDestReceiver | bool | true | true/false | USERSET | Cursor drain receiver |
| 108 | indexBuildsScheduledOnBgWorker | bool | false | true/false | USERSET | Index on bgworker |
| 109 | localhost_connection_string | str | "host=localhost" | any | SUSET | Connection parameters |
| 110 | enable_create_collection_on_insert | bool | true | true/false | USERSET | Auto create coll |
| 111 | enableDbNameValidation | bool | true | true/false | USERSET | Validate $db |
| 112 | query_plan_cache_size | int | 100 | 1 to INT_MAX | USERSET | Plan cache size |
| 113 | maxWriteBatchSize | int | 25000 | 1 to INT_MAX | USERSET | Write batch size |
| 114 | forceUseIndexIfAvailable | bool | true | true/false | USERSET | Force index use |
| 115 | coll_stats_count_policy_threshold | int | 10000 | 1 to INT_MAX | USERSET | CollStats threshold |
| 116 | batchWriteSubTransactionCount | int | 512 | 1 to INT_MAX | USERSET | Sub-transaction size |
| 117 | IsPgReadOnlyForDiskFull | bool | false | true/false | USERSET | Read-only flag |
| 118 | geo2dsphereSegmentMaxLength | real | 500.0 | 0.0 to 6372.0 | USERSET | Geo segment length (km) |
| 119 | geo2dsphereSegmentMaxVertices | int | 8 | 0 to 32 | USERSET | Geo vertices |
| 120 | maxIndexesPerCollection | int | 64 | 0 to 300 | USERSET | Max indexes/coll |
| 121 | maxWildcardIndexKeySize | int | 200 | 1 to INT32_MAX | USERSET | Wildcard key size |
| 122 | maxSchemaValidatorSize | int | 10240 | 0 to 16777216 | USERSET | Schema validator (bytes) |
| 123 | sharding_max_chunks | int | 128 | 1 to 8192 | USERSET | Max shard chunks |
| 124 | scramDefaultSaltLen | int | 28 | 1 to 64 | SUSET | SCRAM salt length |
| 125 | throwDeadlockOnCRUD | bool | false | true/false | USERSET | Throw deadlock |
| 126 | maxUserLimit | int | 100 | 1 to 500 | SUSET | Max users |
| 127 | maxCustomCommandTimeoutLimit | int | 10800000 | 0 to INT_MAX | SUSET | Max timeout (ms) |
| 128 | tdigestCompressionAccuracy | int | 1500 | 10 to 10000 | USERSET | T-digest accuracy |
| 129 | blockedRolePrefixList | str | "" | csv | USERSET | Blocked role prefix |
| 130 | current_op_application_name | str | "" | any | USERSET | Track app name |
| 131 | aggregation_stages_limit | int | 1000 | 1000 to 5000 | USERSET | Max stages |
| 132 | index_term_compression_threshold | int | INT_MAX | 128 to INT_MAX | USERSET | Compression threshold |
| 133 | enableUserCrud | bool | true | true/false | USERSET | Enable user CRUD |
| 134 | enableTTLJobsOnReadOnly | bool | false | true/false | USERSET | TTL on read-only |
| 135 | enable_force_push_geonear_index | bool | true | true/false | USERSET | Force geonear |
| 136 | vectorPreFilterIterativeScanMode | enum | "relaxed_order" | off/relaxed/strict | USERSET | Vector scan mode |
| 137 | defaultCursorFirstPageBatchSize | int | 101 | 1 to INT_MAX | USERSET | Cursor first page |
| 138 | enableExtendedExplainPlans | bool | false | true/false | USERSET | Extended explain |
| 139 | defaultCursorExpiryTimeLimitSeconds | int | 60 | 1 to 3600 | USERSET | Cursor expiry (sec) |
| 140 | maxCursorIntermediateFileSizeMB | int | 4096 | 1 to INT_MAX | USERSET | Cursor file size (MB) |
| 141 | maxCursorFileCount | int | 5000 | 0 to INT_MAX | USERSET | Cursor file count |
| 142 | rum_library_load_option | enum | "require_..." | none/prefer/require | POSTMASTER | RUM library option |
| 143 | enableStatementTimeout | bool | true | true/false | USERSET | Statement timeout |
| 144 | alternate_index_handler_name | str | "" | any | USERSET | Alternate handler |
| 145 | max_non_ordered_term_scan_threshold | int | 500 | -1 to INT_MAX | USERSET | Term scan threshold |
| 146 | next_collection_id | int | -1 | -1 to INT_MAX | USERSET | Test collection ID |
| 147 | next_collection_index_id | int | -1 | -1 to INT_MAX | USERSET | Test index ID |
| 148 | simulateRecoveryState | bool | false | true/false | USERSET | Simulate recovery |
| 149 | enableGenerateNonExistsTerm | bool | true | true/false | USERSET | Non-exists term |
| 150 | indexTermLimitOverride | int | INT_MAX | 1 to INT_MAX | USERSET | Test term limit |
| 151 | enableCursorsOnAggregationQueryRewrite | bool | false | true/false | USERSET | Aggregation cursors |
| 152 | defaultUniqueIndexKeyhashOverride | int | 0 | 0 to INT_MAX | USERSET | Test keyhash |
| 153 | useLocalExecutionShardQueries | bool | true | true/false | USERSET | Local shard |
| 154 | forceLocalExecutionShardQueries | bool | false | true/false | USERSET | Force local shard |
| 155 | forceIndexTermTruncation | bool | false | true/false | USERSET | Test truncation |
| 156 | maxWorkerCursorSize | int | 16777216 | 1 to 16777216 | USERSET | Worker cursor (bytes) |
| 157 | enableNativeColocation | bool | true | true/false | USERSET | Native colocation |
| 158 | test.internalQueryMaxAllowedDensifyDocs | int | 500000 | 0 to INT32_MAX | USERSET | Max densify docs |
| 159 | test.internalDocumentSourceDensifyMaxMemoryBytes | int | 16777216 | 0 to 16777216 | USERSET | Densify memory |
| 160 | forceDisableSeqScan | bool | false | true/false | USERSET | Disable seq scan |
| 161 | currentOpAddSqlCommand | bool | false | true/false | USERSET | Add SQL to op |
| 162 | logRelationIndexesOrder | bool | false | true/false | USERSET | Log index order |
| 163 | enable_large_unique_index_keys | bool | true | true/false | USERSET | Large unique keys |
| 164 | enableDebugQueryText | bool | false | true/false | USERSET | Debug query text |
| 165 | enableMultiIndexRumJoin | bool | false | true/false | USERSET | Multi-index join |
| 166 | forceUpdateIndexInline | bool | false | true/false | USERSET | Inline update |
| 167 | forceRunDiagnosticCommandInline | bool | false | true/false | USERSET | Inline diagnostic |
| 168 | forceIndexOnlyScanIfAvailable | bool | false | true/false | USERSET | Force index-only |
| 169 | forceParallelScanIfAvailable | bool | false | true/false | USERSET | Force parallel |
| 170 | enableRbacCompliantSchemas | bool | false | true/false | POSTMASTER | RBAC schemas |
| 171 | disableExtendedRumExplainPlans | bool | false | true/false | USERSET | Disable RUM explain |
| 172 | enableDataTableWithoutCreationTime | bool | true | true/false | USERSET | No creation time |
| 173 | rumFailOnLostPath | bool | false | true/false | USERSET | Fail lost path |
| 174 | forceCollStatsDataCollection | bool | false | true/false | USERSET | Force collStats |
| 175 | forceBitmapScanForLookup | bool | false | true/false | USERSET | Bitmap lookup |
| 176 | forceGroupSubqueryElimination | bool | false | true/false | USERSET | Force group elim |
| 177 | forceWildcardReducedTerm | bool | false | true/false | USERSET | Wildcard reduced |

## Context Legend

- **USERSET**: Can be changed anytime without restart ✅
- **SUSET**: Superuser only, runtime changeable ✅
- **POSTMASTER**: Requires restart ⚠️

## Type Legend

- **int**: Integer value
- **bool**: true or false
- **str**: String value
- **real**: Floating-point value
- **enum**: Enumerated value (predefined options)

## Quick Filter by Category

### Must Configure (Production)
- `enableBackgroundWorker`
- `enableBackgroundWorkerJobs`
- `maxWriteBatchSize`
- `forceUseIndexIfAvailable`
- `maxIndexBuildAttempts`

### Performance Tuning
- `maxTTLDeleteBatchSize`
- `TTLTaskMaxRunTimeInMS`
- `maxNumActiveUsersIndexBuilds`
- `query_plan_cache_size`
- `aggregation_stages_limit`

### Vector Search
- `enableVectorHNSWIndex`
- `enableVectorPreFilter`
- `enableVectorCompressionHalf`
- `enableVectorCompressionPQ`

### Requires Restart
- `enableBackgroundWorker` (POSTMASTER)
- `enableBackgroundWorkerInitJobs` (POSTMASTER)
- `bg_worker_database_name` (POSTMASTER)
- `bg_worker_latch_timeout` (POSTMASTER)
- `enableRbacCompliantSchemas` (POSTMASTER)
- `rum_library_load_option` (POSTMASTER)

