// SOURCE ONLY. No environment-variable admission, daemon/container discovery,
// installation, provisioning, or startup occurs on import.
import { fork } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { exportJWK,importJWK,CompactSign } from 'jose';
import { createOwnedPool,PostgresStore,closeOwnedPool } from '../store.mjs';
import { migrate } from '../migrate.mjs';
import { B1Authority,FIXTURE_MAXIMUMS } from '../authority.mjs';
import { canonical,reject } from '../proof.mjs';
import { assertFixtureEnvironment } from './owner/owner.mjs';

const admitted=new WeakSet();
const image='sha256:a85953d6f830fd55a12929df3b7a4fa94dc96d652de62d2d714e0867ccb3670d';
function ownerShape(owner) {
  if(!owner||! /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(owner.runId)||
    owner.uid!==process.getuid()||owner.imageDigest!==image||owner.platform!=='linux/arm64'||
    !/^[0-9a-f]{64}$/.test(owner.containerId)||! /^[0-9a-f]{64}$/.test(owner.networkId)||
    typeof owner.artifactRoot!=='string'||!owner.artifactRoot.endsWith('/.artifacts/b1-pg-'+owner.runId)||
    !owner.artifactRoot.startsWith('/Volumes/ExternalSSD/')||owner.host!=='127.0.0.1'||
    !Number.isSafeInteger(owner.port)||owner.port<1||owner.port>65535) reject('SQL_NOT_ADMITTED');
}
export function assertAdmitted(harness) {if(!admitted.has(harness))reject('SQL_NOT_ADMITTED');}
function createFixturePool(connection){
  const pool=createOwnedPool(connection);
  // pg-pool constructs clients at checkout, including queued/idle replacements.
  // Pin this owned plaintext fixture's options before any client can be made;
  // later process env drift never changes its protocol. Production is untouched.
  pool.options.ssl=false;pool.options.sslnegotiation='postgres';return pool;
}
// Cache by real Client: guards stay attached across pool checkout cycles.
function wrapPool(pool, hooks={}, intercept) {
  const wrappers=new WeakMap();
  function wrap(client) {
    let state=wrappers.get(client);
    if(state){state.generation++;state.released=false;return state.value;}
    state={generation:1,released:false,dead:false,business:false};
    client.on('error',()=>{state.dead=true;});client.on('end',()=>{state.dead=true;});
    const alive=generation=>{if(state.dead||state.released||generation!==state.generation)reject('DB_UNAVAILABLE');};
    const value={connection:client.connection,get _txStatus(){return client._txStatus;},
      on:(...args)=>{client.on(...args);return value;},removeListener:(...args)=>{client.removeListener(...args);return value;},
      async query(sql,params) {
        const generation=state.generation;alive(generation);
        if(sql==='BEGIN ISOLATION LEVEL SERIALIZABLE')state.business=true;
        const commit=sql==='COMMIT'&&state.business;
        if(commit)await hooks.beforeCommit?.();alive(generation);
        // Interceptors/keepalives retain their checkout generation after awaits.
        const raw={connection:client.connection,get _txStatus(){return client._txStatus;},
          query:(...args)=>{alive(generation);return client.query(...args);},on:(...args)=>client.on(...args)};
        const result=intercept?await intercept(raw,sql,params):await raw.query(sql,params);alive(generation);
        if(sql==='COMMIT'||sql==='ROLLBACK')state.business=false;
        if(commit)await hooks.afterCommit?.();alive(generation);return result;
      },release:discard=>{if(state.released)return;state.released=true;client.release(discard);}};
    state.value=value;wrappers.set(client,state);return value;
  }
  return {on:(...args)=>pool.on(...args),
    connect(callback) {
      if(callback)return pool.connect((error,client)=>callback(error,error?undefined:wrap(client)));
      return pool.connect().then(wrap);
    },end:()=>pool.end()};
}
export async function admitPostgres({owner,verifyOwner,connections,trust,lifecycle}) {
  assertFixtureEnvironment();
  ownerShape(owner);
  if(typeof verifyOwner!=='function'||typeof lifecycle?.restartDatabase!=='function')reject('SQL_NOT_ADMITTED');
  let resources=null;
  async function admission(action) {
    assertFixtureEnvironment();
    // Resource hooks are installed only after initial, fully branded admission.
    resources?.check();const receipt=await verifyOwner(owner,action);
    if(!receipt||['runId','uid','containerId','networkId','artifactRoot','imageDigest','platform','host','port'].some(k=>receipt[k]!==owner[k])||
      !Number.isSafeInteger(receipt.storageFreeBytes)||receipt.storageFreeBytes<0||receipt.storageFreeBytes<6*1024**3||receipt.dataQuotaBytes!==2*1024**3||receipt.connectionLimit!==12||
      receipt.cpuLimit!==2||receipt.memoryLimitBytes!==1024**3||receipt.shmBytes!==128*1024**2||
      receipt.wallBudgetSeconds!==1800||receipt.resultsQuotaBytes!==128*1024**2||
      receipt.durabilityMountVerified!==true||receipt.loopbackPublicationVerified!==true||
      receipt.roleGrantsVerified!==true||receipt.secretFileModesVerified!==true)reject('SQL_NOT_ADMITTED');
  }
  await admission('connect-owned-fixture');
  for(const role of ['b1_bootstrap','b1_migrator','b1_app']) {
    const c=connections?.[role];
    if(!c||c.host!==owner.host||c.port!==owner.port||c.user!==role||c.database!=='b1')reject('SQL_NOT_ADMITTED');
  }
  const pools=new Set(),workers=new Set();let closed=false;
  function checkScope(){if(closed)reject('SERVER_CLOSED');resources?.check();assertFixtureEnvironment();}
  function reserve(kind){checkScope();const release=resources?.reserve(kind,2)??(()=>{});if(typeof release!=='function')reject('SQL_NOT_ADMITTED');return release;}
  function trackedClose(kind,value,name){
    const original=value[name].bind(value);let pending;
    value[name]=()=>pending??=(async()=>{await original();resources?.settled(value);})();
    resources?.track(kind,value,()=>value[name]());return value;
  }
  function pool(role='b1_app',kind='helper') {
    const release=reserve(kind);let p;
    try{p=createFixturePool(connections[role]);}catch(error){release();throw error;}
    pools.add(p);const end=p.end.bind(p);let ending;
    p.end=()=>ending??=(async()=>{await end();release();pools.delete(p);resources?.settled(p);})();
    resources?.track('pool',p,()=>closeOwnedPool(p,1000));return p;
  }
  async function health() {
    await admission('verify-health');const p=pool(),client=await p.connect();
    client.on('error',()=>{});
    try {
      const {rows:[r]}=await client.query("SELECT current_user AS role,current_database() AS database,current_setting('server_version_num') AS version,current_setting('fsync') AS fsync,current_setting('synchronous_commit') AS synchronous_commit,current_setting('full_page_writes') AS full_page_writes,(SELECT rolsuper FROM pg_roles WHERE rolname=current_user) AS superuser,has_database_privilege(current_user,current_database(),'CREATE') AS database_ddl,has_schema_privilege(current_user,'provider_b1','CREATE') AS schema_ddl");
      if(r.role!=='b1_app'||r.database!=='b1'||r.version!=='170011'||r.fsync!=='on'||r.synchronous_commit!=='on'||r.full_page_writes!=='on'||r.superuser!==false||r.database_ddl!==false||r.schema_ddl!==false)reject('SQL_NOT_ADMITTED');
      return {version:r.version,fsync:r.fsync,synchronous_commit:r.synchronous_commit,full_page_writes:r.full_page_writes};
    } finally {client.release();await p.end();pools.delete(p);}
  }
  const harness={owner,trust,
    bindResources(hooks) {
      // Configure lifecycle observation once while idle. No public method is
      // replaced; this very same frozen/WeakSet-branded object is retained.
      if(closed||resources||pools.size||workers.size||!hooks||
        ['check','reserve','track','settled'].some(k=>typeof hooks[k]!=='function'))reject('SQL_NOT_ADMITTED');
      resources=Object.freeze({...hooks});return harness;
    },
    async initializeFresh() {
      await admission('create-fresh-schema');const p=pool('b1_bootstrap');
      try {await migrate({pool:p,trust,owner,verifyOwner:()=>admission('create-fresh-schema')});}finally{pools.delete(p);}
      await health();
    },
    health,
    newStore(hooks={},intercept) {
      const p=pool('b1_app','app');
      const wrapped=wrapPool(p,hooks,intercept);
      const end=wrapped.end;wrapped.end=async()=>{await end();pools.delete(p);};
      return trackedClose('store',new PostgresStore({pool:wrapped}),'close');
    },
    async holdDomain() {
      await admission('lock-owned-domain');const p=pool(),c=await p.connect();
      c.on('error',()=>{});
      try{await c.query('BEGIN');await c.query('SELECT issuer FROM provider_b1.domains WHERE issuer=$1 AND realm=$2 AND service_environment=$3 FOR UPDATE',[trust.issuer,trust.realm,trust.serviceEnvironment]);}
      catch(error){c.release(true);await p.end();pools.delete(p);throw error;}
      let released=false;
      return trackedClose('held',{async release(){if(released)return;released=true;
        try{await c.query('COMMIT');}finally{c.release();await p.end();pools.delete(p);}
      }},'release');
    },
    async holdCredential(id) {
      await admission('lock-owned-credential');const p=pool(),c=await p.connect();
      c.on('error',()=>{});
      try{await c.query('BEGIN');await c.query('SELECT id FROM provider_b1.credentials WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 FOR UPDATE',[trust.issuer,trust.realm,trust.serviceEnvironment,id]);}
      catch(error){c.release(true);await p.end();pools.delete(p);throw error;}
      let released=false;
      return trackedClose('held',{async release(){if(released)return;released=true;try{await c.query('COMMIT');}finally{c.release();await p.end();pools.delete(p);}}},'release');
    },
    async query(sql,values=[]) {
      await admission('inspect-owned-fixture');const p=pool(),c=await p.connect();
      c.on('error',()=>{});
      try{return await c.query(sql,values);}finally{c.release();await p.end();pools.delete(p);}
    },
    async restartDatabase(kind) {
      if(!['clean','crash'].includes(kind))reject('SQL_NOT_ADMITTED');
      await admission('restart-'+kind);await lifecycle.restartDatabase(owner,kind);await health();
    },
    async exhaustSerialization({context,maximumAttempts}) {
      if(maximumAttempts!==3)reject('SQL_NOT_ADMITTED');await admission('serialization-fixture');
      const outer=pool(),other=pool(),D=[trust.issuer,trust.realm,trust.serviceEnvironment];
      let attempts=0;const sqlStates=[];
      const wrapped=wrapPool(outer,{},async(client,sql,values)=>{
        if(sql==='BEGIN ISOLATION LEVEL SERIALIZABLE')attempts++;
        if(sql.startsWith('SELECT * FROM provider_b1.domains')) {
          await client.query('SELECT trust_epoch FROM provider_b1.domains WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D);
          const c=await other.connect();
          c.on('error',()=>{});
          try {await c.query('UPDATE provider_b1.domains SET revocation_seq=revocation_seq WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D);}
          finally{c.release();}
        }
        try{return await client.query(sql,values);}catch(error){if(error.code==='40001')sqlStates.push(error.code);throw error;}
      });
      const end=wrapped.end;wrapped.end=async()=>{await end();pools.delete(outer);};
      const store=new PostgresStore({pool:wrapped});
      try{await store.transaction(context,async()=>{});reject('DB_UNAVAILABLE');}
      catch(error){if(error.code!=='40001')throw error;return {attempts,sqlStates};}
      finally{await store.close();await other.end();pools.delete(other);}
    },
    async issuanceWorker(f,p) {
      await admission('start-owned-worker');
      if(process.version!=='v22.23.1'||!p.data||p.path!=='/bootstrap/register'||f.config.trust.issuer!==trust.issuer)reject('SQL_NOT_ADMITTED');
      // Export before spawning so an invalid/nonextractable fixture key cannot
      // leave an unreturned worker behind. Private material uses IPC only.
      const signingJwk=await exportJWK(f.serverKey.privateKey),release=reserve('app');
      const nonce=randomUUID();let child;
      try{child=fork(new URL(import.meta.url),['--owned-b1-worker'],{execPath:process.execPath,
        env:{PATH:'/usr/bin:/bin'},stdio:['ignore','ignore','ignore','ipc']});}catch(error){release();throw error;}
      workers.add(child);
      const events=[],waiters=[];let exit;
      const exited=new Promise(resolve=>{let settled=false;const done=(code,signal)=>{if(settled)return;settled=true;exit??={code,signal};workers.delete(child);release();resources?.settled(child);resolve(exit);};child.once('exit',done);child.once('close',done);});
      resources?.track('worker',child,async()=>{if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');await exited;});
      child.on('error',()=>{exit={code:null,signal:'SPAWN_ERROR'};});
      child.on('message',event=>{if(event?.nonce!==nonce)return;events.push(event);for(const wake of waiters.splice(0))wake();});
      async function event(name) {
        const deadline=Date.now()+6000;
        while(Date.now()<deadline) {
          const i=events.findIndex(e=>e.name===name||e.name==='failed');
          if(i>=0){const e=events.splice(i,1)[0];if(e.name==='failed')reject('DB_UNAVAILABLE');return e;}
          if(exit)reject('DB_UNAVAILABLE');
          await new Promise(resolve=>{let timer;const wake=()=>{clearTimeout(timer);resolve();};waiters.push(wake);timer=setTimeout(()=>{const i=waiters.indexOf(wake);if(i>=0)waiters.splice(i,1);resolve();},100);});
        }
        reject('DEADLINE_EXCEEDED');
      }
      child.send({nonce,owner,connection:connections.b1_app,trust:{...trust,publicKey:undefined},
        signingJwk,origin:f.origin,now:f.clock.now,
        limits:f.config.limits,request:p.data,headers:p.headers});
      return {event,continue:()=>child.send({nonce,name:'continue'}),async kill(){if(child.exitCode===null&&child.signalCode===null)child.kill('SIGKILL');await exited;},exited};
    },
    async close() {
      if(closed)return;closed=true;
      for(const child of workers)child.kill('SIGKILL');
      await Promise.all([...workers].map(child=>new Promise(resolve=>child.once('exit',resolve))));
      await Promise.all([...pools].map(p=>closeOwnedPool(p,1000)));pools.clear();
      // Container/network/data deletion belongs to the external receipt owner.
    },
  };
  admitted.add(harness);return Object.freeze(harness);
}
async function worker() {
  const timer=setTimeout(()=>process.exit(2),10_000);
  const input=await new Promise(resolve=>process.once('message',resolve));
  try {
    ownerShape(input.owner);
    if(!input.nonce||input.connection.host!==input.owner.host||input.connection.port!==input.owner.port||input.connection.user!=='b1_app')reject('SQL_NOT_ADMITTED');
    const key=await importJWK(input.signingJwk,'ES256');
    const publicJwk={...input.signingJwk};delete publicJwk.d;
    const trust={...input.trust,publicKey:await importJWK(publicJwk,'ES256')};
    const pool=createFixturePool(input.connection);let first=true;
    const waitContinue=()=>new Promise(resolve=>{const next=m=>{if(m?.nonce===input.nonce&&m.name==='continue'){process.removeListener('message',next);resolve();}};process.on('message',next);});
    let stopped=false;
    const wrapped=wrapPool(pool,{
      beforeCommit:async()=>{if(first){first=false;stopped=true;process.send({nonce:input.nonce,name:'before-commit'});await waitContinue();}},
      afterCommit:async()=>{if(stopped){stopped=false;process.send({nonce:input.nonce,name:'after-commit'});await waitContinue();}},
    });
    const authority=new B1Authority({mode:'fixture',db:new PostgresStore({pool:wrapped}),trust,
      limits:input.limits??FIXTURE_MAXIMUMS,clock:{observe:()=>({now:Math.max(input.now,Math.floor(Date.now()/1000)),uncertaintySeconds:0})},
      ownership:{verify:async()=>reject('OWNERSHIP_REQUIRED')},administration:{verify:async()=>reject('UNAUTHORIZED')},
      signer:{keyId:trust.keyId,algorithm:'ES256',sign:claims=>new CompactSign(Buffer.from(canonical(claims))).setProtectedHeader({alg:'ES256',kid:trust.keyId,typ:'aegis-provider+jws'}).sign(key)}});
    authority.bindOrigin(input.origin);
    await authority.issue('register',input.request,{proof:input.headers['x-aegis-pop']});
    await authority.close();process.send({nonce:input.nonce,name:'completed'});
  } catch {process.send({nonce:input?.nonce,name:'failed'});}
  finally {clearTimeout(timer);process.disconnect();}
}
if(process.argv[2]==='--owned-b1-worker') {
  if(typeof process.send!=='function'||process.version!=='v22.23.1')reject('SQL_NOT_ADMITTED');
  await worker();
}
