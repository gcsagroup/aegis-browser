import test from 'node:test';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import nativeFs,{ promises as fs,constants as FC } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire,syncBuiltinESMExports } from 'node:module';
import { EventEmitter } from 'node:events';
import { Readable } from 'node:stream';
import { gzipSync } from 'node:zlib';
import nativeCrypto from 'node:crypto';
import { Client } from 'pg';
import { exportJWK,compactVerify } from 'jose';
import { admitPostgres,assertAdmitted } from '../pg-harness.mjs';
import { fixtureBindings,keyPair } from '../fixtures.mjs';
import { PostgresStore,createOwnedPool } from '../../store.mjs';
import { ProviderError,canonical } from '../../proof.mjs';
import { FrameDecoder,CommitTracker,WireProxy,WireError,WireLifetime,classifySql,errorSqlState,WIRE_LIMITS } from './wire-proxy.mjs';
import { toolDirectories,createPlan,command,colimaStartArgs,containerArgs,residualCapacity,ConnectionBudget,PhaseGate,OwnerSupervisor,OwnerError,ownedRace,CAPS,PIN,digest,remainingMilliseconds,resolveExecutable,regular,createContainerWithSecret,assertFixtureEnvironment,RUNTIME_SOURCE_FILES,verifyReviewedSources,capabilityAuthorizer,runAuthorizedCommand,verifyToolchain,toolEnvironment,TOOL_NAMES } from './owner.mjs';
import { budgetHarness,runCli,createResourceLifecycle,finishRuntime,persistentBindings,integrationStages,prepareRuntime } from './runner.mjs';
import { validateAckReceipt,validateDeadlockEvidence,isClockDisconnect,registerFixtureAndClose } from './fault-cases.mjs';
// Migrated from the prior artifact-only 23 tests; the original packet stays immutable.
// These are pure unit/regression tests; no real resource/SQL admission is claimed.
const testFiles=await fs.mkdtemp(path.join(process.env.M_OWNER_TEST_TMPDIR??tmpdir(),'owner-pure-'));
test.after(()=>fs.rm(testFiles,{recursive:true,force:true}));
const root='/Volumes/ExternalSSD/repositories/pure-owner-fixture',U='a1234567-1234-4321-8765-123456789abc';
const plan=createPlan({worktree:root,runId:U,vmImage:root+'/.artifacts/cache.raw',ociLayout:root+'/.artifacts/oci',importArchive:root+'/.artifacts/cache.tar'});
const frame=(type,body=Buffer.alloc(0))=>{const raw=Buffer.alloc(body.length+5);raw[0]=type.charCodeAt(0);raw.writeUInt32BE(body.length+4,1);body.copy(raw,5);return new FrameDecoder().push(raw)[0];};
const str=s=>Buffer.from(s+'\0');
const query=s=>frame('Q',str(s)),ready=s=>frame('Z',Buffer.from(s)),complete=s=>frame('C',str(s));
const startup=()=>{const body=Buffer.from('user\0b1_app\0database\0b1\0\0'),b=Buffer.alloc(8+body.length);b.writeUInt32BE(b.length);b.writeUInt32BE(196608,4);body.copy(b,8);return b;};
const sqlError=code=>frame('E',Buffer.concat([Buffer.from('S'),str('ERROR'),Buffer.from('C'),str(code),Buffer.from('M'),str('password secret SQL body must not appear'),Buffer.from([0])]));
const step=(t,s,tag='SELECT 1',status='T')=>{t.frontend(query(s));assert.equal(t.backend(complete(tag)).forward,true);assert.equal(t.backend(ready(status)).forward,true);};
const flush=()=>new Promise(r=>setImmediate(r));
const deferred=()=>{let resolve;const promise=new Promise(r=>{resolve=r;});return {promise,resolve};};
test('all imports and constructors are inert, default gate refuses runtime',async()=>{
  assert.equal(process.versions.node,PIN.node);
  const owner=new OwnerSupervisor({plan,manifest:{},authorize:async()=>false});const proxy=new WireProxy({backendPort:54321,authorize:async()=>{throw new Error('denied');}});
  assert.equal(owner.phase,'new');assert.equal(owner.owner,null);assert.deepEqual(owner.events,[]);assert.deepEqual(proxy.metadata,[]);
  await assert.rejects(owner.preflight(),e=>e.code==='OWNER_NOT_AUTHORIZED');assert.equal(owner.denied.length,1);assert.equal(owner.phase,'new');
  await assert.rejects(proxy.start({deadline:performance.now()+10000,signal:owner.signal}),/denied/);await proxy.close();
});
test('exact UUID-owned paths and structured commands cannot select a default daemon',()=>{
  assert.equal(plan.colimaHome,'/Volumes/ExternalSSD/b1pg-'+U+'/c');assert.ok(Buffer.byteLength(plan.socket)<104);
  const d=command(plan,'docker',['inspect','a'.repeat(64)],{stdin:'private',secret:true});assert.deepEqual(d.args.slice(0,2),['-H','unix://'+plan.socket]);assert.equal(d.env.DOCKER_CONFIG,plan.dockerConfig);assert.equal(d.env.DOCKER_HOST,undefined);assert.equal(d.env.SSH_AUTH_SOCK,undefined);assert.ok(!d.args.includes('private'));
  assert.throws(()=>command(plan,'docker',['context','use','default']));assert.throws(()=>command(plan,'docker',['system','prune']));assert.throws(()=>command(plan,'docker',['image','pull',PIN.image]));assert.throws(()=>command(plan,'docker',['inspect','--context','default']));
  const c=command(plan,'colima',colimaStartArgs(plan));assert.deepEqual(c.args.slice(0,2),['--profile','b1-owner']);assert.ok(c.args.includes('--mount'));assert.ok(c.args.includes('none'));assert.ok(c.args.includes('--activate=false'));assert.equal(c.env.COLIMA_HOME,plan.colimaHome);
  const args=containerArgs(plan,'a'.repeat(64));assert.ok(args.includes('--pull=never'));assert.ok(args.includes('127.0.0.1:0:5432'));assert.ok(args.includes('--read-only'));assert.equal(args[args.indexOf('--memory-swap')+1],'1g');assert.equal(args[args.indexOf('--log-driver')+1],'none');assert.ok(!args.includes('--privileged'));
  for(const runId of ['../../default','1','A'.repeat(36)])assert.throws(()=>createPlan({worktree:root,runId}));assert.throws(()=>createPlan({worktree:'/tmp/repo',runId:U}));
});
test('capacity is residual after worst-case reserve, equality accepted and unsafe values rejected',()=>{
  assert.equal(residualCapacity(9*1024**3,7*1024**3,{hostReserve:3*1024**3,guestReserve:1024**3}),6*1024**3);
  assert.throws(()=>residualCapacity(9*1024**3-1,7*1024**3,{hostReserve:3*1024**3,guestReserve:1024**3}),e=>e.code==='OWNER_CAPACITY');
  for(const n of [NaN,Infinity,-1,Number.MAX_SAFE_INTEGER+1])assert.throws(()=>residualCapacity(n,100*1024**3));
});
test('two app reservations and twelve total clients hold until idempotent release',()=>{
  const b=new ConnectionBudget(),a=b.reserve('app'),c=b.reserve('app'),helper=b.reserve('helper',8);assert.equal(b.state.used,12);assert.throws(()=>b.reserve('app'));assert.throws(()=>b.reserve('helper',1));a();a();assert.equal(b.state.used,10);c();helper();assert.equal(b.state.used,0);b.close();assert.throws(()=>b.reserve('helper'));
});
test('denied and unknown operations remain remembered and cannot be silently retried',async()=>{
  const gate=new PhaseGate({runId:U,authorize:async()=>false});await assert.rejects(gate.require('colima-start'));await assert.rejects(gate.require('prune'));assert.deepEqual(gate.denied.map(e=>e.reason),['OWNER_NOT_AUTHORIZED','UNKNOWN_ACTION']);
});
test('cancellation consumes late checkout and late rejection without duplicate cleanup',async()=>{
  let resolve,closed=0;const p=new Promise(r=>{resolve=r;}),controller=new AbortController();
  const raced=ownedRace(()=>p,{signal:controller.signal,deadline:performance.now()+1000,onLate:()=>{closed++;}});await flush();controller.abort();await assert.rejects(raced,e=>e.code==='OWNER_CANCELLED');resolve({});await flush();await flush();assert.equal(closed,1);
  const c=new AbortController();await assert.rejects(ownedRace(()=>{c.abort();return {};},{signal:c.signal,deadline:performance.now()+1000,onLate:()=>{closed++;}}));await flush();assert.equal(closed,2);
  let reject;const late=new Promise((_,no)=>{reject=no;});await assert.rejects(ownedRace(()=>late,{deadline:performance.now()+1}));reject(new Error('late failure'));await flush();
});
test('real decoder preserves every split point and coalesced startup/auth/query frame bytes',()=>{
  const bytes=Buffer.concat([startup(),frame('p',Buffer.from('SCRAM-SECRET')).raw,query('BEGIN').raw]);
  for(let split=0;split<=bytes.length;split++){const decoder=new FrameDecoder({startup:true});const out=[...decoder.push(bytes.subarray(0,split)),...decoder.push(bytes.subarray(split))];assert.deepEqual(out.map(f=>f.type),['Startup','p','Q']);assert.deepEqual(Buffer.concat(out.map(f=>f.raw)),bytes);assert.equal(decoder.bufferedBytes,0);}
});
test('decoder rejects SSL, bad frame/startup lengths and bounded buffered overrun',()=>{
  const ssl=Buffer.alloc(8);ssl.writeUInt32BE(8);ssl.writeUInt32BE(80877103,4);assert.throws(()=>new FrameDecoder({startup:true}).push(ssl),e=>e.code==='WIRE_SSL_CANCEL_OR_PROTOCOL');
  for(const size of [0,3,WIRE_LIMITS.frame+1]){const raw=Buffer.alloc(5);raw[0]=81;raw.writeUInt32BE(size,1);assert.throws(()=>new FrameDecoder().push(raw));}
  const big=Buffer.alloc(4);big.writeUInt32BE(WIRE_LIMITS.startup+1);assert.throws(()=>new FrameDecoder({startup:true}).push(big));assert.throws(()=>new FrameDecoder().push(Buffer.alloc(WIRE_LIMITS.buffered+1)));
});
for(const mode of ['issuance','marker','observation'])test('exact '+mode+' ACK suppression requires real COMMIT CommandComplete then ReadyForQuery I',()=>{
  let selected=0;const t=new CommitTracker({select:m=>{if(m!==mode)return false;selected++;return true;}});
  step(t,mode==='issuance'?'BEGIN ISOLATION LEVEL SERIALIZABLE':'BEGIN ISOLATION LEVEL READ COMMITTED','BEGIN');
  step(t,mode==='issuance'?'INSERT INTO provider_b1.operations (id) VALUES ($1)':'SELECT * FROM provider_b1.clock_'+(mode==='marker'?'begin':'finish')+'($1)',mode==='issuance'?'INSERT 0 1':'SELECT 1');
  t.frontend(query('COMMIT'));assert.equal(selected,1);assert.deepEqual(t.backend(complete('COMMIT')),{forward:false});assert.deepEqual(t.backend(ready('I')),{forward:false,disconnect:true,committed:mode});
});
test('ordinary business commit, clock acquisition and ROLLBACK cannot satisfy an issuance fault',()=>{
  let selected=0;const t=new CommitTracker({select:()=>{selected++;return true;}});step(t,'BEGIN ISOLATION LEVEL SERIALIZABLE','BEGIN');step(t,'SELECT 1');step(t,'COMMIT','COMMIT','I');assert.equal(selected,0);
  step(t,'BEGIN ISOLATION LEVEL READ COMMITTED','BEGIN');step(t,'SELECT * FROM provider_b1.clock_try_lock($1)');step(t,'COMMIT','COMMIT','I');assert.equal(selected,0);
  step(t,'BEGIN ISOLATION LEVEL SERIALIZABLE','BEGIN');step(t,'INSERT INTO provider_b1.operations (id) VALUES ($1)','INSERT 0 1');step(t,'ROLLBACK','ROLLBACK','I');assert.equal(selected,0);
});
for(const response of ['error','rollback','early-ready','ready-T'])test('selected COMMIT fails closed for '+response,()=>{
  const t=new CommitTracker({select:()=>true});step(t,'BEGIN ISOLATION LEVEL READ COMMITTED','BEGIN');step(t,'SELECT * FROM provider_b1.clock_begin($1)');t.frontend(query('COMMIT'));
  if(response==='error')assert.throws(()=>t.backend(sqlError('40P01')),e=>e.code==='WIRE_SELECTED_COMMIT_ERROR');
  if(response==='rollback')assert.throws(()=>t.backend(complete('ROLLBACK')));
  if(response==='early-ready')assert.throws(()=>t.backend(ready('I')));
  if(response==='ready-T'){t.backend(complete('COMMIT'));assert.throws(()=>t.backend(ready('T')));}
});
test('extended Parse/Bind/Describe/Execute/Sync tracks SQL while keeping parameter bytes opaque',()=>{
  const t=new CommitTracker();const parse=sql=>frame('P',Buffer.concat([str(''),str(sql),Buffer.from([0,0])]));
  const value=Buffer.from('password=SENSITIVE_BIND_VALUE'),len=Buffer.alloc(4);len.writeUInt32BE(value.length);
  const bind=frame('B',Buffer.concat([str(''),str(''),Buffer.from([0,0,0,1]),len,value,Buffer.from([0,0])]));
  t.frontend(parse('BEGIN ISOLATION LEVEL SERIALIZABLE'));t.frontend(bind);t.frontend(frame('D',Buffer.from('P\0')));t.frontend(frame('E',Buffer.alloc(5)));t.frontend(frame('S'));t.backend(complete('BEGIN'));t.backend(ready('T'));
  assert.equal(t.transaction,'business');assert.throws(()=>t.frontend(query('SELECT 1; SELECT 2')));
  const p=new CommitTracker();p.frontend(query('SELECT 1'));assert.throws(()=>p.frontend(query('SELECT 2')),e=>e.code==='WIRE_PIPELINING');assert.throws(()=>new CommitTracker().frontend(frame('d',value)),e=>e.code==='WIRE_COPY_UNSUPPORTED');
});
test('error metadata contains SQLSTATE only, no server message/query/password',()=>{
  const records=[],t=new CommitTracker({record:v=>records.push(v)});t.frontend(query('SELECT 1'));assert.equal(t.backend(sqlError('40P01')).forward,true);assert.deepEqual(records,[{sqlState:'40P01'}]);assert.equal(errorSqlState(sqlError('40001').body),'40001');assert.doesNotMatch(JSON.stringify(records),/secret|password|SQL body/);assert.throws(()=>errorSqlState(Buffer.from('Msecret\0\0')));
});
test('fault validators reject wrong victim, synthetic class, timeout, counts and ACK stand-ins',()=>{
  const d={mainSqlStates:['40P01'],helperSqlStates:[],errorClass:'DatabaseError',begins:2,rollbacks:1,commits:1,callbacks:2,blockedByMain:true,barrierMs:40,timeouts:['250ms','1s','1s','20ms']};assert.equal(validateDeadlockEvidence(d),d);
  for(const patch of [{errorClass:'Error'},{mainSqlStates:['40001']},{helperSqlStates:['40P01']},{barrierMs:101},{begins:3},{rollbacks:0},{blockedByMain:false},{timeouts:['1s','1s','1s','20ms']}])assert.throws(()=>validateDeadlockEvidence({...d,...patch}));
  const ack={mode:'marker',connection:'a'.repeat(24),commitCommandComplete:true,readyForQuery:'I',ackForwarded:false};validateAckReceipt(ack,'marker');for(const patch of [{commitCommandComplete:false},{readyForQuery:'T'},{ackForwarded:true},{mode:'observation'},{connection:'pid'}])assert.throws(()=>validateAckReceipt({...ack,...patch},'marker'));
});
async function pureHarness({onAdmission,captureAdmission=()=>()=>{}}={}) {
  const bindings=await fixtureBindings(),owner={runId:U,uid:process.getuid(),imageDigest:PIN.imageDigest,platform:'linux/arm64',containerId:'a'.repeat(64),networkId:'b'.repeat(64),artifactRoot:root+'/.artifacts/b1-pg-'+U,host:'127.0.0.1',port:54321};
  const receipt={...owner,storageFreeBytes:6*1024**3,dataQuotaBytes:2*1024**3,connectionLimit:12,cpuLimit:2,memoryLimitBytes:1024**3,shmBytes:128*1024**2,wallBudgetSeconds:1800,resultsQuotaBytes:128*1024**2,durabilityMountVerified:true,loopbackPublicationVerified:true,roleGrantsVerified:true,secretFileModesVerified:true};
  // Deliberate receipt double: brand construction and pool lifecycle only.
  const connections=Object.fromEntries(['b1_bootstrap','b1_migrator','b1_app'].map(user=>[user,{host:owner.host,port:owner.port,database:'b1',user,password:'pure-test-only'}]));
  const harness=await admitPostgres({owner,connections,trust:bindings.config.trust,verifyOwner:async(o,action)=>{if(onAdmission)await onAdmission(action);return receipt;},lifecycle:{captureAdmission,restartDatabase:async()=>{throw new Error('NO_ENGINE');}}});
  return {harness,bindings};
}
test('actual frozen admitted harness accepts budgeting without replacing methods or its brand',async()=>{
  const {harness}=await pureHarness(),owner={budget:new ConnectionBudget(),signal:new AbortController().signal},original=harness.newStore;
  assert.equal(Object.isFrozen(harness),true);assertAdmitted(harness);const resources=budgetHarness(harness,owner);
  assert.equal(resources.harness,harness);assert.equal(harness.newStore,original);assert.equal(Object.isFrozen(harness),true);assertAdmitted(harness);
  assert.throws(()=>budgetHarness(Object.freeze({...harness}),owner),e=>e.code==='SQL_NOT_ADMITTED');
  assert.throws(()=>budgetHarness(harness,owner),e=>e.code==='SQL_NOT_ADMITTED');
  const a=harness.newStore(),b=harness.newStore();assert.equal(owner.budget.state.used,4);assert.throws(()=>harness.newStore(),e=>e.code==='OWNER_CLIENT_BUDGET');
  await a.close();await a.close();assert.equal(owner.budget.state.used,2);await resources.closeCase();await harness.close();assert.equal(owner.budget.state.used,0);assert.equal(resources.state().stores,0);assert.equal(resources.state().pools,0);await b.close();
});
test('plan CLI reads only supplied local configuration and reports no runtime admission',async()=>{
  const filename=path.join(testFiles,'plan-input.json');await fs.writeFile(filename,JSON.stringify({worktree:root,runId:U}));const result=await runCli(['plan',filename]);assert.equal(result.engine,'NOT_RUN');assert.match(result.status,/NO_RUNTIME_ADMISSION/);await assert.rejects(runCli(['smoke',filename]),e=>e.code==='OWNER_RUNTIME_CAPABILITY_REQUIRED');
});

test('reviewed fixed migration batch is accepted without accepting arbitrary SQL batches',async()=>{
  const sql=await fs.readFile(new URL('../../sql/001-b1.sql',import.meta.url),'utf8');
  assert.equal(classifySql(sql),'migration');const t=new CommitTracker();step(t,'BEGIN','BEGIN');t.frontend(query(sql));assert.equal(t.pending,'migration');
  for(const tag of ['CREATE SCHEMA','CREATE TABLE','CREATE FUNCTION','GRANT'])assert.equal(t.backend(complete(tag)).forward,true);assert.equal(t.backend(ready('T')).forward,true);step(t,'COMMIT','COMMIT','I');
  assert.throws(()=>classifySql(sql+' '));assert.throws(()=>classifySql('SELECT 1; SELECT 2'));
});

test('late callback inherits a closed case scope and cannot create a new pool or worker',async()=>{
  const {harness}=await pureHarness(),owner={budget:new ConnectionBudget(),signal:new AbortController().signal};let release,late;
  const resources=budgetHarness(harness,owner),gate=new Promise(r=>{release=r;});
  await resources.runCase(async()=>{late=gate.then(()=>{assert.throws(()=>harness.newStore(),e=>e.code==='OWNER_CASE_SCOPE_ENDED');return assert.rejects(harness.issuanceWorker(),e=>e.code==='OWNER_CASE_SCOPE_ENDED');});});
  release();await late;assert.equal(owner.budget.state.used,0);await harness.close();
});

test('actual harness emits the four supported lifecycle actions; unknown actions stay denied',async()=>{
  const seen=[],gate=new PhaseGate({runId:U,authorize:async()=>true});
  const {harness}=await pureHarness({onAdmission:async action=>{
    await gate.require(action);seen.push(action);
    if(action!=='connect-owned-fixture')throw new OwnerError('PURE_STOP_BEFORE_ENGINE');
  }});
  for(const call of [()=>harness.restartDatabase('clean'),()=>harness.restartDatabase('crash'),()=>harness.exhaustSerialization({maximumAttempts:3}),()=>harness.issuanceWorker()])
    await assert.rejects(call(),e=>e.code==='PURE_STOP_BEFORE_ENGINE');
  assert.deepEqual(seen,['connect-owned-fixture','restart-clean','restart-crash','serialization-fixture','start-owned-worker']);
  await assert.rejects(gate.require('restart-arbitrary'),e=>e.code==='OWNER_ACTION');
  assert.deepEqual(gate.denied,[{action:'restart-arbitrary',reason:'UNKNOWN_ACTION'}]);await harness.close();
});
test('secret materialization precedes mount creation and a failed write prevents create',async()=>{
  const secret=path.join(testFiles,'bootstrap'),events=[];
  const result=await createContainerWithSecret({writeSecret:async()=>{await fs.writeFile(secret,'fixture-only',{mode:0o600});events.push('secret');},create:async()=>{assert.equal(await fs.readFile(secret,'utf8'),'fixture-only');events.push('create');return 'container';}});
  assert.equal(result,'container');assert.deepEqual(events,['secret','create']);assert.equal((await fs.stat(secret)).mode&0o777,0o600);
  await assert.rejects(createContainerWithSecret({writeSecret:async()=>{throw new Error('write failed');},create:async()=>{events.push('unexpected');}}),/write failed/);
  assert.deepEqual(events,['secret','create']);
  const args=containerArgs(plan,'a'.repeat(64));assert.ok(args.includes('type=bind,src='+plan.guestRoot+'/secrets/bootstrap,dst=/run/secrets/bootstrap,readonly'));
  assert.doesNotMatch(JSON.stringify(args),/fixture-only/);
});
test('container bootstrap authenticates local and host access with SCRAM',()=>{
  const args=containerArgs(plan,'a'.repeat(64));
  assert.ok(args.includes('POSTGRES_USER=b1_bootstrap'));
  assert.ok(args.includes('POSTGRES_PASSWORD_FILE=/run/secrets/bootstrap'));
  assert.ok(args.includes('POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256 --auth-local=scram-sha-256'));
  assert.doesNotMatch(JSON.stringify(args),/auth-local=peer|auth-host=trust/);
  // Argument construction only: no entrypoint/bootstrap or guest quota execution.
});
test('persisted fixture identity remains private, exportable, signable and stable on reload',async t=>{
  const dir=path.join(testFiles,'bindings');await fs.mkdir(dir,{mode:0o700});let fingerprint;
  const base=new OwnerSupervisor({plan:{...createPlan({worktree:currentWorktree,runId:U}),artifactRoot:dir},manifest:{},authorize:async()=>true});await assert.rejects(base.preflight(),e=>e.code==='OWNER_MANIFEST');
  const owner={plan:base.plan,signal:base.signal,captureAdmission:base.captureAdmission.bind(base),gate:{require:async action=>assert.equal(action,'create-owned-root')},setBindingsFingerprint:value=>{base.setBindingsFingerprint(value);fingerprint=value;}};
  const first=await persistentBindings(owner),jwk=await exportJWK(first.serverKey.privateKey);
  assert.equal(jwk.d.length>0,true);assert.equal(first.serverKey.privateKey.extractable,true);
  const claims={version:1,purpose:'pure fixture regression'},signed=await first.config.signer.sign(claims);
  const verified=await compactVerify(signed,first.serverKey.publicKey);assert.deepEqual(JSON.parse(Buffer.from(verified.payload).toString()),claims);
  const family=await first.family('case-a'),request=first.grantOwnership('installation',family,'fixture-subject');
  const admin=await first.config.administration.verify(first.adminCapability),second=await persistentBindings(owner);
  assert.deepEqual(await exportJWK(second.serverKey.privateKey),jwk);assert.equal(fingerprint,digest(canonical(first.serverKey.jwk)));
  assert.equal((await second.family('case-a')).fingerprint,family.fingerprint);
  assert.deepEqual(await second.config.administration.verify(second.adminCapability),admin);
  assert.deepEqual(await second.config.ownership.verify({installationId:'installation',request,recipientFingerprint:family.fingerprint}),{installationId:'installation',profileKind:'normal',subject:'fixture-subject'});
  assert.equal((await fs.stat(dir)).mode&0o777,0o700);assert.equal((await fs.stat(path.join(dir,'fixture-bindings.json'))).mode&0o777,0o600);
  await assert.rejects(second.config.administration.verify(first.adminCapability),e=>e.code==='UNAUTHORIZED');
  await first.store.close();await second.store.close();
});
test('actual resource lifecycle bounds rejection and stalls while retaining uncertain handles',async()=>{
  const owner={budget:new ConnectionBudget(),signal:new AbortController().signal},resources=createResourceLifecycle(owner),bad={},slow={};let resolve;
  resources.hooks.track('store',bad,async()=>{throw new OwnerError('PURE_CLOSE_REJECTED');});
  resources.hooks.track('worker',slow,()=>new Promise(yes=>{resolve=yes;}));
  const began=performance.now();await assert.rejects(resources.closeCase({deadline:began+40}),e=>{
    assert.deepEqual(e.failures.map(v=>v.code),['PURE_CLOSE_REJECTED','OWNER_DEADLINE']);return e.code==='OWNER_CASE_CLEANUP_INCOMPLETE';
  });assert.ok(performance.now()-began<500);assert.equal(resources.state().stores,1);assert.equal(resources.state().workers,1);
  resolve();await flush();assert.equal(resources.state().workers,1);resources.hooks.settled(slow);assert.equal(resources.state().workers,0);
});
test('finish always invokes owner teardown after resource rejection and harness stall, retaining failures',async()=>{
  const events=[],nested=[{name:'store-0',status:'UNCERTAIN',code:'PURE_STORE_FAILED'}];let late;
  const runtime={resources:{closeCase:async()=>{events.push('resources');throw Object.assign(new OwnerError('OWNER_CASE_CLEANUP_INCOMPLETE'),{failures:nested});}},harness:{close:()=>{events.push('harness');return new Promise(resolve=>{late=resolve;});}},owner:{cleanup:async()=>{events.push('owner');return {status:'STOPPED_RETAINED'};}}};
  const began=performance.now();await assert.rejects(finishRuntime(runtime,{deadline:began+50}),error=>{
    assert.equal(error.code,'OWNER_CLEANUP_INCOMPLETE');assert.deepEqual(error.failures[0].failures,nested);assert.equal(error.failures[1].code,'OWNER_DEADLINE');return true;
  });assert.deepEqual(events,['resources','harness','owner']);assert.ok(performance.now()-began<500);late();await flush();
});
test('finish retains rejected or stalled owner teardown as incomplete',async()=>{
  for(const close of [async()=>{throw new OwnerError('PURE_OWNER_FAILED');},()=>new Promise(()=>{})]){
    let calls=0;await assert.rejects(finishRuntime({owner:{cleanup:()=>{calls++;return close();}}},{deadline:performance.now()+30}),e=>e.code==='OWNER_CLEANUP_INCOMPLETE'&&e.cleanup.status==='CLEANUP_INCOMPLETE_RETAINED');assert.equal(calls,1);
  }
});
test('fractional cleanup budgets floor without extending their absolute deadline',()=>{
  assert.equal(remainingMilliseconds(100.9,100,1.2),99);assert.equal(remainingMilliseconds(100.9,30,1.2),30);
  const timeoutMs=remainingMilliseconds(10.9,100,1.2);assert.equal(command(plan,'docker',['inspect','a'.repeat(64)],{timeoutMs}).timeoutMs,9);
  for(const [end,now] of [[1.9,1.2],[1,2],[NaN,0],[Infinity,0]])assert.throws(()=>remainingMilliseconds(end,100,now),e=>e.code==='OWNER_DEADLINE');
  assert.throws(()=>remainingMilliseconds(100,1.5,0),e=>e.code==='OWNER_INTEGER');
});
test('installed executable aliases resolve to pinned canonical targets while cache aliases remain invalid',async()=>{
  const dir=path.join(testFiles,'tools');await fs.mkdir(dir);const binary=path.join(dir,'colima'),alias=path.join(dir,'alias'),other=path.join(dir,'other');
  await fs.writeFile(binary,'pure executable fixture',{mode:0o755});await fs.writeFile(other,'changed executable',{mode:0o755});await fs.symlink(binary,alias);
  const stat=await fs.stat(binary),pin={canonicalPath:await fs.realpath(binary),bytes:stat.size,sha256:digest(await fs.readFile(binary))};
  const executable=await resolveExecutable(alias,pin),spec=command(plan,'colima',['--version'],{executable});assert.equal(spec.executable,pin.canonicalPath);
  await fs.unlink(alias);await fs.symlink(other,alias);assert.equal(spec.executable,pin.canonicalPath);await assert.rejects(resolveExecutable(alias,pin),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
  await assert.rejects(regular(alias),e=>e.code==='OWNER_REGULAR_FILE');await fs.chmod(binary,0o644);await assert.rejects(resolveExecutable(binary,pin),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
});

// Scripted transport only: actual PostgresStore guards execute, no SQL engine.
function disconnectDriver({mode,event}){
  const pool=new EventEmitter(),clients=[],ledger={pending:null,highwater:0},lost=mode==='marker'?1:2;let commits=0;
  pool.connect=async()=>{
    const client=new EventEmitter();client._txStatus='I';client.released=[];client.destroyed=0;
    client.connection={stream:{destroy(){client.destroyed++;}}};client.release=discard=>client.released.push(discard);
    client.query=async(sql,values=[])=>{
      if(sql.startsWith('BEGIN'))client._txStatus='T';
      if(sql.includes('clock_try_lock('))return {rows:[{acquired:true}]};
      if(sql.includes('clock_begin(')){ledger.pending=values[5];return {rows:[{ready:true}]};}
      if(sql.includes('clock_finish(')){assert.equal(ledger.pending,values[5]);ledger.pending=null;ledger.highwater=values[6];return {rows:[{completed:true,highwater:String(ledger.highwater),db_now:'0',rollback_detected:false}]};}
      if(sql==='COMMIT'){commits++;client._txStatus='I';if(commits===lost){client.emit(event,...(event==='error'?[new Error('scripted disconnect')]:[]));return new Promise(()=>{});}}
      if(sql.includes('clock_unlock('))return {rows:[{released:true}]};return {rows:[]};
    };clients.push(client);return client;
  };pool.end=async()=>{};return {pool,clients,ledger,commits:()=>commits};
}
for(const mode of ['marker','observation'])for(const event of ['error','end'])test('actual clock guard preserves DB_UNAVAILABLE on scripted '+mode+' COMMIT '+event,async()=>{
  const bindings=await fixtureBindings(),d=disconnectDriver({mode,event}),store=new PostgresStore({pool:d.pool});let samples=0;
  await assert.rejects(store.observeTime({trust:bindings.config.trust,deadline:performance.now()+1000,signal:new AbortController().signal},()=>{samples++;return {now:100,uncertaintySeconds:0};}),isClockDisconnect);
  assert.equal(samples,mode==='marker'?0:1);assert.equal(d.commits(),mode==='marker'?1:2);assert.equal(d.clients.length,2);
  assert.ok(d.clients[1].released.includes(true));assert.ok(d.clients[1].destroyed>0);
  assert.equal(d.ledger.pending===null,mode==='observation');assert.equal(d.ledger.highwater,mode==='marker'?0:100);
  await store.close();await bindings.store.close();
});
test('clock disconnect predicate requires the guarded ProviderError class and exact code',()=>{
  assert.equal(isClockDisconnect(new ProviderError('DB_UNAVAILABLE')),true);assert.equal(isClockDisconnect(new ProviderError('CLOCK_UNTRUSTED')),false);
  assert.equal(isClockDisconnect(Object.assign(new Error('DB_UNAVAILABLE'),{code:'DB_UNAVAILABLE'})),false);
});
function fakeTimers(){
  const timers=new Map();let id=0;return {timers,schedule:(callback,ms)=>{timers.set(++id,{callback,ms});return id;},cancel:key=>timers.delete(key),fire:()=>{const list=[...timers.values()];timers.clear();for(const t of list)t.callback();}};
}
const auth=code=>{const body=Buffer.alloc(4);body.writeUInt32BE(code);return frame('R',body);};
test('startup deadline survives Startup, auth exchanges and every split of authenticated initial Ready',()=>{
  const bytes=Buffer.concat([auth(10).raw,auth(0).raw,frame('K',Buffer.alloc(8)).raw,ready('I').raw]);
  for(let split=0;split<=bytes.length;split++){
    const timers=fakeTimers(),expired=[],lifetime=new WireLifetime({...timers,onExpire:e=>expired.push(e.code)}),frontend=new FrameDecoder({startup:true}),backend=new FrameDecoder();
    for(const f of frontend.push(startup()))lifetime.frontend(f);lifetime.transaction(false);assert.equal(timers.timers.size,1);
    lifetime.frontend(frame('p',Buffer.from('opaque SCRAM response')));
    for(const f of backend.push(bytes.subarray(0,split)))lifetime.backend(f);
    assert.equal(lifetime.startupComplete,split===bytes.length);assert.equal(timers.timers.size,split===bytes.length?0:1);
    for(const f of backend.push(bytes.subarray(split)))lifetime.backend(f);
    assert.equal(lifetime.startupComplete,true);assert.equal(timers.timers.size,0);timers.fire();assert.deepEqual(expired,[]);lifetime.close();
  }
});
test('authentication stall expires; unauthenticated Ready/query fails; transaction deadline is independent',()=>{
  const timers=fakeTimers(),expired=[],lifetime=new WireLifetime({...timers,onExpire:e=>expired.push(e.code)});
  lifetime.frontend(new FrameDecoder({startup:true}).push(startup())[0]);lifetime.backend(auth(10));lifetime.frontend(frame('p',Buffer.from('opaque')));lifetime.transaction(false);
  timers.fire();assert.deepEqual(expired,['WIRE_STARTUP_DEADLINE']);lifetime.close();
  const secondTimers=fakeTimers(),second=new WireLifetime({...secondTimers,onExpire:e=>expired.push(e.code)});
  second.frontend(new FrameDecoder({startup:true}).push(startup())[0]);assert.throws(()=>second.backend(ready('I')),e=>e.code==='WIRE_STARTUP_NOT_COMPLETE');assert.throws(()=>second.frontend(query('SELECT 1')),e=>e.code==='WIRE_AUTHENTICATION_INCOMPLETE');
  second.backend(auth(0));second.backend(ready('I'));second.transaction(true);assert.equal(secondTimers.timers.size,1);assert.equal([...secondTimers.timers.values()][0].ms,5000);
  secondTimers.fire();assert.equal(expired.at(-1),'WIRE_TRANSACTION_DEADLINE');second.close();
});

test('finish preserves all actual lifecycle failure results before its enclosing deadline',async()=>{
  const owner={budget:new ConnectionBudget(),signal:new AbortController().signal,cleanup:async()=>({status:'STOPPED_RETAINED'})},resources=createResourceLifecycle(owner);
  resources.hooks.track('store',{},async()=>{throw new OwnerError('PURE_FIRST_FAILURE');});resources.hooks.track('worker',{},()=>new Promise(()=>{}));
  await assert.rejects(finishRuntime({owner,resources},{deadline:performance.now()+70}),error=>{
    assert.equal(error.failures[0].code,'OWNER_CASE_CLEANUP_INCOMPLETE');assert.deepEqual(error.failures[0].failures.map(f=>f.code),['PURE_FIRST_FAILURE','OWNER_DEADLINE']);return true;
  });
});

// The same helper used by runDeadlock: fixture doubles have no HTTP listener.
test('deadlock registration rejection always closes the application and preserves its original error',async()=>{
  const failure=new ProviderError('DB_UNAVAILABLE'),events=[],f={close:async()=>events.push('application-close')};
  await assert.rejects(registerFixtureAndClose(f,'pure',{registerFixture:async app=>{assert.equal(app,f);events.push('register');throw failure;}}),e=>e===failure);
  assert.deepEqual(events,['register','application-close']);
});
test('deadlock non201 assertion also closes the whole application',async()=>{
  const events=[],f={close:async()=>events.push('application-close')};
  await assert.rejects(registerFixtureAndClose(f,'pure',{registerFixture:async()=>({status:503})}),e=>e.code==='ERR_ASSERTION'&&e.actual===503&&e.expected===201);
  assert.deepEqual(events,['application-close']);
});
test('deadlock successful registration retains its result after exactly one application close',async()=>{
  const result={status:201,json:{claims:{installationRef:'fixture'}}};let closes=0;
  assert.equal(await registerFixtureAndClose({close:async()=>closes++},'pure',{registerFixture:async()=>result}),result);assert.equal(closes,1);
});
test('deadlock cleanup rejection retains both registration and closure failure',async()=>{
  const failure=new ProviderError('DB_UNAVAILABLE');let closes=0;
  await assert.rejects(registerFixtureAndClose({close:async()=>{closes++;throw new OwnerError('PURE_APPLICATION_CLOSE_FAILED');}},'pure',{registerFixture:async()=>{throw failure;}}),e=>{
    assert.equal(e.cause,failure);assert.equal(e.failures[0].code,'PURE_APPLICATION_CLOSE_FAILED');return e.code==='OWNER_FAULT_APP_CLEANUP_INCOMPLETE';
  });assert.equal(closes,1);
});
test('deadlock stalled cleanup is bounded and retains the non201 assertion and uncertain state',async()=>{
  let closes=0,late;const began=performance.now();
  await assert.rejects(registerFixtureAndClose({close:()=>{closes++;return new Promise(resolve=>{late=resolve;});}},'pure',{registerFixture:async()=>({status:409}),cleanupMs:30}),e=>{
    assert.equal(e.cause.code,'ERR_ASSERTION');assert.equal(e.cause.actual,409);assert.equal(e.failures[0].code,'OWNER_DEADLINE');return e.code==='OWNER_FAULT_APP_CLEANUP_INCOMPLETE';
  });assert.equal(closes,1);assert.ok(performance.now()-began<500);late();await flush();
});
const currentWorktree=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../../../..');
async function measureReviewed(worktree){
  const files=[];
  for(const name of RUNTIME_SOURCE_FILES){const filename=path.join(worktree,name),data=await fs.readFile(filename);files.push({path:name,type:'file',bytes:data.length,sha256:digest(data)});}
  const entry=await fs.realpath(createRequire(worktree+'/prototypes/access-provider-service/package.json').resolve('@aegis-local/access-provider-contract'));
  // Deliberately fabricated review inputs for pure validator tests. These do
  // not authorize resource startup and are never real review receipts.
  return {format:'B1_REVIEWED_RUNTIME_SOURCES_V1',worktree,files,resolvedContract:{entryPath:path.relative(worktree,entry)}};
}
async function reviewedFixture(){
  const base=await fs.mkdtemp(path.join(testFiles,'reviewed-')),worktree=await fs.realpath(base);
  for(const name of RUNTIME_SOURCE_FILES){const filename=path.join(worktree,name);await fs.mkdir(path.dirname(filename),{recursive:true});await fs.copyFile(path.join(currentWorktree,name),filename);}
  const installed=path.join(worktree,'prototypes/access-provider-service/node_modules/.pnpm/pure-contract/node_modules/@aegis-local/access-provider-contract'),alias=path.join(worktree,'prototypes/access-provider-service/node_modules/@aegis-local/access-provider-contract');
  await fs.mkdir(installed,{recursive:true});await fs.mkdir(path.dirname(alias),{recursive:true});
  for(const name of ['README.md','package.json','contract.mjs','contract.test.mjs','vectors.json'])await fs.copyFile(path.join(worktree,'prototypes/access-provider-contract',name),path.join(installed,name));
  await fs.symlink(installed,alias);return {worktree,installed,alias,reviewed:await measureReviewed(worktree)};
}
const changedSource=e=>e.code==='OWNER_REVIEW_SOURCE_CHANGED';
test('complete reviewed source validator rejects missing omitted duplicate unexpected and stale manifest entries',async()=>{
  const {worktree,reviewed}=await reviewedFixture(),plan={worktree};assert.equal(reviewed.files.length,27);assert.equal(await verifyReviewedSources(plan,reviewed),true);
  const missing=structuredClone(reviewed);missing.files.pop();
  const duplicate=structuredClone(reviewed);duplicate.files[26]=duplicate.files[0];
  const unexpected=structuredClone(reviewed);unexpected.files[0].path='prototypes/access-provider-service/unreviewed.mjs';
  const stale=structuredClone(reviewed);stale.files[0].sha256='0'.repeat(64);
  const wrongSize=structuredClone(reviewed);wrongSize.files[0].bytes++;
  const wrongRoot=structuredClone(reviewed);wrongRoot.worktree+='/elsewhere';
  const wrongDependency=structuredClone(reviewed);wrongDependency.resolvedContract.entryPath='prototypes/access-provider-contract/contract.mjs';
  for(const manifest of [undefined,missing,duplicate,unexpected,stale,wrongSize,wrongRoot,wrongDependency])await assert.rejects(verifyReviewedSources(plan,manifest),changedSource);
  const extra=path.join(worktree,'prototypes/access-provider-service/unreviewed.mjs');await fs.writeFile(extra,'// unreviewed');await assert.rejects(verifyReviewedSources(plan,reviewed),changedSource);await fs.unlink(extra);
  const missingFile=path.join(worktree,'prototypes/access-provider-service/test/pg-harness.mjs'),saved=await fs.readFile(missingFile);await fs.unlink(missingFile);await assert.rejects(verifyReviewedSources(plan,reviewed),changedSource);await fs.writeFile(missingFile,saved);
  assert.equal(await verifyReviewedSources(plan,reviewed),true);
});
test('every logical service21 and contract6 input drift refuses the prior approved manifest',async()=>{
  const {worktree,reviewed}=await reviewedFixture();
  assert.equal(await verifyReviewedSources({worktree},reviewed),true);
  for(const name of RUNTIME_SOURCE_FILES){const filename=path.join(worktree,name),saved=await fs.readFile(filename);await fs.appendFile(filename,'\n');await assert.rejects(verifyReviewedSources({worktree},reviewed),changedSource,name);await fs.writeFile(filename,saved);}
  assert.equal(await verifyReviewedSources({worktree},reviewed),true);
});
test('source binding checks materialized Node dependency bytes and rejects alias retargeting',async()=>{
  const {worktree,reviewed,installed,alias}=await reviewedFixture();
  assert.equal(await verifyReviewedSources({worktree},reviewed),true);
  for(const name of ['README.md','package.json','contract.mjs','contract.test.mjs','vectors.json']){const filename=path.join(installed,name),saved=await fs.readFile(filename);await fs.appendFile(filename,'\n');await assert.rejects(verifyReviewedSources({worktree},reviewed),changedSource);await fs.writeFile(filename,saved);}
  const elsewhere=path.join(worktree,'different-contract');await fs.mkdir(elsewhere);
  for(const name of ['README.md','package.json','contract.mjs','contract.test.mjs','vectors.json'])await fs.copyFile(path.join(installed,name),path.join(elsewhere,name));
  await fs.unlink(alias);await fs.symlink(elsewhere,alias);await assert.rejects(verifyReviewedSources({worktree},reviewed),changedSource);
});
test('actual capability loading binds CLEAR receipt and immutable source reference, rechecking before each action',async()=>{
  const dir=await fs.mkdtemp(path.join(testFiles,'capability-')),manifest=await measureReviewed(currentWorktree),manifestPath=path.join(dir,'sources.json'),receiptPath=path.join(dir,'review.json'),capPath=path.join(dir,'capability.json');
  const manifestRaw=JSON.stringify(manifest),manifestHash=digest(manifestRaw),receipt={decision:'CLEAR',reviewedIdentity:{runtimeSourceManifestSha256:manifestHash}},receiptRaw=JSON.stringify(receipt);
  await fs.writeFile(manifestPath,manifestRaw);await fs.writeFile(receiptPath,receiptRaw);
  const tools={colima:{canonicalPath:'/pure/colima',bytes:1,sha256:'a'.repeat(64)}},cap={status:'SOURCE_REVIEWED_RUNTIME_PHASE_ADMITTED',runId:U,actions:['preflight'],expiresAt:new Date(Date.now()+60000).toISOString(),reviewedSources:{path:manifestPath,sha256:manifestHash},independentReview:{path:receiptPath,sha256:digest(receiptRaw)},manifest:{tools}};
  const saveCap=async value=>fs.writeFile(capPath,JSON.stringify(value));await saveCap(cap);
  const authorization=await capabilityAuthorizer(capPath,{worktree:currentWorktree,runId:U});assert.ok(Number.isFinite(authorization.authorize.expiresAt));assert.equal(Object.getOwnPropertyDescriptor(authorization.authorize,'expiresAt').writable,false);assert.deepEqual(authorization.manifest.tools,tools);
  assert.equal(await authorization.authorize({runId:U,action:'preflight'}),true);assert.equal(await authorization.authorize({runId:U,action:'docker-start'}),false);
  assert.equal(authorization.manifest.sourceSha256['guest.sh'],manifest.files.find(f=>f.path.endsWith('/guest.sh')).sha256);
  await fs.appendFile(manifestPath,' ');await assert.rejects(authorization.authorize({runId:U,action:'preflight'}),changedSource);await fs.writeFile(manifestPath,manifestRaw);
  await fs.appendFile(receiptPath,' ');await assert.rejects(authorization.authorize({runId:U,action:'preflight'}),e=>e.code==='OWNER_REVIEW_RECEIPT');await fs.writeFile(receiptPath,receiptRaw);
  for(const changed of [{...cap,reviewedSources:undefined},{...cap,reviewedSources:{...cap.reviewedSources,path:path.join(dir,'missing')}},{...cap,reviewedSources:{...cap.reviewedSources,sha256:'0'.repeat(64)}}]){await saveCap(changed);await assert.rejects(capabilityAuthorizer(capPath,{worktree:currentWorktree,runId:U}),changedSource);}
  const notClear=JSON.stringify({...receipt,decision:'NOT_CLEAR'});await fs.writeFile(receiptPath,notClear);await saveCap({...cap,independentReview:{path:receiptPath,sha256:digest(notClear)}});await assert.rejects(capabilityAuthorizer(capPath,{worktree:currentWorktree,runId:U}),e=>e.code==='OWNER_REVIEW_RECEIPT');
  await fs.writeFile(receiptPath,receiptRaw);await fs.appendFile(manifestPath,' ');const changedHash=digest(manifestRaw+' ');await saveCap({...cap,reviewedSources:{path:manifestPath,sha256:changedHash}});await assert.rejects(capabilityAuthorizer(capPath,{worktree:currentWorktree,runId:U}),e=>e.code==='OWNER_REVIEW_RECEIPT');
});
function savePgEnvironment(){const saved=Object.fromEntries(['PGSSLMODE','PGSSLNEGOTIATION'].map(k=>[k,process.env[k]]));return ()=>{for(const [k,v] of Object.entries(saved))if(v===undefined)delete process.env[k];else process.env[k]=v;};}
test('fixture TLS admission rejects require and direct negotiation; allowed setup uses actual pinned pg Client defaults',async()=>{
  const restore=savePgEnvironment();
  try{
    delete process.env.PGSSLNEGOTIATION;
    for(const mode of ['require','prefer','verify-full','no-verify','unknown','']){process.env.PGSSLMODE=mode;let admissions=0;await assert.rejects(pureHarness({onAdmission:async()=>admissions++}),e=>e.code==='OWNER_PG_TLS_ENV');assert.equal(admissions,0);}
    process.env.PGSSLMODE='disable';process.env.PGSSLNEGOTIATION='direct';assert.throws(()=>assertFixtureEnvironment(),e=>e.code==='OWNER_PG_TLS_ENV');
    for(const mode of [undefined,'disable']){
      if(mode===undefined)delete process.env.PGSSLMODE;else process.env.PGSSLMODE=mode;process.env.PGSSLNEGOTIATION='postgres';assertFixtureEnvironment();
      const pool=createOwnedPool({host:'127.0.0.1',port:54321,user:'b1_app',database:'b1',password:'pure-only'}),client=new pool.Client(pool.options);
      assert.equal(client.ssl,false);assert.equal(client.sslNegotiation,'postgres');await pool.end();
      const {harness}=await pureHarness();assertAdmitted(harness);assert.equal(Object.isFrozen(harness),true);await harness.close();
    }
  }finally{restore();}
});
test('TLS environment drift after real harness admission refuses a new pool without changing process environment',async()=>{
  const restore=savePgEnvironment();let harness;
  try{
    delete process.env.PGSSLMODE;delete process.env.PGSSLNEGOTIATION;({harness}=await pureHarness());process.env.PGSSLMODE='require';
    assert.throws(()=>harness.newStore(),e=>e.code==='OWNER_PG_TLS_ENV');assert.equal(process.env.PGSSLMODE,'require');
    delete process.env.PGSSLMODE;const store=harness.newStore();await store.close();assertAdmitted(harness);
  }finally{restore();await harness?.close();}
});
test('owner rejects incompatible TLS before preflight authorization or connection selection',async()=>{
  const restore=savePgEnvironment();let grants=0;
  try{
    process.env.PGSSLMODE='require';delete process.env.PGSSLNEGOTIATION;
    const owner=new OwnerSupervisor({plan,manifest:{},authorize:async()=>{grants++;return true;}});
    await assert.rejects(owner.preflight(),e=>e.code==='OWNER_PG_TLS_ENV');assert.equal(grants,0);assert.throws(()=>owner.connections(),e=>e.code==='OWNER_PG_TLS_ENV');assert.equal(owner.phase,'new');
  }finally{restore();}
});

// Real pg-pool/client construction and harness/store lifetime, fake transport.
// Client.connect/query/end are mocked before any effectful connection method.
function scriptedPinnedPg(t){
  const clients=[],ended=[],ledger={pending:null,highwater:0};
  t.mock.method(Client.prototype,'connect',function(callback){
    assert.equal(this.ssl,false);assert.equal(this.sslNegotiation,'postgres');assert.equal(this.connectionParameters.ssl,false);assert.equal(this.connectionParameters.sslnegotiation,'postgres');
    this._txStatus='I';clients.push(this);queueMicrotask(()=>callback(null));
  });
  t.mock.method(Client.prototype,'query',async function(sql,values=[]){
    if(sql.startsWith('BEGIN'))this._txStatus='T';if(sql==='COMMIT'||sql==='ROLLBACK')this._txStatus='I';
    if(sql.includes('clock_try_lock('))return {rows:[{acquired:true}]};
    if(sql.includes('clock_begin(')){assert.equal(ledger.pending,null);ledger.pending=values[5];return {rows:[{ready:true}]};}
    if(sql.includes('clock_finish(')){assert.equal(ledger.pending,values[5]);ledger.pending=null;ledger.highwater=Math.max(ledger.highwater,values[6]);return {rows:[{completed:true,highwater:String(ledger.highwater),db_now:'0',rollback_detected:false}]};}
    if(sql.includes('clock_unlock('))return {rows:[{released:true}]};return {rows:[]};
  });
  t.mock.method(Client.prototype,'end',function(callback){
    this._ending=true;ended.push(this);queueMicrotask(()=>{this.emit('end');callback?.();});return Promise.resolve();
  });
  return {clients,ended,ledger};
}
const observePure=(store,harness,now)=>store.observeTime({trust:harness.trust,deadline:performance.now()+4000,signal:new AbortController().signal},()=>({now,uncertaintySeconds:0}));
for(const [setting,value] of [['PGSSLMODE','require'],['PGSSLNEGOTIATION','direct']])test('actual harness first checkout pins TLS after store creation then '+setting+' drift',async t=>{
  const restore=savePgEnvironment(),driver=scriptedPinnedPg(t);let harness,store,bindings;
  try{
    delete process.env.PGSSLMODE;delete process.env.PGSSLNEGOTIATION;({harness,bindings}=await pureHarness());store=harness.newStore();assert.equal(driver.clients.length,0);
    process.env[setting]=value;const observed=await observePure(store,harness,100);assert.equal(observed.latest,100);assert.equal(driver.clients.length,2);assert.equal(process.env[setting],value);
    // Reuse remains compatible, and restoring env allows the next operation.
    delete process.env[setting];assert.equal((await observePure(store,harness,101)).latest,101);assert.equal(driver.clients.length,2);assertAdmitted(harness);assert.equal(Object.isFrozen(harness),true);
  }finally{try{await store?.close();await harness?.close();await bindings?.store.close();}finally{restore();t.mock.restoreAll();}}
});
test('actual pg-pool idle expiry replaces harness clients with pinned TLS despite later require/direct env',async t=>{
  const restore=savePgEnvironment(),driver=scriptedPinnedPg(t);let harness,store,bindings;
  try{
    delete process.env.PGSSLMODE;delete process.env.PGSSLNEGOTIATION;({harness,bindings}=await pureHarness());store=harness.newStore();
    assert.equal((await observePure(store,harness,200)).latest,200);assert.equal(driver.clients.length,2);assert.equal(driver.ended.length,0);
    const original=driver.clients.slice();process.env.PGSSLMODE='require';process.env.PGSSLNEGOTIATION='direct';
    // Preserve actual fixture idleTimeoutMillis=1000. Its real expiry removes
    // both released clients; this is no manual/fake pool replacement.
    const deadline=performance.now()+2500;
    while(driver.ended.length<2){assert.ok(performance.now()<deadline,'pinned pg-pool idle expiry missing');await new Promise(resolve=>setTimeout(resolve,20));}
    assert.equal((await observePure(store,harness,201)).latest,201);assert.equal(driver.clients.length,4);assert.ok(driver.clients.slice(2).every(c=>!original.includes(c)));
    assert.equal(process.env.PGSSLMODE,'require');assert.equal(process.env.PGSSLNEGOTIATION,'direct');assertAdmitted(harness);
  }finally{try{await store?.close();await harness?.close();await bindings?.store.close();}finally{restore();t.mock.restoreAll();}}
});

test('executable fixture pins the real target through a symlinked temp parent and rejects lexical or stale pins',async()=>{
  const base=await fs.mkdtemp(path.join(tmpdir(),'owner-linked-parent-'));
  try{
    const target=path.join(base,'real'),linked=path.join(base,'linked');await fs.mkdir(target);await fs.symlink(target,linked);
    const binary=path.join(linked,'colima'),alias=path.join(linked,'entry');await fs.writeFile(binary,'pure parent-alias executable',{mode:0o755});await fs.symlink(binary,alias);
    const canonicalPath=await fs.realpath(binary),data=await fs.readFile(binary),pin={canonicalPath,bytes:data.length,sha256:digest(data)};
    assert.notEqual(binary,canonicalPath);assert.equal(await resolveExecutable(alias,pin),canonicalPath);
    await assert.rejects(resolveExecutable(alias,{...pin,canonicalPath:binary}),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
    await assert.rejects(resolveExecutable(alias,{...pin,sha256:'0'.repeat(64)}),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
    await assert.rejects(resolveExecutable(alias,{...pin,bytes:pin.bytes+1}),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
    await assert.rejects(regular(alias),e=>e.code==='OWNER_REGULAR_FILE');
  }finally{await fs.rm(base,{recursive:true,force:true});}
});

for(const validation of ['references','sources'])test('capability expiry during actual pending '+validation+' validation denies command and listener authorization',async t=>{
  const dir=await fs.mkdtemp(path.join(testFiles,'expiry-')),manifest=await measureReviewed(currentWorktree),manifestPath=path.join(dir,'sources.json'),receiptPath=path.join(dir,'review.json'),capPath=path.join(dir,'capability.json');
  const manifestRaw=JSON.stringify(manifest),manifestHash=digest(manifestRaw),receiptRaw=JSON.stringify({decision:'CLEAR',reviewedIdentity:{runtimeSourceManifestSha256:manifestHash}});
  let wall=Date.now();const end=wall+60000;t.mock.method(Date,'now',()=>wall);
  await fs.writeFile(manifestPath,manifestRaw);await fs.writeFile(receiptPath,receiptRaw);
  await fs.writeFile(capPath,JSON.stringify({status:'SOURCE_REVIEWED_RUNTIME_PHASE_ADMITTED',runId:U,actions:['preflight','start-owned-wire-proxy'],expiresAt:new Date(end).toISOString(),reviewedSources:{path:manifestPath,sha256:manifestHash},independentReview:{path:receiptPath,sha256:digest(receiptRaw)},manifest:{}}));
  const authorization=await capabilityAuthorizer(capPath,{worktree:currentWorktree,runId:U}),gate=new PhaseGate({runId:U,authorize:authorization.authorize}),owner={gate,signal:new AbortController().signal};
  let starts=0;const spec=command(plan,'colima',['--version']);
  assert.equal(await runAuthorizedCommand(owner,'preflight',spec,{deadline:performance.now()+10000},()=>{starts++;return 'inert';}),'inert');
  assert.equal(await authorization.authorize({runId:'b1234567-1234-4321-8765-123456789abc',action:'preflight'}),false);
  const entered=deferred(),release=deferred(),method=validation==='references'?'readFile':'readdir',original=fs[method],target=validation==='references'?receiptPath:currentWorktree+'/prototypes/access-provider-service';let held=false;
  t.mock.method(fs,method,async function(filename,...args){
    if(filename===target&&!held){held=true;entered.resolve();await release.promise;}
    return original.call(this,filename,...args);
  });
  const pending=runAuthorizedCommand(owner,'preflight',spec,{deadline:performance.now()+10000},()=>{starts++;});
  try{
    await entered.promise;wall=end;release.resolve();
    await assert.rejects(pending,e=>e.code==='OWNER_NOT_AUTHORIZED');assert.equal(starts,1);assert.equal(held,true);
    const proxy=new WireProxy({backendPort:54321,authorize:a=>gate.require(a)});
    await assert.rejects(proxy.start({deadline:performance.now()+10000,signal:owner.signal}),e=>e.code==='OWNER_NOT_AUTHORIZED');await proxy.close();
    assert.equal(gate.denied.length,2);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});

for(const [phase,action] of [['setup','colima-start'],['suite','docker-start']])test('shared command path refuses exhausted '+phase+' deadline after otherwise valid authorization',async t=>{
  let now=10,starts=0;t.mock.method(performance,'now',()=>now);
  const entered=deferred(),release=deferred(),owner={gate:new PhaseGate({runId:U,authorize:async()=>{entered.resolve();await release.promise;return true;}}),signal:new AbortController().signal};
  const pending=runAuthorizedCommand(owner,action,command(plan,'docker',['start','a'.repeat(64)]),{deadline:100},()=>{starts++;});
  try{await entered.promise;now=100;release.resolve();await assert.rejects(pending,e=>e.code==='OWNER_DEADLINE');assert.equal(starts,0);assert.deepEqual(owner.gate.denied,[]);}
  finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});

test('shared command path consumes authorization time from both command cap and original phase remainder',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);
  try{
    for(const row of [{phaseEnd:90,cap:50,resume:30,end:60,left:30},{phaseEnd:40,cap:100,resume:25,end:40,left:15}]){
      now=10;const entered=deferred(),release=deferred(),owner={gate:new PhaseGate({runId:U,authorize:async()=>{entered.resolve();await release.promise;return true;}}),signal:new AbortController().signal};
      const pending=runAuthorizedCommand(owner,'docker-start',command(plan,'docker',['start','a'.repeat(64)],{timeoutMs:row.cap}),{deadline:row.phaseEnd},budget=>budget);
      await entered.promise;now=row.resume;release.resolve();assert.deepEqual(await pending,{deadline:row.end,timeoutMs:row.left});
    }
  }finally{t.mock.restoreAll();}
});

test('shared command path retains authority and cancellation refusal; cleanup permission cannot renew deadlines',async t=>{
  let now=10,starts=0,authorizations=0;t.mock.method(performance,'now',()=>now);
  const controller=new AbortController(),owner={gate:new PhaseGate({runId:U,authorize:async()=>{authorizations++;return false;}}),signal:controller.signal},spec=command(plan,'docker',['stop','a'.repeat(64)],{timeoutMs:50}),start=()=>{starts++;return 'inert';};
  try{
    await assert.rejects(runAuthorizedCommand(owner,'docker-stop',spec,{deadline:100},start),e=>e.code==='OWNER_NOT_AUTHORIZED');assert.equal(starts,0);
    owner.gate=new PhaseGate({runId:U,authorize:async()=>{authorizations++;return true;}});controller.abort();
    await assert.rejects(runAuthorizedCommand(owner,'docker-stop',spec,{deadline:100},start),e=>e.code==='OWNER_CANCELLED');
    assert.equal(await runAuthorizedCommand(owner,'docker-stop',spec,{deadline:100,cleanup:true},start),'inert');assert.equal(starts,1);
    const before=authorizations;now=100;
    for(const deadline of [100,NaN,Infinity])await assert.rejects(runAuthorizedCommand(owner,'docker-stop',spec,{deadline,cleanup:true},start),e=>e.code==='OWNER_DEADLINE');
    assert.equal(starts,1);assert.equal(authorizations,before);
  }finally{t.mock.restoreAll();}
});

test('owner setup budget includes its initial pending preflight authorization',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred();
  const owner=new OwnerSupervisor({plan,manifest:{},authorize:async()=>{entered.resolve();await release.promise;return true;}}),pending=owner.preflight();
  try{await entered.promise;now=10+CAPS.setupMs;release.resolve();await assert.rejects(pending,e=>e.code==='OWNER_SETUP_DEADLINE');assert.equal(owner.phase,'new');assert.deepEqual(owner.events,[]);}
  finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});

test('actual owner cleanup cannot start a command when authorization resumes after finishRuntime deadline',async t=>{
  let now=0,lateCleanup;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),actions=[];
  const owner=new OwnerSupervisor({plan,manifest:{},authorize:async({action})=>{actions.push(action);if(action==='docker-stop'){entered.resolve();await release.promise;}return true;}});
  owner.owner={containerId:'a'.repeat(64)};owner.phase='provisioned';
  const finishing=finishRuntime({owner:{cleanup:options=>(lateCleanup=owner.cleanup(options))}},{deadline:30});
  const rejected=assert.rejects(finishing,e=>e.code==='OWNER_CLEANUP_INCOMPLETE'&&e.cleanup.status==='CLEANUP_INCOMPLETE_RETAINED');
  try{
    await entered.promise;await rejected;now=30;release.resolve();const receipt=await lateCleanup;
    assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.ok(owner.signal.aborted);
    assert.deepEqual(receipt.failures.filter(f=>['docker-stop','colima-stop'].includes(f.action)),[{action:'docker-stop',code:'OWNER_DEADLINE'},{action:'colima-stop',code:'OWNER_DEADLINE'}]);
    assert.deepEqual(actions,['cleanup','docker-stop']);assert.deepEqual(owner.events,[]);
  }finally{release.resolve();await rejected;await lateCleanup?.catch(()=>{});t.mock.restoreAll();}
});

test('actual owner cleanup cap starts before initial cleanup authorization even with a farther caller deadline',async t=>{
  let now=10,receipt;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),actions=[];
  const owner=new OwnerSupervisor({plan,manifest:{},authorize:async({action})=>{actions.push(action);if(action==='cleanup'){entered.resolve();await release.promise;}return true;}});
  owner.owner={containerId:'a'.repeat(64)};owner.phase='provisioned';const pending=owner.cleanup({deadline:10+2*CAPS.cleanupMs});
  try{
    await entered.promise;now=10+CAPS.cleanupMs;release.resolve();receipt=await pending;
    assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.deepEqual(actions,['cleanup']);
    assert.ok(receipt.failures.some(f=>f.action==='cleanup'&&f.code==='OWNER_DEADLINE'));assert.deepEqual(owner.events,[]);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});

function inertListener({onCreate=()=>{},onListen=null}={}){
  const state={created:0,listened:0,closed:0,options:null},server=new EventEmitter();
  server.listen=(options,ready)=>{state.listened++;state.options=options;if(onListen)onListen(ready);else queueMicrotask(ready);return server;};
  server.close=done=>{state.closed++;queueMicrotask(()=>done?.());return server;};server.address=()=>({port:54322});
  return {state,create:()=>{state.created++;onCreate();return server;}};
}
for(const during of ['expiry','cancel','close'])test('actual proxy start refuses '+during+' during pending authorization without creating a listener',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),controller=new AbortController(),listener=inertListener();
  const proxy=new WireProxy({backendPort:54321,createListener:listener.create,authorize:async action=>{assert.equal(action,'start-owned-wire-proxy');entered.resolve();await release.promise;}}),options={deadline:100,signal:controller.signal},pending=proxy.start(options);
  try{
    await entered.promise;await assert.rejects(proxy.start(options),e=>e.code==='WIRE_ALREADY_STARTED');
    if(during==='expiry')now=100;else if(during==='cancel')controller.abort();else await proxy.close();release.resolve();
    await assert.rejects(pending,e=>e.code===({expiry:'WIRE_PHASE_DEADLINE',cancel:'WIRE_CANCELLED',close:'WIRE_ALREADY_STARTED'}[during]));
    assert.equal(listener.state.created,0);assert.equal(listener.state.listened,0);
    if(during==='close')await assert.rejects(proxy.start(options),e=>e.code==='WIRE_ALREADY_STARTED');
  }finally{release.resolve();await pending.catch(()=>{});await proxy.close();t.mock.restoreAll();}
});
test('actual proxy start admits valid remaining budget and retains the original listen deadline',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),controller=new AbortController(),listener=inertListener(),timers=[],schedule=globalThis.setTimeout;
  t.mock.method(globalThis,'setTimeout',function(callback,ms,...args){timers.push(ms);return schedule(callback,ms,...args);});
  const proxy=new WireProxy({backendPort:54321,createListener:listener.create,authorize:async()=>{entered.resolve();await release.promise;}}),pending=proxy.start({deadline:100,signal:controller.signal});
  try{
    await entered.promise;now=50;release.resolve();assert.equal(await pending,54322);
    assert.equal(listener.state.created,1);assert.equal(listener.state.listened,1);assert.ok(timers.includes(50));
    assert.deepEqual(listener.state.options,{host:'127.0.0.1',port:0,exclusive:true});
    await assert.rejects(proxy.start({deadline:200,signal:controller.signal}),e=>e.code==='WIRE_ALREADY_STARTED');
  }finally{release.resolve();await pending.catch(()=>{});await proxy.close();t.mock.restoreAll();}
});
test('actual proxy start rechecks the original deadline immediately before listen',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const listener=inertListener({onCreate:()=>{now=100;}}),proxy=new WireProxy({backendPort:54321,createListener:listener.create,authorize:async()=>{}});
  try{
    await assert.rejects(proxy.start({deadline:100,signal:new AbortController().signal}),e=>e.code==='WIRE_PHASE_DEADLINE');
    assert.equal(listener.state.created,1);assert.equal(listener.state.listened,0);assert.equal(listener.state.closed,1);
  }finally{await proxy.close();t.mock.restoreAll();}
});
for(const during of ['expiry','cancel'])test('actual pending listen rejects '+during+' and closes its inert server without a late startup success',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);let ready;const entered=deferred(),controller=new AbortController(),listener=inertListener({onListen:callback=>{ready=callback;entered.resolve();}}),proxy=new WireProxy({backendPort:54321,createListener:listener.create,authorize:async()=>{}}),pending=proxy.start({deadline:100,signal:controller.signal});
  try{
    await entered.promise;if(during==='cancel')controller.abort();else {now=100;ready();}
    await assert.rejects(pending,e=>e.code===(during==='cancel'?'WIRE_CANCELLED':'WIRE_PHASE_DEADLINE'));
    assert.equal(listener.state.closed,1);ready();await flush();
    await assert.rejects(proxy.start({deadline:200,signal:new AbortController().signal}),e=>e.code==='WIRE_ALREADY_STARTED');
  }finally{await pending.catch(()=>{});await proxy.close();t.mock.restoreAll();}
});

// Establish the real private setup deadline via preflight, deliberately stopping
// at the missing-manifest refusal before tool/runtime work. No admission claim.
async function deadlineOwner(t,authorize=async()=>true){
  const owner=new OwnerSupervisor({plan:createPlan({worktree:currentWorktree,runId:U}),manifest:{},authorize});
  await assert.rejects(owner.preflight(),e=>e.code==='OWNER_MANIFEST');let selections=0;
  t.mock.method(owner,'connections',()=>{selections++;return {b1_bootstrap:{host:'127.0.0.1',port:54321,user:'b1_bootstrap',database:'b1',password:'pure-only'}};});
  return {owner,selections:()=>selections};
}
function scriptedOwnerPg(t){
  const driver=scriptedPinnedPg(t);
  // Owner uses createOwnedPool's default pg negotiation, while harness pools
  // explicitly materialize sslnegotiation. Preserve the harness's strict mock.
  t.mock.method(Client.prototype,'connect',function(callback){
    assert.equal(this.ssl,false);assert.equal(this.sslNegotiation,'postgres');assert.equal(this.connectionParameters.ssl,false);
    this._txStatus='I';driver.clients.push(this);queueMicrotask(()=>callback(null));
  });return driver;
}
for(const during of ['expiry','cancel','denial'])test('actual SQL helper refuses '+during+' during authorization before pool and budget admission',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),driver=scriptedOwnerPg(t),{owner,selections}=await deadlineOwner(t,async({action})=>{
    if(action==='inspect-owned-fixture'){entered.resolve();await release.promise;return during!=='denial';}return true;
  });
  const end=10+CAPS.setupMs;now=end-50;let calls=0;const pending=owner.withClient('b1_bootstrap',()=>{calls++;});
  try{
    await entered.promise;if(during==='expiry')now=end;else if(during==='cancel')owner.cancel();release.resolve();
    await assert.rejects(pending,e=>e.code===({expiry:'OWNER_DEADLINE',cancel:'OWNER_CANCELLED',denial:'OWNER_NOT_AUTHORIZED'}[during]));
    assert.equal(selections(),0);assert.equal(driver.clients.length,0);assert.equal(calls,0);assert.equal(owner.budget.state.used,0);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
test('actual SQL helper reduces connection and query budgets against the same phase end and closes its scope',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const authorized=deferred(),releaseAuth=deferred(),connected=deferred(),releaseConnect=deferred(),driver=scriptedOwnerPg(t),connect=Client.prototype.connect,query=Client.prototype.query,timers=[],schedule=globalThis.setTimeout;let queries=0,leaked;
  t.mock.method(Client.prototype,'connect',function(callback){connected.resolve();releaseConnect.promise.then(()=>connect.call(this,callback)).catch(error=>callback(error));});
  t.mock.method(Client.prototype,'query',function(...args){queries++;return query.apply(this,args);});
  t.mock.method(globalThis,'setTimeout',function(callback,ms,...args){timers.push(ms);return schedule(callback,ms,...args);});
  const {owner}=await deadlineOwner(t,async({action})=>{if(action==='inspect-owned-fixture'){authorized.resolve();await releaseAuth.promise;}return true;}),end=10+CAPS.setupMs;
  now=end-100;const pending=owner.withClient('b1_bootstrap',async client=>{leaked=client;assert.equal(owner.budget.state.used,2);await client.query('SELECT 1');return 'inert-query';});
  try{
    await authorized.promise;now=end-40;releaseAuth.resolve();await connected.promise;now=end-20;releaseConnect.resolve();
    assert.equal(await pending,'inert-query');assert.ok(timers.includes(40));assert.ok(timers.includes(20));
    assert.equal(queries,1);assert.equal(driver.clients.length,1);assert.equal(driver.ended.length,1);assert.equal(owner.budget.state.used,0);
    assert.throws(()=>leaked.query('SELECT 2'),e=>e.code==='OWNER_CLIENT_SCOPE_ENDED');assert.equal(queries,1);
  }finally{releaseAuth.resolve();releaseConnect.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
for(const bound of ['phase','connect-cap'])test('actual SQL helper discards a checkout completing after its '+bound+' deadline without invoking SQL',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),driver=scriptedOwnerPg(t),connect=Client.prototype.connect;
  t.mock.method(Client.prototype,'connect',function(callback){entered.resolve();release.promise.then(()=>connect.call(this,callback)).catch(error=>callback(error));});
  const {owner}=await deadlineOwner(t),end=10+CAPS.setupMs;now=bound==='phase'?end-50:10;const timeout=bound==='phase'?end:1510;let calls=0;
  const pending=owner.withClient('b1_bootstrap',()=>{calls++;});
  try{
    await entered.promise;now=timeout;release.resolve();await assert.rejects(pending,e=>e.code==='OWNER_DEADLINE');await flush();
    assert.equal(calls,0);assert.equal(driver.clients.length,1);assert.equal(driver.ended.length,1);assert.equal(owner.budget.state.used,0);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
for(const bound of ['phase','callback-cap'])test('actual SQL helper blocks late query at its '+bound+' deadline and releases the client budget',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),driver=scriptedOwnerPg(t),query=Client.prototype.query;let leaked,queries=0;
  t.mock.method(Client.prototype,'query',function(...args){queries++;return query.apply(this,args);});
  const {owner}=await deadlineOwner(t),end=10+CAPS.setupMs;now=bound==='phase'?end-50:10;const timeout=bound==='phase'?end:5010;
  const pending=owner.withClient('b1_bootstrap',async client=>{leaked=client;entered.resolve();await release.promise;return 'late';});
  try{
    await entered.promise;now=timeout;assert.throws(()=>leaked.query('SELECT late'),e=>e.code==='OWNER_CLIENT_SCOPE_ENDED');release.resolve();
    await assert.rejects(pending,e=>e.code==='OWNER_DEADLINE');assert.equal(queries,0);assert.equal(driver.ended.length,1);assert.equal(owner.budget.state.used,0);
    assert.throws(()=>leaked.query('SELECT after'),e=>e.code==='OWNER_CLIENT_SCOPE_ENDED');
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
test('actual SQL helper releases its budget if connection selection fails before pool construction',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const driver=scriptedOwnerPg(t),{owner}=await deadlineOwner(t),failure=new Error('inert selection failed');
  t.mock.method(owner,'connections',()=>{throw failure;});
  try{await assert.rejects(owner.withClient('b1_bootstrap',()=>{}),e=>e===failure);assert.equal(driver.clients.length,0);assert.equal(owner.budget.state.used,0);}
  finally{t.mock.restoreAll();}
});

for(const during of ['expiry','cancel','valid'])test('actual SQL transition checks original setup after pending start-sql-slice authorization: '+during,async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),{owner}=await deadlineOwner(t,async({action})=>{if(action==='start-sql-slice'){entered.resolve();await release.promise;}return true;}),end=10+CAPS.setupMs,stop=new Error('inert migration boundary');let migrations=0;
  const stages=integrationStages({owner,harness:{initializeFresh:async()=>{migrations++;throw stop;}}});now=end-10;const pending=stages.initialize();
  try{
    await entered.promise;if(during==='expiry')now=end;else if(during==='cancel')owner.cancel();else now=end-1;release.resolve();
    await assert.rejects(pending,e=>during==='valid'?e===stop:e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));
    assert.equal(migrations,during==='valid'?1:0);
    assert.throws(()=>owner.beginSql(),e=>e.code===(during==='valid'?'OWNER_SUITE_ALREADY_STARTED':during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));
  }finally{release.resolve();await pending.catch(()=>{});await owner.cleanup({deadline:now+100});t.mock.restoreAll();}
});

async function cleanupCapabilityFixture(){
  const dir=await fs.mkdtemp(path.join(testFiles,'cleanup-cap-')),manifest=await measureReviewed(currentWorktree),manifestPath=path.join(dir,'sources.json'),receiptPath=path.join(dir,'review.json'),capPath=path.join(dir,'capability.json'),manifestRaw=JSON.stringify(manifest),manifestHash=digest(manifestRaw),receiptRaw=JSON.stringify({decision:'CLEAR',reviewedIdentity:{runtimeSourceManifestSha256:manifestHash}}),expires=Date.now()+60000;
  await fs.writeFile(manifestPath,manifestRaw);await fs.writeFile(receiptPath,receiptRaw);
  await fs.writeFile(capPath,JSON.stringify({status:'SOURCE_REVIEWED_RUNTIME_PHASE_ADMITTED',runId:U,actions:['start-owned-wire-proxy','cleanup'],expiresAt:new Date(expires).toISOString(),reviewedSources:{path:manifestPath,sha256:manifestHash},independentReview:{path:receiptPath,sha256:digest(receiptRaw)},manifest:{}}));
  const plan=createPlan({worktree:currentWorktree,runId:U}),authorization=await capabilityAuthorizer(capPath,plan),owner=new OwnerSupervisor({plan,...authorization}),listener=inertListener();
  owner.proxy=new WireProxy({backendPort:54321,authorize:a=>owner.gate.require(a),createListener:listener.create});
  await owner.proxy.start({deadline:performance.now()+10000,signal:owner.signal});owner.owner={runId:U,containerId:'a'.repeat(64)};owner.phase='provisioned';
  return {owner,listener,manifestPath,expires};
}
for(const refusal of ['source','capability'])test('actual cleanup retires the started proxy and budget before actual '+refusal+' authorization refusal',async t=>{
  const {owner,listener,manifestPath,expires}=await cleanupCapabilityFixture(),identity=owner.owner,releaseBudget=owner.budget.reserve('helper'),require=owner.gate.require,actions=[];
  t.mock.method(owner.gate,'require',function(action,...args){
    actions.push(action);assert.ok(owner.signal.aborted);assert.equal(listener.state.closed,1);assert.throws(()=>owner.budget.reserve('helper'),e=>e.code==='OWNER_CLIENT_BUDGET');return require.call(this,action,...args);
  });
  if(refusal==='source')await fs.appendFile(manifestPath,' ');else t.mock.method(Date,'now',()=>expires);
  try{
    const receipt=await owner.cleanup({deadline:performance.now()+1000});
    assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.equal(receipt.owner,identity);assert.equal(receipt.dataRemoved,false);assert.equal(receipt.secretsRetained,true);
    assert.equal(receipt.code,refusal==='source'?'OWNER_REVIEW_SOURCE_CHANGED':'OWNER_NOT_AUTHORIZED');assert.deepEqual(actions,['cleanup']);assert.deepEqual(owner.events,[]);
    await assert.rejects(owner.proxy.start({deadline:performance.now()+1000,signal:new AbortController().signal}),e=>e.code==='WIRE_ALREADY_STARTED');
    assert.equal(owner.budget.state.used,2);releaseBudget();assert.equal(owner.budget.state.used,0);
  }finally{releaseBudget();t.mock.restoreAll();}
});
test('actual cleanup starts local retirement even when its original wait budget is already exhausted',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const actions=[],listener=inertListener(),owner=new OwnerSupervisor({plan,manifest:{},authorize:async({action})=>{actions.push(action);return true;}});
  owner.proxy=new WireProxy({backendPort:54321,authorize:a=>owner.gate.require(a),createListener:listener.create});await owner.proxy.start({deadline:100,signal:owner.signal});actions.length=0;
  try{
    now=100;const receipt=await owner.cleanup({deadline:100});assert.equal(listener.state.closed,1);assert.ok(owner.signal.aborted);assert.deepEqual(actions,[]);
    assert.throws(()=>owner.budget.reserve('helper'),e=>e.code==='OWNER_CLIENT_BUDGET');assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');
    assert.ok(receipt.failures.some(f=>f.action==='proxy-close'&&f.code==='OWNER_DEADLINE'));assert.equal(receipt.code,'OWNER_DEADLINE');
    await assert.rejects(owner.proxy.start({deadline:200,signal:new AbortController().signal}),e=>e.code==='WIRE_ALREADY_STARTED');
  }finally{t.mock.restoreAll();}
});
test('actual cleanup has retired local resources while external authorization is pending and cannot extend its deadline',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),actions=[],listener=inertListener(),owner=new OwnerSupervisor({plan,manifest:{},authorize:async({action})=>{actions.push(action);if(action==='cleanup'){entered.resolve();await release.promise;}return true;}});
  owner.proxy=new WireProxy({backendPort:54321,authorize:a=>owner.gate.require(a),createListener:listener.create});await owner.proxy.start({deadline:100,signal:owner.signal});actions.length=0;owner.owner={containerId:'a'.repeat(64)};owner.phase='provisioned';const pending=owner.cleanup({deadline:50});
  try{
    await entered.promise;assert.ok(owner.signal.aborted);assert.equal(listener.state.closed,1);assert.throws(()=>owner.budget.reserve('helper'),e=>e.code==='OWNER_CLIENT_BUDGET');
    now=50;release.resolve();const receipt=await pending;assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.equal(receipt.code,'OWNER_DEADLINE');assert.deepEqual(actions,['cleanup']);assert.deepEqual(owner.events,[]);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
test('actual cleanup keeps local retirement terminal through finish timeout, repeat teardown and late authorization completion',async t=>{
  let now=10,lateCleanup;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),actions=[],listener=inertListener(),owner=new OwnerSupervisor({plan,manifest:{},authorize:async({action})=>{actions.push(action);if(action==='cleanup'){entered.resolve();await release.promise;}return true;}});
  owner.proxy=new WireProxy({backendPort:54321,authorize:a=>owner.gate.require(a),createListener:listener.create});await owner.proxy.start({deadline:100,signal:owner.signal});actions.length=0;owner.owner={containerId:'a'.repeat(64)};owner.phase='provisioned';
  const finishing=finishRuntime({owner:{cleanup:options=>(lateCleanup=owner.cleanup(options))}},{deadline:40}),rejected=assert.rejects(finishing,e=>e.code==='OWNER_CLEANUP_INCOMPLETE');
  try{
    await entered.promise;assert.equal(listener.state.closed,1);assert.ok(owner.signal.aborted);await rejected;now=40;
    const again=await owner.cleanup({deadline:40});assert.equal(again.status,'CLEANUP_INCOMPLETE_RETAINED');assert.equal(listener.state.closed,2);
    release.resolve();await lateCleanup;await flush();assert.deepEqual(actions,['cleanup']);assert.deepEqual(owner.events,[]);
    await assert.rejects(owner.proxy.start({deadline:100,signal:new AbortController().signal}),e=>e.code==='WIRE_ALREADY_STARTED');assert.throws(()=>owner.budget.reserve('helper'),e=>e.code==='OWNER_CLIENT_BUDGET');
  }finally{release.resolve();await rejected;await lateCleanup?.catch(()=>{});t.mock.restoreAll();}
});
test('actual cleanup retains a proxy close failure and still performs cancellation, budget closure and authority refusal',async t=>{
  const listener=inertListener(),actions=[],owner=new OwnerSupervisor({plan,manifest:{},authorize:async({action})=>{actions.push(action);return action!=='cleanup';}});
  owner.proxy=new WireProxy({backendPort:54321,authorize:a=>owner.gate.require(a),createListener:()=>{const server=listener.create();server.close=()=>{throw new OwnerError('OWNER_TEST_PROXY_CLOSE');};return server;}});await owner.proxy.start({deadline:performance.now()+1000,signal:owner.signal});actions.length=0;
  try{
    const receipt=await owner.cleanup({deadline:performance.now()+1000});assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.ok(owner.signal.aborted);assert.deepEqual(actions,['cleanup']);
    assert.ok(receipt.failures.some(f=>f.action==='proxy-close'&&f.code==='OWNER_TEST_PROXY_CLOSE'));assert.throws(()=>owner.budget.reserve('helper'),e=>e.code==='OWNER_CLIENT_BUDGET');
    await assert.rejects(owner.proxy.start({deadline:performance.now()+1000,signal:new AbortController().signal}),e=>e.code==='WIRE_ALREADY_STARTED');
  }finally{t.mock.restoreAll();}
});
test('actual cleanup calls child cancellation and clears the suite watchdog before a throwing external authority',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);let suiteTimer;const schedule=globalThis.setTimeout,cleared=[],cancelled=[],clear=globalThis.clearTimeout;
  t.mock.method(globalThis,'setTimeout',function(callback,ms,...args){const timer=schedule(callback,ms,...args);if(ms===CAPS.suiteMs)suiteTimer=timer;return timer;});
  t.mock.method(globalThis,'clearTimeout',function(timer){cleared.push(timer);return clear(timer);});
  const {owner}=await deadlineOwner(t,async({action})=>{if(action==='cleanup')throw new Error('inert authority throws');return true;}),cancel=owner.cancel;
  t.mock.method(owner,'cancel',function(...args){cancelled.push('cancel');return cancel.apply(this,args);});owner.beginSql();
  try{
    const receipt=await owner.cleanup({deadline:100});assert.ok(suiteTimer);assert.ok(cleared.includes(suiteTimer));assert.deepEqual(cancelled,['cancel']);assert.ok(owner.signal.aborted);
    assert.equal(receipt.code,'OWNER_NOT_AUTHORIZED');assert.throws(()=>owner.budget.reserve('helper'),e=>e.code==='OWNER_CLIENT_BUDGET');
  }finally{if(suiteTimer)clear(suiteTimer);t.mock.restoreAll();}
});

let effectFixtureNumber=0;
function nestedFixtureMocks(t){
  const mocks=[],method=t.mock.method.bind(t.mock);
  const restoreAll=()=>{
    // Node 22 restores tracked methods in creation order. Clear its tracker first
    // so later automatic cleanup cannot reinstall an inner mock, then unwind.
    t.mock.reset();
    while(mocks.length)mocks.pop().mock.restore();
    syncBuiltinESMExports();
  };
  t.after(restoreAll);
  return {after:t.after.bind(t),mock:{method(...args){const fn=method(...args);mocks.push(fn);return fn;},restoreAll}};
}


async function rootFilesOwner(t,authorize){
  const outerClock=performance.now,fx=await effectFixture(t,{authorizeHook:action=>authorize({action})});
  t.mock.method(performance,'now',()=>outerClock());
  t.after(()=>{t.mock.restoreAll();syncBuiltinESMExports();});
  return {owner:fx.owner};
}
function inertRootFiles(t,owner,{pause=null,entered=deferred(),release=deferred()}={}){
  const p=owner.plan,roots=[p.artifactRoot,path.dirname(p.colimaHome)],dirs=[...roots,...toolDirectories(p),p.results],files=[p.artifactRoot+'/database-secrets.json',p.artifactRoot+'/identity.json'],npmrc=p.artifactRoot+'/config/npmrc',allFiles=[npmrc,...files],originalStat=fs.lstat,state={stats:[],mkdir:[],open:[],write:[],sync:[],closed:[],symlink:[]};let held=false;
  const hold=async where=>{if(pause===where&&!held){held=true;entered.resolve();await release.promise;}};
  t.mock.method(fs,'lstat',async function(filename,...args){if(!roots.includes(filename))return originalStat.call(this,filename,...args);state.stats.push(filename);await hold('stat');throw Object.assign(new Error('inert absent root'),{code:'ENOENT'});});
  t.mock.method(fs,'mkdir',async(filename,options)=>{assert.ok(dirs.includes(filename));assert.deepEqual(options,{mode:0o700});state.mkdir.push(filename);await hold('mkdir');});
  t.mock.method(fs,'open',async(filename,flags,mode)=>{
    assert.ok(allFiles.includes(filename));assert.equal(flags,FC.O_WRONLY|FC.O_CREAT|FC.O_NOFOLLOW|FC.O_EXCL);assert.equal(mode,0o600);state.open.push(filename);if(filename!==npmrc)await hold(filename===files[1]?'identity-open':'open');
    // Never persist, log or return credential bytes; these are inert handles.
    return {writeFile:async data=>{if(filename===npmrc)assert.equal(data,'');state.write.push(filename);if(filename!==npmrc)await hold('write');},sync:async()=>{state.sync.push(filename);if(filename!==npmrc)await hold('sync');},close:async()=>{state.closed.push(filename);}};
  });
  t.mock.method(fs,'symlink',async(target,filename)=>{assert.ok(['node','pnpm','colima','docker'].some(n=>filename===p.artifactRoot+'/tools/bin/'+n));state.symlink.push(filename);});
  return {state,entered,release,files,allFiles,dirs,npmrc,held:()=>held};
}
for(const during of ['expiry','cancel'])test('actual provision refuses '+during+' during create-owned-root authorization with zero filesystem mutation',async t=>{
  t=nestedFixtureMocks(t);
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),actions=[],{owner}=await rootFilesOwner(t,async({action})=>{actions.push(action);if(action==='create-owned-root'){entered.resolve();await release.promise;}return true;}),end=10+CAPS.setupMs;
  owner.phase='preflight';const {state}=inertRootFiles(t,owner);now=end-10;const pending=owner.provision();
  try{
    await entered.promise;if(during==='expiry')now=end;else owner.cancel();release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));
    assert.deepEqual(state,{stats:[],mkdir:[],open:[],write:[],sync:[],closed:[],symlink:[]});assert.equal(owner.phase,'preflight');assert.deepEqual(actions,['preflight','provision','create-owned-root']);assert.deepEqual(owner.events,[]);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
for(const pause of ['stat','mkdir','open','write','sync','identity-open'])for(const during of ['expiry','cancel'])test('actual provision keeps the original setup boundary across inert '+pause+' await: '+during,async t=>{
  t=nestedFixtureMocks(t);
  let now=10;t.mock.method(performance,'now',()=>now);const actions=[],{owner}=await rootFilesOwner(t,async({action})=>{actions.push(action);return true;}),end=10+CAPS.setupMs;
  owner.phase='preflight';const {state,entered,release,files,dirs,npmrc,held}=inertRootFiles(t,owner,{pause});now=end-10;const pending=owner.provision();
  try{
    await entered.promise;assert.equal(held(),true);assert.equal(state.write.filter(f=>f===files[1]).length,0);if(during==='expiry')now=end;else owner.cancel();release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));assert.equal(owner.phase,'preflight');assert.ok(!actions.includes('hdiutil-create'));assert.deepEqual(owner.events,[]);
    assert.equal(state.mkdir.length,pause==='stat'?0:pause==='mkdir'?1:dirs.length);assert.equal(state.open.filter(f=>f!==npmrc).length,['stat','mkdir'].includes(pause)?0:pause==='identity-open'?2:1);
    assert.equal(state.write.filter(f=>f!==npmrc).length,['write','sync','identity-open'].includes(pause)?1:0);assert.equal(state.sync.filter(f=>f!==npmrc).length,['sync','identity-open'].includes(pause)?1:0);
    assert.equal(state.write.filter(f=>f===files[1]).length,0);assert.deepEqual(state.closed,state.open);
  }finally{release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
test('actual provision preserves valid root and private identity admission while an external command remains denied',async t=>{
  t=nestedFixtureMocks(t);
  let now=10;t.mock.method(performance,'now',()=>now);const actions=[],{owner}=await rootFilesOwner(t,async({action})=>{actions.push(action);return action!=='hdiutil-create';});
  owner.phase='preflight';const {state,allFiles,dirs}=inertRootFiles(t,owner);
  try{
    await assert.rejects(owner.provision(),e=>e.code==='OWNER_NOT_AUTHORIZED');assert.equal(state.mkdir.length,dirs.length);assert.deepEqual(state.open,allFiles);assert.deepEqual(state.write,allFiles);assert.deepEqual(state.sync,allFiles);assert.deepEqual(state.closed,allFiles);assert.equal(state.symlink.length,4);
    assert.deepEqual(actions,['preflight','provision','create-owned-root','hdiutil-create']);assert.equal(owner.phase,'allocating');assert.deepEqual(owner.events,[]);
  }finally{t.mock.restoreAll();}
});

async function bindingOwner(t,authorize=async()=>true){
  const dir=await fs.mkdtemp(path.join(testFiles,'phase-bindings-')),owner=new OwnerSupervisor({plan:{...createPlan({worktree:currentWorktree,runId:U}),artifactRoot:dir},manifest:{},authorize});
  // Real private setup deadline, intentionally refused before tool/runtime work.
  await assert.rejects(owner.preflight(),e=>e.code==='OWNER_MANIFEST');
  return {owner,dir,file:path.join(dir,'fixture-bindings.json')};
}
function inertPrepare(t,owner){
  const events=[],stop=new Error('inert bindings admission boundary'),fingerprint=owner.setBindingsFingerprint;
  // Only preparation effects are inert; the actual composed persistence path,
  // private original deadline, gate and filesystem/key code remain in use.
  t.mock.method(owner,'preflight',async()=>{events.push('preflight');});t.mock.method(owner,'provision',async()=>{events.push('provision');});
  t.mock.method(owner,'setBindingsFingerprint',function(value){fingerprint.call(this,value);events.push('bindings-admitted');throw stop;});
  return {events,stop};
}
function pendingCrypto(t,method,matches=()=>true,ordinal=1){
  const entered=deferred(),release=deferred(),subtle=globalThis.crypto.subtle,original=subtle[method];let seen=0,held=false;
  t.mock.method(subtle,method,async function(...args){
    if(matches(args)&&++seen===ordinal){held=true;entered.resolve();await release.promise;}
    return original.apply(this,args);
  });return {entered,release,held:()=>held};
}
const bindingPauses=['auth','stat-missing','stat-existing','read-existing','generate-server','generate-installation','export-server','export-installation','fixture-generation','restore-existing'];
for(const pause of bindingPauses)for(const during of ['expiry','cancel'])test('actual prepareRuntime bindings reject '+during+' after pending '+pause+' without stale private-key persistence',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const entered=deferred(),release=deferred(),{owner,dir,file}=await bindingOwner(t,async({action})=>{if(pause==='auth'&&action==='create-owned-root'){entered.resolve();await release.promise;}return true;}),end=10+CAPS.setupMs;
  const existing=['stat-existing','read-existing','fixture-generation','restore-existing'].includes(pause);let baseline=null;
  if(existing){const bindings=await persistentBindings(owner);await bindings.store.close();baseline=digest(await fs.readFile(file));}
  let wait={entered,release};
  if(pause.startsWith('stat-')){
    const original=fs.lstat;t.mock.method(fs,'lstat',async function(filename,...args){if(filename===file){entered.resolve();await release.promise;}return original.call(this,filename,...args);});
  }else if(pause==='read-existing'){
    const original=fs.readFile;t.mock.method(fs,'readFile',async function(filename,...args){if(filename===file){entered.resolve();await release.promise;}return original.call(this,filename,...args);});
  }else if(pause.startsWith('generate-')||pause==='fixture-generation')wait=pendingCrypto(t,'generateKey',()=>true,pause==='generate-installation'?2:1);
  else if(pause.startsWith('export-'))wait=pendingCrypto(t,'exportKey',args=>args[0]==='jwk'&&args[1].type==='private',pause==='export-installation'?2:1);
  else if(pause==='restore-existing')wait=pendingCrypto(t,'importKey');
  const {events}=inertPrepare(t,owner);now=end-10;const pending=prepareRuntime({owner});
  try{
    await wait.entered.promise;if(during==='expiry')now=end;else owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));
    assert.deepEqual(events,['preflight','provision']);assert.deepEqual(await fs.readdir(dir),existing?['fixture-bindings.json']:[]);
    if(existing)assert.equal(digest(await fs.readFile(file)),baseline);assert.deepEqual(owner.events,[]);
  }finally{wait.release.resolve();release.resolve();await pending.catch(()=>{});t.mock.restoreAll();}
});
for(const during of ['expiry','cancel'])test('actual prepareRuntime bindings recheck '+during+' after synchronous directory inspection before opening a private temp file',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const {owner,dir}=await bindingOwner(t),end=10+CAPS.setupMs,{events}=inertPrepare(t,owner),stat=nativeFs.lstatSync;let inspections=0;
  t.mock.method(nativeFs,'lstatSync',function(filename,...args){const result=stat.call(this,filename,...args);if(filename===dir&&++inspections===2){if(during==='expiry')now=end;else owner.cancel();}return result;});syncBuiltinESMExports();
  try{
    await assert.rejects(prepareRuntime({owner}),e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));assert.equal(inspections,2);assert.deepEqual(events,['preflight','provision']);assert.deepEqual(await fs.readdir(dir),[]);
  }finally{t.mock.restoreAll();syncBuiltinESMExports();}
});
test('actual prepareRuntime bindings preserve valid private persistence and reach the inert admission boundary',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const {owner,dir,file}=await bindingOwner(t),{events,stop}=inertPrepare(t,owner);
  try{
    await assert.rejects(prepareRuntime({owner}),e=>e===stop);assert.deepEqual(events,['preflight','provision','bindings-admitted']);
    assert.deepEqual(await fs.readdir(dir),['fixture-bindings.json']);assert.equal((await fs.stat(file)).mode&0o777,0o600);
    const value=JSON.parse(await fs.readFile(file,'utf8'));assert.equal(value.runId,U);assert.equal(value.version,1);assert.ok(value.server.private.d);assert.ok(value.installation.private.d);
    assert.deepEqual(owner.events,[]);
  }finally{t.mock.restoreAll();}
});
test('actual bindings family and ownership persistence remain valid in SQL phase after original setup expires',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const {owner,file}=await bindingOwner(t),bindings=await persistentBindings(owner),end=10+CAPS.setupMs;
  try{
    now=end-1;owner.beginSql();now=end+100;const family=await bindings.family('valid-sql'),request=bindings.grantOwnership('pure-installation',family,'pure-owner');
    assert.deepEqual(await bindings.config.ownership.verify({installationId:'pure-installation',request,recipientFingerprint:family.fingerprint}),{installationId:'pure-installation',profileKind:'normal',subject:'pure-owner'});
    const state=JSON.parse(await fs.readFile(file,'utf8'));assert.ok(state.families[digest('valid-sql')]);assert.equal(state.ownership.length,1);
    const baseline=digest(await fs.readFile(file));await assert.rejects(persistentBindings(owner),e=>e.code==='OWNER_SETUP_DEADLINE');assert.equal(digest(await fs.readFile(file)),baseline);
  }finally{await bindings.store.close();await owner.cleanup({deadline:now+100});t.mock.restoreAll();}
});
for(const during of ['expiry','cancel','transition'])test('actual pending family cannot renew its captured active phase through '+during,async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const {owner,file}=await bindingOwner(t),bindings=await persistentBindings(owner),setupEnd=10+CAPS.setupMs;
  if(during!=='transition')owner.beginSql();const end=owner.captureAdmission().deadline,baseline=digest(await fs.readFile(file)),wait=pendingCrypto(t,'generateKey');now=end-10;const pending=bindings.family('late-family');
  try{
    await wait.entered.promise;if(during==='cancel')owner.cancel();else if(during==='transition'){now=setupEnd-5;owner.beginSql();now=setupEnd;}else now=end;wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='cancel'?'OWNER_CANCELLED':'OWNER_DEADLINE'));assert.equal(digest(await fs.readFile(file)),baseline);
  }finally{wait.release.resolve();await pending.catch(()=>{});await bindings.store.close();await owner.cleanup({deadline:now+100});t.mock.restoreAll();}
});
for(const during of ['expiry','cancel'])test('actual ownership and cached-family operations reject '+during+' in their original SQL phase without persisting',async t=>{
  let now=10;t.mock.method(performance,'now',()=>now);const {owner,file}=await bindingOwner(t),bindings=await persistentBindings(owner);owner.beginSql();const family=await bindings.family('cached-family'),baseline=digest(await fs.readFile(file)),end=owner.captureAdmission().deadline;
  try{
    if(during==='expiry')now=end;else owner.cancel();
    assert.throws(()=>bindings.grantOwnership('pure-installation',family),e=>e.code===(during==='cancel'?'OWNER_CANCELLED':'OWNER_DEADLINE'));
    await assert.rejects(bindings.family('cached-family'),e=>e.code===(during==='cancel'?'OWNER_CANCELLED':'OWNER_DEADLINE'));assert.equal(digest(await fs.readFile(file)),baseline);
  }finally{await bindings.store.close();await owner.cleanup({deadline:now+100});t.mock.restoreAll();}
});

async function effectFixture(t,{preflight=true,deny=null,imageExtraBytes=512*1024,applyRootMode=true,authorizeHook=null,commandInterceptor=null,capabilityExpiresAt=undefined}={}){
  const number=++effectFixtureNumber,base=path.join(testFiles,'effects-'+number),home=path.join(testFiles,'external-'+number,'c');
  const p={...createPlan({worktree:currentWorktree,runId:U}),artifactRoot:base,colimaHome:home,dockerConfig:base+'/docker-config',results:base+'/results',logImage:base+'/logs.img',socket:home+'/b1-owner/docker.sock',vmImage:base+'/inert-vm',ociLayout:base+'/inert-oci',importArchive:base+'/inert-archive'};
  const source=await fs.readFile(new URL('./guest.sh',import.meta.url),'utf8'),guestPath=fileURLToPath(new URL('./guest.sh',import.meta.url)),N='a'.repeat(64),C='b'.repeat(64),GiB=1024**3;
  const paths={sourceParent:home+'/b1-owner',sourceLeaf:home+'/b1-owner/logs',sinkParent:p.results+'/colima',fileSink:p.results+'/colima/stdout.log',fileLink:home+'/b1-owner/logs/stdout.log',directorySink:p.results+'/cache',directoryLink:home+'/b1-owner/cache',identity:base+'/resource-identity.json'};
  const routes=[{path:paths.fileLink,sink:paths.fileSink,kind:'file'},{path:paths.directoryLink,sink:paths.directorySink,kind:'directory'}],files=new Map(),dirs=new Set(),links=new Map(),modes=new Map(),effects=[],starts=[],kills=[],closed=[],records=[];
  const defaultFiles=[process.env.HOME+'/.docker/config.json',process.env.HOME+'/.colima/default/colima.yaml',process.env.HOME+'/.ssh/config'];
  const failures=new Map(),replies=new Map();let now=10,mounted=false,volumeBytes=0,running=true,activeAction=null,paused=null,seen=0,held=false,entered=deferred(),release=deferred(),schema=null,initialIdentity=null;
  const labels=new Map([[p.logImage,'log-image'],[p.results,'results'],[base,'artifact-root'],[home,'source-root'],[paths.sourceParent,'source-parent'],[paths.sourceLeaf,'source-leaf'],[paths.sinkParent,'sink-parent'],[paths.fileSink,'route-file'],[paths.fileLink,'route-link'],[paths.directorySink,'route-directory'],[paths.directoryLink,'directory-link'],[paths.identity,'identity'],[home+'/b1-owner/colima.yaml','vm-config'],[p.results+'/container-passwd','passwd'],[guestPath,'guest-source'],[p.results+'/ordinary.json','ordinary'],[p.results+'/cleanup.json','cleanup'],[p.results+'/suite-accounting.json','suite-accounting'],[p.socket,'socket']]);
  const label=filename=>labels.get(filename)??(filename.startsWith(paths.identity+'.')?'identity-temp':defaultFiles.includes(filename)?'default-'+defaultFiles.indexOf(filename):'other');
  const hold=async tag=>{if(paused&&tag===paused.tag&&++seen===paused.ordinal){held=true;entered.resolve();await release.promise;}if(failures.has(tag))throw new OwnerError(failures.get(tag));};
  const normalized=filename=>filename instanceof URL?fileURLToPath(filename):String(filename);
  const absent=()=>Object.assign(new Error('inert absent input'),{code:'ENOENT'});
  const meta=filename=>{
    const target=links.get(filename)??filename,dev=mounted&&target.startsWith(p.results)?2:1,isLink=links.has(filename),isDir=dirs.has(target)||target==='/Volumes/ExternalSSD';
    if(!isLink&&!isDir&&!files.has(target))throw absent();
    const bytes=files.get(target)?.bytes??Buffer.byteLength(files.get(target)?.data??'');
    return {uid:p.uid,mode:modes.get(target)??(isDir||filename.startsWith('/inert/')?0o700:0o600),dev,ino:1,size:bytes,isDirectory:()=>!isLink&&isDir,isFile:()=>!isLink&&!isDir,isSymbolicLink:()=>isLink,isSocket:()=>target===p.socket};
  };
  const put=(filename,data,bytes)=>files.set(filename,{data,bytes});
  const vm='INERT_VM_BYTES',archive='INERT_IMPORT_BYTES',layers=Array.from({length:14},(_,i)=>({digest:'sha256:'+digest('inert-layer-'+i),size:i===13?156463634-13:1}));
  const manifest=JSON.stringify({inertKind:'manifest',config:{digest:PIN.configDigest},layers}),config=JSON.stringify({inertKind:'config',os:'linux',architecture:'arm64'});
  const pins=new Map([[vm,PIN.vmSha256],[manifest,PIN.imageDigest.slice(7)],[config,PIN.configDigest.slice(7)]]);
  put(p.vmImage,vm,PIN.vmBytes);put(p.importArchive,archive);put(p.ociLayout+'/blobs/sha256/'+PIN.imageDigest.slice(7),manifest);put(p.ociLayout+'/blobs/sha256/'+PIN.configDigest.slice(7),config);
  for(let i=0;i<layers.length;i++)put(p.ociLayout+'/blobs/sha256/'+layers[i].digest.slice(7),'inert-layer-'+i,layers[i].size);

  const tools={};dirs.add('/inert');
  const provenancePath='/inert/tool-provenance.json',provenance=JSON.stringify({kind:'INERT_UNIT_INPUT_NOT_RUNTIME_QUALIFICATION'});put(provenancePath,provenance);
  const reference=filename=>{const data=files.get(filename).data;return {path:filename,bytes:Buffer.byteLength(data),sha256:digest(data)};};
  for(const name of TOOL_NAMES){const filename='/inert/'+name,data='inert-'+name;put(filename,data);tools[name]={canonicalPath:filename,trustedRoot:'/inert',uid:p.uid,mode:0o700,bytes:Buffer.byteLength(data),sha256:digest(data),version:PIN[name]??'host-system',provenance:reference(provenancePath)};}
  const prefix='/inert/lima-prefix',prefixEntries=[];
  for(const name of ['', 'bin','share','share/lima']){dirs.add(prefix+(name?'/'+name:''));if(name)prefixEntries.push({path:name,type:'directory',uid:p.uid,mode:0o700,bytes:0,sha256:null});}
  for(const [name,data] of [['bin/limactl','inert-private-limactl'],['bin/lima','inert-private-launcher'],['share/lima/lima-guestagent.Linux-aarch64','inert-private-guest']]){put(prefix+'/'+name,data);prefixEntries.push({path:name,type:'file',uid:p.uid,mode:0o700,bytes:Buffer.byteLength(data),sha256:digest(data)});}
  const version='v2.1.3-aegis.stage1.unit+base.1285a6d70f23',sourceSha256='e'.repeat(64),pairId=digest(JSON.stringify({host:prefixEntries.find(x=>x.path==='bin/limactl').sha256,guest:prefixEntries.find(x=>x.path==='share/lima/lima-guestagent.Linux-aarch64').sha256,sourceSha256,version}));
  const prefixManifest='/inert/prefix.json';put(prefixManifest,JSON.stringify({format:'B1_BOUND_LIMA_PREFIX_V1',prefix,version,sourceSha256,baseCommit:'1285a6d70f23afe8129c3868df178cf9ffe23aaf',pairId,entries:prefixEntries}));
  const ownedLogs='/inert/owned-logs.json';put(ownedLogs,JSON.stringify({unitOnly:true,instance:'colima-b1-owner'}));
  const toolchain={format:'B1_BOUND_TOOLCHAIN_V1',runId:U,lima:{prefix,version,pairId,manifest:reference(prefixManifest)},ownedLogManifest:reference(ownedLogs)};

  const proofPath=base+'/inert-log-proof',proof=JSON.stringify({status:'EXHAUSTIVE_LOG_SINKS_REVIEWED',runId:U,vmImageSha256:PIN.vmSha256,routes});put(proofPath,proof);
  const m={runId:U,tools,toolchain,imageImport:{protocol:'REVIEWED_DOCKER_LOAD_ARCHIVE',imageDigest:PIN.imageDigest,sha256:digest(archive)},logRouting:{sourceReceipt:{path:proofPath,sha256:digest(proof)},routes,vmImageSha256:PIN.vmSha256,guestBootPolicy:'NO_PERSISTENT_LOG_SINKS_BEFORE_OWNED_SETUP'},sourceSha256:{'guest.sh':digest(source)},vmConfigFields:{cpu:'cpu',memory:'memory',rootDisk:'disk',dataDisk:'dataDisk'},vmStatusFields:{profile:'profile',runtime:'runtime',arch:'arch',vmType:'vmType',status:'status'}};
  put(guestPath,source);put(home+'/b1-owner/colima.yaml','cpu: 2\nmemory: 3\ndisk: 12\ndataDisk: 16\nmounts: []\n');
  const actualHash=nativeCrypto.createHash;
  // Metadata/pinned byte streams are deliberately inert, not runtime evidence.
  t.mock.method(nativeCrypto,'createHash',function(...args){const hash=actualHash(...args),chunks=[];return {update(chunk){hash.update(chunk);chunks.push(Buffer.from(chunk));return this;},digest(encoding){const pin=pins.get(Buffer.concat(chunks).toString());return pin??hash.digest(encoding);}};});
  t.mock.method(nativeFs,'createReadStream',filename=>{
    filename=normalized(filename);const value=files.get(filename);
    return Readable.from((async function*(){await hold('hash:'+label(filename));if(!value)throw absent();yield Buffer.from(value.data);})());
  });syncBuiltinESMExports();
  t.mock.method(performance,'now',()=>now);
  t.mock.method(fs,'lstat',async filename=>{filename=normalized(filename);await hold('lstat:'+label(filename));return meta(filename);});
  t.mock.method(fs,'stat',async filename=>{filename=normalized(filename);await hold('stat:'+label(filename));const s=meta(filename);return {...s,isDirectory:()=>dirs.has(links.get(filename)??filename)||filename==='/Volumes/ExternalSSD',isFile:()=>!dirs.has(links.get(filename)??filename),isSymbolicLink:()=>false,isSocket:()=>filename===p.socket};});
  t.mock.method(fs,'statfs',async filename=>{filename=normalized(filename);await hold('statfs:'+label(filename));return {bavail:200*GiB,bsize:1,blocks:filename===p.results?volumeBytes:200*GiB};});
  t.mock.method(fs,'access',async()=>{});
  t.mock.method(fs,'readdir',async filename=>{filename=normalized(filename);await hold('readdir:'+label(filename));if(!dirs.has(filename))throw absent();return [...new Set([...dirs,...files.keys(),...links.keys()].filter(x=>x!==filename&&path.dirname(x)===filename).map(x=>path.basename(x)))];});

  t.mock.method(fs,'realpath',async filename=>{filename=normalized(filename);await hold('realpath:'+label(filename));if(filename===process.execPath)return '/inert/node';if(filename.startsWith('/opt/homebrew/bin/'))throw new OwnerError('OWNER_TEST_GLOBAL_FALLBACK');return links.get(filename)??filename;});
  t.mock.method(fs,'readFile',async(filename,encoding)=>{filename=normalized(filename);await hold('read:'+label(filename));const value=files.get(filename);if(!value)throw absent();return encoding?value.data:Buffer.from(value.data);});
  t.mock.method(fs,'mkdir',async(filename,options)=>{assert.equal(options.recursive,undefined);assert.equal(options.mode,0o700);effects.push('mkdir:'+label(filename));await hold('mkdir:'+label(filename));if(dirs.has(filename))throw Object.assign(new Error('inert exists'),{code:'EEXIST'});dirs.add(filename);});
  t.mock.method(fs,'chmod',async(filename,mode)=>{assert.equal(filename,p.results);assert.equal(mode,0o700);effects.push('chmod:'+label(filename));await hold('chmod:'+label(filename));if(applyRootMode)modes.set(filename,mode);});
  t.mock.method(fs,'symlink',async(target,filename)=>{effects.push('symlink:'+label(filename));await hold('symlink:'+label(filename));links.set(filename,target);});
  t.mock.method(fs,'rename',async(from,to)=>{effects.push('rename:'+label(to));await hold('rename:'+label(to));assert.ok(files.has(from));files.set(to,files.get(from));files.delete(from);});
  t.mock.method(fs,'open',async(filename,flags,mode)=>{
    const kind=label(filename);effects.push('open:'+kind);await hold('open:'+kind);
    if(flags===FC.O_RDONLY){assert.ok(dirs.has(filename));return {sync:async()=>{effects.push('dir-sync:'+kind);await hold('dir-sync:'+kind);},close:async()=>{closed.push(kind);await hold('dir-close:'+kind);}};}
    assert.equal(flags,FC.O_WRONLY|FC.O_CREAT|FC.O_NOFOLLOW|FC.O_EXCL);assert.equal(mode,0o600);if(files.has(filename))throw Object.assign(new Error('inert exists'),{code:'EEXIST'});put(filename,'');
    return {writeFile:async data=>{effects.push('write:'+kind);await hold('write:'+kind);if(filename.endsWith('/database-secrets.json'))return;put(filename,String(data));if(filename===paths.identity&&!initialIdentity)initialIdentity=String(data);if(filename.startsWith(p.results+'/')&&filename.endsWith('.json'))records.push(filename);},sync:async()=>{effects.push('sync:'+kind);await hold('sync:'+kind);},close:async()=>{closed.push(kind);await hold('close:'+kind);}};
  });
  const guest={cpu:2,memoryBytes:3*GiB,swapBytes:0,hostMounts:[],rootFilesystemBytes:12*GiB,dockerFilesystemBytes:16*GiB,rootDevice:'root',dockerDevice:'docker',quotaBytes:CAPS.data,blockSize:4096,blockCount:524288,mountType:'ext4',backingFile:p.guestRoot+'/data.ext4',secretModes:true,enospcProofExists:true,filesystemUuid:'inert-fs',backingInode:1,loopDevice:'inert-loop',mountDevice:2,capacityParentFreeBytes:200*GiB};
  const container=()=>({Id:C,Name:'/'+p.containerName,Config:{Labels:{'b1.owner':U},Image:PIN.image,Env:['PGDATA=/var/lib/postgresql/data/pgdata']},HostConfig:{NanoCpus:2e9,Memory:GiB,MemorySwap:GiB,ShmSize:CAPS.shm,PidsLimit:128,ReadonlyRootfs:true,LogConfig:{Type:'none'},Privileged:false,NetworkMode:N},Platform:'linux',State:{Running:running},Mounts:[{Destination:'/var/lib/postgresql/data',Type:'bind',Source:p.guestRoot+'/data',RW:true},{Destination:'/run/secrets/bootstrap',Source:p.guestRoot+'/secrets/bootstrap',RW:false}],NetworkSettings:{Ports:{'5432/tcp':[{HostIp:'127.0.0.1',HostPort:'54321'}]}}});
  const response=action=>{
    if(replies.has(action))return replies.get(action);
    if(action==='preflight')return 'colima '+PIN.colima+' docker '+PIN.docker+' pnpm '+PIN.pnpm;
    if(action==='colima-status')return JSON.stringify({profile:p.profile,runtime:'docker',arch:'aarch64',vmType:'vz',status:'Stopped'});
    if(action==='docker-image-inspect')return JSON.stringify([{Os:'linux',Architecture:'arm64',RepoDigests:[PIN.image]}]);
    if(action==='docker-network-create')return N;if(action==='docker-create')return C;
    if(action==='docker-inspect')return JSON.stringify([container()]);
    if(action==='docker-network-inspect')return JSON.stringify([{Id:N,Name:p.networkName,Labels:{'b1.owner':U},Internal:true,Containers:{[C]:{}}}]);
    if(action==='verify-forwarder')return 'p1\nn127.0.0.1:54321\n';
    if(action==='guest-quota-test')return JSON.stringify({enospcObserved:true,furtherAllocationFailed:true,uid:999,gid:999});
    if(action.startsWith('guest-'))return JSON.stringify(guest);
    return '';
  };
  const listener=inertListener();
  const authorize=async({action})=>{if(capabilityExpiresAt!==undefined&&Date.now()>=capabilityExpiresAt)return false;activeAction=action;await hold('authorize:'+action);return (capabilityExpiresAt===undefined||Date.now()<capabilityExpiresAt)&&action!==deny&&(!authorizeHook||await authorizeHook(action));};
  if(capabilityExpiresAt!==undefined)Object.defineProperty(authorize,'expiresAt',{value:capabilityExpiresAt});
  const commandOutput=(action,executable,args)=>{
    if(action==='hdiutil-create'){const size=args[args.indexOf('-size')+1];assert.match(size,/^\d+m$/);volumeBytes=Number.parseInt(size,10)*1024**2;put(p.logImage,'',volumeBytes+imageExtraBytes);}
    if(action==='hdiutil-attach'){mounted=true;modes.set(p.results,0o755);}
    if(action==='docker-cp-passwd')put(p.results+'/container-passwd','postgres:x:999:999:inert:/inert:/bin/false');
    if(action==='docker-stop')running=false;if(action==='docker-start')running=true;
    return action==='verify-forwarder'&&path.basename(executable)==='ps'?p.uid+' birth '+p.colimaHome:response(action);
  };
  const owner=new OwnerSupervisor({plan:p,manifest:m,createListener:listener.create,authorize,startCommand:(executable,args,options)=>{
    const interceptedAction=activeAction,intercepted=commandInterceptor?.({action:interceptedAction,executable,args,options,complete:()=>commandOutput(interceptedAction,executable,args)});
    if(intercepted)return intercepted;
    const action=activeAction,child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.stdin=new EventEmitter();starts.push(action);
    child.kill=signal=>{kills.push({action,signal});return true;};child.stdin.end=()=>{(async()=>{
      await hold('command:'+action);
      const out=commandOutput(action,executable,args);
      for(const chunk of Array.isArray(out)?out:[out])child.stdout.emit('data',Buffer.from(chunk));child.emit('close',0);
    })().catch(error=>child.emit('error',error));};return child;
  }});
  const query=async sql=>{
    await hold('sql:'+sql.split(' ')[0]);
    if(sql.includes('FROM pg_roles WHERE'))return {rows:[{rolname:'b1_app',rolsuper:false,rolcreatedb:false,rolcreaterole:false,rolreplication:false,ddl:false,temp:false,connect:true},{rolname:'b1_bootstrap',rolsuper:true},{rolname:'b1_migrator',rolsuper:false,rolcreatedb:false,rolcreaterole:false,rolreplication:false,ddl:true,temp:false,connect:true}]};
    if(sql.includes("current_setting('server_version_num')"))return {rows:[{version:PIN.serverVersion,max_connections:'12',fsync:'on',synchronous_commit:'on',full_page_writes:'on',deadlock_timeout:'20ms',data_directory:'/var/lib/postgresql/data/pgdata',system_identifier:'inert-system',schema}]};
    if(sql.includes('FROM pg_tablespace'))return {rows:[]};
    if(sql.includes('FROM pg_proc'))return {rows:['clock_begin','clock_finish','clock_try_lock','clock_unlock','clock_key','clock_owned','clock_assert_owned','seed_clock'].map(proname=>({proname,prosecdef:true,proconfig:['search_path=pg_catalog'],rolname:'b1_migrator',definition:'inert-function',app_execute:['clock_begin','clock_finish','clock_try_lock','clock_unlock'].includes(proname)}))};
    if(sql.includes('AS schema_ddl'))return {rows:[{schema_ddl:false,clock_update:false,clock_insert:false}]};
    if(sql.includes('system_identifier::text'))return {rows:[{system_identifier:'inert-system'}]};
    if(sql.includes('to_regnamespace'))return {rows:[{schema}]};
    return {rows:[]};
  };
  // SQL is inert here; the original helper/pg transport regressions stay intact.
  t.mock.method(owner,'withClient',async(role,callback)=>{const admission=owner.captureAdmission();return callback({query:async(...args)=>{admission.check();const result=await query(...args);admission.check();return result;}});});
  put(p.socket,'');
  const fixture={owner,p,m,paths,effects,starts,kills,closed,records,files,dirs,links,modes,listener,N,C,get now(){return now;},set now(value){now=value;},setupEnd:10+CAPS.setupMs,get initialIdentity(){return initialIdentity;},set migrated(value){schema=value?'provider_b1':null;},
    arm(tag,ordinal=1){paused={tag,ordinal};seen=0;held=false;entered=deferred();release=deferred();return {entered,release};},
    fail(tag,code){failures.set(tag,code);},reply(action,value){replies.set(action,value);},
    disarm(){release.resolve();paused=null;},
    async dispose(){release.resolve();paused=null;await owner.cleanup({deadline:now+2000});await flush();t.mock.restoreAll();syncBuiltinESMExports();}};
  if(preflight)await owner.preflight();return fixture;
}

const logEffectPauses=['command:hdiutil-create','lstat:log-image','command:hdiutil-attach','lstat:results','stat:artifact-root','statfs:results','chmod:results','lstat:results-private','lstat:source-root','mkdir:source-parent','mkdir:source-leaf','mkdir:sink-parent','open:route-file','write:route-file','sync:route-file','close:route-file','symlink:route-link','lstat:route-link','realpath:route-link','stat:route-link','mkdir:route-directory','symlink:directory-link','statfs:results-final'];
for(const pause of logEffectPauses)for(const during of ['expiry','cancel'])test('actual log routing blocks follow-up effects after '+during+' at '+pause,async t=>{
  const fx=await effectFixture(t),tag=pause==='statfs:results-final'?'statfs:results':pause==='lstat:results-private'?'lstat:results':pause,wait=fx.arm(tag,['statfs:results-final','lstat:results-private'].includes(pause)?2:1);fx.now=fx.setupEnd-10;const pending=fx.owner.provision();
  try{
    await wait.entered.promise;const count=fx.effects.length;if(during==='expiry')fx.now=fx.setupEnd;else fx.owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));await flush();
    assert.equal(fx.effects.length,count);assert.equal(fx.starts.includes('colima-start'),false);assert.equal(fx.owner.phase,'allocating');
    assert.equal(fx.owner.provision(),pending);await assert.rejects(fx.owner.provision());
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
test('actual healthy setup performs routed private effects and publishes only the verified inert owner',async t=>{
  const fx=await effectFixture(t);
  try{
    assert.equal(fx.owner.preflight(),fx.owner.preflight());assert.equal(fx.starts.filter(a=>a==='preflight').length,0);
    const pending=fx.owner.provision();assert.equal(fx.owner.provision(),pending);const owner=await pending;
    assert.equal(owner.containerId,fx.C);assert.equal(owner.networkId,fx.N);assert.equal(owner.port,54322);assert.equal(fx.owner.phase,'provisioned');
    assert.equal(fx.starts.filter(a=>a==='docker-create').length,1);assert.equal(fx.starts.filter(a=>a==='docker-network-create').length,1);
    assert.ok(fx.files.get(fx.p.logImage).bytes<=CAPS.results);assert.ok(fx.files.get(fx.p.logImage).bytes>120*1024**2);
    assert.equal(fx.modes.get(fx.p.results),0o700);assert.ok(fx.effects.indexOf('chmod:results')<fx.effects.indexOf('open:route-file'));
    assert.equal(fx.links.get(fx.paths.fileLink),fx.paths.fileSink);assert.equal(fx.links.get(fx.paths.directoryLink),fx.paths.directorySink);assert.ok(fx.effects.includes('rename:identity'));
    assert.equal(fx.owner.retainedIdentity.container.id,fx.C);assert.equal(fx.owner.retainedIdentity.network.id,fx.N);assert.equal(fx.owner.retainedIdentity.mount.device,2);assert.ok(Buffer.byteLength(JSON.stringify(fx.owner.retainedIdentity))<=16384);
  }finally{await fx.dispose();}
});
test('UDRW backing metadata exceeding the cap refuses attachment and VM startup',async t=>{
  const fx=await effectFixture(t,{imageExtraBytes:9*1024**2});
  try{
    await assert.rejects(fx.owner.provision(),e=>e.code==='OWNER_LOG_IMAGE_LIMIT');
    assert.equal(fx.starts.includes('hdiutil-attach'),false);assert.equal(fx.starts.includes('colima-start'),false);
  }finally{await fx.dispose();}
});
for(const failure of ['rejected','ineffective'])test('mounted root chmod '+failure+' prevents log writes and VM startup',async t=>{
  const fx=await effectFixture(t,{applyRootMode:failure!=='ineffective'});
  if(failure==='rejected')fx.fail('chmod:results','INERT_CHMOD_REJECTED');
  try{
    await assert.rejects(fx.owner.provision(),e=>e.code===(failure==='rejected'?'INERT_CHMOD_REJECTED':'OWNER_LOG_ROUTE_PARENT'));
    assert.equal(fx.effects.includes('open:route-file'),false);assert.equal(fx.starts.includes('colima-start'),false);
    assert.equal(fx.owner.retainedIdentity.mount.device,2);
  }finally{await fx.dispose();}
});
for(const during of ['expiry','cancel'])test('actual preflight is single-flight and refuses final defaults publication after '+during,async t=>{
  const fx=await effectFixture(t,{preflight:false}),wait=fx.arm('lstat:default-2');const pending=fx.owner.preflight();
  try{
    assert.equal(fx.owner.preflight(),pending);await wait.entered.promise;if(during==='expiry')fx.now=fx.setupEnd;else fx.owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));assert.equal(fx.owner.phase,'new');assert.deepEqual(fx.effects,[]);assert.equal(fx.starts.length,0);
    assert.equal(fx.owner.preflight(),pending);await assert.rejects(fx.owner.preflight());
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
const provisionEffectPauses=['read:vm-config','read:guest-source','command:guest-prepare','command:docker-image-load','command:docker-network-create','command:docker-create','open:identity','write:identity','sync:identity','command:docker-cp-passwd','read:passwd','command:guest-quota-test','open:identity-temp','write:identity-temp','sync:identity-temp','close:identity-temp','rename:identity','open:artifact-root','dir-sync:artifact-root'];
for(const pause of provisionEffectPauses)for(const during of ['expiry','cancel'])test('actual provision retains identities and blocks late '+during+' follow-up at '+pause,async t=>{
  const fx=await effectFixture(t),wait=fx.arm(pause);fx.now=fx.setupEnd-10;const pending=fx.owner.provision();
  try{
    await wait.entered.promise;const count=fx.effects.length,commands=fx.starts.length;if(during==='expiry')fx.now=fx.setupEnd;else fx.owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_SETUP_DEADLINE':'OWNER_CANCELLED'));await flush();assert.equal(fx.effects.length,count);assert.equal(fx.starts.length,commands);
    if(['command:docker-network-create','command:docker-create'].includes(pause)){assert.equal(fx.owner.retainedIdentity.network.id,fx.N);if(pause==='command:docker-create')assert.equal(fx.owner.retainedIdentity.container.id,fx.C);}
    if(pause.includes('identity-temp'))assert.equal(fx.files.get(fx.paths.identity).data,fx.initialIdentity);
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
for(const pause of ['authorize:inspect-owned-fixture','lstat:route-link','realpath:route-link','stat:route-link','statfs:results','lstat:results','open:ordinary','write:ordinary','sync:ordinary','close:ordinary'])for(const during of ['expiry','cancel'])test('actual ordinary record uses original SQL admission after '+during+' at '+pause,async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();fx.now=fx.setupEnd-1;fx.owner.beginSql();fx.now=fx.setupEnd+10;const end=fx.owner.captureAdmission().deadline,wait=fx.arm(pause),pending=fx.owner.record('ordinary',{inert:true});
  try{
    await wait.entered.promise;const count=fx.effects.length;if(during==='expiry')fx.now=end;else fx.owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_DEADLINE':'OWNER_CANCELLED'));await flush();assert.equal(fx.effects.length,count);
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
test('actual pending setup record cannot borrow a later SQL deadline while a fresh SQL record remains valid',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();const wait=fx.arm('lstat:route-link');fx.now=fx.setupEnd-10;const pending=fx.owner.record('ordinary',{inert:true});
  try{
    await wait.entered.promise;fx.now=fx.setupEnd-5;fx.owner.beginSql();fx.now=fx.setupEnd;wait.release.resolve();await assert.rejects(pending,e=>e.code==='OWNER_DEADLINE');
    fx.disarm();const result=await fx.owner.record('ordinary',{inert:true});assert.equal(result,fx.p.results+'/ordinary.json');assert.equal(JSON.parse(fx.files.get(result).data).measurement.inert,true);
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
test('actual cleanup preserves one restricted evidence file after authority denial and validates fixed suite accounting',async t=>{
  const fx=await effectFixture(t,{deny:'cleanup'});await fx.owner.provision();
  try{
    const receipt=await fx.owner.cleanup({deadline:fx.now+100});assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.equal(receipt.receiptWriteFailed,undefined);assert.ok(fx.files.has(fx.p.results+'/cleanup.json'));
    const accounting={cases:[{name:'fixture secret SELECT payload',status:'PASS'}],registered:1,passed:1,notRun:0,zeroTestsSuccess:false};
    const filename=await fx.owner.record('suite-accounting',accounting),text=fx.files.get(filename).data;assert.doesNotMatch(text,/fixture secret|SELECT payload/);assert.equal(JSON.parse(text).measurement.reportedEvidence,true);
    await assert.rejects(fx.owner.record('suite-accounting',accounting),e=>e.code==='OWNER_EVIDENCE_ALREADY_RECORDED');
    await assert.rejects(fx.owner.record('arbitrary',{terminal:true}),e=>e.code==='OWNER_CANCELLED');await assert.rejects(fx.owner.record('cleanup-other',{}),e=>e.code==='OWNER_RECEIPT_NAME');
    await assert.rejects(fx.owner.record('suite-accounting',{...accounting,passed:0}),e=>e.code==='OWNER_ACCOUNTING_SCHEMA');
    assert.equal(fx.records.filter(p=>p.endsWith('/cleanup.json')).length,1);assert.equal(fx.records.filter(p=>p.endsWith('/suite-accounting.json')).length,1);
  }finally{await fx.dispose();}
});
for(const pause of ['lstat:route-link','open:cleanup','write:cleanup','sync:cleanup','close:cleanup'])test('actual cleanup evidence cannot renew its latched end at '+pause,async t=>{
  const fx=await effectFixture(t,{deny:'cleanup'});await fx.owner.provision();const wait=fx.arm(pause),end=fx.now+100,pending=fx.owner.cleanup({deadline:end});
  try{
    await wait.entered.promise;const count=fx.effects.length;fx.now=end;wait.release.resolve();const receipt=await pending;await flush();assert.equal(receipt.receiptWriteFailed,true);assert.equal(fx.effects.length,count);
    const repeated=await fx.owner.cleanup({deadline:end+1000});assert.equal(repeated.code,'OWNER_DEADLINE');assert.equal(fx.effects.length,count);
    await assert.rejects(fx.owner.record('suite-accounting',{cases:[{name:'inert',status:'PASS'}],registered:1,passed:1,notRun:0,zeroTestsSuccess:false}),e=>e.code==='OWNER_DEADLINE');
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
for(const pause of ['authorize:inspect-owned-fixture','command:docker-inspect','command:docker-network-inspect','lstat:socket','read:guest-source','sql:SELECT','lstat:default-2'])for(const during of ['expiry','cancel'])test('actual owner measurement refuses late '+during+' receipt or follow-up at '+pause,async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();const wait=fx.arm(pause);fx.now=fx.setupEnd-10;const pending=fx.owner.verifyOwner(fx.owner.owner,'inspect-owned-fixture');
  try{
    await wait.entered.promise;const count=fx.effects.length,commands=fx.starts.length;if(during==='expiry')fx.now=fx.setupEnd;else fx.owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_DEADLINE':'OWNER_CANCELLED'));await flush();assert.equal(fx.effects.length,count);assert.equal(fx.starts.length,commands);
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
for(const [kind,pauses] of [['database',['command:docker-stop','command:docker-start','command:guest-verify-sentinel','sql:SELECT']],['vm',['command:colima-stop','command:colima-start','command:guest-prepare','command:docker-start']]])for(const pause of pauses)for(const during of ['expiry','cancel'])test('actual '+kind+' restart blocks late '+during+' effects at '+pause,async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();fx.migrated=true;const wait=fx.arm(pause,pause==='sql:SELECT'?6:1);fx.now=fx.setupEnd-10;const pending=kind==='database'?fx.owner.restartDatabase(fx.owner.owner,'clean'):fx.owner.restartVm();
  try{
    await wait.entered.promise;const count=fx.effects.length,commands=fx.starts.length;if(during==='expiry')fx.now=fx.setupEnd;else fx.owner.cancel();wait.release.resolve();
    await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_DEADLINE':'OWNER_CANCELLED'));await flush();assert.equal(fx.effects.length,count);assert.equal(fx.starts.length,commands);
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
test('actual provisioning command cannot borrow SQL lifetime after its original setup authorization wait',async t=>{
  const fx=await effectFixture(t),wait=fx.arm('authorize:colima-start');fx.now=fx.setupEnd-10;const pending=fx.owner.provision();
  try{
    await wait.entered.promise;fx.now=fx.setupEnd-5;fx.owner.beginSql();fx.now=fx.setupEnd;wait.release.resolve();
    await assert.rejects(pending,e=>e.code==='OWNER_SETUP_DEADLINE');assert.equal(fx.starts.includes('colima-start'),false);assert.equal(fx.owner.owner,null);
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
test('actual log routing refuses symlink ancestors before creating any descendant or VM',async t=>{
  const fx=await effectFixture(t);fx.links.set(fx.paths.sourceParent,'/inert-foreign');
  try{await assert.rejects(fx.owner.provision(),e=>e.code==='OWNER_LOG_ROUTE_PARENT');assert.equal(fx.effects.includes('mkdir:source-leaf'),false);assert.equal(fx.starts.includes('colima-start'),false);}
  finally{await fx.dispose();}
});
for(const action of ['docker-network-create','docker-create'])test('actual allocation retains uncertainty instead of a malformed '+action+' identity',async t=>{
  const fx=await effectFixture(t);fx.reply(action,(action==='docker-create'?fx.C:fx.N)+'\npartial');
  try{
    await assert.rejects(fx.owner.provision(),e=>e.code===(action==='docker-create'?'OWNER_CONTAINER_ID':'OWNER_NETWORK_ID'));
    const identity=fx.owner.retainedIdentity;assert.equal(action==='docker-create'?identity.container:identity.network,null);assert.equal(fx.owner.owner,null);
    assert.ok(identity.uncertainty.some(v=>v.action===action&&v.code==='OWNER_ALLOCATION_ID_UNKNOWN'));assert.equal(fx.starts.filter(a=>a===action).length,1);
  }finally{await fx.dispose();}
});
test('actual allocation never accepts a valid-looking ID from truncated command output',async t=>{
  const fx=await effectFixture(t);fx.reply('docker-network-create',[fx.N,'x'.repeat(2*1024**2)]);
  try{await assert.rejects(fx.owner.provision(),e=>e.code==='OWNER_OUTPUT_LIMIT');assert.equal(fx.owner.retainedIdentity.network,null);assert.equal(fx.owner.owner,null);assert.equal(fx.starts.filter(a=>a==='docker-network-create').length,1);}
  finally{await fx.dispose();}
});
test('actual private identity writer preserves initiating failure and uncertain close without replacing the prior identity',async t=>{
  const fx=await effectFixture(t);fx.fail('write:identity-temp','INERT_WRITE_FAILURE');fx.fail('close:identity-temp','INERT_CLOSE_FAILURE');
  try{
    await assert.rejects(fx.owner.provision(),e=>e.code==='INERT_WRITE_FAILURE'&&e.retirementFailures.includes('INERT_CLOSE_FAILURE'));
    assert.equal(fx.files.get(fx.paths.identity).data,fx.initialIdentity);assert.equal(fx.effects.includes('rename:identity'),false);
    assert.equal(fx.owner.retainedIdentity.container.id,fx.C);assert.ok(fx.owner.retainedIdentity.retirementFailures.some(v=>v.code==='INERT_CLOSE_FAILURE'));
  }finally{await fx.dispose();}
});
test('actual cleanup reports evidence retention failure without a fallback or duplicate write',async t=>{
  const fx=await effectFixture(t,{deny:'cleanup'});await fx.owner.provision();fx.fail('close:cleanup','INERT_CLOSE_FAILURE');
  try{
    const receipt=await fx.owner.cleanup({deadline:fx.now+100});assert.equal(receipt.receiptWriteFailed,true);assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');
    assert.ok(fx.owner.retainedIdentity.evidenceFailures.some(v=>v.slot==='cleanup'&&v.code==='INERT_CLOSE_FAILURE'));const count=fx.effects.length;
    await fx.owner.cleanup({deadline:fx.now+1000});assert.equal(fx.effects.length,count);assert.equal(fx.records.filter(p=>p.endsWith('/cleanup.json')).length,1);
  }finally{await fx.dispose();}
});
test('actual terminal evidence revalidates route identity and exposes an unpersisted failure',async t=>{
  const fx=await effectFixture(t,{deny:'cleanup'});await fx.owner.provision();fx.links.set(fx.paths.fileLink,'/inert-foreign');
  try{
    const count=fx.effects.length,receipt=await fx.owner.cleanup({deadline:fx.now+100});assert.equal(receipt.receiptWriteFailed,true);assert.equal(fx.effects.length,count);
    assert.equal(fx.files.has(fx.p.results+'/cleanup.json'),false);assert.ok(fx.owner.retainedIdentity.evidenceFailures.some(v=>v.code==='OWNER_LOG_ROUTE_CHANGED'));
  }finally{await fx.dispose();}
});
test('actual completed operation closes inherited admission for a late ordinary record while its phase remains live',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();const release=deferred(),entered=deferred(),original=fx.owner.withClient;let scheduled=false,late;
  t.mock.method(fx.owner,'withClient',async function(...args){
    if(!scheduled){scheduled=true;late=release.promise.then(()=>this.record('late',{inert:true}));late.catch(()=>{});entered.resolve();}
    return original.apply(this,args);
  });
  try{
    await fx.owner.verifyOwner(fx.owner.owner,'inspect-owned-fixture');await entered.promise;const count=fx.effects.length;release.resolve();await assert.rejects(late,e=>e.code==='OWNER_OPERATION_SCOPE_ENDED');assert.equal(fx.effects.length,count);
    assert.equal(fx.owner.signal.aborted,false);assert.ok(fx.now<fx.setupEnd);
  }finally{release.resolve();await late?.catch(()=>{});await fx.dispose();}
});
test('actual accounting adapter has no generic terminal options and refuses unvalidated reported counts',async t=>{
  const fx=await effectFixture(t,{deny:'cleanup'});await fx.owner.provision();await fx.owner.cleanup({deadline:fx.now+100});
  try{
    const count=fx.effects.length;
    await assert.rejects(fx.owner.record('ordinary',{inert:true},{terminal:true}),e=>e.code==='OWNER_RECEIPT_NAME');
    await assert.rejects(fx.owner.record('suite-accounting',{cases:[],registered:0,passed:0,notRun:0,zeroTestsSuccess:false}),e=>e.code==='OWNER_ACCOUNTING_SCHEMA');
    await assert.rejects(fx.owner.record('suite-accounting',{cases:[{name:'inert',status:'PASS'}],registered:1,passed:0,notRun:0,zeroTestsSuccess:false}),e=>e.code==='OWNER_ACCOUNTING_SCHEMA');
    assert.equal(fx.effects.length,count);
  }finally{await fx.dispose();}
});

// repair10 exercises production ownership of successful and losing open results.
for(const kind of ['file','directory'])for(const during of ['expiry','cancel','healthy','close-failure'])test('actual '+kind+' open retires exactly once after race success and outer '+during+' admission',async t=>{
  const fx=await effectFixture(t);if(kind==='file')await fx.owner.provision();
  const originalOpen=fs.open,signal=fx.owner.signal,remove=signal.removeEventListener;let acquired=false,triggered=false;
  const target=kind==='file'?fx.p.results+'/ordinary.json':fx.p.artifactRoot,closeTag=kind==='file'?'ordinary':'artifact-root';
  t.mock.method(fs,'open',async function(filename,flags,...args){const handle=await originalOpen.call(this,filename,flags,...args);if(filename===target&&(kind==='file'||flags===FC.O_RDONLY))acquired=true;return handle;});
  t.mock.method(signal,'removeEventListener',function(...args){
    const result=remove.apply(this,args);
    if(acquired&&!triggered){triggered=true;if(during==='expiry')fx.now=fx.setupEnd;else if(during==='cancel'||during==='close-failure')fx.owner.cancel();}
    return result;
  });
  if(during==='close-failure')fx.fail(kind==='file'?'close:ordinary':'dir-close:artifact-root','INERT_CLOSE_FAILURE');
  const pending=kind==='file'?fx.owner.record('ordinary',{inert:true}):fx.owner.provision();
  try{
    if(during==='healthy')await pending;
    else await assert.rejects(pending,e=>e.code===(during==='expiry'?(kind==='file'?'OWNER_DEADLINE':'OWNER_SETUP_DEADLINE'):'OWNER_CANCELLED')&&(during!=='close-failure'||e.retirementFailures.includes('INERT_CLOSE_FAILURE')));
    await flush();assert.equal(triggered,true);assert.equal(fx.closed.filter(v=>v===closeTag).length,1);
    if(kind==='file'&&during!=='healthy')assert.equal(fx.effects.includes('write:ordinary'),false);
    if(during==='close-failure')assert.ok(fx.owner.retainedIdentity.retirementFailures.some(v=>v.code==='INERT_CLOSE_FAILURE'));
  }finally{await pending.catch(()=>{});await fx.dispose();}
});
for(const during of ['expiry','cancel','close-failure'])test('actual losing open completion retires once with '+during+' and retains failure',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();const wait=fx.arm('open:ordinary'),pending=fx.owner.record('ordinary',{inert:true});pending.catch(()=>{});
  try{
    await wait.entered.promise;if(during==='expiry')fx.now=fx.setupEnd;else fx.owner.cancel();
    if(during==='close-failure')fx.fail('close:ordinary','INERT_CLOSE_FAILURE');
    wait.release.resolve();await assert.rejects(pending,e=>e.code===(during==='expiry'?'OWNER_DEADLINE':'OWNER_CANCELLED'));await flush();
    assert.equal(fx.closed.filter(v=>v==='ordinary').length,1);assert.equal(fx.effects.includes('write:ordinary'),false);
    if(during==='close-failure')assert.ok(fx.owner.retainedIdentity.retirementFailures.some(v=>v.code==='INERT_CLOSE_FAILURE'));
  }finally{wait.release.resolve();await pending.catch(()=>{});await fx.dispose();}
});
for(const pause of ['authorize:cleanup','authorize:docker-stop','authorize:verify-stopped','command:docker-inspect','command:colima-status'])test('actual concurrent cleanup tightening ends pending '+pause+' without stale commands or stopped success',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();if(pause==='command:colima-status')fx.reply('docker-inspect','invalid-json');
  const wait=fx.arm(pause),first=fx.owner.cleanup({deadline:fx.now+100});
  try{
    await wait.entered.promise;const commands=fx.starts.length;fx.now+=10;const second=fx.owner.cleanup({deadline:fx.now});
    const receipts=await Promise.all([first,second]);
    // The pending promise settles at tightened equality before the inert gate/child resolves.
    for(const receipt of receipts){assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.equal(receipt.resourcesStopped,false);}
    assert.equal(fx.starts.length,commands);wait.release.resolve();await flush();assert.equal(fx.starts.length,commands);
    assert.equal(fx.owner.retainedIdentity.container.id,fx.C);assert.equal(fx.owner.retainedIdentity.network.id,fx.N);
  }finally{wait.release.resolve();await first.catch(()=>{});await fx.dispose();}
});
test('actual cleanup admits a pending authorization within a healthy tightened original deadline',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();const wait=fx.arm('authorize:cleanup'),first=fx.owner.cleanup({deadline:fx.now+100});
  try{
    await wait.entered.promise;const second=await fx.owner.cleanup({deadline:fx.now+60});assert.equal(second.status,'STOPPED_RETAINED');
    wait.release.resolve();const receipt=await first;assert.equal(receipt.status,'STOPPED_RETAINED');assert.equal(receipt.resourcesStopped,true);
    assert.equal(fx.records.filter(p=>p.endsWith('/cleanup.json')).length,1);
  }finally{wait.release.resolve();await first.catch(()=>{});await fx.dispose();}
});
for(const operation of ['write','sync','close'])test('actual finishRuntime rejects stopped resources when mandatory cleanup '+operation+' evidence fails',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();fx.fail(operation+':cleanup','INERT_'+operation.toUpperCase()+'_FAILURE');
  try{
    await assert.rejects(finishRuntime({owner:fx.owner},{deadline:fx.now+100}),e=>e.code==='OWNER_CLEANUP_INCOMPLETE'&&e.cleanup.status==='CLEANUP_INCOMPLETE_RETAINED'&&e.cleanup.resourcesStopped===true&&e.cleanup.receiptWriteFailed===true&&e.cleanup.failures.some(f=>f.action==='cleanup-evidence'&&f.code==='INERT_'+operation.toUpperCase()+'_FAILURE'));
    const effects=fx.effects.length,again=await fx.owner.cleanup({deadline:fx.now+1000});assert.equal(again.status,'CLEANUP_INCOMPLETE_RETAINED');assert.equal(again.resourcesStopped,true);assert.equal(fx.effects.length,effects);
    assert.equal(fx.owner.retainedIdentity.container.id,fx.C);assert.ok(fx.owner.retainedIdentity.evidenceFailures.some(v=>v.slot==='cleanup'&&v.code==='INERT_'+operation.toUpperCase()+'_FAILURE'));
  }finally{await fx.dispose();}
});
test('actual finishRuntime retains healthy stopped evidence and succeeds without changing runner',async t=>{
  const fx=await effectFixture(t);await fx.owner.provision();
  try{const receipt=await finishRuntime({owner:fx.owner},{deadline:fx.now+100});assert.equal(receipt.status,'STOPPED_RETAINED');assert.equal(receipt.resourcesStopped,true);assert.equal(receipt.receiptWriteFailed,undefined);assert.deepEqual(receipt.failures,[]);assert.ok(fx.files.has(fx.p.results+'/cleanup.json'));}
  finally{await fx.dispose();}
});

async function cleanupChildFixture(t){
  let now=10,serial=0,gateHold,childHold;const timers=new Map(),starts=[],kills=[],children=[],listeners=new Set(),gateCounts=new Map();
  t.mock.method(performance,'now',()=>now);
  t.mock.method(globalThis,'setTimeout',(callback,ms,...args)=>{const id={serial:++serial,unref(){return this;}};timers.set(id,{at:now+Math.max(0,ms),callback:()=>callback(...args),name:callback.name});return id;});
  t.mock.method(globalThis,'clearTimeout',id=>timers.delete(id));
  const add=AbortSignal.prototype.addEventListener,remove=AbortSignal.prototype.removeEventListener;
  t.mock.method(AbortSignal.prototype,'addEventListener',function(type,listener,...args){if(type==='abort'&&listener.name==='retire')listeners.add(listener);return add.call(this,type,listener,...args);});
  t.mock.method(AbortSignal.prototype,'removeEventListener',function(type,listener,...args){if(type==='abort'&&listener.name==='retire')listeners.delete(listener);return remove.call(this,type,listener,...args);});
  let armed=false;
  const ack=(record,code=0)=>{if(record.closed)return;record.closed=true;const output=record.complete();for(const value of Array.isArray(output)?output:[output])record.child.stdout.emit('data',Buffer.from(value));record.child.emit('close',code);};
  const fx=await effectFixture(t,{authorizeHook:async action=>{
    const ordinal=(gateCounts.get(action)??0)+1;gateCounts.set(action,ordinal);
    if(gateHold?.action===action&&gateHold.ordinal===ordinal){const held=gateHold;held.entered.resolve();await held.release.promise;}
    return true;
  },commandInterceptor:({action,executable,args,options,complete})=>{
    if(!armed)return null;
    assert.equal(options.shell,false);assert.ok(['docker','colima'].includes(path.basename(executable)));
    const child=new EventEmitter();child.stdout=new EventEmitter();child.stderr=new EventEmitter();child.stdin=new EventEmitter();
    const record={child,action,args,complete,closed:false,ordinal:starts.filter(a=>a===action).length+1};starts.push(record.action);children.push(record);
    const hold=childHold?.action===record.action&&childHold.ordinal===record.ordinal?childHold:null;
    child.kill=signal=>{kills.push({action:record.action,ordinal:record.ordinal,signal,at:now});if(hold?.closeOn===signal)ack(record);return true;};
    child.stdin.end=()=>{if(hold){hold.record=record;hold.entered.resolve();}else queueMicrotask(()=>ack(record));};return child;
  }});
  await fx.owner.provision();const owner=fx.owner;armed=true;
  t.mock.method(performance,'now',()=>now);
  // Genuine prepared roots, bound tools, routed logs, and retained resource identities.
  assert.equal(owner.phase,'provisioned');assert.equal(owner.retainedIdentity.mount.device,2);
  return {owner,starts,kills,children,timers,listeners,get now(){return now;},
    holdGate(action){gateHold={action,ordinal:(gateCounts.get(action)??0)+1,entered:deferred(),release:deferred()};return gateHold;},
    holdChild(action,{closeOn}={}){childHold={action,ordinal:starts.filter(a=>a===action).length+1,entered:deferred(),closeOn,record:null};return childHold;},
    ack,async advance(end){let limit=1000;while(true){const next=[...timers].filter(([,v])=>v.at<=end).sort((a,b)=>a[1].at-b[1].at||a[0].serial-b[0].serial)[0];if(!next)break;assert.ok(limit-->0,'controlled timer loop');now=Math.max(now,next[1].at);timers.delete(next[0]);next[1].callback();await flush();}now=end;await flush();},
    async dispose(){gateHold?.release.resolve();for(const record of children)ack(record);await flush();timers.clear();fx.disarm();t.mock.restoreAll();syncBuiltinESMExports();}
  };
}
test('actual cleanup child spawned after future tightening receives current deadline TERM KILL and retained unconfirmed ownership',async t=>{
  const fx=await cleanupChildFixture(t),gate=fx.holdGate('docker-stop'),first=fx.owner.cleanup({deadline:fx.now+1000});
  try{
    await Promise.race([gate.entered.promise,first.then(()=>{throw new Error('cleanup gate was not reached');})]);const tightened=fx.now+60,second=await fx.owner.cleanup({deadline:tightened});assert.equal(second.status,'STOPPED_RETAINED');
    const hold=fx.holdChild('docker-stop');gate.release.resolve();await Promise.race([hold.entered.promise,first.then(()=>{throw new Error('cleanup child was not reached');})]);assert.ok(hold.record);const ordinal=hold.record.ordinal;
    assert.ok(fx.now<tightened);assert.deepEqual(fx.kills,[]);assert.ok([...fx.timers.values()].some(v=>v.name==='retire'&&v.at===tightened));
    await fx.advance(tightened);const receipt=await first;assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');assert.ok(receipt.failures.some(f=>f.code==='OWNER_CHILDREN_REMAIN'));
    assert.deepEqual(fx.kills.filter(k=>k.ordinal===ordinal).map(k=>k.signal),['SIGTERM']);fx.owner.cancel();assert.equal(fx.kills.filter(k=>k.ordinal===ordinal).length,1);
    await fx.advance(tightened+1000);assert.deepEqual(fx.kills.filter(k=>k.ordinal===ordinal).map(k=>k.signal),['SIGTERM','SIGKILL']);
    await fx.advance(tightened+2000);assert.ok(fx.owner.retainedIdentity.retirementFailures.some(v=>v.action==='docker-stop'&&v.code==='OWNER_CHILD_STOP_UNCONFIRMED'));
    const repeated=await fx.owner.cleanup({deadline:tightened+5000});assert.ok(repeated.failures.some(f=>f.code==='OWNER_CHILDREN_REMAIN'));assert.equal(repeated.status,'CLEANUP_INCOMPLETE_RETAINED');
    fx.ack(hold.record);await flush();assert.equal(fx.listeners.size,0);assert.equal(fx.timers.size,0);
  }finally{gate.release.resolve();await first.catch(()=>{});await fx.dispose();}
});
test('actual already spawned cleanup child retires once when a concurrent future deadline tightens',async t=>{
  const fx=await cleanupChildFixture(t),hold=fx.holdChild('docker-stop'),first=fx.owner.cleanup({deadline:fx.now+1000});
  try{
    await Promise.race([hold.entered.promise,first.then(()=>{throw new Error('cleanup child was not reached');})]);assert.ok(hold.record);const tightened=fx.now+60,second=await fx.owner.cleanup({deadline:tightened});assert.equal(second.status,'CLEANUP_INCOMPLETE_RETAINED');
    assert.equal(fx.kills.filter(k=>k.ordinal===hold.record.ordinal&&k.signal==='SIGTERM').length,1);
    await fx.advance(tightened);await first;assert.equal(fx.kills.filter(k=>k.ordinal===hold.record.ordinal&&k.signal==='SIGTERM').length,1);
    await fx.advance(tightened+1000);assert.equal(fx.kills.filter(k=>k.ordinal===hold.record.ordinal&&k.signal==='SIGKILL').length,1);
    fx.ack(hold.record);await flush();await fx.advance(tightened+2000);assert.equal(fx.listeners.size,0);assert.equal(fx.timers.size,0);assert.equal(fx.owner.retainedIdentity.retirementFailures.length,0);
  }finally{await fx.dispose();}
});
test('actual pending cleanup child admission refuses after the tightened deadline without spawn',async t=>{
  const fx=await cleanupChildFixture(t),gate=fx.holdGate('docker-stop'),first=fx.owner.cleanup({deadline:fx.now+1000});
  try{
    await Promise.race([gate.entered.promise,first.then(()=>{throw new Error('cleanup gate was not reached');})]);const tightened=fx.now+60;await fx.owner.cleanup({deadline:tightened});const count=fx.starts.length;
    await fx.advance(tightened);assert.equal((await first).status,'CLEANUP_INCOMPLETE_RETAINED');gate.release.resolve();await flush();assert.equal(fx.starts.length,count);assert.deepEqual(fx.kills,[]);assert.equal(fx.listeners.size,0);assert.equal(fx.timers.size,0);
  }finally{gate.release.resolve();await first.catch(()=>{});await fx.dispose();}
});
test('actual healthy cleanup child completion clears cancellation listeners and command timers before expiry',async t=>{
  const fx=await cleanupChildFixture(t),hold=fx.holdChild('docker-stop'),pending=fx.owner.cleanup({deadline:fx.now+60});
  try{
    await Promise.race([hold.entered.promise,pending.then(()=>{throw new Error('cleanup child was not reached');})]);assert.ok(hold.record);assert.equal(fx.listeners.size,1);fx.ack(hold.record);const receipt=await pending;assert.equal(receipt.status,'STOPPED_RETAINED');assert.equal(receipt.resourcesStopped,true);assert.equal(fx.listeners.size,0);
    assert.equal(fx.timers.size,1);await fx.advance(fx.now+2060);assert.deepEqual(fx.kills,[]);assert.equal(fx.timers.size,0);
  }finally{await fx.dispose();}
});
for(const signal of ['SIGTERM','SIGKILL'])test('actual cleanup child '+signal+' close race acknowledges once without orphaned escalation',async t=>{
  const fx=await cleanupChildFixture(t),hold=fx.holdChild('docker-stop',{closeOn:signal}),end=fx.now+60,pending=fx.owner.cleanup({deadline:end});
  try{
    await Promise.race([hold.entered.promise,pending.then(()=>{throw new Error('cleanup child was not reached');})]);assert.ok(hold.record);await fx.advance(end);assert.equal((await pending).status,'CLEANUP_INCOMPLETE_RETAINED');if(signal==='SIGKILL')await fx.advance(end+1000);
    fx.ack(hold.record);await flush();await fx.advance(end+2000);
    assert.deepEqual(fx.kills.map(k=>k.signal),signal==='SIGTERM'?['SIGTERM']:['SIGTERM','SIGKILL']);assert.equal(fx.listeners.size,0);assert.equal(fx.timers.size,0);
    assert.equal(fx.owner.events.filter(e=>e.action==='docker-stop'&&e.exitCode===0).length,1);assert.equal(fx.owner.retainedIdentity.retirementFailures.length,0);
  }finally{await fx.dispose();}
});

async function toolInputFixture(){
  const dir=await fs.realpath(await fs.mkdtemp(path.join(testFiles,'bound-tools-'))),prefix=dir+'/prefix',run=dir+'/run';
  await fs.mkdir(prefix+'/bin',{recursive:true,mode:0o700});await fs.mkdir(prefix+'/share/lima',{recursive:true,mode:0o700});
  for(const [name,data] of [['bin/limactl','private-limactl'],['bin/lima','#!/bin/sh\nexec limactl shell "$@"\n'],['share/lima/lima-guestagent.Linux-aarch64','paired-guest']]){
    await fs.writeFile(prefix+'/'+name,data,{mode:0o700});
  }
  const p={...plan,artifactRoot:run,colimaHome:dir+'/private-colima/c',dockerConfig:run+'/docker-config',results:run+'/results'};
  const provenance=dir+'/provenance.json';await fs.writeFile(provenance,JSON.stringify({kind:'INERT_UNIT_INPUT_NOT_RUNTIME_QUALIFICATION'}),{mode:0o600});
  const reference=async filename=>{const data=await fs.readFile(filename);return {path:await fs.realpath(filename),bytes:data.length,sha256:digest(data)};};
  const tools={};
  for(const name of TOOL_NAMES){
    const filename=name==='node'?await fs.realpath(process.execPath):dir+'/'+name;
    if(name!=='node')await fs.writeFile(filename,'inert-'+name,{mode:0o700});
    const s=await fs.stat(filename),data=await fs.readFile(filename);
    tools[name]={canonicalPath:filename,trustedRoot:path.dirname(filename),uid:s.uid,mode:s.mode,bytes:data.length,sha256:digest(data),version:PIN[name]??'host-system',provenance:await reference(provenance)};
  }
  const entries=[];
  async function walk(parent){
    for(const name of (await fs.readdir(parent)).sort()){
      const filename=parent+'/'+name,s=await fs.lstat(filename),relative=path.relative(prefix,filename);
      entries.push({path:relative,type:s.isDirectory()?'directory':'file',uid:s.uid,mode:s.mode,bytes:s.isDirectory()?0:s.size,sha256:s.isDirectory()?null:digest(await fs.readFile(filename))});
      if(s.isDirectory())await walk(filename);
    }
  }
  await walk(prefix);
  const version='v2.1.3-aegis.stage1.unit+base.1285a6d70f23',sourceSha256='e'.repeat(64);
  const host=entries.find(x=>x.path==='bin/limactl').sha256,guest=entries.find(x=>x.path==='share/lima/lima-guestagent.Linux-aarch64').sha256;
  const pairId=digest(JSON.stringify({host,guest,sourceSha256,version}));
  const bundle={format:'B1_BOUND_LIMA_PREFIX_V1',prefix,version,sourceSha256,baseCommit:'1285a6d70f23afe8129c3868df178cf9ffe23aaf',pairId,entries};
  const bundlePath=dir+'/prefix.json';await fs.writeFile(bundlePath,JSON.stringify(bundle),{mode:0o600});
  const ownedLogPath=dir+'/owned-logs.json';await fs.writeFile(ownedLogPath,JSON.stringify({unitOnly:true,instance:'colima-b1-owner'}),{mode:0o600});
  const m={runId:p.runId,tools,toolchain:{format:'B1_BOUND_TOOLCHAIN_V1',runId:p.runId,lima:{prefix,version,pairId,manifest:await reference(bundlePath)},ownedLogManifest:await reference(ownedLogPath)}};
  return {dir,p,m,bundle,bundlePath,reference};
}

test('bound tools select canonical mise/private inputs with a deterministic child environment',async()=>{
  const f=await toolInputFixture(),saved={PATH:process.env.PATH,NODE_OPTIONS:process.env.NODE_OPTIONS,DOCKER_HOST:process.env.DOCKER_HOST};
  try{
    process.env.PATH='/poisoned';process.env.NODE_OPTIONS='--require=/untrusted';process.env.DOCKER_HOST='unix:///foreign.sock';
    const checked=await verifyToolchain(f.p,f.m),env=toolEnvironment(f.p,f.m.toolchain);
    assert.equal(checked.executables.pnpm,f.m.tools.pnpm.canonicalPath);
    assert.equal(env.PATH,f.m.toolchain.lima.prefix+'/bin:'+f.p.artifactRoot+'/tools/bin:/usr/bin:/bin:/usr/sbin:/sbin');
    assert.equal(env.HOME,process.env.HOME);assert.equal(env.NODE_OPTIONS,undefined);assert.equal(env.DOCKER_HOST,undefined);assert.equal(env.SSH_AUTH_SOCK,undefined);
    const spec=command(f.p,'colima',['--version'],{executable:checked.executables.colima,toolchain:f.m.toolchain});
    assert.equal(spec.executable,f.m.tools.colima.canonicalPath);assert.deepEqual(spec.env,env);assert.ok(!spec.env.PATH.includes('/opt/homebrew/bin'));
  }finally{for(const [k,v]of Object.entries(saved))if(v===undefined)delete process.env[k];else process.env[k]=v;}
});
for(const [name,mutate] of [
  ['digest',m=>m.tools.pnpm.sha256='f'.repeat(64)],
  ['size',m=>m.tools.pnpm.bytes++],
  ['mode',m=>m.tools.pnpm.mode=0o777],
  ['owner',m=>m.tools.pnpm.uid=2147483647],
  ['version',m=>m.tools.pnpm.version='9.15.1'],
  ['escape',m=>m.tools.pnpm.trustedRoot+='/other'],
  ['unknown tool',m=>m.tools.unreviewed={...m.tools.pnpm}],
  ['ambient environment field',m=>m.toolchain.environment={NODE_OPTIONS:'--require=foreign'}],
  ['old Lima version',m=>m.toolchain.lima.version='v0.0.0-stage1-20261017.2'],
])test('bound tool inputs refuse '+name+' before executable probes',async()=>{
  const f=await toolInputFixture();mutate(f.m);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e instanceof OwnerError&&/^OWNER_(TOOL|LIMA)/.test(e.code));
});
test('bound tool inputs reject symlink retargeting and missing provenance',async()=>{
  const f=await toolInputFixture(),binary=f.m.tools.pnpm.canonicalPath;
  await fs.unlink(binary);await fs.symlink(f.m.tools.docker.canonicalPath,binary);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
  await fs.unlink(binary);await fs.writeFile(binary,'inert-pnpm',{mode:0o700});f.m.tools.pnpm.provenance.sha256='0'.repeat(64);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_TOOL_PROVENANCE');
});
for(const item of ['launcher','guest bytes','extra member','mixed pair'])test('private Lima prefix refuses '+item,async()=>{
  const f=await toolInputFixture(),prefix=f.m.toolchain.lima.prefix;
  if(item==='launcher')await fs.unlink(prefix+'/bin/lima');
  if(item==='guest bytes')await fs.writeFile(prefix+'/share/lima/lima-guestagent.Linux-aarch64','foreign');
  if(item==='extra member')await fs.writeFile(prefix+'/bin/foreign','foreign');
  if(item==='mixed pair')f.m.toolchain.lima.pairId='0'.repeat(64);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_LIMA_PAIR');
});
async function materializeUnitToolDirectories(f){
  const env=toolEnvironment(f.p,f.m.toolchain),dirs=[...toolDirectories(f.p),env.TMPDIR];
  for(const dir of dirs)await fs.mkdir(dir,{recursive:true,mode:0o700});
  await fs.writeFile(env.npm_config_userconfig,'',{mode:0o600});
  for(const name of ['node','pnpm','colima','docker'])await fs.symlink(f.m.tools[name].canonicalPath,f.p.artifactRoot+'/tools/bin/'+name);
}
test('ready directory validation refuses absent private homes, alias drift, and untrusted parents',async()=>{
  const f=await toolInputFixture();
  await assert.rejects(verifyToolchain(f.p,f.m,{ready:true}),e=>e.code==='OWNER_TOOL_ENVIRONMENT');
  await materializeUnitToolDirectories(f);await verifyToolchain(f.p,f.m,{ready:true});
  const alias=f.p.artifactRoot+'/tools/bin/pnpm';await fs.unlink(alias);await fs.symlink(f.m.tools.docker.canonicalPath,alias);
  await assert.rejects(verifyToolchain(f.p,f.m,{ready:true}),e=>e.code==='OWNER_TOOL_ALIAS');
  await fs.unlink(alias);await fs.symlink(f.m.tools.pnpm.canonicalPath,alias);await fs.chmod(path.dirname(alias),0o777);
  await assert.rejects(verifyToolchain(f.p,f.m,{ready:true}),e=>e.code==='OWNER_TOOL_ENVIRONMENT');
});
for(const phase of ['start','restart','cleanup'])test('actual owner revalidates changed tool bytes before '+phase+' command dispatch',async t=>{
  const f=await effectFixture(t);
  try{
    if(phase!=='start')await f.owner.provision();f.starts.length=0;
    f.files.get('/inert/pnpm').data='changed-tool-bytes';
    if(phase==='cleanup'){const receipt=await f.owner.cleanup();assert.equal(receipt.status,'CLEANUP_INCOMPLETE_RETAINED');}
    else await assert.rejects(phase==='start'?f.owner.provision():f.owner.restartVm(),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
    assert.deepEqual(f.starts,[]);
  }finally{await f.dispose();}
});
test('filesystem-only preflight leaves unresolved image and log receipts fail closed',async t=>{
  const f=await effectFixture(t,{preflight:false});
  try{
    f.m.logRouting.guestBootPolicy='UNPROVEN';await assert.rejects(f.owner.preflight(),e=>e.code==='OWNER_LOG_ROUTING_UNVERIFIED');
    assert.deepEqual(f.starts,[]);assert.equal(f.owner.phase,'new');
  }finally{await f.dispose();}
});

test('bound tools admit the separately pinned system ps metadata and reject set-id package tools',async()=>{
  const f=await toolInputFixture(),filename=await fs.realpath('/bin/ps'),s=await fs.stat(filename);
  f.m.tools.ps={...f.m.tools.ps,canonicalPath:filename,trustedRoot:path.dirname(filename),uid:s.uid,mode:s.mode,bytes:s.size,sha256:digest(await fs.readFile(filename))};
  await verifyToolchain(f.p,f.m);
  const binary=f.m.tools.pnpm.canonicalPath;await fs.chmod(binary,0o4755);f.m.tools.pnpm.mode=(await fs.stat(binary)).mode;
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_TOOL_SOURCE_PIN');
});
test('private Lima bin cannot shadow the separately bound Node executable',async()=>{
  const f=await toolInputFixture();await fs.writeFile(f.m.toolchain.lima.prefix+'/bin/node','unbound',{mode:0o700});
  const s=await fs.stat(f.m.toolchain.lima.prefix+'/bin/node');
  f.bundle.entries.push({path:'bin/node',type:'file',uid:s.uid,mode:s.mode,bytes:s.size,sha256:digest('unbound')});
  await fs.writeFile(f.bundlePath,JSON.stringify(f.bundle));f.m.toolchain.lima.manifest=await f.reference(f.bundlePath);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_LIMA_PAIR');
});

test('actual command dispatch catches tool replacement during final pending authority',async t=>{
  const f=await effectFixture(t),gate=f.arm('authorize:hdiutil-create',2),pending=f.owner.provision();
  try{
    await gate.entered.promise;f.files.get('/inert/pnpm').data='replaced-pnpm';gate.release.resolve();
    await assert.rejects(pending,e=>e.code==='OWNER_TOOL_SOURCE_PIN');assert.deepEqual(f.starts,[]);
  }finally{gate.release.resolve();await pending.catch(()=>{});await f.dispose();}
});

for(const layout of ['both','compressed-only'])test('M01 exact selected uncompressed pair succeeds and '+layout+' guest alternative refuses',async()=>{
  const f=await toolInputFixture();await verifyToolchain(f.p,f.m);
  const name='share/lima/lima-guestagent.Linux-aarch64.gz',filename=f.m.toolchain.lima.prefix+'/'+name;
  await fs.writeFile(filename,gzipSync(Buffer.from('different guest build')),{mode:0o700});
  const s=await fs.lstat(filename);f.bundle.entries.push({path:name,type:'file',uid:s.uid,mode:s.mode,bytes:s.size,sha256:digest(await fs.readFile(filename))});
  if(layout==='compressed-only'){await fs.unlink(f.m.toolchain.lima.prefix+'/share/lima/lima-guestagent.Linux-aarch64');f.bundle.entries=f.bundle.entries.filter(e=>e.path!=='share/lima/lima-guestagent.Linux-aarch64');}
  await fs.writeFile(f.bundlePath,JSON.stringify(f.bundle));f.m.toolchain.lima.manifest=await f.reference(f.bundlePath);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_LIMA_PAIR');
});
test('M01 selected guest symlink retarget refuses despite an otherwise exact prefix manifest',async()=>{
  const f=await toolInputFixture(),p=f.m.toolchain.lima.prefix+'/share/lima/lima-guestagent.Linux-aarch64';
  await verifyToolchain(f.p,f.m);await fs.unlink(p);await fs.symlink(f.m.toolchain.lima.prefix+'/bin/limactl',p);
  await assert.rejects(verifyToolchain(f.p,f.m),e=>e.code==='OWNER_LIMA_PAIR');
});
for(const operation of ['provision','restartVm','cleanup'])test('M04 '+operation+' expiry solely during final tool validation prevents the next spawn',async t=>{
  let wall=10;t.mock.method(Date,'now',()=>wall);
  const fx=await effectFixture(t,{capabilityExpiresAt:100});
  try{
    if(operation!=='provision')await fx.owner.provision();
    const count=fx.starts.length,original=fx.owner.revalidateCommand;let checks=0;
    t.mock.method(fx.owner,'revalidateCommand',async function(...args){
      const value=await original.apply(this,args);
      if(++checks===2)wall=100;return value;
    });
    if(operation==='cleanup'){
      const result=await fx.owner.cleanup({deadline:fx.now+1000});
      assert.equal(result.status,'CLEANUP_INCOMPLETE_RETAINED');
      const stopped=result.failures.filter(f=>f.action==='docker-stop');
      assert.equal(stopped.length,1);assert.equal(stopped[0].code,'OWNER_CAPABILITY_EXPIRED');
      assert.equal(result.failures.some(f=>f.action==='cleanup'),false);
    }else await assert.rejects(fx.owner[operation](),e=>e.code==='OWNER_CAPABILITY_EXPIRED');
    assert.equal(checks,2);assert.equal(fx.starts.length,count);
  }finally{wall=10;await fx.dispose();}
});

test('M04 an unexpired finite capability retains healthy qualified provision and cleanup',async t=>{
  t.mock.method(Date,'now',()=>10);const fx=await effectFixture(t,{capabilityExpiresAt:100});
  try{
    await fx.owner.provision();assert.ok(fx.starts.includes('colima-start'));
    const receipt=await fx.owner.cleanup({deadline:fx.now+1000});
    assert.equal(receipt.status,'STOPPED_RETAINED');assert.equal(receipt.resourcesStopped,true);
  }finally{await fx.dispose();}
});

for(const scenario of ['positive','export-expired','reauth-expired','original-deadline','cancelled','closed','export-error','fork-error','reauth-denied'])test('worker issuance preserves final admission across '+scenario,async t=>{
  let admissions=0,spawned=0,captures=0,now=10;
  if(scenario==='original-deadline'){
    t.mock.method(performance,'now',()=>now);
    const schedule=setTimeout;
    t.mock.method(globalThis,'setTimeout',(...args)=>{const timer=schedule(...args);if(args[1]===CAPS.suiteMs)timer.unref();return timer;});
  }
  const authorize=async({action})=>{
    if(action==='start-owned-worker'){
      admissions++;
      if(admissions===2&&scenario==='reauth-denied')return false;
      if(admissions===2&&scenario==='reauth-expired')await new Promise(resolve=>setTimeout(resolve,Math.max(0,authorize.expiresAt-Date.now()+5)));
    }
    return true;
  };
  const {owner}=await bindingOwner(t,authorize),end=owner.captureAdmission().deadline;
  const {harness,bindings}=await pureHarness({
    onAdmission:action=>owner.gate.require(action),
    captureAdmission:()=>{captures++;const {check}=owner.captureAdmission();return ()=>{check();owner.gate.assertFresh();};},
  });
  const resources=budgetHarness(harness,owner),cp=createRequire(import.meta.url)('node:child_process');
  t.mock.method(cp,'fork',()=>{
    spawned++;
    if(scenario==='fork-error')throw new Error('fixture fork failure');
    const child=new EventEmitter();child.exitCode=null;child.signalCode=null;
    child.send=()=>true;
    child.kill=signal=>{queueMicrotask(()=>{child.signalCode=signal;child.emit('exit',null,signal);child.emit('close',null,signal);});return true;};
    return child;
  });
  syncBuiltinESMExports();
  let wait,worker,pending;
  try{
    if(scenario==='export-error'){
      const keys=await crypto.subtle.generateKey({name:'ECDSA',namedCurve:'P-256'},false,['sign','verify']);
      bindings.serverKey.privateKey=keys.privateKey;
    }else wait=pendingCrypto(t,'exportKey',args=>args[0]==='jwk'&&args[1].type==='private');
    authorize.expiresAt=Date.now()+(['export-expired','reauth-expired'].includes(scenario)?80:60000);
    pending=harness.issuanceWorker({...bindings,origin:'http://127.0.0.1',clock:{now:1}},{path:'/bootstrap/register',data:{},headers:{}}).then(value=>{worker=value;return value;});
    // Observe rejection immediately while the real WebCrypto export is held.
    pending.catch(()=>{});
    if(wait){
      await wait.entered.promise;
      assert.equal(admissions,1);assert.equal(spawned,0);assert.equal(owner.budget.state.used,0);
      if(scenario==='export-expired')await new Promise(resolve=>setTimeout(resolve,Math.max(0,authorize.expiresAt-Date.now()+5)));
      if(scenario==='original-deadline'){now=end-1;owner.beginSql();now=end;}
      if(scenario==='cancelled')owner.cancel();
      if(scenario==='closed')await harness.close();
      wait.release.resolve();
    }
    if(scenario==='positive'){
      await pending;assert.equal(admissions,2);assert.equal(captures,1);assert.equal(spawned,1);
      assert.equal(owner.budget.state.used,2);await worker.kill();worker=null;
    }else{
      const codes={'export-expired':'OWNER_CAPABILITY_EXPIRED','reauth-expired':'OWNER_CAPABILITY_EXPIRED','original-deadline':'OWNER_DEADLINE','cancelled':'OWNER_CANCELLED','closed':'SERVER_CLOSED','reauth-denied':'OWNER_NOT_AUTHORIZED'};
      await assert.rejects(pending,error=>scenario==='export-error'?error instanceof Error:scenario==='fork-error'?error.message==='fixture fork failure':error.code===codes[scenario]);
      assert.equal(spawned,scenario==='fork-error'?1:0);
    }
    assert.equal(owner.budget.state.used,0);assert.equal(resources.state().workers,0);
  }catch(error){throw error;}finally{
    wait?.release.resolve();if(pending)await pending.catch(()=>{});
    if(worker)await worker.kill();await harness.close();await bindings.store.close();owner.cancel();
    t.mock.restoreAll();syncBuiltinESMExports();
  }
});
