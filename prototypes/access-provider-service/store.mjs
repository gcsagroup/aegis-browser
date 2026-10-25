import { Pool, DatabaseError } from 'pg';
import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { setTimeout as sleep } from 'node:timers/promises';
import { ProviderError, reject, safeInteger, observation } from './proof.mjs';

const numberFields = new Set(['revision', 'trust_epoch', 'time_highwater', 'highwater', 'revocation_seq',
  'parent_revision', 'issued_at', 'not_before', 'expires_at', 'consumed_at',
  'revoked_at', 'result_deadline', 'created_at', 'db_now', 'count']);
function normalize(row) {
  if (!row) return null;
  const value = { ...row };
  for (const [key,item] of Object.entries(value)) {
    if (numberFields.has(key) && item !== null) { value[key]=Number(item); safeInteger(value[key]); }
    else if ((key.endsWith('_hash') || key.endsWith('_digest')) && Buffer.isBuffer(item)) value[key]=item.toString('hex');
  }
  return value;
}
const bytes = value => value === null || value === undefined ? null : Buffer.from(value,'hex');
function active(signal,deadline) {
  if (signal?.aborted) throw signal.reason instanceof ProviderError ? signal.reason : new ProviderError('DEADLINE_EXCEEDED');
  if (performance.now()>=deadline) reject('DEADLINE_EXCEEDED');
}
const poolSink=()=>{}; // Never log SQL, connection values, credentials or errors.
export function createOwnedPool(connection) {
  if (!connection || connection.host!=='127.0.0.1' || !Number.isSafeInteger(connection.port) ||
    connection.port<1 || connection.port>65535 || connection.database!=='b1' ||
    !['b1_app','b1_migrator','b1_bootstrap'].includes(connection.user) ||
    typeof connection.password!=='string' || !connection.password ||
    Object.keys(connection).some(k=>!['host','port','database','user','password'].includes(k))) reject('SQL_NOT_ADMITTED');
  const pool=new Pool({...connection,max:2,connectionTimeoutMillis:1000,idleTimeoutMillis:1000,
    application_name:'aegis-b1-owned-fixture',options:'-c lock_timeout=250 -c statement_timeout=1000 -c idle_in_transaction_session_timeout=1000'});
  pool.on('error',poolSink); // Installed before any connection, including migration clients.
  return pool;
}
// Pinned pg disposal boundary. A JS deadline does not cancel a server query.
// Destroy its owned transport, then release(discard); retain an error sink.
export function disposePgClient(client) {
  try { client.connection?.stream?.destroy(); } catch {}
}
const guards=new WeakMap();
const poolGates=new WeakMap();
const poolEnds=new WeakMap();
const queryFailures=new WeakSet();
function guarded(client) {
  if (!client || typeof client.on!=='function' || typeof client.query!=='function' ||
    typeof client.release!=='function' || typeof client.connection?.stream?.destroy!=='function') reject('BINDING_REQUIRED');
  let entry=guards.get(client);
  if (!entry) {
    entry={owner:null,failed:false};guards.set(client,entry);
    const failed=()=>{entry.failed=true;entry.owner?.fail('DB_UNAVAILABLE');};
    client.on('error',failed);client.on('end',failed);
  }
  return entry;
}
class Scope {
  constructor(context,shutdown) {
    if (!Number.isFinite(context?.deadline) || !context.signal?.addEventListener) reject('BINDING_REQUIRED');
    this.controller=new AbortController();this.context={...context,signal:this.controller.signal};
    this.failure=new Promise((_,rejectPromise)=>{this.rejectFailure=rejectPromise;});this.failure.catch(()=>{});
    this.parent=context.signal;this.shutdown=shutdown;
    this.abortParent=()=>this.fail(context.signal.reason instanceof ProviderError?context.signal.reason.code:'DEADLINE_EXCEEDED');
    this.abortShutdown=()=>this.fail('SERVER_CLOSED');
    this.parent.addEventListener('abort',this.abortParent,{once:true});shutdown.addEventListener('abort',this.abortShutdown,{once:true});
    this.timer=setTimeout(()=>this.fail('DEADLINE_EXCEEDED'),Math.max(0,context.deadline-performance.now()));
    if (this.parent.aborted) this.abortParent();if (shutdown.aborted) this.abortShutdown();
  }
  check() { active(this.context.signal,this.context.deadline); }
  fail(code) {
    if (this.controller.signal.aborted || this.ended) return;
    const error=new ProviderError(code);this.controller.abort(error);this.rejectFailure(error);
  }
  async wait(promise) {
    // Attach to both losing promises even when already aborted.
    const race=Promise.race([Promise.resolve(promise),this.failure]);race.catch(()=>{});
    this.check();const result=await race;this.check();return result;
  }
  end() {
    this.ended=true;this.controller.abort(new ProviderError('DB_UNAVAILABLE'));clearTimeout(this.timer);this.parent.removeEventListener('abort',this.abortParent);
    this.shutdown.removeEventListener('abort',this.abortShutdown);
  }
}
class Gate {
  busy=false;queue=[];
  async lock(scope) {
    scope.check();let resolve;const ticket={granted:false,promise:new Promise(r=>{resolve=r;}),resolve:null};ticket.resolve=resolve;
    const release=()=>{if(!ticket.granted)return;ticket.granted=false;this.busy=false;this.next();};
    ticket.release=release;this.queue.push(ticket);this.next();
    try { await scope.wait(ticket.promise);return release; }
    catch(error) {const i=this.queue.indexOf(ticket);if(i>=0)this.queue.splice(i,1);release();throw error;}
  }
  next() {
    if(this.busy)return;const next=this.queue.shift();if(!next)return;
    this.busy=true;next.granted=true;next.resolve();
  }
}
class Lease {
  constructor(client,scope) {this.client=client;this.scope=scope;this.entry=guarded(client);this.entry.owner=scope;this.busy=0;this.released=false;this.lifecycle=null;}
  async query(sql,values=[]) {
    if(this.released || this.entry.failed) reject('DB_UNAVAILABLE');this.scope.check();
    this.busy++;
    const pending=Promise.resolve().then(()=>{this.scope.check();if(this.released)reject('DB_UNAVAILABLE');return this.client.query(sql,values);})
      .catch(error=>{if(error instanceof DatabaseError)queryFailures.add(error);throw error;})
      .finally(()=>{this.busy--;});
    return this.scope.wait(pending);
  }
  async rollback(began) {
    if(!began)return;
    if(this.entry.failed || this.busy || this.scope.context.signal.aborted ||
      performance.now()>=this.scope.context.deadline) {this.release(true);return;}
    let timer;
    try {
      this.busy++;
      const query=Promise.resolve().then(()=>this.client.query('ROLLBACK')).finally(()=>{this.busy--;});
      await Promise.race([query,new Promise((_,fail)=>{timer=setTimeout(()=>fail(new ProviderError('DB_UNAVAILABLE')),
        Math.min(250,Math.max(0,this.scope.context.deadline-performance.now())));}),this.scope.failure]);
    } catch {this.release(true);} finally {clearTimeout(timer);}
  }
  release(discard=false) {
    if(this.released)return;this.released=true;
    const failed=discard||this.entry.failed||this.busy>0||this.scope.context.signal.aborted||
      this.lifecycle!==null||this.client._txStatus!=='I';
    if(failed)disposePgClient(this.client);
    try {this.client.release(failed);}catch{}finally{this.entry.owner=null;}
  }
}
async function checkout(pool,scope) {
    scope.check();let delivered,obtained;
    const pending=new Promise((resolve,fail)=>{
      const receive=(error,client)=>{
        if(error){fail(error);return;}
        if(delivered){if(delivered!==client){disposePgClient(client);try{client.release(true);}catch{}}return;}
        delivered=client;let lease;
        try {
          lease=new Lease(client,scope);scope.check();if(lease.entry.failed)reject('DB_UNAVAILABLE');
          obtained=lease;resolve(lease);
        } catch(error){if(lease)lease.release(true);else{disposePgClient(client);try{client.release(true);}catch{}}fail(error);}
      };
      try {
        // Pinned pg's callback installs the guard synchronously on checkout.
        // Promise-only injected fixtures also resolve here, never granting auth.
        const result=pool.connect(receive);
        if(result?.then)result.then(client=>receive(null,client),receive);
      }catch(error){fail(error);}
    });
    try{const lease=await scope.wait(pending);if(lease.client._txStatus!=='I')reject('DB_UNAVAILABLE');return lease;}
    catch(error){obtained?.release(true);throw error;}
  }

export function closeOwnedPool(pool,milliseconds=1000) {
  if(poolEnds.has(pool))return poolEnds.get(pool);
  let timer;
  const ending=Promise.race([Promise.resolve().then(()=>pool.end()),new Promise((_,fail)=>{
    timer=setTimeout(()=>fail(new ProviderError('DB_UNAVAILABLE')),Math.max(0,Math.min(1000,milliseconds)));
  })]).finally(()=>clearTimeout(timer));ending.catch(()=>{});poolEnds.set(pool,ending);return ending;
}
// Migration consumes a dedicated owned pool; admission runs before checkout.
export async function withOwnedPgClient(pool,context,prepare,work) {
  if(!pool||typeof pool.on!=='function'||typeof pool.end!=='function'||typeof pool.connect!=='function')reject('SQL_NOT_ADMITTED');
  pool.on('error',poolSink);const scope=new Scope(context,new AbortController().signal);let lease;
  try {
    const prepared=await scope.wait(Promise.resolve().then(()=>{scope.check();return prepare(scope.context);}));
    lease=await checkout(pool,scope);
    const result=await scope.wait(Promise.resolve().then(()=>{scope.check();return work(lease,scope,prepared);}));
    lease.release();scope.check();return result;
  }finally{lease?.release();scope.end();}
}
export class PostgresStore {
  #pool;#closed=false;#gate=new Gate();#shutdown=new AbortController();#leases=new Set();#endPromise;
  constructor({pool}) {
    if(!pool || typeof pool.connect!=='function' || typeof pool.end!=='function' || typeof pool.on!=='function')reject('BINDING_REQUIRED');
    this.#pool=pool;pool.on('error',poolSink);this.kind='postgresql';
    if(!poolGates.has(pool))poolGates.set(pool,new Gate());this.#gate=poolGates.get(pool);
  }
  async #checkout(scope) {const lease=await checkout(this.#pool,scope);this.#leases.add(lease);return lease;}
  async #borrow(context,work) {
    if(this.#closed)reject('SERVER_CLOSED');const scope=new Scope(context,this.#shutdown.signal);
    let unlock,main,clock;
    try {
      unlock=await this.#gate.lock(scope);
      main=await this.#checkout(scope);clock=await this.#checkout(scope);
      const result=await scope.wait(work(main,clock,scope));
      // Release may synchronously emit an error while this borrower is active.
      main.release();clock.release();scope.check();return result;
    } finally {
      main?.release();clock?.release();if(main)this.#leases.delete(main);if(clock)this.#leases.delete(clock);
      scope.end();unlock?.();
    }
  }
  async #clock(lease,scope,sample) {
    if(typeof sample!=='function')reject('CLOCK_UNTRUSTED');scope.check();const t=scope.context.trust;
    const domain=[t.issuer,t.realm,t.serviceEnvironment,t.audience,t.trustEpoch],marker=randomUUID();
    let began=false,committing=false,held=false;
    const unlock=async()=>{
      lease.lifecycle='unlocking';
      const {rows}=await lease.query('SELECT * FROM provider_b1.clock_unlock($1,$2,$3,$4,$5)',domain);
      if(rows.length!==1||rows[0].released!==true)reject('CLOCK_UNTRUSTED');
      held=false;lease.lifecycle=null;
    };
    const begin=async()=>{
      await lease.query('BEGIN ISOLATION LEVEL READ COMMITTED');began=true;
      await lease.query("SET LOCAL lock_timeout = '250ms'");await lease.query("SET LOCAL statement_timeout = '1s'");
      await lease.query("SET LOCAL idle_in_transaction_session_timeout = '1s'");
    };
    const commit=async()=>{committing=true;await lease.query('COMMIT');committing=false;began=false;};
    try {
      while(!held) {
        lease.lifecycle='acquiring';
        const {rows}=await lease.query('SELECT * FROM provider_b1.clock_try_lock($1,$2,$3,$4,$5)',domain);
        if(rows.length!==1||typeof rows[0].acquired!=='boolean')reject('CLOCK_UNTRUSTED');
        held=rows[0].acquired;lease.lifecycle=held?'held':null;
        if(!held)await scope.wait(sleep(10+Math.floor(Math.random()*10),undefined,{signal:scope.context.signal}));
      }
      await begin();
      const {rows}=await lease.query('SELECT * FROM provider_b1.clock_begin($1,$2,$3,$4,$5,$6)',[...domain,marker]);
      if(rows.length!==1||rows[0].ready!==true)reject('CLOCK_UNTRUSTED');
      await commit(); // Fence is acknowledged; ownership remains session-wide.
      const interval=observation(await scope.wait(Promise.resolve().then(sample)));
      await begin();
      const {rows:completed}=await lease.query('SELECT * FROM provider_b1.clock_finish($1,$2,$3,$4,$5,$6,$7)',[...domain,marker,interval.latest]);
      const row=normalize(completed[0]);
      if(completed.length!==1||row?.completed!==true)reject('CLOCK_UNTRUSTED');
      await commit();await unlock();
      if(row.rollback_detected===true)reject('CLOCK_UNTRUSTED');
      return {...interval,latest:row.highwater};
    }catch(error) {
      const healthy=error instanceof ProviderError&&error.code==='CLOCK_UNTRUSTED'&&!committing&&
        !lease.entry.failed&&!lease.busy&&!scope.context.signal.aborted&&lease.lifecycle!=='acquiring'&&lease.lifecycle!=='unlocking';
      if(healthy) {
        await lease.rollback(began);
        if(!lease.released&&held){try{await unlock();}catch{lease.release(true);}}
      }else lease.release(true);
      if(error instanceof ProviderError)throw error;
      throw new ProviderError('CLOCK_UNTRUSTED');
    }
  }
  async observeTime(context,sample) {return this.#borrow(context,async(_main,clock,scope)=>this.#clock(clock,scope,sample));}
  async proofBinding(id,context) {
    return this.#borrow(context,async(main,_clock,scope)=>{
      const {trust}=scope.context;const {rows}=await main.query(
        'SELECT c.* FROM provider_b1.challenges c JOIN provider_b1.domains d USING (issuer,realm,service_environment) WHERE c.issuer=$1 AND c.realm=$2 AND c.service_environment=$3 AND c.id=$4 AND d.audience=$5 AND d.trust_epoch=$6',
        [trust.issuer,trust.realm,trust.serviceEnvironment,id,trust.audience,trust.trustEpoch]);
      if(rows.length!==1)reject('UNAUTHORIZED');return normalize(rows[0]);
    });
  }
  async transaction(context,work) {
    if(typeof work!=='function')reject('BINDING_REQUIRED');
    return this.#borrow(context,async(main,clock,scope)=>{
      for(let attempt=0;attempt<=2;attempt++) {
        scope.check();let began=false,tx,commitSent=false;
        try {
          await main.query('BEGIN ISOLATION LEVEL SERIALIZABLE');began=true;
          await main.query("SET LOCAL lock_timeout = '250ms'");await main.query("SET LOCAL statement_timeout = '1s'");
          await main.query("SET LOCAL idle_in_transaction_session_timeout = '1s'");
          tx=new PostgresTransaction(main,scope.context,sample=>this.#clock(clock,scope,sample));
          await tx.lockDomain();const value=await scope.wait(work(tx));scope.check();tx.finish();
          commitSent=true;await main.query('COMMIT');began=false;return value;
        } catch(error) {
          tx?.finish();
          const retry=queryFailures.has(error)&&['40001','40P01'].includes(error?.code)&&!scope.context.signal.aborted&&!main.entry.failed;
          // Only those PG SQLSTATEs positively identify an aborted transaction.
          if(commitSent&&!retry){main.release(true);began=false;}
          await main.rollback(began);
          if(retry&&attempt<2&&!main.released) {await scope.wait(sleep(10+Math.floor(Math.random()*20),undefined,{signal:scope.context.signal}));continue;}
          throw error;
        } finally{tx?.finish();}
      }
      reject('DB_UNAVAILABLE');
    });
  }
  async close() {
    if(this.#endPromise)return this.#endPromise;
    this.#closed=true;this.#shutdown.abort();for(const lease of this.#leases)lease.release(true);
    this.#endPromise=closeOwnedPool(this.#pool);
    return this.#endPromise;
  }
}
export class PostgresTransaction {
  #client;#context;#domain;#finished=false;#clock;
  constructor(client,context,clock) {
    this.#client=client;this.#context=context;this.#clock=clock;
    this.#domain=[context.trust.issuer,context.trust.realm,context.trust.serviceEnvironment];
    this.context=context;this.signal=context.signal;
  }
  finish(){this.#finished=true;}
  async #query(sql,values=[]) {
    if(this.#finished)reject('DB_UNAVAILABLE');active(this.#context.signal,this.#context.deadline);
    const result=await this.#client.query(sql,values);
    if(this.#finished)reject('DB_UNAVAILABLE');active(this.#context.signal,this.#context.deadline);
    return result.rows.map(normalize);
  }
  #params(values=[]) {return [...this.#domain,...values];}
  async lockDomain() {
    const [row]=await this.#query('SELECT * FROM provider_b1.domains WHERE issuer=$1 AND realm=$2 AND service_environment=$3 FOR UPDATE',this.#params());
    if(!row||row.audience!==this.#context.trust.audience||row.trust_epoch!==this.#context.trust.trustEpoch)reject('BINDING_REQUIRED');this.domain=row;
  }
  async time(sample) {
    if(this.#finished)reject('DB_UNAVAILABLE');active(this.#context.signal,this.#context.deadline);
    const value=await this.#clock(sample);
    if(this.#finished)reject('DB_UNAVAILABLE');active(this.#context.signal,this.#context.deadline);return value;
  }
  async installationByKey(channel, keyHash) {
    const [installation] = await this.#query(
      'SELECT * FROM provider_b1.installations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND channel=$4 AND key_hash=$5 FOR UPDATE',
      this.#params([channel, bytes(keyHash)]));
    if (!installation) return null;
    const [pool] = await this.#query(
      'SELECT * FROM provider_b1.pools WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND installation_id=$4 FOR UPDATE',
      this.#params([installation.id]));
    const [credential] = await this.#query(
      "SELECT * FROM provider_b1.credentials WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND installation_id=$4 AND kind='installation-credential' FOR UPDATE",
      this.#params([installation.id]));
    if (!pool || !credential) reject('DB_UNAVAILABLE');
    return { installation, pool, credential };
  }
  async installationById(id) {
    const [row] = await this.#query(
      'SELECT channel,key_hash FROM provider_b1.installations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4',
      this.#params([id]));
    return row ? this.installationByKey(row.channel, row.key_hash) : null;
  }
  async hierarchy(credentialId) {
    const [hint] = await this.#query(
      'SELECT installation_id FROM provider_b1.credentials WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4',
      this.#params([credentialId]));
    if (!hint) reject('UNAUTHORIZED');
    const [installation] = await this.#query(
      'SELECT * FROM provider_b1.installations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 FOR UPDATE',
      this.#params([hint.installation_id]));
    const [pool] = await this.#query(
      'SELECT * FROM provider_b1.pools WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND installation_id=$4 FOR UPDATE',
      this.#params([installation.id]));
    const [parent] = await this.#query(
      "SELECT * FROM provider_b1.credentials WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND installation_id=$4 AND kind='installation-credential' FOR UPDATE",
      this.#params([installation.id]));
    if (!pool || !parent) reject('DB_UNAVAILABLE');
    if (parent.id === credentialId) return { installation, pool, credential: parent, parent: null, profile: null };
    const [profile] = await this.#query(
      'SELECT p.* FROM provider_b1.profiles p JOIN provider_b1.credentials c ON (c.issuer,c.realm,c.service_environment,c.profile_id)=(p.issuer,p.realm,p.service_environment,p.id) WHERE c.issuer=$1 AND c.realm=$2 AND c.service_environment=$3 AND c.id=$4 FOR UPDATE OF p',
      this.#params([credentialId]));
    const [credential] = await this.#query(
      'SELECT * FROM provider_b1.credentials WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 FOR UPDATE',
      this.#params([credentialId]));
    if (!profile || !credential || credential.parent_id !== parent.id) reject('DB_UNAVAILABLE');
    return { installation, pool, parent, profile, credential };
  }
  async profileByOwner(installationId, ownerHash) {
    const [profile] = await this.#query(
      'SELECT * FROM provider_b1.profiles WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND installation_id=$4 AND ownership_hash=$5 FOR UPDATE',
      this.#params([installationId, bytes(ownerHash)]));
    if (!profile) return null;
    const [credential] = await this.#query(
      'SELECT * FROM provider_b1.credentials WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND profile_id=$4 FOR UPDATE',
      this.#params([profile.id]));
    if (!credential) reject('DB_UNAVAILABLE');
    return { profile, credential };
  }
  async challenge(id) {
    const [row] = await this.#query(
      'SELECT * FROM provider_b1.challenges WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 FOR UPDATE',
      this.#params([id]));
    if (!row) reject('UNAUTHORIZED');
    return row;
  }
  async operation(actor, operation, key) {
    const [row] = await this.#query(
      'SELECT * FROM provider_b1.operations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND actor=$4 AND operation=$5 AND idem_key=$6 FOR UPDATE',
      this.#params([actor, operation, key]));
    return row ?? null;
  }
  async capacity(table, maximum, installationId) {
    const sql = {
      installations: 'SELECT count(*)::bigint AS count FROM provider_b1.installations WHERE issuer=$1 AND realm=$2 AND service_environment=$3',
      profiles: 'SELECT count(*)::bigint AS count FROM provider_b1.profiles WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND installation_id=$4',
      challenges: 'SELECT count(*)::bigint AS count FROM provider_b1.challenges WHERE issuer=$1 AND realm=$2 AND service_environment=$3',
      operations: "SELECT count(*)::bigint AS count FROM provider_b1.operations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND operation<>'revoke'",
      revocations: "SELECT count(*)::bigint AS count FROM provider_b1.operations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND operation='revoke'",
    }[table];
    if (!sql) reject('INVALID_INPUT');
    const [row] = await this.#query(sql, this.#params(table === 'profiles' ? [installationId] : []));
    if (row.count >= maximum) reject('STATE_CAPACITY');
  }
  async insertInstallation(row) {
    await this.#query(
      'INSERT INTO provider_b1.installations (issuer,realm,service_environment,id,channel,key_id,key_hash,public_jwk,registration_digest) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9)',
      this.#params([row.id, row.channel, row.key_id, bytes(row.key_hash), row.public_jwk, bytes(row.registration_digest)]));
  }
  async insertPool(row) {
    await this.#query(
      "INSERT INTO provider_b1.pools (issuer,realm,service_environment,id,installation_id,kind) VALUES ($1,$2,$3,$4,$5,'installation_guest')",
      this.#params([row.id, row.installation_id]));
  }
  async insertProfile(row) {
    await this.#query(
      'INSERT INTO provider_b1.profiles (issuer,realm,service_environment,id,installation_id,pool_id,ownership_hash,profile_binding,key_id,key_hash,public_jwk) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)',
      this.#params([row.id, row.installation_id, row.pool_id, bytes(row.ownership_hash), row.profile_binding, row.key_id, bytes(row.key_hash), row.public_jwk]));
  }
  async insertCredential(row) {
    await this.#query(
      'INSERT INTO provider_b1.credentials (issuer,realm,service_environment,id,kind,installation_id,pool_id,profile_id,parent_id,revision,claims,claims_hash,immutable_hash,issued_at,not_before,expires_at,revoked_at,jws) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,NULL,$17)',
      this.#params([row.id, row.kind, row.installation_id, row.pool_id, row.profile_id ?? null, row.parent_id ?? null,
        row.revision, row.claims, bytes(row.claims_hash), bytes(row.immutable_hash), row.issued_at, row.not_before, row.expires_at, row.jws]));
  }
  async insertChallenge(row) {
    await this.#query(
      'INSERT INTO provider_b1.challenges (issuer,realm,service_environment,id,nonce_hash,operation,actor,key_hash,recipient_hash,signer_jwk,recipient_jwk,parent_id,parent_revision,idem_key,request_hash,issued_at,expires_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)',
      this.#params([row.id, bytes(row.nonce_hash), row.operation, row.actor, bytes(row.key_hash), bytes(row.recipient_hash),
        row.signer_jwk, row.recipient_jwk ?? null, row.parent_id ?? null, row.parent_revision ?? null, row.idem_key,
        bytes(row.request_hash), row.issued_at, row.expires_at]));
  }
  async insertOperation(row) {
    await this.#query(
      'INSERT INTO provider_b1.operations (issuer,realm,service_environment,id,actor,operation,idem_key,request_hash,result_credential_id,status,headers,body,result_deadline,created_at) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)',
      this.#params([row.id, row.actor, row.operation, row.idem_key, bytes(row.request_hash), row.result_credential_id ?? null,
        row.status, row.headers, row.body, row.result_deadline ?? null, row.created_at]));
  }
  async consumeChallenge(id, operationId, at) {
    await this.#query(
      'UPDATE provider_b1.challenges SET consumed_operation_id=$5,consumed_at=$6 WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 AND consumed_operation_id IS NULL',
      this.#params([id, operationId, at]));
  }
  async revoke(credentialId, at) {
    await this.#query(
      'UPDATE provider_b1.credentials SET revoked_at=$5 WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 AND revoked_at IS NULL',
      this.#params([credentialId, at]));
    await this.#query(
      'UPDATE provider_b1.domains SET revocation_seq=revocation_seq+1 WHERE issuer=$1 AND realm=$2 AND service_environment=$3',
      this.#params());
    this.domain.revocation_seq++;
  }
}
