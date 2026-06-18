# Metrics Installation for DocumentDB Autoscaler

This doc lists the steps to install the two metrics backends the DocumentDB
autoscaler depends on:

| Backend | API it serves | Unblocks |
|---|---|---|
| **metrics-server** | `metrics.k8s.io/v1beta1` (pod/node CPU+memory) | **Compute** autoscaling (VPA recommendations) |
| **storage-metrics-apiserver** | `custom.metrics.k8s.io/v1beta1` + `v1beta2` (per-PVC volume stats) | **Storage** autoscaling (VolumeExpansion ops) |

> **Do NOT run these yet.** This file is just the installation prompt/recipe.
> Run it later when you are ready to test the autoscaler.

Local source repos (already cloned on this machine):
- metrics-server chart: `/home/sabnaj/go/src/kubeops.dev/metrics-server/charts/metrics-server`
- storage-metrics chart: `/home/sabnaj/go/src/kubeops.dev/storage-metrics-apiserver/charts/storage-metrics-apiserver`

Prerequisites: `helm` and `kubectl` in PATH, cluster reachable.

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
```

---

## 1. metrics-server (compute)

Serves `v1beta1.metrics.k8s.io`. Required for compute (CPU/memory) autoscaling.

> **k3s note:** k3s ships a bundled metrics-server in `kube-system`. If
> `kubectl get apiservice v1beta1.metrics.k8s.io` already shows `AVAILABLE=True`,
> you can SKIP this section. Installing a second one will conflict over the same
> APIService — only do this if the bundled one is absent/disabled.

Check first:

```bash
kubectl get apiservice v1beta1.metrics.k8s.io
kubectl top nodes        # works only if metrics-server is healthy
```

Install (chart appVersion 0.8.0). `--kubelet-insecure-tls` is needed on k3s
because kubelet serves a self-signed cert:

```bash
helm install metrics-server \
  /home/sabnaj/go/src/kubeops.dev/metrics-server/charts/metrics-server \
  --namespace kube-system \
  --set 'args[0]=--kubelet-insecure-tls'
```

Defaults from the chart's `values.yaml` already include:
`--kubelet-preferred-address-types=InternalIP,ExternalIP,Hostname`,
`--kubelet-use-node-status-port`, `--metric-resolution=15s`, and the APIService
is created with `insecureSkipTLSVerify: true`.

### Verify

```bash
# APIService must show AVAILABLE=True (give it ~30-60s)
kubectl get apiservice v1beta1.metrics.k8s.io

kubectl get pods -n kube-system -l app.kubernetes.io/name=metrics-server

# Should print real numbers, not "error: metrics not available yet"
kubectl top nodes
kubectl top pods -n demo
```

---

## 2. storage-metrics-apiserver (storage)

Registers `v1beta1.custom.metrics.k8s.io` AND `v1beta2.custom.metrics.k8s.io`,
exposing per-PVC volume stats. Required for storage autoscaling — metrics-server
alone is NOT enough.

Default image: `ghcr.io/arnobkumarsaha/storage-metrics-apiserver:dev`.
`--kubelet-insecure-tls` is on by default in the chart's `extraArgs` (safe for
k3s/dev; remove for production).

```bash
kubectl create namespace storage-metrics

helm install storage-metrics-apiserver \
  /home/sabnaj/go/src/kubeops.dev/storage-metrics-apiserver/charts/storage-metrics-apiserver \
  --namespace storage-metrics
```

### Verify

```bash
# Both must show AVAILABLE=True (~30s)
kubectl get apiservice v1beta2.custom.metrics.k8s.io
kubectl get apiservice v1beta1.custom.metrics.k8s.io

kubectl get pods -n storage-metrics
```

### Query the PVC metrics

```bash
# All available custom-metrics endpoints
kubectl get --raw "/apis/custom.metrics.k8s.io/v1beta2" | jq .

# Usage % for one PVC (milli units; 1000m = 100%) -- this is what the
# storage autoscaler reads against usageThreshold.
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/persistentvolumeclaims/<pvc-name>/volume_used_percentage" \
  | jq .

# All PVCs in a namespace for one metric
kubectl get --raw \
  "/apis/custom.metrics.k8s.io/v1beta2/namespaces/demo/persistentvolumeclaims/*/volume_used_bytes" \
  | jq .
```

Available metric names on the `persistentvolumeclaims` resource:
`volume_capacity_bytes`, `volume_available_bytes`, `volume_used_bytes`,
`volume_used_percentage` (milli; 1000m = 100%), `volume_inodes`,
`volume_inodes_free`, `volume_inodes_used`, `volume_inodes_used_percentage`.

---

## 3. Uninstall (cleanup)

```bash
helm uninstall storage-metrics-apiserver -n storage-metrics
kubectl delete namespace storage-metrics

# Only if YOU installed metrics-server (don't remove the k3s-bundled one)
helm uninstall metrics-server -n kube-system
```

---

## Mapping back to the autoscaler tests

- `compute-autoscaler.yaml` / compute half of `combined-autoscaler.yaml` → needs **§1**.
- `storage-autoscaler.yaml` / storage half of `combined-autoscaler.yaml` → needs **§2** (plus an expandable StorageClass via `object-longhorn.yaml`).
</content>
