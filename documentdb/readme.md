## PostgreSQL is running on port 9712 and mongoDB wire protocol is running on port 10260. 
- Your application connects to port 10260 using MongoDB protocol (wire protocol)
- The MongoDB Gateway translates MongoDB commands to PostgreSQL
- The Gateway then talks to PostgreSQL on port 9712 internally
- PostgreSQL stores the actual data
- We only expose the MongoDB port (10260) to the outside world, while PostgreSQL remains hidden and secure within the DocumentDB architecture. 

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


## Running document db image in docker container and inserting data using  mongos shell

```bash
# Pull the latest DocumentDB Docker image
   docker pull ghcr.io/documentdb/documentdb/documentdb-local:latest

# Tag the image for con
docker tag ghcr.io/documentdb/documentdb/documentdb-local:latest documentdb

# Run the container with your chosen username and password
docker run -dt -p 10260:10260 --name documentdb-container documentdb --username <YOUR_USERNAME> --password <YOUR_PASSWORD>

#Remove the pulled image to free up space, since we have tagged it as 'documentdb' and can use that for future runs.
docker image rm -f ghcr.io/documentdb/documentdb/documentdb-local:latest || echo "No existing documentdb image to remove"
# eg: docker run -dt -p 10260:10260 --name documentdb-container documentdb --username default_user --password documentdb
```
**Note: Replace <YOUR_USERNAME> and <YOUR_PASSWORD> with your desired credentials. You must set these when creating the container for authentication to work. <br>
Port Note: Port 10260 is used by default in these instructions to avoid conflicts with other local database services. You can use port 27017 (the standard MongoDB port) or any other available port if you prefer. If you do, be sure to update the port number in both your docker run command and your connection string accordingly.**

## connect to the running container and open mongosh shell to insert data

```bash
# Connect to the running container to the port, where the document db process is running
mongosh "mongodb://default_user:1234@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"
```
## To connect with the standby pod 
```bash
mongosh 'mongodb://default_user:d*t1dTkqXR!QLN!o@dcdb.demo.svc:10260/?tls=true&tlsAllowInvalidCertificates=true'
#dcdb.demo.svc is the service_name.namespace_name.svc
```
## connect inside the container by pod exec command and open mongosh shell to insert data

```bash
 kubectl exec -it documentdb-0 -n demo -- mongosh "mongodb://default_user:1234@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"
```
## inside the contianer mongosh shell, create a database and collection, then insert a document

```javascript
// Create a database and collection
use quickStartDatabase
db.createCollection("quickStartCollection")
db.quickStartCollection.insertOne({
     name: "John Doe",
     email: "john@example.com",
     age: 30,
     createdAt: new Date()
})

db.quickStartCollection.find() // it will show the inserted document

```

## Connecting with postgres 
- Postgres is running on port 9712
```bash
kubectl exec -it documentdb-0 -n demo -- psql -U documentdb -d postgres -p 9712
# now we can run postgres commands
```
- create db mydb
```sql
CREATE DATABASE mydb;
```
- connect to mydb
```sql
\c mydb
```
- create table users
```sql
CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(100) NOT NULL,
    email VARCHAR(100) NOT NULL UNIQUE,
    age INT
);
```
- insert data into users table
```sql
INSERT INTO users (name, email, age) VALUES ('John Doe', 'sabnaj.cpm', 30);
```
- query data from users table
```sql
SELECT * FROM users;
```
