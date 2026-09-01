# DocumentDB logical backup/restore driven entirely by the gateway user — VERIFIED

**Date:** 2026-08-31 · **Cluster:** k3s `sabnaj` · **Namespace:** `ddb-logical` (created and torn down)
**Version:** `pg17-0.109.0` (`ghcr.io/documentdb/documentdb/documentdb-local:pg17-0.109.0`, init `ghcr.io/kubedb/documentdb-init:0.1.0`)
**Status:** ✅ both restore paths verified byte-identical to source. No code changed in any repo.

Follow-up to `documentdb-handson-backup.md` finding **F1** ("pg_dump silently loses the collection
catalog"). That run used the Postgres superuser `documentdb` from `<db>-admin-auth`. This run does
the whole thing as the **gateway user `default_user`** from `<db>-auth`, and closes the catalog gap.

---

## 0. Headline results

| | |
|---|---|
| Gateway user is sufficient for a full logical backup **and** restore | ✅ yes — no superuser needed anywhere |
| `pg_dump` archive contains catalog entries | ❌ **0 of 42 TOC entries** |
| Path A (id-preserving catalog copy) | ✅ fingerprint identical to source |
| Path B (recreate via gateway, remap ids) | ✅ fingerprint identical to source |
| Gateway restart needed to see restored catalog | ❌ **not needed** — catalog is read live per query |
| Superuser `documentdb` can reach the gateway | ❌ `MongoServerError: Username is invalid.` |

---

## 1. Why it has to be the gateway user

The gateway config (`/home/documentdb/gateway/pg_documentdb_gw/target/SetupConfiguration_temp.json`)
carries:

```json
"BlockedRolePrefixes": ["documentdb", "citus", "pg", "internal_role"]
```

So the `<db>-admin-auth` superuser **cannot authenticate over the Mongo wire at all**:

```
$ mongosh "mongodb://documentdb:<admin-pw>@127.0.0.1:10260/?...tls=true..."
MongoServerError: Username is invalid.
```

while `<db>-auth` / `default_user` works normally. Any addon that has to both move Postgres bytes
*and* verify through the wire protocol therefore wants `default_user`, not the superuser.

### `default_user` has exactly the privileges needed

Not an accident — upstream `pg_documentdb/sql/rbac/extension_admin_setup--0.10-0.sql` grants them to
`documentdb_admin_role`, and `documentdb_api.create_user(... clusterAdmin + readWriteAnyDatabase ...)`
makes `default_user` a member of that role.

| object | `default_user` |
|---|---|
| schema `documentdb_data` | USAGE + **CREATE** |
| schema `documentdb_api_catalog` | USAGE (no CREATE — only INSERT is needed) |
| `collections`, `collection_indexes`, `documentdb_index_queue` | SELECT / INSERT / UPDATE / DELETE |
| `collections_collection_id_seq`, `collection_indexes_index_id_seq` | SELECT + UPDATE (`setval`) |
| `documentdb_data.documents_*`, `retry_*` | SELECT + INSERT (owner `documentdb_admin_role`, and `default_user` is a member, so `ALTER TABLE ... OWNER TO documentdb_admin_role` in the dump replays fine) |

Verified live:

```sql
select nspname, has_schema_privilege('default_user',nspname,'CREATE') from pg_namespace
 where nspname like 'documentdb%';
--  documentdb_data        | t
--  documentdb_api_catalog | f    <- fine, we only INSERT
```

---

## 2. Root cause, re-confirmed at the archive level

```sql
select e.extname, e.extconfig from pg_extension e where e.extconfig is not null;
--  pg_cron | {16484,16483,16503,16502}
--  postgis | {17178}
--  (documentdb: absent — extconfig IS NULL)
```

```
documentdb_api_catalog.collections                     -> pg_depend deptype='e' (extension member)
documentdb_api_catalog.collection_indexes              -> extension member
documentdb_api_catalog.documentdb_index_queue          -> extension member
documentdb_api_catalog.collections_collection_id_seq   -> extension member
documentdb_api_catalog.collection_indexes_index_id_seq -> extension member
documentdb_data.documents_N / retry_N                  -> NOT extension members
```

PostgreSQL never dumps extension-owned table **data** unless the extension registers it with
`pg_extension_config_dump()`. `pg_cron` and `postgis` do; `documentdb` does not.

```
$ pg_restore -l documentdb_data.pgc
;     TOC Entries: 42
$ pg_restore -l documentdb_data.pgc | grep -c documentdb_api_catalog
0
```

**Upstream fix** would be, in the extension SQL:

```sql
SELECT pg_catalog.pg_extension_config_dump('documentdb_api_catalog.collections', '');
SELECT pg_catalog.pg_extension_config_dump('documentdb_api_catalog.collection_indexes', '');
SELECT pg_catalog.pg_extension_config_dump('documentdb_api_catalog.roles', '');
SELECT pg_catalog.pg_extension_config_dump('documentdb_api_catalog.collections_collection_id_seq', '');
SELECT pg_catalog.pg_extension_config_dump('documentdb_api_catalog.collection_indexes_index_id_seq', '');
```

---

## 3. Negative control — the original failure, reproduced on demand

`dcdb-dst-c`: fresh instance, `pg_restore` of the `documentdb_data` archive **only**, no catalog step.

```
pg_restore exit=0                     <- silent success, no warning

-- SQL layer: the documents ARE physically there
documents_4 = 1000 rows
documents_5 =  250 rows

-- Catalog layer
1 kubedb_system/system.dbSentinel
2 kubedb_system/health_check          <- nothing maps to documents_4 / documents_5

-- MongoDB layer: what the user sees
databases   = ["kubedb_system"]
collections = []
orders      = 0
customers   = 0
```

🔴 1,250 documents restored into Postgres, `shopdb` does not exist over the wire. Backup job
succeeded, restore job succeeded, database lost. This is F1, on demand, in under a minute.

---

## 4. Test dataset

Mongo db `shopdb`, seeded **through the gateway** as `default_user`:

- `orders` — 1000 docs: ObjectId `_id`, NumberInt, **NumberDecimal**, string, **ISODate**, array,
  nested subdocument, **BinData**, NumberLong, one explicit `null`, one absent field.
- `customers` — 250 docs.
- Indexes: `orders {region:1, ts:-1}` (`region_ts_idx`), `customers {email:1} unique` (`email_uniq_idx`).

Source SQL mapping:

```
kubedb_system | system.dbSentinel | id=1
kubedb_system | health_check      | id=2
shopdb        | system.dbSentinel | id=3
shopdb        | orders            | id=4    -> documents_4, 1000 rows
shopdb        | customers         | id=5    -> documents_5,  250 rows
coll_seq=5  idx_seq=7
```

Note the gateway creates a per-database `system.dbSentinel` collection; it consumes a
`collection_id` and must be carried (or recreated) like any other.

---

## 5. Backup — every command as `default_user`

Artifacts are base64-wrapped **inside the pod** so binary survives `kubectl exec`, and md5-verified
on both sides. No file is left in the pod, no Kubernetes object is created.

```bash
NS=ddb-logical
gwpw() { kubectl get secret -n $NS $1-auth -o jsonpath='{.data.password}' | base64 -d; }
PW="$(gwpw dcdb-src)"
```

**5a — document data + DDL** (66,947 bytes)

```bash
kubectl exec -n $NS dcdb-src-0 -c documentdb -- env PGPASSWORD="$PW" bash -c \
  'pg_dump -h 127.0.0.1 -p 9712 -U default_user -d postgres -Fc -n documentdb_data | base64 -w0' \
  | base64 -d > documentdb_data.pgc
```

**5b — the gateway catalog, which `pg_dump` refuses to touch** (436 + 1,071 bytes)

`FORMAT binary` is mandatory: `~/.psqlrc` sets `documentdb_core.bsonUseEJson=true`, so text COPY of
a `bson` column is not round-trippable. `-X` bypasses `.psqlrc` entirely.

```bash
for t in collections collection_indexes; do
  kubectl exec -n $NS dcdb-src-0 -c documentdb -- env PGPASSWORD="$PW" bash -c \
    "psql -X -q -h 127.0.0.1 -p 9712 -U default_user -d postgres \
       -c \"\\copy (select * from documentdb_api_catalog.$t) to stdout (format binary)\" | base64 -w0" \
    | base64 -d > $t.bin
done
```

**5c — sequence high-water marks**

```bash
psql -X -Atc "select last_value from documentdb_api_catalog.collections_collection_id_seq"       > seq_coll
psql -X -Atc "select last_value from documentdb_api_catalog.collection_indexes_index_id_seq"     > seq_idx
```

**5d — per-collection payload without `shard_key_value`** (only needed for Path B)

```bash
psql -X -q -c "\copy (select object_id, document from documentdb_data.documents_<srcid>) \
                 to stdout (format binary)"   # -> docs_shopdb__orders.bin (262,031 B), __customers.bin (40,805 B)
```

⚠️ **Consistency:** `pg_dump` is one snapshot, but each `\copy` above is its own transaction. This
run was quiesced. A real addon must wrap the catalog reads and the data dump in a single
`REPEATABLE READ` transaction (or use `pg_dump --snapshot=` with an exported snapshot id).

---

## 6. Path A — id-preserving catalog copy (`dcdb-dst-a`)

**Collision guard first.** Path A only works if the target's own `collection_id`s do not overlap the
source's user ids. A fresh KubeDB instance holds 1,2 for `kubedb_system`; source user ids start at 3.

```
target ids  : 1,2
source user : 3,4,5
OVERLAP     : none -> safe
```

**A1 — restore only the user tables**, so the target's own `documents_1/2` (backing the operator
health check) are not clobbered. Build a TOC list and filter:

```bash
pg_restore -l /tmp/d.pgc > toc-full.list
grep -Ev 'documents_1|documents_2|retry_1|retry_2|collection_pk_1|collection_pk_2' \
  toc-full.list > toc-userdata.list          # keeps documents_3/4/5 + retry_3/4/5 + their
                                             # constraints and the two rum indexes
kubectl exec -n $NS dcdb-dst-a-0 -c documentdb -- env PGPASSWORD="$(gwpw dcdb-dst-a)" \
  pg_restore -h 127.0.0.1 -p 9712 -U default_user -d postgres \
             -L /tmp/toc.list --exit-on-error /tmp/d.pgc
```

Clean run as `default_user`, `--exit-on-error`, no warnings. Secondary indexes come across as real
PG objects (`documents_rum_index_6` on documents_4, `documents_rum_index_7` on documents_5).

**A2 — restore the catalog rows through staging tables** (binary COPY cannot be filtered in flight,
and `kubedb_system` rows must not be duplicated). `\copy` is client-side, so it reads a file *in the
pod* — simpler than juggling two binary blobs on stdin.

```sql
BEGIN;
CREATE TABLE documentdb_data.stg_collections        (LIKE documentdb_api_catalog.collections);
CREATE TABLE documentdb_data.stg_collection_indexes (LIKE documentdb_api_catalog.collection_indexes);
\copy documentdb_data.stg_collections        FROM '/tmp/collections.bin'        (format binary)
\copy documentdb_data.stg_collection_indexes FROM '/tmp/collection_indexes.bin' (format binary)

INSERT INTO documentdb_api_catalog.collections
  SELECT * FROM documentdb_data.stg_collections WHERE database_name <> 'kubedb_system';

INSERT INTO documentdb_api_catalog.collection_indexes
  SELECT * FROM documentdb_data.stg_collection_indexes
   WHERE collection_id IN (SELECT collection_id FROM documentdb_data.stg_collections
                            WHERE database_name <> 'kubedb_system');

SELECT setval('documentdb_api_catalog.collections_collection_id_seq',
              GREATEST(5, (SELECT last_value FROM documentdb_api_catalog.collections_collection_id_seq)));
SELECT setval('documentdb_api_catalog.collection_indexes_index_id_seq',
              GREATEST(7, (SELECT last_value FROM documentdb_api_catalog.collection_indexes_index_id_seq)));

DROP TABLE documentdb_data.stg_collections, documentdb_data.stg_collection_indexes;
COMMIT;
```

```
COPY 5 / COPY 7 / INSERT 0 3 / INSERT 0 5 / coll_seq=5 / idx_seq=7
```

**A3 — the gateway sees it immediately, with no pod restart:**

```
databases   = ["kubedb_system","shopdb"]
collections = ["customers","orders"]
orders      = 1000
customers   = 250
```

This matters for addon design: a restore can be applied to a **live, running** instance; there is no
gateway-side catalog cache to invalidate.

---

## 7. Path B — recreate via the gateway, remap ids (`dcdb-dst-b`)

Never writes to an extension-owned catalog table. Works even when ids collide.

First run happened to allocate the same ids 3,4,5 (same creation order), which would not have tested
anything — so the target was deliberately given prior activity (`drop()` + recreate in reverse
order) to force a genuine remap:

```
source: orders=4, customers=5
target: orders=7, customers=6      <- both different AND swapped
```

**B1 — replay the manifest through mongosh as `default_user`:**

```js
const d = db.getSiblingDB("shopdb");
d.createCollection("customers"); d.createCollection("orders");
d.customers.createIndex({email:1}, {name:"email_uniq_idx", unique:true});
d.orders.createIndex({region:1, ts:-1}, {name:"region_ts_idx"});
```

The extension allocates its own ids and creates `documents_6` / `documents_7`.

**B2 — load with `shard_key_value` re-stamped.** This is mandatory; each table carries a CHECK:

```
documentdb_data.documents_6 : CHECK ((shard_key_value = '6'::bigint))
documentdb_data.documents_7 : CHECK ((shard_key_value = '7'::bigint))
```

```sql
BEGIN;
CREATE TEMP TABLE stage_orders    (object_id documentdb_core.bson, document documentdb_core.bson);
CREATE TEMP TABLE stage_customers (object_id documentdb_core.bson, document documentdb_core.bson);
\copy stage_orders    FROM '/tmp/docs_shopdb__orders.bin'    (format binary)
\copy stage_customers FROM '/tmp/docs_shopdb__customers.bin' (format binary)

INSERT INTO documentdb_data.documents_7 (shard_key_value, object_id, document)
  SELECT 7::bigint, object_id, document FROM stage_orders;      -- src 4 -> dst 7
INSERT INTO documentdb_data.documents_6 (shard_key_value, object_id, document)
  SELECT 6::bigint, object_id, document FROM stage_customers;   -- src 5 -> dst 6
COMMIT;
```

```
COPY 1000 / COPY 250 / INSERT 0 1000 / INSERT 0 250
```

(`shard_key_value == collection_id` holds for unsharded collections, which is all KubeDB creates.
A sharded collection would need the real shard key preserved instead.)

---

## 8. Verification — identical script against all three instances

A single `fingerprint.js` captured: `listDatabases`, collection names, per-collection counts, index
specs, `$sum:"$qty"`, `$sum:"$price"` (Decimal128), `count({region:"eu"})`, and full `EJSON` of 7
pinned documents chosen to cover every BSON type including the null/absent-field edge cases.

```
diff fp-src.json fp-dst-a.json  -> IDENTICAL
diff fp-src.json fp-dst-b.json  -> IDENTICAL
```

Identical **including `_id` ObjectIds and Decimal128 / ISODate / BinData round-trips** — and for
Path B that holds even though every `collection_id` differs, which is the whole point.

Behaviour checks, both targets, connecting with the target's **own `<db>-auth`** secret:

| check | dst-a | dst-b |
|---|---|---|
| `countDocuments({region:"eu"})` == 200 | ✅ | ✅ |
| plan actually uses `region_ts_idx` | ✅ | ✅ |
| `insertOne` then `deleteOne` (instance live) | ✅ | ✅ |
| duplicate email rejected (unique index real) | ✅ code 11000 | ✅ code 11000 |
| `createCollection` after restore gets a fresh id | ✅ id=6, no clash | ✅ |
| `qty_sum` 4003 / `price_sum` 685685.00 | ✅ | ✅ |

The `createCollection`-after-restore check is what proves the `setval` step in A2 was necessary and
correct — without it the next collection would have reused `collection_id` 3 and collided with the
restored `documents_3`.

---

## 9. Path A vs Path B

| | **A — id-preserving** | **B — gateway remap** |
|---|---|---|
| Writes to extension catalog tables | yes (INSERT + `setval`) | **no** |
| Needs the source `collection_id`s to be free on the target | **yes** | no |
| Handles a target with prior activity | no | **yes** |
| Restores indexes | as real PG objects, from the dump | rebuilt by `createIndex` |
| Restores exact `collection_uuid` | **yes** | no (new uuid) |
| Steps | dump + 2 catalog blobs + 2 setvals | dump payloads + mongosh replay + N re-stamped inserts |
| Per-collection work at restore | none (bulk) | one staged insert per collection |
| Failure mode if assumption breaks | id collision → constraint violation, loud | none found |
| Needs a collection manifest | no | **yes** (names + index specs) |

**Recommendation for a KubeStash addon:** Path B. It is immune to id collisions, never touches
extension-owned catalog tables (so it survives an upstream schema change), and it lets the extension
maintain its own invariants — the same reason `mongorestore` works where `pg_dump` fails. Path A is
faster and preserves `collection_uuid`, so it is the better fit for the narrow "restore into a
freshly provisioned, untouched instance" case — which is exactly what a KubeStash restore
normally is, so **A with the collision guard as a hard precondition, falling back to B** is the
pragmatic design.

Either way the non-negotiable part is the same: **the catalog must be carried out-of-band, because
`pg_dump` will not carry it and will not tell you.**

---

## 10. Known gaps of any `pg_dump`-based approach (not fixed by this run)

1. **Users are lost.** Mongo users are Postgres roles; SCRAM verifiers live in `pg_authid`, which
   `pg_dump` does not carry and `default_user` cannot read. `default_user` itself survives only
   because `SetupCustomAdminUser` re-creates it on **every** gateway start (its guard is
   `SELECT 1 FROM pg_roles`). `docdb_admin` is created only when `initSetup == "true"`, so it is
   **lost** on a logical restore. Any application-created Mongo user is lost.
2. **`documentdb_api_catalog.roles`** (custom-role BSON, 0.110-0+) keys on `role_oid`; a logical
   restore leaves dangling OIDs. Not exercised here (0.109-0 has no such table).
3. **Multi-transaction extraction** — see the warning in §5.
4. **`documentdb_index_queue`** was not carried. Empty in this test; a restore taken mid
   index-build would need it (or a rebuild).
5. **No PITR.** This is a snapshot-in-time tool. wal-g remains the PITR path
   (`documentdb-walg-backup-command.md`).

---

## 10b. `pg_basebackup` does NOT work as the gateway user (tested 2026-08-31)

The logical path and the physical path split cleanly on privilege, in opposite directions.

```
              rolcanlogin  rolreplication  rolsuper
default_user      t             f             f
docdb_admin       t             f             f
documentdb        t             t             t
```

```
$ pg_basebackup -h 127.0.0.1 -p 9712 -U default_user -D - -F t -X fetch
pg_basebackup: error: FATAL:  permission denied to start WAL sender
DETAIL:  Only roles with the REPLICATION attribute may start a WAL sender process.
                                                                    exit=1, 0 bytes

$ pg_basebackup -h 127.0.0.1 -p 9712 -U documentdb   -D - -F t -X fetch
                                                                    exit=0, 52,277,760 bytes
```

`pg_hba.conf` is **not** the blocker — loopback replication is `trust`:

```
local        replication     all                                     trust
host         replication     all             127.0.0.1/32            trust
host         replication     all             0.0.0.0/0               scram-sha-256
```

The block is the role attribute, and `default_user` cannot lift it itself:

```
ALTER ROLE default_user WITH REPLICATION;
ERROR:  permission denied to alter role
DETAIL:  Only roles with the CREATEROLE attribute and the ADMIN option ... may alter this role.
```

### Consequence

| | logical (`pg_dump` + catalog) | physical (`pg_basebackup` / wal-g) |
|---|---|---|
| Runs as | **`default_user`** (`<db>-auth`) | **`documentdb`** (`<db>-admin-auth`) — superuser only |
| Catalog | **lost unless carried out-of-band** (§2) | survives — it copies bytes |
| Roles + SCRAM passwords (`pg_authid`) | **lost** | survive |
| PITR | no | yes (wal-g) |
| Can verify through the Mongo wire with the same credential | **yes** | no — that role is gateway-blocked (§1) |

This is exactly why `pkg/controllers/appbinding.go` creates **two** AppBindings: `<db>` →
`<db>-auth`, type `kubedb.com/documentdb`, for the Mongo surface; and `<db>-admin` →
`<db>-admin-auth`, type **`kubedb.com/postgres`**, because the KubeStash Postgres addon doing
physical backup needs the superuser. A logical addon would be the first one that could ride on the
non-admin AppBinding instead.

Granting `REPLICATION` to `default_user` would make it work, but that is a real privilege
escalation of the gateway's own login credential — the role every mongosh client authenticates as.
Not recommended; use the admin secret for physical backup, as the operator already does.

---

## 11. Reproduction crib

```bash
export KUBECONFIG=/home/sabnaj/k3s.yaml
NS=ddb-logical
```

Non-optional flags, all learned the hard way:

| flag | why |
|---|---|
| `-p 9712` | Postgres is not on 5432 |
| `-c documentdb` | the pod has an init container |
| `-d postgres` | there is no database named `documentdb` |
| `psql -X` | `~/.psqlrc` sets `search_path` **and `bsonUseEJson=true`** |
| `(format binary)` on every bson COPY | text format is not round-trippable with EJson on |
| `kubectl exec -i` | without `-i`, stdin is discarded |
| `base64 -w0` in-pod | binary through `kubectl exec` otherwise risks mangling; md5-verify both ends |
| mongosh `tls=true&tlsAllowInvalidCertificates=true` | gateway is TLS-only (`CertType: PemAutoGenerated`) even with `sslMode: disable`; without it → `read ECONNRESET` |
| mongosh `directConnection=true` | `?replicaSet=rs0` never connects |
| `env HOME=/tmp` | mongosh needs a writable HOME |
| password percent-encoding | generated passwords contain `*` and friends |

Cleanup: `kubectl delete ns ddb-logical` (all four DBs are `deletionPolicy: WipeOut`).
