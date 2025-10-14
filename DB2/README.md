## DB2 Resources
- pdf pages: https://www.ibm.com/support/pages/node/627743



## DB2 POC

### HADR-High Availability Disaster Recovery
HADR 4 mode: Sync, Nearsync, Async, Supersync

**SYNC :** 🔒 Highest protection | 🐢 Slowest performance
- A transaction is committed only after the log is written to both the primary and standby disks, and an acknowledgment is received from the standby.
- If the standby fails, it can recover logs from its own files; if the primary fails, failover ensures no data loss.

**NEARSYNC :** ⚖️ Good protection | 🚶‍♂️ Faster than SYNC
- Transaction is committed when:
    - Logs are written to the primary disk, and
    - Standby acknowledges they’ve been received in memory (not yet written to disk).
- Data loss occurs only if both primary and standby fail before standby writes logs to disk.
- Possible log loss if standby crashes before flushing memory to disk.

**ASYNC(Asynchronous Mode) :** ⚡ Faster transactions | ⚠️ Higher data loss risk
- Primary commits after writing logs locally and sending them to the network (TCP layer),
  without waiting for standby acknowledgment.
- Data in transit may be lost if the primary or network fails.
- Standby can catch up later if primary survives, but if failover occurs, some transactions are lost.

**SUPERASYNC :** 🚀 Fastest performance | ❌ Lowest protection
- Primary commits as soon as logs are written locally — no waiting for standby at all.
- Standby always lags behind; the log gap can become large.
- If failover happens, all logs not yet replicated are lost permanently.
- Best suited for cases where performance and availability are prioritized over data protection (e.g., long-distance disaster recovery).

SYNC and NEARSYNC modes are typically used on LAN. ASYNC and SUPERASYNC modes are typically used over WAN.