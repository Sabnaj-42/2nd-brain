# Testing Cassandra storage-migration

## export:  export KUBECONFIG=/home/sabnaj/k3s.yaml
- Now you can run all command in my virtual machine k3s cluster

## Image build
- There are two project 
    - /home/sabnaj/go/src/kubedb.dev/ops-manager  this one is for ops-request
    - /home/sabnaj/go/src/kubedb.dev/provisioner this one is for provisioner operator

- In these both project go to the go.mod file and In this line 	kubedb.dev/cassandra v0.17.1-0.20260515163629-7fc107b1c7d1 change the tag with this : 7fc107b1c7d13c40893e7946b607bd3d27a10514
- In both project run : go mod tidy && go mod vendor
- Run :  export REGISTRY=sabnaj
- Then build and push image in both project: Run: make push
- Now use this two image tag in:
    - in my cluster 5 pods are running in kubedb namesapce: 
        - in provisoner pod: replace the image with the built provisoner image and ops-manager pod image with the built ops-manager image


## Apply a bsic cassandra yaml
- Ar first apply all crds related to cassandra from this directory: /home/sabnaj/go/src/kubedb.dev/apimachinery/crds/ 

``` yaml
apiVersion: kubedb.com/v1alpha2
kind: Cassandra
metadata:
  name: cassandra-quickstart
  namespace: demo
spec:
  deletionPolicy: Delete
  topology:
    rack:
    - name: r0
      replicas: 2
      storage:
        storageClassName: "local-path"
        accessModes:
        - ReadWriteOnce
        resources:
          requests:
            storage: 600Mi
  version: 5.0.7


```
- when the database go to the ready state apply the below yaml to test storage migration: 

```yaml
apiVersion: ops.kubedb.com/v1alpha1
kind: CassandraOpsRequest
metadata:
  name: storage-migration
  namespace: demo
spec:
  type: StorageMigration
  databaseRef:
    name: cassandra-quickstart
  timeout: 10m
  migration:
    storageClassName: standard-custom
    oldPVReclaimPolicy: Delete

```
- Now to chek if the test is successful or not: 
    - see if the database status is successful
    - Also check the database yaml if the corresponding storage migration field is changed or not

