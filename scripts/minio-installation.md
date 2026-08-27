## Install Minio:

```bash

helm repo add minio https://operator.min.io/
helm upgrade --install --namespace "minio-operator" \
              --create-namespace "kubestash-minio-operator" minio/operator \
              --set operator.replicaCount=1 \
              --wait

helm upgrade --install \
  --namespace "demo" \
  --create-namespace \
  kubestash-minio \
  minio/tenant \
  --set tenant.pools[0].servers=1 \
  --set tenant.pools[0].volumesPerServer=1 \
  --set tenant.pools[0].size=1Gi \
  --set tenant.certificate.requestAutoCert=false \
  --set tenant.pools[0].name="default" \
  --set tenant.buckets[0].name="kubestash" \
  --wait
```

## Kubestash specific Stuff:

```bash

kubectl create secret generic minio-secret --from-literal=AWS_ACCESS_KEY_ID=minio --from-literal=AWS_SECRET_ACCESS_KEY=minio123 -n demo
```

S3 information:
    s3:
      bucket: kubestash
      endpoint: http://minio.demo.svc.cluster.local:80
      secretName: minio-secret
      region: us-east-1
      prefix: sabnaj
