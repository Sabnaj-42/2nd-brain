# DB2 Kubernetes Reconciler

A comprehensive Kubernetes operator controller that manages the complete lifecycle of DB2 database instances within a Kubernetes cluster. This reconciler ensures that the actual state of DB2 resources always matches the desired state defined in custom DB2 objects.

## Table of Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [How It Works](#how-it-works)
- [Key Functions](#key-functions)
- [Reconciliation Workflow](#reconciliation-workflow)
- [Trigger Mechanism](#trigger-mechanism)
- [Configuration](#configuration)
- [Error Handling](#error-handling)
- [Dependencies](#dependencies)
- [Usage](#usage)

## Overview

The DB2 Reconciler is built on **controller-runtime**, a powerful framework for building Kubernetes controllers in Go. It automates the deployment, configuration, health monitoring, and lifecycle management of DB2 database instances on Kubernetes.

The reconciler continuously monitors DB2 objects and their dependent resources (Services, Secrets, PetSets) and automatically reconciles any drift from the desired state.

## Architecture

### Core Components

| Component | Purpose |
|-----------|---------|
| **DB2Reconciler** | Main controller struct that orchestrates the entire reconciliation process |
| **db2ReconcileState** | Internal state object holding context and resources during a single reconciliation cycle |
| **Controller-runtime** | Framework that manages watchers, work queues, and event handling |
| **HealthChecker** | Monitors the health status of running DB2 instances |
| **LicenseRestrictions** | Validates DB2 version against license compliance rules |

### Struct Fields

```go
type DB2Reconciler struct {
    *amc.Controller
    *amc.Config
    
    NetworkPolicyEnabled bool                    // Enable automatic network policy creation
    Scheme               *runtime.Scheme         // Kubernetes API scheme
    Ctx                  context.Context         // Base context for operations
    HealthChecker        *health.HealthChecker   // Instance health monitoring
    LicenseRestrictions  v1alpha1.LicenseRestrictions // License validation rules
}

type db2ReconcileState struct {
    *DB2Reconciler
    
    log     logr.Logger                    // Logger with request context
    db      *dbapi.DB2                     // The DB2 object being reconciled
    version *catalogv1alpha1.DB2Version    // The DB2 version specification
}
```

## How It Works

### Trigger Mechanism

When you apply a DB2 object to the cluster, a sophisticated event-driven mechanism triggers reconciliation:

1. **Apply DB2 Object**
   ```bash
   kubectl apply -f db2.yaml
   ```

2. **Kubernetes API Server**
    - Stores the object in etcd (cluster data store)
    - Broadcasts a CREATE, UPDATE, or DELETE event

3. **Controller-runtime Informer**
    - Detects the event (CREATE, UPDATE, DELETE, or WATCH event)
    - Filters by resource type (DB2 objects)

4. **Work Queue**
    - Enqueues the object's namespaced name (namespace/name)
    - Prevents duplicate processing

5. **Reconcile() Function**
    - Called with `ctrl.Request` containing namespace and name
    - Fetches the current object state
    - Executes the reconciliation workflow

### Event Types That Trigger Reconciliation

| Event | Trigger | Description |
|-------|---------|-------------|
| **CREATE** | New DB2 object applied | Initialize all resources |
| **UPDATE** | Spec or annotations changed | Update infrastructure to match new spec |
| **DELETE** | Object marked for deletion | Run cleanup logic via finalizers |
| **REQUEUE** | Error occurred during reconciliation | Automatic retry with exponential backoff |
| **WATCH** | Dependent resource changed | Detect and reconcile drift in Services, PetSets, Secrets |

## Reconciliation Workflow

The `Reconcile()` function executes these steps in strict order:

### Step 1: Get Reconcile State
```go
rs, err := r.getDB2ReconcileState(ctx, req)
```
- Fetches the DB2 object from the API server
- Retrieves the corresponding DB2Version catalog entry
- Returns error if object doesn't exist (gracefully handled)

### Step 2: License Validation
```go
ok, reason, err := license.MeetsLicenseRestrictions(...)
```
- Validates that the DB2 version meets license restrictions
- Prevents use of unlicensed features
- Returns descriptive error if validation fails

### Step 3: Finalize & Cleanup
```go
isFinalizersRemoved, err := rs.ensureFinalizers()
```
- **On deletion**: Removes finalizers and stops health checker
- **On creation**: Adds finalizers to track deletion
- Ensures no orphaned resources remain after deletion

### Step 4: Apply Defaults
```go
cu.CreateOrPatch(ctx, r.KBClient, rs.db, func(obj client.Object, createOp bool) client.Object {
    in := obj.(*dbapi.DB2)
    in.SetDefaults(r.KBClient)
    return in
})
```
- Patches the DB2 object with default values
- Works even if webhook server is offline
- Ensures consistent configuration

### Step 5: Start Health Monitoring
```go
rs.runHealthChecker(req)
```
- Initiates continuous health checking
- Monitors database connectivity and readiness
- Updates status conditions based on health

### Step 6: Update Phase
```go
rs.updatePhaseFromCondition()
```
- Sets the database phase (Provisioning, Ready, Failed, etc.)
- Based on current conditions
- Updates status for visibility in `kubectl get`

### Step 7: Pause Check
```go
if cutil.IsConditionTrue(rs.db.Status.Conditions, kubedb.DatabasePaused) {
    return r.reconciled()
}
```
- Skips remaining reconciliation if database is paused
- Allows manual pause/resume without deletion

### Step 8: Network Policies
```go
if r.NetworkPolicyEnabled {
    netpol.EnsureNetworkPolicy(r.KBClient, rs.db.GetNamespace())
}
```
- Creates default network policies for security
- Only if enabled in controller configuration
- Restricts ingress/egress traffic as needed

### Step 9: Create/Update Infrastructure
```go
err = rs.EnsureServices()      // Create headless and client-facing services
err = rs.ensureSecrets()       // Create connection secrets
err = rs.EnsurePetSet()        // Create/update StatefulSet
```
- Ensures all required Kubernetes resources exist
- Updates resources if spec changed
- Handles resource lifecycle management

## Key Functions

### `Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error)`

**Purpose**: Main reconciliation loop, called whenever DB2 object or dependent resources change

**Parameters**:
- `ctx`: Context for operations
- `req`: Request containing namespace and name of the DB2 object

**Returns**:
- `ctrl.Result`: Requeue information (empty = no requeue, delay = requeue after delay)
- `error`: Reconciliation error (nil = success)

**Flow**:
```
Get State → Validate License → Handle Finalizers → Apply Defaults 
→ Start Health Check → Update Phase → Skip if Paused 
→ Setup Network Policies → Create Services/Secrets/PetSet
```

---

### `getDB2ReconcileState(ctx context.Context, req ctrl.Request) (*db2ReconcileState, error)`

**Purpose**: Initialize and populate the reconcile state with DB2 object and version information

**What it does**:
1. Creates new `db2ReconcileState` struct
2. Sets up logger with request context
3. Fetches DB2 object via API client: `r.KBClient.Get(rs.Ctx, req.NamespacedName, db2)`
4. Fetches DB2Version catalog: `r.KBClient.Get(r.Ctx, types.NamespacedName{Name: db2.Spec.Version}, db2Version)`
5. Populates state with fetched objects

**Returns error when**:
- DB2 object doesn't exist: `kerr.IsNotFound(err)` - handled gracefully, returns immediately
- DB2Version catalog entry not found - version doesn't exist in cluster
- API server communication fails - network/permission issues
- Data deserialization fails - malformed API response

**Example**:
```go
rs, err := r.getDB2ReconcileState(ctx, req)
if err != nil {
    if kerr.IsNotFound(err) {
        return ctrl.Result{}, nil // DB2 deleted, nothing to do
    }
    return r.requeueWithError(err) // Retry on other errors
}
```

---

### `getUpdatedDB(ctx context.Context, req ctrl.Request) (*dbapi.DB2, error)`

**Purpose**: Fetch the latest DB2 object from the API server before making updates

**Why it's needed**:
- Gets the current state to avoid stale data
- Called after defaults are applied
- Ensures patches use latest version

**Returns error when**:
- DB2 object no longer exists
- API server is unreachable
- Permission denied reading the object

---

### `ensureFinalizers()`

**Purpose**: Manage Kubernetes finalizers for proper cleanup on deletion

**On deletion** (object marked for deletion):
- Stops the health checker
- Syncs owner references
- Removes the finalizer
- Returns `true` to abort further reconciliation

**On creation** (object not being deleted):
- Checks if finalizer exists
- Adds finalizer if missing
- Returns `false` to continue reconciliation

**Why finalizers matter**: They ensure custom cleanup logic runs before the object is fully deleted, preventing orphaned resources.

## Configuration

### Controller Setup Example

```go
type DB2Reconciler struct {
    *amc.Controller           // Base controller functionality
    *amc.Config              // Configuration from KubeDB
    
    NetworkPolicyEnabled bool // Enable network policy creation
    Scheme               *runtime.Scheme
    Ctx                  context.Context
    HealthChecker        *health.HealthChecker
    LicenseRestrictions  v1alpha1.LicenseRestrictions
}
```

### Configuration Fields

| Field | Type | Default | Purpose |
|-------|------|---------|---------|
| `NetworkPolicyEnabled` | bool | false | Create default network policies for namespace |
| `Scheme` | \*runtime.Scheme | - | Kubernetes API object serialization |
| `Ctx` | context.Context | - | Base context for all operations |
| `HealthChecker` | \*health.HealthChecker | - | Monitor DB2 instance health |
| `LicenseRestrictions` | v1alpha1.LicenseRestrictions | - | License validation rules |

## Error Handling

### Error Types and Handling

| Error Type | Handling | Behavior |
|-----------|----------|----------|
| **NotFound** | Graceful abort | Returns immediately, no requeue |
| **License violation** | Descriptive error | Requeued with human-readable message |
| **Transient errors** | Automatic retry | Requeued with exponential backoff |
| **API errors** | Logged and retry | Requeued for later attempt |

### Error Recovery

```go
if err != nil {
    if kerr.IsNotFound(err) {
        return ctrl.Result{}, nil // Don't retry deleted objects
    }
    return r.requeueWithError(err) // Retry other errors
}
```

The `requeueWithError()` function:
- Logs the error
- Increments retry counter
- Requeues the object for later processing
- Uses exponential backoff to avoid hammering the API

## Dependencies

### Core Dependencies

| Package | Purpose | Version |
|---------|---------|---------|
| `sigs.k8s.io/controller-runtime` | Kubernetes controller framework | Latest |
| `kubedb.dev/apimachinery` | KubeDB API types and utilities | Latest |
| `kmodules.xyz/client-go` | Kubernetes client utilities | Latest |
| `github.com/go-logr/logr` | Structured logging framework | Latest |
| `k8s.io/apimachinery` | Kubernetes core APIs | Latest |

### Key Imports

```go
import (
    catalogv1alpha1 "kubedb.dev/apimachinery/apis/catalog/v1alpha1"
    dbapi "kubedb.dev/apimachinery/apis/kubedb/v1alpha2"
    amc "kubedb.dev/apimachinery/pkg/controller"
    "kubedb.dev/apimachinery/pkg/license"
    health "kmodules.xyz/client-go/tools/healthchecker"
    ctrl "sigs.k8s.io/controller-runtime"
)
```

## Usage

### 1. Apply a DB2 Object

```yaml
# db2-example.yaml
apiVersion: kubedb.dev/v1alpha2
kind: DB2
metadata:
  name: my-db2
  namespace: default
spec:
  version: "11.5.8"
  replicas: 1
  storage:
    storageClassName: standard
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 10Gi
```

```bash
kubectl apply -f db2-example.yaml
```

### 2. Reconciliation Starts Automatically

The reconciler will:
- Detect the new DB2 object
- Fetch its configuration and version
- Create required Kubernetes resources (Services, Secrets, PetSets)
- Start health monitoring
- Update status with readiness information

### 3. Monitor Reconciliation

```bash
# Watch the DB2 object status
kubectl get db2 my-db2 -w

# View reconciliation logs
kubectl logs -l app.kubernetes.io/name=db2-operator -f

# Check conditions
kubectl describe db2 my-db2
```

### 4. Update the DB2 Object

```bash
# Edit the spec
kubectl edit db2 my-db2

# The reconciler automatically detects changes and updates infrastructure
```

### 5. Delete the DB2 Object

```bash
kubectl delete db2 my-db2

# The reconciler:
# 1. Detects the deletion
# 2. Runs cleanup logic via finalizers
# 3. Removes dependent resources
# 4. Completes the deletion
```

## Reconciliation States

### Database Phases

| Phase | Meaning | Auto-reconcile |
|-------|---------|---|
| **Provisioning** | Resources being created | Yes |
| **Ready** | Database is ready to use | Yes |
| **NotReady** | Health check failed | Yes |
| **Terminating** | Deletion in progress | No |
| **Failed** | Unrecoverable error | No |

### Paused State

When a DB2 object has the `kubedb.com/paused: "true"` condition:
- Reconciliation stops after phase update
- Allows manual intervention without deletion
- Can be resumed by removing the condition

## Best Practices

1. **Always use namespaced resources** - DB2 objects are namespaced
2. **Define storage classes** - Ensure appropriate storage is available
3. **Set resource requests/limits** - For stable scheduling
4. **Monitor health conditions** - Watch status.conditions for issues
5. **Use network policies** - Enable if multi-tenancy is needed
6. **Validate license** - Ensure version meets license restrictions
7. **Implement backup strategy** - Backup data regularly
8. **Set up monitoring** - Use Prometheus metrics from the operator

## Troubleshooting

### DB2 Stuck in Provisioning

1. Check logs: `kubectl logs -l app.kubernetes.io/name=db2-operator`
2. Check events: `kubectl describe db2 my-db2`
3. Verify storage availability
4. Check license restrictions

### Reconciliation Errors

- **License violation**: Upgrade to licensed version
- **Storage unavailable**: Create storage class or PVC
- **API server timeout**: Check network connectivity
- **Permission denied**: Verify RBAC roles

## Contributing

When modifying the reconciler:

1. Update reconciliation logic in `Reconcile()`
2. Add corresponding tests
3. Update documentation
4. Run `make test` to verify
5. Submit PR with description of changes

## License

Apache License 2.0 - See LICENSE file

