// Genuine engine cases; imports are inert. No synthetic database exception is
// created by a fault case. Pure validators make wrong-victim/ACK claims reject.
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { DatabaseError } from 'pg';
import { launch,register,registerArgs,prepared,issue,deferred } from '../fixtures.mjs';
import { ProviderError } from '../../proof.mjs';
import { OwnerError,digest,ownedRace,settleClosures } from './owner.mjs';

const D=h=>[h.trust.issuer,h.trust.realm,h.trust.serviceEnvironment];
const context=(h,owner,ms=4000)=>({trust:h.trust,deadline:performance.now()+ms,signal:owner.signal});
const fail=code=>{throw new OwnerError(code);};
const pause=ms=>new Promise(r=>setTimeout(r,ms));
export function validateDeadlockEvidence(e){
  if(e?.mainSqlStates?.length!==1||e.mainSqlStates[0]!=='40P01'||e.helperSqlStates?.length!==0||e.errorClass!=='DatabaseError'||e.begins!==2||e.rollbacks!==1||e.commits!==1||e.callbacks!==2||e.blockedByMain!==true||!Number.isFinite(e.barrierMs)||e.barrierMs<0||e.barrierMs>100||JSON.stringify(e.timeouts)!=='["250ms","1s","1s","20ms"]')fail('OWNER_DEADLOCK_NOT_PROVEN');return e;
}
export function validateAckReceipt(receipt,mode){
  if(receipt?.mode!==mode||receipt.commitCommandComplete!==true||receipt.readyForQuery!=='I'||receipt.ackForwarded!==false||!/^[0-9a-f]{24}$/.test(receipt.connection??''))fail('OWNER_COMMIT_ACK_NOT_PROVEN');return receipt;
}
export function isClockDisconnect(error){return error instanceof ProviderError&&error.code==='DB_UNAVAILABLE';}
export async function registerFixtureAndClose(f,idem,{registerFixture=register,signal,deadline=performance.now()+4000,cleanupMs=2000}={}){
  assert.ok(Number.isSafeInteger(cleanupMs)&&cleanupMs>0&&cleanupMs<=2000);
  let result,failure;
  try{result=await ownedRace(()=>registerFixture(f,idem),{signal,deadline});assert.equal(result.status,201);}
  catch(error){failure=error;}
  finally{
    const [closed]=await settleClosures([{name:'fault-application',close:()=>f.close()}],performance.now()+cleanupMs);
    if(closed.status!=='CLOSED')throw Object.assign(new OwnerError('OWNER_FAULT_APP_CLEANUP_INCOMPLETE'),{failures:[closed],...(failure?{cause:failure}:{})});
  }
  if(failure)throw failure;return result;
}
export async function clockSmoke({owner,harness,bindings}){
  await owner.gate.require('run-clock-smoke');await harness.health();
  // Migration is already complete. Verify actual lock privileges before a
  // business request and fail on every forbidden clock/schema mutation.
  await owner.withClient('b1_app',async c=>{
    for(const table of ['domains','installations','pools','profiles','credentials','challenges','operations'])await c.query('SELECT * FROM provider_b1.'+table+' WHERE issuer=$1 AND realm=$2 AND service_environment=$3 FOR UPDATE',D(harness));
    await assert.rejects(c.query('UPDATE provider_b1.domain_clocks SET highwater=highwater'),e=>e instanceof DatabaseError&&e.code==='42501');
    const {rows:[r]}=await c.query("SELECT has_database_privilege(current_user,'b1','CREATE') AS db,has_schema_privilege(current_user,'provider_b1','CREATE') AS schema");assert.deepEqual(r,{db:false,schema:false});
  });
  const store=harness.newStore(),held=await harness.holdDomain();let interval;
  try{interval=await store.observeTime(context(harness,owner),()=>bindings.clock.observe());}
  finally{await held.release();}
  const saved=interval.latest+1;if(!Number.isSafeInteger(saved))fail('OWNER_CLOCK_INTEGER');
  try{
    await assert.rejects(store.transaction(context(harness,owner),async tx=>{await tx.time(()=>({now:saved,uncertaintySeconds:0}));throw new ProviderError('EXPIRED');}),e=>e.code==='EXPIRED');
  }finally{await store.close();}
  const before=await clockRow(owner,harness);assert.ok(Number(before.highwater)>=saved);assert.equal(before.pending_id,null);
  await harness.restartDatabase('clean');const after=await clockRow(owner,harness);assert.deepEqual(after,before);
  bindings.clock.now=Math.max(bindings.clock.now,Number(after.highwater));
  return owner.record('migration-lock-clock-smoke',{clockProgressUnderDomainLock:true,rollbackFloor:Number(after.highwater),pending:null,restartRetained:true});
}
async function clockRow(owner,harness){return owner.withClient('b1_bootstrap',async c=>(await c.query('SELECT highwater,pending_id FROM provider_b1.domain_clocks WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D(harness))).rows[0]);}
async function faultApp({owner,harness,bindings},family){
  const db=harness.newStore();let f;const installationKey=bindings.family?await bindings.family(family):bindings.installationKey;
  try{f=await ownedRace(()=>launch({...bindings,installationKey,config:{...bindings.config,db}}),{signal:owner.signal,deadline:performance.now()+2000,onLate:x=>x.close()});return f;}
  catch(e){await db.close();throw e;}
}
export async function runDeadlock(runtime){
  const {owner,harness,bindings}=runtime;await owner.gate.require('run-faults');
  const f=await faultApp(runtime,'deadlock'),root=await registerFixtureAndClose(f,'pg-owner-deadlock',{signal:owner.signal});
  const installationId=root.json.claims.installationRef,key=f.installationKey,Dv=D(harness),domainReady=deferred(),waitReady=deferred(),mainAbort=deferred();
  const evidence={mainSqlStates:[],helperSqlStates:[],errorClass:null,begins:0,rollbacks:0,commits:0,callbacks:0,blockedByMain:false,barrierMs:null,timeouts:null};let mainPid,store;const businessConnections=new WeakSet();const wireStart=performance.now();let wireConnection;
  const before=await owner.withClient('b1_bootstrap',async c=>(await c.query('SELECT to_jsonb(i)::text AS row FROM provider_b1.installations i WHERE id=$1',[installationId])).rows);
  const result=await owner.withClient('b1_bootstrap',async helper=>{
    await helper.query('BEGIN');await helper.query("SET LOCAL deadlock_timeout='200ms'");
    const helperPid=(await helper.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
    await helper.query('SELECT id FROM provider_b1.installations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4 FOR UPDATE',[...Dv,installationId]);
    let hWait,hRollback,mainResult;
    store=harness.newStore({},async(client,sql,values)=>{
      if(sql==='BEGIN ISOLATION LEVEL SERIALIZABLE'){businessConnections.add(client.connection);evidence.begins++;wireConnection=owner.proxy.connectionIdentity(client.connection.stream.localPort);const {rows:[r]}=await client.query("SELECT pg_backend_pid() AS pid,current_setting('lock_timeout') AS lock,current_setting('statement_timeout') AS statement,current_setting('idle_in_transaction_session_timeout') AS idle,current_setting('deadlock_timeout') AS deadlock");mainPid=r.pid;evidence.timeouts=[r.lock,r.statement,r.idle,r.deadlock];}
      if(sql==='ROLLBACK'&&businessConnections.has(client.connection))evidence.rollbacks++;if(sql==='COMMIT'&&businessConnections.has(client.connection))evidence.commits++;
      try{const result=await client.query(sql,values);if(sql==='COMMIT'||sql==='ROLLBACK')businessConnections.delete(client.connection);return result;}catch(error){if(businessConnections.has(client.connection)&&error instanceof DatabaseError&&error.code==='40P01'){evidence.mainSqlStates.push(error.code);evidence.errorClass=error.constructor.name;mainAbort.resolve(error);}throw error;}
    });
    mainResult=store.transaction(context(harness,owner),async tx=>{
      evidence.callbacks++;if(evidence.callbacks===1){domainReady.resolve(performance.now());await ownedRace(()=>waitReady.promise,{signal:owner.signal,deadline:performance.now()+100});}
      const installation=await tx.installationByKey('fixture',key.fingerprint);assert.equal(installation.installation.id,installationId);await tx.time(()=>bindings.clock.observe());return installation.installation.id;
    });mainResult.catch(()=>{});
    try{
      const barrierStart=await ownedRace(()=>domainReady.promise,{signal:owner.signal,deadline:performance.now()+500});
      hWait=helper.query('SELECT issuer FROM provider_b1.domains WHERE issuer=$1 AND realm=$2 AND service_environment=$3 FOR UPDATE',Dv);
      hWait.catch(e=>{if(e instanceof DatabaseError)evidence.helperSqlStates.push(e.code);});
      await owner.withClient('b1_bootstrap',async observer=>{
        const end=barrierStart+90;
        while(performance.now()<end){const {rows:[r]}=await observer.query('SELECT wait_event_type,pg_blocking_pids(pid) AS blocking FROM pg_stat_activity WHERE pid=$1',[helperPid]);if(r?.wait_event_type==='Lock'&&r.blocking.includes(mainPid)){evidence.blockedByMain=true;evidence.barrierMs=performance.now()-barrierStart;waitReady.resolve();return;}await pause(1);}
        fail('OWNER_DEADLOCK_BARRIER_MISSED');
      });
      // ROLLBACK queues immediately on H once the real A ErrorResponse arrives;
      // no manual exception is injected into A or its retry path.
      hRollback=mainAbort.promise.then(()=>helper.query('ROLLBACK'));hRollback.catch(()=>{});
      const id=await ownedRace(()=>mainResult,{signal:owner.signal,deadline:performance.now()+2000});await hWait;await hRollback;return id;
    }finally{
      waitReady.resolve();mainAbort.resolve(null);await helper.query('ROLLBACK').catch(()=>{});await store.close();
      await Promise.allSettled([mainResult,hWait,hRollback].filter(Boolean));
    }
  });
  assert.equal(result,installationId);validateDeadlockEvidence(evidence);
  const wireErrors=owner.proxy.metadata.filter(e=>e.atMs>=wireStart&&e.connection===wireConnection&&e.sqlState==='40P01');if(wireErrors.length!==1)fail('OWNER_DEADLOCK_WIRE_IDENTITY');
  const after=await owner.withClient('b1_bootstrap',async c=>(await c.query('SELECT to_jsonb(i)::text AS row FROM provider_b1.installations i WHERE id=$1',[installationId])).rows);assert.deepEqual(after,before);
  const clock=await clockRow(owner,harness);assert.equal(clock.pending_id,null);
  return owner.record('genuine-deadlock',{...evidence,wireErrors,rowBytesUnchanged:true,highwater:Number(clock.highwater),pending:null});
}
export async function runIssuanceAckLoss(runtime){
  const {owner,harness}=runtime;await owner.gate.require('run-faults');let f=await faultApp(runtime,'wire-issuance');
  try{
    const idem='pg-wire-issuance',p=await prepared(f,'register',registerArgs(f),idem);assert.equal(p.challenge.status,200);
    const receiptPromise=owner.proxy.arm('issuance');const request=issue(f,p);request.catch(()=>{});
    const receipt=validateAckReceipt(await ownedRace(()=>receiptPromise,{signal:owner.signal,deadline:performance.now()+5000}),'issuance');
    const response=await request.catch(()=>null);assert.notEqual(response?.status,201);
    const committed=await owner.withClient('b1_bootstrap',async c=>{
      const {rows}=await c.query('SELECT o.id,o.body,o.result_credential_id,ch.consumed_operation_id FROM provider_b1.operations o JOIN provider_b1.challenges ch ON ch.consumed_operation_id=o.id WHERE o.issuer=$1 AND o.realm=$2 AND o.service_environment=$3 AND o.idem_key=$4 AND ch.id=$5',[...D(harness),idem,p.data.challengeId]);assert.equal(rows.length,1);assert.equal(rows[0].id,rows[0].consumed_operation_id);return rows[0];
    });
    const key=f.installationKey;await f.close();await harness.restartDatabase('crash');f=await faultApp(runtime,'wire-issuance');assert.equal(f.installationKey.fingerprint,key.fingerprint);
    const retry=await prepared(f,'register',registerArgs(f),idem);assert.notEqual(retry.data.challengeId,p.data.challengeId);
    const recovered=await issue(f,retry);assert.equal(recovered.status,201);assert.deepEqual(recovered.body,committed.body);
    return owner.record('wire-issuance-ack-loss',{wire:receipt,operationId:committed.id,resultCredentialId:committed.result_credential_id,resultBodySha256:digest(committed.body),freshChallengeRecovery:true,crashRestartRetained:true});
  }finally{owner.proxy.disarm();await f.close();}
}
export async function runObservationAckLoss({owner,harness,bindings}){
  await owner.gate.require('run-faults');const store=harness.newStore();const sample=Math.max(bindings.clock.now,Number((await clockRow(owner,harness)).highwater))+1;
  const receiptPromise=owner.proxy.arm('observation');let receipt,samples=0;
  try{
    const observing=store.observeTime(context(harness,owner),()=>{samples++;return {now:sample,uncertaintySeconds:0};});observing.catch(()=>{});
    receipt=validateAckReceipt(await ownedRace(()=>receiptPromise,{signal:owner.signal,deadline:performance.now()+5000}),'observation');await assert.rejects(observing,isClockDisconnect);assert.equal(samples,1);
  }finally{owner.proxy.disarm();await store.close();}
  const before=await clockRow(owner,harness);assert.equal(before.pending_id,null);assert.ok(Number(before.highwater)>=sample);
  await harness.restartDatabase('clean');const after=await clockRow(owner,harness);assert.deepEqual(after,before);const restarted=harness.newStore();
  try{await assert.rejects(restarted.observeTime(context(harness,owner),()=>({now:Number(after.highwater)-1,uncertaintySeconds:0})),e=>e.code==='CLOCK_UNTRUSTED');}
  finally{await restarted.close();}
  bindings.clock.now=Math.max(bindings.clock.now,Number(after.highwater)+1);
  return owner.record('wire-observation-ack-loss',{wire:receipt,highwater:Number(after.highwater),pending:null,samples,noAutomaticRetry:true,restartRetained:true,lowerClockRejected:true});
}
export async function runMarkerAckLoss({owner,harness,bindings}){
  await owner.gate.require('run-faults');const before=await clockRow(owner,harness),store=harness.newStore();let samples=0,receipt;
  const receiptPromise=owner.proxy.arm('marker');
  try{
    const observing=store.observeTime(context(harness,owner),()=>{samples++;return bindings.clock.observe();});observing.catch(()=>{});
    receipt=validateAckReceipt(await ownedRace(()=>receiptPromise,{signal:owner.signal,deadline:performance.now()+5000}),'marker');await assert.rejects(observing,isClockDisconnect);assert.equal(samples,0);
  }finally{owner.proxy.disarm();await store.close();}
  const fenced=await clockRow(owner,harness);assert.notEqual(fenced.pending_id,null);assert.equal(fenced.highwater,before.highwater);
  await harness.restartDatabase('crash');const after=await clockRow(owner,harness);assert.deepEqual(after,fenced);const restarted=harness.newStore();
  try{await assert.rejects(restarted.observeTime(context(harness,owner),()=>{samples++;return bindings.clock.observe();}),e=>e.code==='CLOCK_UNTRUSTED');assert.equal(samples,0);}
  finally{await restarted.close();}
  assert.deepEqual(await clockRow(owner,harness),fenced);
  return owner.record('terminal-wire-marker-fence',{wire:receipt,pendingId:fenced.pending_id,highwater:Number(fenced.highwater),samples:0,noAutomaticRetry:true,crashRestartRetained:true,reconciliation:'NOT_AUTHORIZED_NOT_PERFORMED'});
}
