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
``` 
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

### Cluster Ip Service:




