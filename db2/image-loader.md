##  Operator:
```bash
$ make container 

$ docker save sabnaj/db2-operator:hadr_linux_amd64 | \
  ssh ubuntu@10.2.0.255 "sudo ctr images import - && sudo crictl images | \
  grep sabnaj/db2-operator:hadr_linux_amd64 && echo '￼ Image successfully loaded into K3s containerd'"

$ make install IMAGE_PULL_POLICY=IfNotPresent
```
---

## CO-Ordinator:
```bash
$ make container

$ docker save sabnaj/db2-coordinator:db2-script | \
     ssh ubuntu@10.2.0.255 "sudo ctr images import - && sudo crictl images | \
     grep sabnaj/db2-coordinator:db2-script && echo '￼ Image successfully loaded into K3s containerd'"

```
---

## Troubleshot:
```text
Importing	elapsed: 19.6s	total:   0.0 B	(0.0 B/s)	


This means image successfully pushed
```