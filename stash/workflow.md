Backup

```
                         ┌─────────────────┐
                         │     YOU         │
                         └────────┬────────┘
                                  │
                                  │ create
                                  ▼
                       ┌─────────────────────┐
                       │ BackupConfiguration │
                       └──────────┬──────────┘
                                  │
                    ┌─────────────┼──────────────┐
                    │             │              │
                    ▼             ▼              ▼
               Repository      Addon          Schedule
                    │             │              │
                    │             │              ▼
                    │             │           CronJob
                    │             │              │
                    │             │              ▼
                    │             │       BackupSession
                    │             │              │
                    │             │              ▼
                    │             │          Snapshot
                    │             │              │
                    │             ▼              │
                    │          Function          │
                    │             │              │
                    └─────────────┼──────────────┘
                                  │
                                  ▼
                            Backup Job
                                  │
                                  ▼
                            Backup Data
                                  │
                                  ▼
                         ┌─────────────────┐
                         │ BackupStorage   │
                         └────────┬────────┘
                                  │
                                  ▼
                              MinIO/S3
```

Restore:

```
                Snapshot
                    │
                    ▼
             RestoreSession
                    │
                    ▼
              KubeStash Operator
                    │
             ┌──────┴──────┐
             ▼             ▼
           Addon        Function
             │             │
             └──────┬──────┘
                    ▼
               Restore Job
                    │
                    ▼
               Target PVC
```