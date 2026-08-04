# How PetSet Creates Pods in KubeDB MSSQL Operator

## Overview
This code is responsible for creating and managing Kubernetes PetSets (a stateful workload similar to StatefulSets) that orchestrate MS SQL Server pods in Kubernetes. The PetSet is an advanced controller that manages ordered, stable, and uniquely identified pods.

---

## 1. PetSet Creation Flow

### Entry Point: `EnsurePetSet()` (Lines 49-64)
This is the main function that orchestrates the entire PetSet creation process:

```
EnsurePetSet()
├── 1. checkPetSetAvailable()      - Verify if PetSet already exists
└── 2. createOrPatchPetSet(ps)     - Create or update the PetSet
```

#### What it does:
1. **Checks if a PetSet with the same name already exists** (line 50) by calling `checkPetSetAvailable()`
    - If a PetSet exists with a different resource, it returns an error to prevent conflicts
    - If it doesn't exist or is a valid match, proceeds to creation

2. **Creates or patches the PetSet** (line 59) by calling `createOrPatchPetSet(ps)`
    - Uses the `clientutil.CreateOrPatch()` utility which either creates a new PetSet or updates an existing one

---

## 2. Detailed PetSet Creation: `createOrPatchPetSet()` (Lines 66-188)

This is the core function that actually configures and creates/patches the PetSet.

### Step-by-Step Process:

#### **Phase 1: Gather Configuration Components** (Lines 67-88)

```
1. getVolumes()              → Collect all storage volumes needed
2. getPVC()                  → Get Persistent Volume Claims (if persistent storage)
3. getDBContainer()          → Create the main MSSQL database container
4. [If Cluster] getCoordinatorContainer()  → Add coordinator container for clusters
5. [If Monitoring] getMonitoringContainer() → Add Prometheus exporter container
6. getInitContainer()        → Create initialization container
```

**Why this order matters:**
- Volumes and PVCs must be defined first since containers reference them
- The DB container is the primary workload
- Additional containers (coordinator, monitoring) are optional based on configuration
- Init containers run before main containers

#### **Phase 2: Build PetSet Specification** (Lines 90-167)

The `clientutil.CreateOrPatch()` function uses a callback to construct the PetSet object:

```go
CreateOrPatch(ctx, client, petset, func(obj, createOp) {
    // Configure the PetSet spec
})
```

**Key configurations applied:**

| Configuration | Purpose |
|---|---|
| `in.Labels` | Labels for the PetSet controller itself |
| `in.Annotations` | Metadata annotations |
| `in.Spec.Selector` | Label selector to identify pods this PetSet manages |
| `in.Spec.Replicas` | Number of pods to create (from DB spec) |
| `in.Spec.ServiceName` | Headless service name for stable DNS |
| `in.Spec.Template` | Pod template (the blueprint for pods) |
| `in.Spec.PodManagementPolicy` | Set to "OrderedReady" (creates pods sequentially) |
| `in.Spec.UpdateStrategy` | Set to "OnDelete" (manual pod updates) |

#### **Phase 3: Configure Pod Template** (Lines 102-162)

The pod template is the blueprint used to create each pod:

```
PetSet.Spec.Template
├── ObjectMeta
│   ├── Labels          → Pod labels (for identification)
│   └── Annotations     → Pod metadata
│
└── Spec (Pod Specification)
    ├── ServiceAccountName  → RBAC permissions
    ├── InitContainers      → Init containers (run once, sequentially)
    ├── Containers          → Main containers (MSSQL, Coordinator, Exporter)
    ├── Volumes             → Storage definitions
    ├── VolumeClaimTemplates → Templates for dynamic PVC creation
    ├── NodeSelector        → Node affinity
    ├── Tolerations         → Node taints tolerance
    ├── SecurityContext     → Pod security settings
    ├── ImagePullSecrets    → Registry credentials
    ├── PriorityClassName   → Pod priority
    └── HostNetwork/PID/IPC → Host resource sharing
```

#### **Phase 4: Persist PetSet & Create PDB** (Lines 169-182)

```
1. CreateOrPatch()      → Saves PetSet to Kubernetes API
2. Log creation if new
3. SyncPetSetPodDisruptionBudget() → Create PodDisruptionBudget
```

---

## 3. How Kubernetes Creates Pods from PetSet

Once the PetSet is created, **Kubernetes automatically handles pod creation** following this flow:

```
PetSet Controller (Kubernetes)
├── Reads PetSet spec.replicas (e.g., 3)
├── Creates pods in order (1, 2, 3) with predictable names:
│   ├── <petset-name>-0
│   ├── <petset-name>-1
│   └── <petset-name>-2
│
├── For each pod:
│   ├── Wait for previous pod to be Ready (OrderedReady policy)
│   ├── Create a Persistent Volume Claim (PVC) using volumeClaimTemplates
│   ├── Launch containers in order:
│   │   ├── InitContainers (setup phase)
│   │   └── Containers (main workload)
│   └── Attach volumes and mount them
│
└── Result: Ordered, stable, uniquely-identified pods
```

### Predictable Pod Naming
- Pod names are deterministic: `<petset-name>-<ordinal>`
- MSSQL pods would be named like: `mssql-0`, `mssql-1`, `mssql-2`
- Allows stable DNS: `mssql-0.mssql-headless.default.svc.cluster.local`

---

## 4. Container Building Details

### **Main Database Container** (`getDBContainer()` - Lines 314-376)

Creates the primary MSSQL Server container:

```
Container Configuration:
├── Name: "mssql"
├── Image: MS SQL Server (with digest verification)
├── Ports:
│   ├── 1433 (database port)
│   ├── 5022 (database mirroring)
│   └── 9399 (Prometheus metrics - if monitoring enabled)
├── Commands: /scripts/tini (process supervisor)
├── Args: /scripts/run.sh (cluster) or /scripts/standalone-run.sh (standalone)
├── Environment Variables: MSSQL_SA_PASSWORD, MSSQL_PID, etc.
├── VolumeMounts: Data, Config, TLS certificates
├── Lifecycle:
│   └── PreStop: Graceful SHUTDOWN via sqlcmd
└── SecurityContext: Applied from spec
```

**Key validation:** Ensures `MSSQL_PID` environment variable is set (required for MSSQL licensing).

### **Coordinator Container** (`getCoordinatorContainer()` - Lines 516-545)
- Only added if database is configured as a cluster
- Manages cluster coordination and failover logic
- Mounts same volumes as main container for shared state

### **Monitoring Container** (`getMonitoringContainer()` - Lines 378-447)
- Only added if Prometheus monitoring is enabled
- Exports MSSQL metrics in Prometheus format
- Connects to MSSQL via connection string with credentials from environment

### **Init Container** (`getInitContainer()` - Lines 556-574)
- Runs once before main containers
- Prepares the environment, initializes scripts
- Ensures proper setup of initialization directories

---

## 5. Volume and Storage Configuration

### **Volume Types Created** (`getVolumes()` - Lines 190-253)

| Volume Name | Type | Purpose | When Created |
|---|---|---|---|
| `init-script` | EmptyDir | Temporary init scripts | Always |
| `data` | PVC or EmptyDir | Database data files | Always (PVC for persistent, EmptyDir for ephemeral) |
| `config` | Secret | MSSQL configuration | Always |
| `init-database` | Custom Volume | Custom initialization scripts | If `Spec.Init.Script` provided |
| `tls` | Projected Secret | TLS certificates | If TLS enabled |
| `ca-certificates` | Projected Secret | CA certificates | If TLS enabled |
| `endpoint-cert` | Secret | Internal cluster certificates | If cluster mode |
| `certs` | EmptyDir | Shared certificates volume | If cluster mode |

### **Persistent Volume Claims** (`getPVC()` - Lines 255-284)

For persistent storage:
```
PVC Spec:
├── Name: "data"
├── AccessModes: ReadWriteOnce (or custom)
├── StorageClassName: User-specified (optional)
└── Size: From spec.storage.resources.requests
```

Generated automatically by PetSet using volumeClaimTemplate, creating one PVC per pod ordinal.

---

## 6. Volume Mounting Strategy

### **Main Container Mounts** (`getDBContainerVolumeMounts()` - Lines 449-512)

```
Container mounts volumes at:
├── /var/opt/mssql → data volume (database files)
├── /var/opt/mssql/backup → backup directory
├── /var/opt/mssql/data → init scripts
├── /var/opt/mssql/secrets/tls → TLS certificates
├── /etc/ssl/certs → CA certificates
├── /scripts → initialization scripts
├── /etc/init-db (if custom init scripts)
└── /etc/ssl/certs/cacerts (if client TLS)
```

---

## 7. Execution Flow Summary

```
User Creates MSSQL Resource
        ↓
ReconcileState.EnsurePetSet()
        ↓
checkPetSetAvailable()  ← Verify no conflicts
        ↓
createOrPatchPetSet()
        ├── Gather components:
        │   ├── Volumes
        │   ├── PVC
        │   ├── Containers
        │   └── Init containers
        ├── Build PetSet Spec
        ├── Configure Pod Template
        └── CreateOrPatch() → Kubernetes API
        ↓
Kubernetes PetSet Controller
        ├── Read spec.replicas
        ├── Create pods in order (0, 1, 2, ...)
        ├── For each pod:
        │   ├── Create PVC from volumeClaimTemplate
        │   ├── Run InitContainers
        │   ├── Run Containers
        │   └── Mount Volumes
        └── Pods are now running MSSQL
```

---

## 8. Key Design Patterns

### **Declarative Configuration**
- Code defines the desired state (PetSet spec)
- Kubernetes reconciles actual state to desired state
- Idempotent: Running multiple times produces same result

### **Ordered Pod Creation**
- `PodManagementPolicy: OrderedReady` ensures sequential startup
- Pod-0 starts first, then pod-1 only after pod-0 is ready
- Prevents thundering herd problem during cluster initialization

### **Graceful Shutdown**
- PreStop lifecycle hook runs MSSQL shutdown command
- Allows graceful cleanup before pod termination
- Prevents data corruption

### **Flexible Container Composition**
- Base MSSQL container always created
- Coordinator container added for clusters
- Monitoring container added if Prometheus enabled
- Init container always present
- Multiple container support in single pod

### **User Customization**
- Users can override any pod template spec
- Custom volumes, environment variables, security contexts
- Code merges defaults with user-provided overrides

---

## 9. Important Notes

1. **PetSet vs StatefulSet**: PetSet is an enhanced version offering more control over pod management and deployment order.

2. **Stable Identity**: Each pod has a stable hostname (mssql-0, mssql-1, etc.) that remains constant even after restart.

3. **Persistent Data**: Each pod gets its own PVC, ensuring data persists across pod restarts.

4. **TLS Communication**:
    - Server TLS: Certificates for client connections
    - Cluster TLS: Internal communication between nodes
    - Client TLS: Optional mTLS for client verification

5. **Monitoring Integration**: SQL Exporter container exports metrics compatible with Prometheus monitoring systems.

6. **Pod Disruption Budget**: After PetSet creation, a PodDisruptionBudget is created to maintain availability during voluntary disruptions.
