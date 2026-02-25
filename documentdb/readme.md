## DocumentDB(NOSQL): 
Fully managed and scalable document database service that supports mongodb workloads. It provides high availability, security, and performance for applications that require flexible schema and rich query capabilities. DocumentDB is designed to handle large volumes of unstructured data and is ideal for use cases such as content management, catalogs, user profiles, and real-time analytics. With DocumentDB, developers can focus on building applications without worrying about database management tasks.


**Fully managed:** That means the cloud provider takes care of all the operational aspects of running the database, such as provisioning, patching, backups, and scaling. You don't have to worry about managing the underlying infrastructure or performing routine maintenance tasks.<br>
**Mongodb Compatibility:** DocumentDB is designed to be compatible with MongoDB workloads, which means you can use the same MongoDB drivers and tools to interact with DocumentDB. This allows you to easily migrate existing MongoDB applications to DocumentDB without making significant changes to your code.<br>

Architecture:
1. DocumentDB has two major parts:
- Compute Layer → Handles MongoDB API compatibility
- Storage Layer → Distributed, replicated storage system (Aurora-based)<br>
     **Only Log writes is sent from compute layer to storage layer. All reads are served from compute layer cache. This architecture allows for high performance and scalability while maintaining data durability and availability.**
2. Replication: DocumentDB replicates data across multiple availability zones (AZs) to ensure high availability and durability. This means that if one AZ goes down, your data is still available in another AZ, minimizing downtime and data loss.<br>
3. Durability: DocumentDB uses a distributed storage system that provides durability and fault tolerance. Data is automatically replicated across multiple nodes, and the system is designed to handle node failures without losing data.<br>
4. Backup: DocumentDB provides automated backups that are stored in a secure and durable manner. You can also take manual snapshots of your database at any time, which can be used for point-in-time recovery or to create new instances.<br>
   **Applications talk to DocumentDB using MongoDB drivers.<br>
   Internally, AWS uses Aurora-style storage (inspired by PostgreSQL).**<br>
