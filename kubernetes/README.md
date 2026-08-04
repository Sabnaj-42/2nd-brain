## etcd (etcd = persistent + distributed + strongly consistent key-value store)
In Kubernetes, etcd is the central database (key-value store) that stores all cluster data. It is distributed, consistent key-value store. It used by keubernetes to store c luster con
figuration and state data in a reliable way, It used the Raft consensus algorithm to ensure consistency across multiple etcd nodes (in HA setup).

etcd stores in kubernetes:
- API objects: Pods, Deployments, Services, ConfigMaps, Secrets, etc.
- Cluster configuration: Nodes, namespaces, roles, bindings.
- Status info: Events, resource versions, leader election info, etc.

when "kubectl get pods" command is run:
the kube-apiserver fetches the pod data from etcd (via the kubernetes api)

How It Works in the Control Plane
- An object (like a Deployment) is created or updated via kubectl or the API.
- The kube-apiserver validates the request.
- The apiserver writes the new object’s data into etcd.
- The controllers and schedulers read from etcd to take action (like creating Pods).
- The cluster’s current state is always synced with the desired state stored in etcd.

## Pod anti-Affinity:
- Pod anti-affinity is a Kubernetes scheduling rule that tells the scheduler not to place certain Pods together on the same node (or even in the same zone or rack).
- Its primary purpose is to ensure that certain pods are not co-located on the same node or within the same failure domain (like an availability zone or region), thereby enhancing fault tolerance and resilience.
- Let's assume, we have three replica(web-0, web-1, web-2) of our web app. Without anti-affinity, kubernetes might schedule all three on the same node- it there's enough CPU and memory. In that case, it the node fails -> all three Pods fo down.
- Anti-affinity is done by using level-selector

## Sidecar container
A sidecar container is a helper container that runs alongside the main container in the same Pod in Kubernetes.
Both share:
- The same IP address and port space
- The same volumes
- The same start and stop lifecycle

## Service
In Kubernetes, a Service is an abstraction that defines a stable network endpoint (IP address and DNS name) to access a group of Pods running the same application. Expose Pods (your applicaiton) to other parts of the cluster or to the outside world. Provides a fixed IP and DNS name, even if underlying Pods change. 
``` yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app-service
spec:
  selector:
    app: my-app           # Selects Pods with label "app=my-app"
  ports:
    - protocol: TCP
      port: 80            # Service port
      targetPort: 8080    # Container port
  type: ClusterIP         # Service type

```
This Service sends traffic to all Pods labeled app=my-app on port 8080, and exposes them inside the cluster on port 80.
Types of Service:
1. ClusterIP: Default; exposes the Service only within the cluster - Inside cluster
2. NodePort: Expose the Service on each node's IP at a static port - Inside and ouside cluster (via Node Ip:Port)
3. LoadBalancer: Integrates with cloud provider load balancers - Outside cluster
4. ExternalName: Maps the Service to an external DNS name - Outside service (DNS only)

### 1. Cluster Ip Service:
#### Kubernetes Example: Ingress + Service + Deployment
- Service port is arbitrary 
- Target Port must match the port, the container is listening at

Below is a complete YAML example showing how Ingress, Service, and Deployment work together in Kubernetes:

```yaml
# ---------------------------------------------
# 1️⃣ Deployment: Runs the application Pods
# ---------------------------------------------
apiVersion: apps/v1
kind: Deployment
metadata:
  name: myapp-deployment
  labels:
    app: myapp
spec:
  replicas: 3
  selector:
    matchLabels:
      app: myapp               # Matches Pod label
  template:
    metadata:
      labels:
        app: myapp             # Pod label
    spec:
      containers:
        - name: myapp-container
          image: nginx           # Example application
          ports:
            - containerPort: 8080  # Application listens on 8080 inside the Pod

---
# ---------------------------------------------
# 2️⃣ Service: Exposes the Pods inside cluster
# ---------------------------------------------
apiVersion: v1
kind: Service
metadata:
  name: myapp-service
  labels:
    app: myapp
spec:
  selector:
    app: myapp                 # Matches Deployment's Pod label
  ports:
    - name: http
      port: 80                   # Service exposed port (ClusterIP port)
      targetPort: 8080           # Pod's container port
  type: ClusterIP              # Internal cluster access only

---
# ---------------------------------------------
# 3️⃣ Ingress: Exposes the Service externally
# ---------------------------------------------
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: myapp-ingress
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  rules:
    - host: myapp.example.com     # Replace with your domain
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: myapp-service # Connects to Service name
                port:
                  number: 80        # Matches Service's port (not Pod port)

```
Flow Diagram:
```
Client (browser)
   ↓
Ingress (port 80)
   ↓
Service (port 80 → targetPort 8080)
   ↓
Pod (containerPort 8080)

```

Let's assume we have three replica of a pod and they are deploy in three different node. Then each pod will have different IP but the same port number. When client try to access the application, the service will choose a pod randomly using the label selector. In the pod it will select exact container using the port. <br>
Here is the diagram how it works:
![Cluster IP Service workflow](../images/ClusterIpService.png)

### 2. Headless Service
- Client wants to communicate with 1 specific pod directly
- Pods want to talk directly with specific Pod
- So, not randomly selected
- Use Case: Statefulset application, like database (mysql, mongodb, elasticsearch)
    - Pod replicas are not identical
    - Master and worker node are different. (Only master is allowed to write)
- Client needs to figure out IP address of each Pod
     - DNS lookup is used to do this
         - Set ClusterIP to "None" - return Pod IP address instead of Cluster IP
Example:
```yaml

apiVersion: v1
kind: Service
metadata:
  name: my-headless-service
spec:
  clusterIP: None # This field makes it headless service
  selector:
    app: my-app
  ports:
    - port: 80
      targetPort: 8080
```
- Each pod gets its own DNS Name
```
pod-ip-1.my-headless-service.default.svc.cluster.local
pod-ip-2.my-headless-service.default.svc.cluster.local
pod-ip-3.my-headless-service.default.svc.cluster.local
```
- There is no load balancing; the client can resolve each pod individually.
- Useful for stateful applications like databases, where you need to talk to each pod separately.

### 3. NodePort Service
A NodePort service in Kubernetes is a type of Service that exposes your application to external traffic (outside the cluster) by opening a specific port on every Node in the cluster.

Key points:
1. External access: Each node in the cluster gets a static port (the NodePort) in the range 30000–32767.
2. Routing to pods: Traffic sent to any node’s IP on that NodePort is forwarded to the pods selected by the service (using the selector).
3. ClusterIP included: Behind the scenes, a NodePort service also creates a ClusterIP service to handle pod routing inside the cluster.

Simple example:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-nodeport-service
spec:
  type: NodePort
  selector:
    app: my-app
  ports:
    - port: 80         # Service port inside cluster
      targetPort: 8080 # Container port
      nodePort: 31000  # Port exposed on every node
```
How it works:
```
Client
  |
  |--- NodeIP:31000 ---> Service ---> Pod (port 8080)
  |
NodeIP2:31000 ---> Service ---> Pod (port 8080)

```
***Note:*** Useful for testing or small clusters, but in production, people usually use LoadBalancer or Ingress for external access.

### 4. LoadBalancer Service
A LoadBalancer service in Kubernetes is a type of Service that exposes your application to external traffic by automatically provisioning a cloud provider’s load balancer (if supported) to distribute traffic to your pods.

Key Points:
1. Automatic external access:
   - When you create a LoadBalancer service, Kubernetes asks the cloud provider (AWS, GCP, Azure, etc.) to create a public load balancer.
   - The load balancer gets a public IP or DNS name that clients can access.
2. Traffic routing:
   - Incoming requests to the load balancer are forwarded to the Service, which then distributes them to pods selected by the service selector.
   - Uses ClusterIP internally for pod routing.
3. Port mapping:
   - port → service port inside the cluster
   - targetPort → container port
   - externalPort → port exposed by the cloud load balancer (usually matches port if not specified)
Example:
```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-loadbalancer-service
spec:
  type: LoadBalancer
  selector:
    app: my-app
  ports:
    - port: 80         # Service port
      targetPort: 8080 # Container port 
   ```
How it works:
```
Client
  |
  v
Cloud Load Balancer (public IP)
  |
  v
Kubernetes Service (ClusterIP)
  |
  v
Pods (port 8080)

```
***Note:*** LoadBalancer service Only works in cloud environments that support external load balancers.<br>


** NodePort Service is an extension of ClusterIP service <br>
** LoadBalancer Service is an extension of NodePort Service

## Ingress
In Kubernetes, an Ingress is an API object that manages external access to services within a cluster, typically HTTP and HTTPS traffic. It provides routing rules to direct incoming requests to the appropriate services based on hostnames, paths, or other criteria.
***Ingress Controller:***
- Kubernetes doesn't implement ingress routing itself
- We must deploy an Ingress controller in the cluster (many ingress controllers are available, we need to install them in the cluster)
- The controller watches Ingress objects and configures a load balancer or reverse proxy accordingly.
Example Yaml:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: my-ingress
spec:
  rules:
    - host: example.com
      http:
        paths:
          - path: /app1
            pathType: Prefix
            backend:
              service:
                name: app1-service
                port:
                  number: 80
          - path: /app2
            pathType: Prefix
            backend:
              service:
                name: app2-service
                port:
                  number: 80
```
How it works:
```
Client (browser)
   |
   v
Ingress Controller (e.g., NGINX)
   |
   |-- /app1 --> app1-service --> Pods
   |
   |-- /app2 --> app2-service --> Pods

```
***Note:***
- A single Ingress can route traffic to multiple services.
- To make it work, you must have an Ingress Controller deployed in the cluster.

## Gateway API

## Network Policy
A NetworkPolicy in Kubernetes is a resource that controls how pods communicate with each other and with other network endpoints.
- By default — all pods can talk to each other freely in a Kubernetes cluster.
- Once you create a NetworkPolicy, traffic is DENIED by default unless explicitly allowed by the policy.
***Basic Structure:***
- Pod selector → which pods the policy applies to
- Ingress rules → who can send traffic to those pods
- Egress rules → who those pods can send traffic to

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-frontend-to-backend
spec:
  podSelector:
    matchLabels:
      app: backend     # Policy applies to backend pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend   # Only frontend pods can access backend
      ports:
        - protocol: TCP
          port: 80
```
- This policy applies to pods labeled app=backend.
- Only pods labeled app=frontend are allowed to connect to them on port 80.
- All other pods are blocked.


## Admission Controller
- In Kubernetes, an admission controller is like a gatekeeper.
- Whenever someone tries to create, update, or delete something in the cluster (like a Pod or Deployment), the gatekeeper checks the request before it’s saved.

- If this gatekeeper is built using your own code running as a web service, it’s called an Admission Webhook.
- That means Kubernetes sends the request to your service first, so your program can check it, change it, or even reject it before it’s stored in the cluster etcd storage.


## Kubebuilder
- Kubebuilder is a framework for building Kubernetes APIs (custom controllers and CRDs) using the Go programming language.<br>
- It is built on top of controller-runtime and helps scaffold and manage:
    - Custom Resource Definition (CRDs)
    - Controller and reconcilers
    - Webhook
    - Deepcopy and client code generation<br>
  
**Kubebuilder project structure:**
```bash
demo/
├── Makefile
├── PROJECT
├── go.mod
├── go.sum
├── main.go
│
├── api/
│   └── v1/
│       ├── foo_types.go
│       ├── groupversion_info.go
│       └── zz_generated.deepcopy.go
│
├── controllers/
│   └── foo_controller.go
│
└── config/
    ├── crd/
    │   └── bases/
    │       └── apps.mydomain.com_foos.yaml
    ├── default/
    ├── manager/
    ├── rbac/
    ├── samples/
    │   └── apps_v1_foo.yaml
    └── webhook/


```
1. kubebuilder init --domain=my.com --repo=example.com/demo  
    - This command initializes a new Kubebuilder project — i.e., it sets up the basic folder structure, configuration files, and boilerplate code needed to start building a Kubernetes controller/operator.
    - --domain my.com  --> defines the API group domain for CRDs. my.com becomes the suffix for API groups: apps.my.com/v1alpha1
    - --repo=example.com/demo  --> Used in go.mod and import path throughout the codebase
    - Lets assume, we ran the command in "Kubebuilder" directory. <br>
**Whats get generated:**
   ```bash
    Kubebuilder/
    ├── Dockerfile                    # Container image build instructions
    ├── Makefile                      # Common development tasks
    ├── PROJECT                       # Kubebuilder project metadata
    ├── go.mod                        # Go module definition
    ├── main.go                       # Operator entry point
    ├── config/                       # Kubernetes manifests for deployment
    │   ├── rbac/                     # Role-based access control
    │   ├── manager/                  # Controller manager deployment
    │   ├── prometheus/               # ServiceMonitor for metrics
    │   └── default/                  # Kustomize base
    ├── hack/                         # Utility scripts
    │   └── boilerplate.go.txt        # License headers
    └── .gitignore

   ```
2. kubebuilder create api --group apps --version v1alpha1 --kind BookServer
    - Create API/Controller
      - --group apps
         - Defines the API group: apps.my.domain (combines with your domain from init)
         - Groups related APIs together (e.g., apps, batch, storage)
      - --version v1alpha1
         - Sets the API version for your resource
         - v1alpha1 = first alpha version (indicates it's experimental and may change)
      - --kind BookServer
         - The resource type name (like Pod, Deployment, Service)
         - Your users will create BookServer resources <br>
**What gets generated:**
    ```bash
    ├── api/v1alpha1/
    │   ├── bookserver_types.go      # CRD structure (Spec, Status)
    │   ├── bookserver_webhook.go    # Validation/mutation webhooks
    │   └── groupversion_info.go     # API registration
    ├── controllers/
    │   └── bookserver_controller.go # Reconciliation logic
    ├── config/crd/
    │   └── bases/
    │       └── apps.my.domain_bookservers.yaml  # Generated CRD manifest
    ├── config/rbac/
    │   ├── bookserver_editor_role.yaml
    │   ├── bookserver_viewer_role.yaml
    │   └── role.yaml                 # Controller permissions
    └── config/samples/
    └── apps_v1alpha1_bookserver.yaml        # Example resource
   ```
**Next steps:**
1. Define your API in api/v1alpha1/bookserver_types.go (add fields to BookServerSpec and BookServerStatus)
2. Generate CRD manifests
   ```bash
    make manifests
   ```
3. Implement controller logic in controllers/bookserver_controller.go (the Reconcile() method)
4. Install CRD and run
     ```bash
      make install run 
    ```

### Steps of running kubebuilder project by pushing controller image into docker hub
1. Implement logic into api/v1/types.go and controllers/controller.go file
2. Generate code and manifests
 ```bash
  make manifests
  ```
3. Install CRDs into the cluster 
  ```bash
  make install 
  ```
4. Build and push the operator image
  ```bash
 make docker-build IMG=<your-dockerhub-username>/<image-name>:<tag>
 make docker-push IMG=<your-dockerhub-username>/<image-name>:<tag>
  ```
5. Update image reference in the deployment
   - config/manager/manger.yaml -> spec.image field
6. Deploy the controller manager
    ```bash
     make deploy IMG=<your-dockerhub-username>/<image-name>:<tag>
    ```
7. create and apply custom resource(create an object)
  ```bash
 kubectl apply -f bookserver.yaml
  ```

### Run the kubebuilder project without pushing the controller image into docker hub
1. Complete writing types go and controller
2. Run belows commands
   ```bash
   make manifests  #generate CRDs and rbac
   make install    #apply crd to your cluseter
   make run        #run the controller locally
   ```
3. Build docker image of the CRD project
 ```bash
  make docker-build 
 ```
4. Load the image to kind cluster
  ```bash
  kind load docker-image sabnaj/db2-controller:latest   #value for IMG variable is set in Makefile as: sabnaj/db2-controller:latest
  ```
5. 
  ```bash
  make manifests
  ```
6. Run the controller/operator in the cluster
   ```bash
   make deploy
   ```
7. Create an object of this crd type (let's assume "db2-obj.yaml)
8. Apply the object into the cluster
  ```bash
  kubctl apply -f db2-obj.yaml
  ```

## Operator Reconciliation Flow   
**Flow Diagram**
![Kubernetes_Operator_Flow_Diagram](../images/reconciliation_loop_flow_diagram.png)

1. User create db2 object and apply the object
```bash
   kubectl apply -f db2-instance.yaml
  ```
| Step | Component             | Action                                                    | Success                             | Failure                      |
| ---- | --------------------- | --------------------------------------------------------- | ----------------------------------- | ---------------------------- |
| 1    | `kubectl`             | Send DB2 CR YAML to API Server                            | -                                   | Network error                |
| 2    | **API Server**        | Parse and route to admission controllers                  | -                                   | Malformed YAML               |
| 3    | **MutatingWebhook**   | Set defaults: `storageSize`, `db2Version`, add finalizers | Object mutated                      | **REJECT** (if webhook down) |
| 4    | **ValidatingWebhook** | Validate: version supported, resource limits, RBAC        | Validation pass                     | **REJECT** (config rejected) |
| 5    | **API Server**        | Store final object in etcd                                | CR created (deletionTimestamp=null) | Store error (rare)           |
 **Result:**   DB2 CR exists but no resources are created yet.
 
2. DB2 Controller's **watch** detects the new object(via informer) and the object is added to DB2 controller's workqueue.
3. DB2 Controller Reconciliation loop(your controller): The DB2 controller processes the object from it's workqueue.
```bash
     //Pseudocode of your controller's Reconcile() function
    func (r *DB2Reconciler) Reconcile(ctx context.Context, req ctrl.Request) (ctrl.Result, error) {
        db2 := &v1alpha1.DB2{}
        r.Get(ctx, req.NamespacedName, db2)
        
        // 1. Create Secret (if not exists)
        secret := generateSecret(db2)
        r.Create(ctx, secret)  // First resource created
        
        // 2. Create Service (Headless) (if not exists)
        service := generateService(db2)
        r.Create(ctx, service)  // Second resource created
        
        // 3. Create StatefulSet (formerly PetSet) (if not exists)
        sts := generateStatefulSet(db2, secret)
        r.Create(ctx, sts)  // Third resource created
        
        return ctrl.Result{}, nil
    }
```
Order is critical due to dependencies:
- Secret → Contains passwords (mounted by StatefulSet pods)
- Service → Network identity (referenced by StatefulSet for DNS
- Petset → Creates pods (depends on Secret & Service)
4. After your controller creates the Petset, the Petset Controller (built into kube-controller-manager) takes over:
    - Petset controller creates pods sequentially (not parallel). It waits for Pod-0 to be Running & Ready before creating Pod-1.
5. Pod creation and container startup:
  - Pod Spec (Generated by Petset)
   ```bash
    apiVersion: v1
kind: Pod
metadata:
  name: db2-0  # Predictable name: {Petset-name}-{ordinal}
  namespace: db2-system
spec:
  containers:
  - name: db2-main  # Main DB2 container
    image: ibmcom/db2:latest
    volumeMounts:
    - name: db2-secret
      mountPath: /etc/db2/secrets
    - name: db2-data
      mountPath: /database/data
    envFrom:
    - secretRef:
        name: db2-secret
    
  - name: db2-sidecar  # Sidecar container
    image: your-db2-sidecar:latest
    command: ["/bin/sidecar"]
    volumeMounts:
    - name: db2-data
      mountPath: /database/data
    
  volumes:
  - name: db2-secret
    secret:
      secretName: db2-secret  # Created by your controller
  - name: db2-data
    persistentVolumeClaim:
      claimName: db2-data-db2-0  # Auto-created by Petset
   ```
**Container Startup Order in Pod:**
- Init Containers (if any) run sequentially to completion
- Main containers start simultaneously:
  - db2-main starts
  - db2-sidecar starts
- PostStart hooks execute (if defined)<br>
<br>
**Important:** Sidecar and main containers start at the same time. They are not sequenced by Kubernetes. Your sidecar must handle the case where DB2 is not yet ready.
6. Since containers starts simultaneously, your sidecar must wait for DB2 readiness
7. Final stage and Ongoing Reconciliation <br>
**After initial creation, three controllers are watching:**

| Controller            | Watches          | Action                             |
|-----------------------| ---------------- | ---------------------------------- |
| **DB2 Controller**    | DB2 CR changes   | Updates Secret/Service/StatefulSet |
| **Petset Controller** | Pod state        | Re-creates failed pods, scales     |
| **Kubelet**           | Container health | Restarts crashed containers        |

**If you delete the DB2 CR:**
- Your controller sees the deletion (foreground/background cascade)
- It deletes Petset first (cascade=orphan option can change this)
- Petset controller deletes pods
- PVCs are NOT deleted (Petset behavior for data safety)
- Finalizer on your DB2 CR blocks deletion until cleanup completes

**Complete Timeline Diagram**
```bash
T+0s   User: kubectl apply -f db2.yaml
       │
       ▼
T+0.1s API Server: DB2 CR stored in etcd
       │
       ▼
T+0.2s DB2 Controller: Detects new CR (informer event)
       │
       ▼
T+0.5s DB2 Controller: CREATE Secret (no dependencies)
       │
       ▼
T+0.6s DB2 Controller: CREATE Service (no dependencies)
       │
       ▼
T+0.7s DB2 Controller: CREATE StatefulSet (depends on Secret/Service)
       │
       ▼
T+1.0s StatefulSet Controller: Detects new StatefulSet
       │
       ▼
T+1.5s StatefulSet Controller: CREATE Pod db2-0
       │
       ▼
T+3.0s Kubelet: Pull images, start containers (db2-main + sidecar)
       │
       ▼
T+10s  db2-main: DB2 instance starts
       │
       ▼
T+12s  sidecar: Detects DB2 ready, configures standby
       │
       ▼
T+15s  Pod db2-0: Status becomes "Running" and "Ready"
       │
       ▼
T+16s  StatefulSet Controller: Creates Pod db2-1 (if replicas > 1)
       │
       ▼
T+30s  All pods ready. Application can connect to db2-0.db2-service.db2-system.svc.cluster.local

```

## Marshal and Unmarshal in Go
- In Go, "marshalling" is the process of converting a Go data structure (like a struct or map) into a format that can be easily stored or transmitted, such as JSON or yaml.
- "Unmarshalling" is the reverse process, where you take data in a specific format (like JSON or yaml) and convert it back into a Go data structure.
 
***NB***: Unmarshaling is how Kubernetes transforms your YAML files into the Go objects that controllers actually work with.

 ```
    # When you apply YAML, the API server:
    1. Unmarshals YAML → Go struct
    2. Validates against OpenAPI schema (generated from your markers)
    3. Marshals back to JSON for storage in etcd
    4. Controller unmarshals from etcd when reconciling.
    
 ```