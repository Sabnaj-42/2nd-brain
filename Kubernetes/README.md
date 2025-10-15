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