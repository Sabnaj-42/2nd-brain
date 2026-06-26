'use strict';
/*
 * DocumentDB failover-resilient writer — compares two client strategies.
 *
 *   MODE=persistent : keep ONE MongoClient and let the driver self-heal (naive)
 *   MODE=reconnect  : on a network error, DISCARD the client and build a new one
 *                     (Postgres-style "error -> open a new connection")
 *
 * Both use idempotent writes (stable _id + retryWrites) so a retry never duplicates.
 * Prints the recovery time = seconds from the first failed write after a failover
 * until writes succeed again.
 *
 * Env: MONGO_URI (required), MODE, DB_NAME, COLL_NAME, DURATION_MS
 */
const { MongoClient } = require('mongodb');

const URI     = process.env.MONGO_URI;
const MODE    = process.env.MODE || 'reconnect';
const DB_NAME = process.env.DB_NAME || 'failover_app';
const COLL    = process.env.COLL_NAME || MODE;
const RUN_MS  = parseInt(process.env.DURATION_MS || '120000', 10);

const ts = () => new Date().toISOString().substr(11, 12);

function isNetworkError(e) {
  if (!e) return false;
  const name = (e.constructor && e.constructor.name) || '';
  const msg  = e.message || '';
  if (/MongoNetwork|ServerSelection|Timeout|PoolCleared|PoolClosed|Topology/.test(name)) return true;
  return /not.*primary|shutting down|connect|socket|ECONNREFUSED|ECONNRESET|EPIPE|server selection|no (writable )?primary|getaddrinfo|ENOTFOUND/i.test(msg);
}

let client = null;
async function getClient() {
  if (client) return client;
  client = new MongoClient(URI);   // timeouts + retryWrites come from the URI
  await client.connect();
  return client;
}
async function dropClient() {
  const old = client; client = null;
  if (old) { try { await old.close(true); } catch (_) {} }
}

async function main() {
  if (!URI) { console.error('MONGO_URI is required'); process.exit(2); }
  console.log(`MODE=${MODE} coll=${COLL} START ${ts()}`);

  const t0 = Date.now();
  await getClient();
  await client.db(DB_NAME).command({ ping: 1 });
  console.log(`initial_connect_ms=${Date.now() - t0}`);
  try { await client.db(DB_NAME).collection(COLL).drop(); } catch (_) {}

  const start = Date.now();
  let seq = 1, inStall = false, stallStart = 0;
  const recoveries = [];
  const markRecovered = (s) => {
    if (!inStall) return;
    const sec = (Date.now() - stallStart) / 1000;
    recoveries.push(sec);
    console.log(`RECOVERED ${ts()} seq=${s} recovery_sec=${sec.toFixed(1)}`);
    inStall = false;
  };

  while (Date.now() - start < RUN_MS) {
    try {
      const c = await getClient();
      await c.db(DB_NAME).collection(COLL).insertOne({ _id: seq, ts: new Date() });
      markRecovered(seq);
      if (++seq % 500 === 0) console.log(`ok ${seq} ${ts()}`);
    } catch (e) {
      if (e && e.code === 11000) { markRecovered(seq); seq++; continue; } // already applied -> recovered, no dup
      if (!isNetworkError(e)) { console.error(`FATAL ${ts()} ${e.message}`); break; }
      if (!inStall) { inStall = true; stallStart = Date.now(); console.log(`STALL  ${ts()} seq=${seq} :: ${(e.message || '').substr(0, 60)}`); }
      if (MODE === 'reconnect') await dropClient();   // <-- the only behavioral difference
      await new Promise(r => setTimeout(r, 300));
    }
  }

  console.log(`END ${ts()} mode=${MODE} reached_seq=${seq} recoveries_sec=${JSON.stringify(recoveries)}`);
  await dropClient();
  process.exit(0);
}

main().catch(e => { console.error(e); process.exit(1); });
