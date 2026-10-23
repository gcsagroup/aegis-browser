import { randomUUID } from 'node:crypto';
import { request as httpRequest } from 'node:http';
import { performance } from 'node:perf_hooks';
import { CompactSign, generateKeyPair, exportJWK } from 'jose';
import { createApp } from '../app.mjs';
import { start } from '../start.mjs';
import { FIXTURE_MAXIMUMS } from '../authority.mjs';
import { ProviderError, normalizePublicJwk, canonical, reject, observation } from '../proof.mjs';

export async function keyPair() {
  const pair = await generateKeyPair('ES256', { extractable: true });
  const exported = await exportJWK(pair.publicKey);
  const { jwk, keyId, fingerprint } = normalizePublicJwk(Object.fromEntries(
    ['kty','crv','x','y'].map(name => [name,exported[name]])));
  return { ...pair, jwk, keyId, fingerprint };
}
export function mutableClock(now = Math.floor(Date.now() / 1000), live = false) {
  let fixed=now,offset=now-Math.floor(Date.now()/1000);
  return { live, get now(){return this.live?Math.floor(Date.now()/1000)+offset:fixed;},
    set now(value){fixed=value;offset=value-Math.floor(Date.now()/1000);}, uncertaintySeconds: 0,
    observe() { return { now: this.now, uncertaintySeconds: this.uncertaintySeconds }; } };
}
function live(context) {
  if (context.signal.aborted) throw context.signal.reason instanceof ProviderError ? context.signal.reason : new ProviderError('DEADLINE_EXCEEDED');
  if (performance.now() >= context.deadline) reject('DEADLINE_EXCEEDED');
}
async function until(promise, context) {
  let timer, abort;
  try {
    return await Promise.race([promise,new Promise((_, fail) => {
      abort = () => fail(context.signal.reason instanceof ProviderError ? context.signal.reason : new ProviderError('DEADLINE_EXCEEDED'));
      context.signal.addEventListener('abort',abort,{ once:true });
      timer = setTimeout(abort,Math.max(0,context.deadline-performance.now()));
      if (context.signal.aborted) abort();
    })]);
  } finally { clearTimeout(timer); context.signal.removeEventListener('abort',abort); }
}
export function deferred() {let resolve,reject;const promise=new Promise((yes,no)=>{resolve=yes;reject=no;});return {promise,resolve,reject};}
// Explicit synthetic session ownership shared by stores using one ledger.
const clockLifecycles=new WeakMap();
class SyntheticClockLifecycle {
  owner=null;queue=[];
  next(){if(this.owner)return;const ticket=this.queue.shift();if(!ticket)return;this.owner=ticket;ticket.ready.resolve();}
  async acquire(context) {
    live(context);const ticket={ready:deferred()},release=()=>{if(this.owner!==ticket)return;this.owner=null;this.next();};
    this.queue.push(ticket);this.next();
    try{await until(ticket.ready.promise,context);live(context);return release;}
    catch(error){const i=this.queue.indexOf(ticket);if(i>=0)this.queue.splice(i,1);release();throw error;}
  }
}
// Deliberate behavioral test double. No connection, SQL parser, fsync,
// persistence or PostgreSQL concurrency claim can be derived from this class.
export class SyntheticStore {
  kind = 'synthetic-test-double';
  closed = false;
  state = { domain:null, installations:[], pools:[], profiles:[], credentials:[], challenges:[], operations:[] };
  #tail = Promise.resolve();
  #controllers = new Set();
  // Outside the business draft: a rejected transaction cannot undo this ledger.
  clockLedger = { domain: null, highwater: 0, pending: null };
  dbNow = 0;
  clockHook = null;
  async observeTime(context, sample) {
    const controller=new AbortController(),relay=()=>controller.abort(context.signal.reason);
    context.signal.addEventListener('abort',relay,{once:true});if(context.signal.aborted)relay();
    const local={...context,signal:controller.signal};this.#controllers.add(controller);let unlock;
    try {
      if(!clockLifecycles.has(this.clockLedger))clockLifecycles.set(this.clockLedger,new SyntheticClockLifecycle());
      unlock=await clockLifecycles.get(this.clockLedger).acquire(local);live(local);
      if(this.closed)reject('SERVER_CLOSED');
      const ledger=this.clockLedger,binding=canonical(context.trust);ledger.domain??=binding;
      if(ledger.domain!==binding||ledger.pending!==null)reject('CLOCK_UNTRUSTED');
      const hook=async phase=>{await until(Promise.resolve().then(()=>this.clockHook?.(phase)),local);live(local);};
      await hook('before-marker');const marker=randomUUID();ledger.pending=marker;
      try {
        await hook('after-marker');const interval=observation(await until(Promise.resolve().then(sample),local));
        await hook('before-observation');const previous=ledger.highwater;
        ledger.highwater=Math.max(previous,interval.latest,this.dbNow);ledger.pending=null;
        await hook('after-observation');
        if(interval.latest<previous)reject('CLOCK_UNTRUSTED');return {...interval,latest:ledger.highwater};
      }catch(error){if(error instanceof ProviderError)throw error;reject('CLOCK_UNTRUSTED');}
    }finally{
      unlock?.();controller.abort(new ProviderError('DB_UNAVAILABLE'));this.#controllers.delete(controller);
      context.signal.removeEventListener('abort',relay);
    }
  }
  beforeCommit = null;
  afterCommit = null;
  async proofBinding(id,context) {
    live(context);if(this.closed)reject('SERVER_CLOSED');
    const row=this.state.challenges.find(c=>c.id===id);if(!row)reject('UNAUTHORIZED');
    return structuredClone(row);
  }
  async transaction(context, work) {
    const prior = this.#tail;
    let unlock;
    const gate = new Promise(resolve => { unlock = resolve; });
    this.#tail = prior.then(() => gate);
    const controller = new AbortController(), relay = () => controller.abort(context.signal.reason);
    context.signal.addEventListener('abort', relay, { once: true });
    if (context.signal.aborted) relay();
    const local = { ...context, signal: controller.signal }; this.#controllers.add(controller);
    let tx;
    try {
      await until(prior, local); live(local);
      if (this.closed) reject('SERVER_CLOSED');
      const draft = structuredClone(this.state);
      draft.domain ??= { audience:context.trust.audience,trust_epoch:context.trust.trustEpoch,time_highwater:0,revocation_seq:0 };
      if (draft.domain.audience !== context.trust.audience || draft.domain.trust_epoch !== context.trust.trustEpoch) reject('BINDING_REQUIRED');
      tx = new SyntheticTransaction(draft,local,sample=>this.observeTime(local,sample));
      const result = await until(work(tx),local);
      if (this.beforeCommit) await until(this.beforeCommit(draft),local);
      live(local); tx.finish(); this.state = draft;
      if (this.afterCommit) await until(this.afterCommit(this.state),local);
      return result;
    } finally {
      tx?.finish(); controller.abort(new ProviderError('DB_UNAVAILABLE'));
      this.#controllers.delete(controller); context.signal.removeEventListener('abort', relay); unlock();
    }
  }
  async close() { this.closed = true; for (const c of this.#controllers) c.abort(new ProviderError('SERVER_CLOSED')); }
}
class SyntheticTransaction {
  #state; #context; #finished=false; #clock;
  constructor(state,context,clock) { this.#state=state; this.#context=context; this.#clock=clock; this.context=context; this.signal=context.signal; this.domain=state.domain; }
  finish() { this.#finished=true; }
  #active() { if(this.#finished) reject('DB_UNAVAILABLE'); live(this.#context); }
  async time(sample) {
    this.#active(); const interval=await this.#clock(sample); this.#active(); return interval;
  }
  async installationByKey(channel,key_hash) {
    this.#active();
    const installation=this.#state.installations.find(i=>i.channel===channel&&i.key_hash===key_hash);
    if(!installation) return null;
    const pool=this.#state.pools.find(p=>p.installation_id===installation.id);
    const credential=this.#state.credentials.find(c=>c.installation_id===installation.id&&c.kind==='installation-credential');
    if(!pool||!credential) reject('DB_UNAVAILABLE'); return {installation,pool,credential};
  }
  async installationById(id) {
    this.#active(); const i=this.#state.installations.find(i=>i.id===id);
    return i?this.installationByKey(i.channel,i.key_hash):null;
  }
  async hierarchy(id) {
    this.#active(); const credential=this.#state.credentials.find(c=>c.id===id);
    if(!credential) reject('UNAUTHORIZED');
    const root=await this.installationById(credential.installation_id);
    if(credential.kind==='installation-credential') return {...root,parent:null,profile:null};
    const profile=this.#state.profiles.find(p=>p.id===credential.profile_id);
    if(!profile||credential.parent_id!==root.credential.id) reject('DB_UNAVAILABLE');
    return {...root,credential,parent:root.credential,profile};
  }
  async profileByOwner(installation_id,ownership_hash) {
    this.#active(); const profile=this.#state.profiles.find(p=>p.installation_id===installation_id&&p.ownership_hash===ownership_hash);
    if(!profile) return null;
    const credential=this.#state.credentials.find(c=>c.profile_id===profile.id);
    if(!credential) reject('DB_UNAVAILABLE'); return {profile,credential};
  }
  async challenge(id) { this.#active(); const c=this.#state.challenges.find(c=>c.id===id); if(!c) reject('UNAUTHORIZED'); return c; }
  async operation(actor,operation,idem_key) { this.#active(); return this.#state.operations.find(o=>o.actor===actor&&o.operation===operation&&o.idem_key===idem_key)??null; }
  async capacity(table,maximum,installationId) {
    this.#active();
    const rows=table==='revocations'?this.#state.operations.filter(o=>o.operation==='revoke'):
      table==='operations'?this.#state.operations.filter(o=>o.operation!=='revoke'):
      table==='profiles'?this.#state.profiles.filter(p=>p.installation_id===installationId):this.#state[table];
    if(rows.length>=maximum) reject('STATE_CAPACITY');
  }
  async insertInstallation(r) { this.#active(); this.#state.installations.push(r); }
  async insertPool(r) { this.#active(); this.#state.pools.push({...r,kind:'installation_guest'}); }
  async insertProfile(r) {
    this.#active();
    if(this.#state.profiles.some(p=>p.key_hash===r.key_hash)) reject('BINDING_MISMATCH');
    this.#state.profiles.push(r);
  }
  async insertCredential(r) { this.#active(); this.#state.credentials.push(r); }
  async insertChallenge(r) { this.#active(); this.#state.challenges.push(r); }
  async insertOperation(r) { this.#active(); this.#state.operations.push(r); }
  async consumeChallenge(id,operationId,at) {
    const row=await this.challenge(id);
    if(row.consumed_operation_id!==null) reject('CHALLENGE_CONSUMED');
    row.consumed_operation_id=operationId; row.consumed_at=at;
  }
  async revoke(id,at) { this.#active(); this.#state.credentials.find(c=>c.id===id).revoked_at=at; this.domain.revocation_seq++; }
}
export async function fixtureBindings({ store,clock=mutableClock(),limits={},ownership,signer }={}) {
  const serverKey=await keyPair(), installationKey=await keyPair();
  const owners=new Map(), capabilities=new WeakMap();
  const adminCapability=Object.freeze({}); capabilities.set(adminCapability,'fixture-administrator');
  const trust={issuer:'aegis-fixture',audience:'aegis-fixture-clients',realm:'synthetic',serviceEnvironment:'b1-test',
    trustEpoch:1,algorithm:'ES256',keyId:'fixture-provider',publicKey:serverKey.publicKey};
  const config={mode:'fixture',db:store??new SyntheticStore(),trust,clock,limits:{...FIXTURE_MAXIMUMS,...limits},
    signer:signer??{keyId:trust.keyId,algorithm:'ES256',async sign(claims){
      return new CompactSign(Buffer.from(canonical(claims))).setProtectedHeader({alg:'ES256',kid:trust.keyId,typ:'aegis-provider+jws'}).sign(serverKey.privateKey);
    }},
    ownership:ownership??{async verify({installationId,request,recipientFingerprint}){
      const owner=owners.get(request);
      if(!owner||owner.installationId!==installationId||owner.recipientFingerprint!==recipientFingerprint) reject('OWNERSHIP_REQUIRED');
      return {installationId,profileKind:'normal',subject:owner.subject};
    }},
    administration:{async verify(capability){
      const subject=capability&&typeof capability==='object'?capabilities.get(capability):null;
      if(!subject) reject('UNAUTHORIZED'); return {subject};
    }}};
  return {config,clock,serverKey,installationKey,adminCapability,store:config.db,
    grantOwnership(installationId,key,subject=randomUUID()) {
      const request='fixture-owner-'+randomUUID();
      owners.set(request,{installationId,recipientFingerprint:key.fingerprint,subject}); return request;
    }};
}
export async function launch(bindings) {
  const app=createApp(bindings.config);
  const server=await start({app,host:'127.0.0.1',port:0});
  return {...bindings,app,...server};
}
export const fixture = async options => launch(await fixtureBindings(options));
export async function request(f,path,data,headers={}) {
  const payload=typeof data==='string'?Buffer.from(data):Buffer.from(canonical(data));
  const defaults={'content-type':'application/json','content-length':String(payload.length),
    'idempotency-key':typeof data==='object'?data.idempotencyKey:'fixture-key'};
  return new Promise((resolve,fail)=>{
    const req=httpRequest(f.origin+path,{method:'POST',headers:{...defaults,...headers},agent:false},res=>{
      const chunks=[]; res.on('data',chunk=>chunks.push(chunk)); res.on('error',fail);
      res.on('end',()=>{const body=Buffer.concat(chunks); let json; try{json=JSON.parse(body);}catch{}
        resolve({status:res.statusCode,headers:res.headers,body,json});});
    });
    req.setTimeout(6000,()=>req.destroy(new Error('fixture client deadline'))); req.on('error',fail); req.end(payload);
  });
}
export async function challenge(f,operation,args,idempotencyKey,root) {
  return request(f,'/bootstrap/challenge',{version:1,operation,arguments:args,idempotencyKey},
    root?{authorization:'Bearer '+root.json.credential}:{});
}
export async function signProof(f,ch,key,role='installation',patch={},headerPatch={}) {
  const c=ch.json;
  const claims={version:1,method:'POST',target:f.origin+(c.operation==='register'?'/bootstrap/register':'/profile-credentials'),
    operation:c.operation,issuer:f.config.trust.issuer,audience:f.config.trust.audience,realm:f.config.trust.realm,
    serviceEnvironment:f.config.trust.serviceEnvironment,role,keyFingerprint:key.fingerprint,
    recipientFingerprint:c.recipientFingerprint,parentId:c.parentId,parentRevision:c.parentRevision,
    challengeId:c.challengeId,nonce:c.nonce,requestDigest:c.requestDigest,actor:c.actor,
    idempotencyKey:ch.idempotencyKey,issuedAt:f.clock.now,notBefore:f.clock.now,expiresAt:c.expiresAt,...patch};
  return new CompactSign(Buffer.from(canonical(claims))).setProtectedHeader({alg:'ES256',kid:key.keyId,typ:'aegis-b1-pop+jws',...headerPatch}).sign(key.privateKey);
}
export async function prepared(f,operation,args,idempotencyKey,root,recipientKey) {
  const ch=await challenge(f,operation,args,idempotencyKey,root); ch.idempotencyKey=idempotencyKey;
  if(ch.status!==200) return {challenge:ch};
  const data={version:1,challengeId:ch.json.challengeId,nonce:ch.json.nonce,idempotencyKey,arguments:args};
  const headers={'x-aegis-pop':await signProof(f,ch,f.installationKey)};
  if(root) {headers.authorization='Bearer '+root.json.credential; headers['x-aegis-recipient-pop']=await signProof(f,ch,recipientKey,'recipient');}
  return {challenge:ch,data,headers,path:operation==='register'?'/bootstrap/register':'/profile-credentials'};
}
export async function issue(f,p) { return p.data?request(f,p.path,p.data,p.headers):p.challenge; }
export function registerArgs(f) { return {channel:'fixture',installationJwk:f.installationKey.jwk}; }
export async function register(f,key='register-1') {return issue(f,await prepared(f,'register',registerArgs(f),key));}
export function profileArgs(f,root,key,subject) {
  return {profileKind:'normal',recipientJwk:key.jwk,ownershipRequest:f.grantOwnership(root.json.claims.installationRef,key,subject)};
}
