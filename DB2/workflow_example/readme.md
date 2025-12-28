# DB2 Reconciliation Flow - Detailed Example

When you apply the DB2 object, this document shows exactly what happens, step-by-step.

## The DB2 Object You Apply

```yaml
# db2-example.yaml
apiVersion: kubedb.dev/v1alpha2
kind: DB2
metadata:
  name: my-db2                    # <-- NAME
  namespace: default              # <-- NAMESPACE
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

## Key Information Extracted

```
name:      "my-db2"
namespace: "default"

Combined as NamespacedName: "default/my-db2"
```

## Complete Reconciliation Flow

### Phase 0: Object Application & Detection

```
You run: kubectl apply -f db2-example.yaml
        ↓
Kubernetes API Server stores in etcd:
  - Key: /kubedb.dev/db2/default/my-db2
  - Value: (full DB2 object)
        ↓
Controller-runtime Informer detects CREATE event
        ↓
Event: ObjectCreated
  metadata: {
    namespace: "default",
    name: "my-db2"
  }
        ↓
Work Queue receives: ctrl.Request{
  NamespacedName: types.NamespacedName{
    Namespace: "default",
    Name: "my-db2"
  }
}
```

---

## The Reconcile() Function Execution Flow

### **Step 1: Get Reconcile State**

```go
rs, err := r.getDB2ReconcileState(ctx, req)
```

**Inside getDB2ReconcileState():**

```
Input: req.NamespacedName = "default/my-db2"
       ↓
1. Create db2ReconcileState struct:
   rs := &db2ReconcileState{
     DB2Reconciler: r,
     log: logger.WithValues(
       "namespace", "default",
       "name", "my-db2"
     ),
   }
   
2. Fetch DB2 object using NamespacedName:
   var db2 dbapi.DB2
   r.KBClient.Get(ctx, req.NamespacedName, &db2)
   
   This translates to:
   - API call: GET /kubedb.dev/db2/default/my-db2
   - Returns the full DB2 object from etcd
   
   Result: db2 = {
     metadata: {
       name: "my-db2",
       namespace: "default",
       uid: "12345-abcde",
       ...
     },
     spec: {
       version: "11.5.8",
       replicas: 1,
       storage: {...}
     },
     status: {}  // empty on first creation
   }

3. Extract version from spec:
   versionName := db2.Spec.Version  // "11.5.8"
   
4. Fetch DB2Version catalog:
   var db2Version catalogv1alpha1.DB2Version
   r.KBClient.Get(ctx, 
     types.NamespacedName{
       Name: "11.5.8"  // Just name, no namespace (cluster-scoped)
     }, 
     &db2Version
   )
   
   Result: db2Version = {
     metadata: {
       name: "11.5.8"
     },
     spec: {
       version: "11.5.8",
       db: {...},
       ui: {...},
       ...
     }
   }

5. Populate and return:
   rs.db = &db2
   rs.version = &db2Version
   return rs, nil
```

---

### **Step 2: License Validation**

```go
ok, reason, err := license.MeetsLicenseRestrictions(
  r.LicenseRestrictions,
  rs.version,
  rs.db,
)
if !ok {
  return r.requeueWithError(fmt.Errorf(reason))
}
```

**Flow:**

```
Input: 
  - LicenseRestrictions: (from controller config)
  - DB2Version: 11.5.8
  - DB2 object: my-db2

Check: Does this version comply with license?
  ↓
If LICENSED: Continue to next step
If UNLICENSED: Return error, requeue with message
If RESTRICTED: Check restrictions, enforce them
```

---

### **Step 3: Handle Finalizers**

```go
isFinalizersRemoved, err := rs.ensureFinalizers()
if isFinalizersRemoved {
  return r.reconciled()  // Stop here, object is being deleted
}
```

**First Reconciliation (Creation):**

```
Input: DB2 object "my-db2" (not marked for deletion)

Check: Does finalizer exist in metadata.finalizers?
  ↓
NOT FOUND:
  - Add finalizer: "kubedb.com/db2-operator"
  - Patch object: 
    metadata.finalizers: ["kubedb.com/db2-operator"]
  - Return false (continue reconciliation)

Already EXISTS:
  - Return false (continue reconciliation)

Result: metadata.finalizers = ["kubedb.com/db2-operator"]
```

**On Deletion (Future):**

```
When: kubectl delete db2 my-db2

Input: DB2 object "my-db2" (marked for deletion)
       metadata.deletionTimestamp = "2025-12-29T10:30:00Z"

Check: Is object marked for deletion?
  ↓
YES:
  - Stop health checker
  - Sync owner references
  - Remove finalizer from metadata.finalizers
  - Patch object
  - Return true (abort reconciliation)

Result: 
  - No finalizers remain
  - Kubernetes allows full deletion
```

---

### **Step 4: Apply Defaults**

```go
cu.CreateOrPatch(ctx, r.KBClient, rs.db, 
  func(obj client.Object, createOp bool) client.Object {
    in := obj.(*dbapi.DB2)
    in.SetDefaults(r.KBClient)
    return in
  },
)
```

**Flow:**

```
Input: DB2 object "my-db2" with partial spec

1. Call SetDefaults() on the object:
   - Fill missing fields with defaults
   - Example:
     spec.storageType = "Durable"  (if not specified)
     spec.deletionPolicy = "Delete"  (if not specified)
     spec.monitoring = {}  (empty monitoring config)

2. Patch the object in etcd:
   - Only changed fields are sent
   - API call: PATCH /kubedb.dev/db2/default/my-db2
   - Update status.observedGeneration

Result: DB2 object now has all defaults applied
```

---

### **Step 5: Start Health Checker**

```go
rs.runHealthChecker(req)
```

**Flow:**

```
Input: DB2 object "my-db2"

1. Create health checker goroutine:
   go r.HealthChecker.CheckHealth(
     "my-db2",
     "default",
     connectionInfo,
   )

2. Health checker runs periodically:
   - Connect to DB2 instance
   - Run: SELECT 1 FROM DUAL
   - Check response time
   - Update conditions:
     * kubedb.com/ready = true/false
     * kubedb.com/accepting-connection = true/false
     * kubedb.com/ready-to-use = true/false

3. Status gets updated:
   status.conditions = [
     {
       type: "Ready",
       status: "False",
       reason: "Provisioning"
     }
   ]

Running in background...
```

---

### **Step 6: Update Phase from Conditions**

```go
rs.updatePhaseFromCondition()
```

**Flow:**

```
Input: DB2 object status.conditions

Check conditions and determine phase:

IF all services ready AND all pods ready AND health check passed:
  status.phase = "Ready"
  ↓
  kubectl get db2 my-db2  →  STATUS: Ready

ELSE IF provisioning in progress:
  status.phase = "Provisioning"
  ↓
  kubectl get db2 my-db2  →  STATUS: Provisioning

ELSE IF health check failed:
  status.phase = "NotReady"
  ↓
  kubectl get db2 my-db2  →  STATUS: NotReady

ELSE IF error occurred:
  status.phase = "Failed"
  ↓
  kubectl get db2 my-db2  →  STATUS: Failed
```

---

### **Step 7: Check if Paused**

```go
if cutil.IsConditionTrue(rs.db.Status.Conditions, kubedb.DatabasePaused) {
  return r.reconciled()  // Skip remaining steps
}
```

**Flow:**

```
Check: Is database paused?
  ↓
IF paused (condition "DatabasePaused" = true):
  - Skip all remaining steps
  - Stop here
  - Don't create/update resources
  - User must manually fix issue
  
IF not paused:
  - Continue to next step
```

---

### **Step 8: Create Network Policies**

```go
if r.NetworkPolicyEnabled {
  netpol.EnsureNetworkPolicy(r.KBClient, rs.db.GetNamespace())
}
```

**Flow:**

```
Check: Is NetworkPolicyEnabled = true?
  ↓
IF enabled:
  1. Create NetworkPolicy resource:
     metadata.namespace = "default"
     metadata.name = "db2-default"
     
  2. Ingress rules:
     - Allow traffic from pods with label
       app: db2
       
  3. Egress rules:
     - Allow DNS (port 53)
     - Allow internal communication (port 5432)

IF disabled:
  - Skip this step

Result: Network policies created if enabled
```

---

### **Step 9: Create Services**

```go
err = rs.EnsureServices()
```

**Flow:**

```
1. Create Headless Service:
   Service "my-db2" in namespace "default"
   {
     metadata: {
       name: "my-db2",
       namespace: "default",
       ownerReferences: [{
         kind: "DB2",
         name: "my-db2",
         uid: "12345-abcde"
       }]
     },
     spec: {
       clusterIP: "None",  // Headless!
       ports: [
         {name: "db2", port: 50000}
       ],
       selector: {
         app: "db2",
         db2-name: "my-db2"
       }
     }
   }

2. Create Client Service (if specified):
   Service "my-db2-client" in namespace "default"
   {
     spec: {
       type: "ClusterIP",
       selector: {
         app: "db2",
         db2-name: "my-db2"
       }
     }
   }

Result: Services created and ready for pod discovery
```

---

### **Step 10: Create Secrets**

```go
err = rs.ensureSecrets()
```

**Flow:**

```
1. Generate default credentials (if not provided):
   username: "db2admin"
   password: (random 32-char)
   
2. Create Secret resource:
   Secret "my-db2-auth" in namespace "default"
   {
     metadata: {
       name: "my-db2-auth",
       namespace: "default",
       ownerReferences: [{
         kind: "DB2",
         name: "my-db2"
       }]
     },
     data: {
       username: base64("db2admin"),
       password: base64("randompassword...")
     }
   }

3. Create connection Secret:
   Secret "my-db2-connection" in namespace "default"
   {
     data: {
       connection-string: base64("db2://db2admin:password@my-db2:50000/testdb")
     }
   }

Result: Secrets created with credentials and connection info
```

---

### **Step 11: Create PetSet (StatefulSet)**

```go
err = rs.EnsurePetSet()
```

**Flow:**

```
1. Create StatefulSet resource:
   StatefulSet "my-db2" in namespace "default"
   {
     metadata: {
       name: "my-db2",
       namespace: "default",
       ownerReferences: [{
         kind: "DB2",
         name: "my-db2"
       }]
     },
     spec: {
       serviceName: "my-db2",  // Links to headless service
       replicas: 1,
       selector: {
         matchLabels: {
           app: "db2",
           db2-name: "my-db2"
         }
       },
       template: {
         metadata: {
           labels: {
             app: "db2",
             db2-name: "my-db2"
           }
         },
         spec: {
           containers: [{
             name: "db2",
             image: "db2:11.5.8",
             ports: [{name: "db2", containerPort: 50000}],
             volumeMounts: [{
               name: "data",
               mountPath: "/var/lib/db2"
             }]
           }]
         }
       },
       volumeClaimTemplates: [{
         metadata: {
           name: "data"
         },
         spec: {
           storageClassName: "standard",
           accessModes: ["ReadWriteOnce"],
           resources: {
             requests: {
               storage: "10Gi"
             }
           }
         }
       }]
     }
   }

2. Kubernetes creates Pods:
   Pod "my-db2-0" starts in namespace "default"
   - Container starts running DB2 process
   - PVC "data-my-db2-0" created and mounted
   - Service endpoints updated with pod IP

3. Pod lifecycle:
   - Pending → Running → Ready
   - Health checks pass
   - Status updates propagate back

Result: DB2 database running inside Kubernetes!
```

---

## Complete Timeline

```
T0:     kubectl apply -f db2-example.yaml
        ↓
T1:     Kubernetes stores in etcd
        ↓
T2:     Controller-runtime detects CREATE event
        ↓
T3:     Reconcile() called with:
        req.NamespacedName = "default/my-db2"
        ↓
T4:     Get DB2 object using NamespacedName
        API call: GET /kubedb.dev/db2/default/my-db2
        Returns: DB2 object with name="my-db2", namespace="default"
        ↓
T5:     Validate license for version 11.5.8
        ↓
T6:     Add finalizer to object
        ↓
T7:     Apply defaults to object
        ↓
T8:     Start health checker goroutine
        ↓
T9:     Update phase to "Provisioning"
        ↓
T10:    Check if paused (it's not)
        ↓
T11:    Create network policies
        ↓
T12:    Create Services (headless + client)
        ↓
T13:    Create Secrets (auth + connection)
        ↓
T14:    Create StatefulSet
        ↓
T15:    Kubernetes creates Pod "my-db2-0"
        ↓
T16:    Pod starts DB2 process
        ↓
T17:    Health checker detects ready
        ↓
T18:    Status updated to "Ready"
        ↓
kubectl get db2 my-db2  →  STATUS: Ready
```

---

## Key Data Flow Summary

```
USER INPUT:
├─ metadata.name: "my-db2"
├─ metadata.namespace: "default"
└─ spec.version: "11.5.8"

↓

NamespacedName (Key in Reconcile):
├─ Namespace: "default"
└─ Name: "my-db2"

↓ (Used to fetch objects)

API Server (GET requests):
├─ GET /kubedb.dev/db2/default/my-db2
│   └─ Returns DB2 object
└─ GET /catalog/db2version/11.5.8
    └─ Returns DB2Version

↓

Reconciliation creates:
├─ Service "my-db2" in "default"
├─ Service "my-db2-client" in "default"
├─ Secret "my-db2-auth" in "default"
├─ Secret "my-db2-connection" in "default"
└─ StatefulSet "my-db2" in "default"
    └─ Pod "my-db2-0" in "default"

↓

Final result: kubectl get all -n default
├─ pod/my-db2-0
├─ service/my-db2
├─ service/my-db2-client
├─ statefulset.apps/my-db2
└─ secret/my-db2-auth, my-db2-connection
```

---

## Important Notes

### NamespacedName vs Name

```
NamespacedName:
  - Used in Reconcile() request
  - Format: "namespace/name"
  - Used to uniquely identify cluster resources
  - Example: "default/my-db2"

Name only:
  - Used for cluster-scoped resources
  - Example: DB2Version "11.5.8" (no namespace)
  - No namespace component

Namespace only:
  - Used when creating resources in a specific namespace
  - Example: "default"
```

### What happens on updates?

```
If you change the spec:
  kubectl edit db2 my-db2
  (change replicas from 1 to 3)

↓

Kubernetes updates object in etcd
↓
Controller-runtime detects UPDATE event
↓
Reconcile() called again with same NamespacedName
↓
Steps 4-11 run again (Finalize skipped)
↓
StatefulSet updated from 1 to 3 replicas
↓
Kubernetes creates Pods "my-db2-1" and "my-db2-2"
```

### What happens on deletion?

```
If you delete the DB2:
  kubectl delete db2 my-db2

↓

Kubernetes marks with deletionTimestamp
↓
Controller-runtime detects DELETE event
↓
Reconcile() called with same NamespacedName
↓
ensureFinalizers() runs
  - Detects deletionTimestamp is set
  - Stops health checker
  - Removes finalizer
  - Returns true (abort reconciliation)
↓
Kubernetes deletes:
  - StatefulSet → Pods deleted
  - Services → removed
  - Secrets → removed
  - PVCs → deleted (if policy allows)
  - DB2 object → removed

Result: Clean deletion with no orphaned resources
```


