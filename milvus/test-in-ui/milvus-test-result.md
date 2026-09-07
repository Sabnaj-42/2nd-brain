## Standalone:

### Successful
- All deletionPolicy( Delete, WipeOut, Halt, DoNotTerminate).
- OPS request:
    - updateVersion
    - restart
    - reconfiguration
    - vertical scaling
    - volume-expansion (need longhorn storageClass)

### Issue:
- **storageclass** : after applying longhorn storageClass, UI editor is not showing the storageClass in the dropdown.
- **Monitoring:** UI editor writes only spec.monitor.agent and drops spec.monitor.prometheus.serviceMonitor. serviceMonitor is not creating. So, we need to edit the yaml manually to add serviceMonitor.
-  **Tls:** tls enable is not working. UI doesn't tls related fields. thers no option in UI for choosing tls type(tls, mtls)




## Distributed (few ops-tests are left, will update when test is done)

### Successful
- All deleteionPolicy( Delete, WipeOut, Halt, DoNotTerminate).
- OPS request:
    - updateVersion
  
  

### Issue:
- storageclass, monitoring, tls are same as standalone.
