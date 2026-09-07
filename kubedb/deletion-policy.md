                         KubeDB Database
                               │
              ┌────────────────┼────────────────┐
              │                │                │
           Delete           WipeOut          Halt
              │                │                │
              ▼                ▼                ▼
          🗑️ DELETE        💥 DELETE         ⏸️ STOP
              │                │                │
       DB/Pods ❌         DB/Pods ❌       DB/Pods ⏸️
       Service ❌         Service ❌       Service ✅
       Secret ❌          Secret ❌        Secret ✅
       PVC ✅             PVC ❌           PVC ✅
       Data ✅            Data ❌          Data ✅


                         KubeDB Database
                               │
                               ▼
                       DoNotTerminate
                               │
                               ▼
                          🛡️ PROTECT
                               │
                       DB/Pods ✅
                       Service  ✅
                       Secret   ✅
                       PVC      ✅
                       Data     ✅