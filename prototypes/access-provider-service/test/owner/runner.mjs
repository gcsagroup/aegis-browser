// Source-only CLI. No execution on import; plan is pure. Runtime needs I's exact
// reviewed phase capability, immutable cache inputs and fresh measured admission.
import { promises as fs, constants as FC, openSync,writeSync,fsyncSync,closeSync,renameSync,lstatSync } from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { randomUUID } from 'node:crypto';
import { performance } from 'node:perf_hooks';
import { AsyncLocalStorage } from 'node:async_hooks';
import { importJWK, exportJWK, CompactSign } from 'jose';
import { fixtureBindings, mutableClock, keyPair } from '../fixtures.mjs';
import { admitPostgres,assertAdmitted } from '../pg-harness.mjs';
import { registerPostgresTests } from '../postgres.test.mjs';
import { normalizePublicJwk,canonical,reject } from '../../proof.mjs';
import { CAPS,OwnerError,OwnerSupervisor,createPlan,capabilityAuthorizer,digest,ownedRace,settleClosures } from './owner.mjs';
import { clockSmoke,runDeadlock,runIssuanceAckLoss,runObservationAckLoss,runMarkerAckLoss } from './fault-cases.mjs';

const bad=code=>{throw new OwnerError(code);};
function savePrivate(filename,value,check){
  check();
  const dir=path.dirname(filename);if((lstatSync(dir).mode&0o777)!==0o700||lstatSync(dir).isSymbolicLink())bad('OWNER_BINDINGS_DIRECTORY');
  const data=Buffer.from(JSON.stringify(value));if(data.length>1024*1024)bad('OWNER_BINDINGS_LIMIT');
  const temp=filename+'.'+randomUUID()+'.tmp';check();const fd=openSync(temp,FC.O_CREAT|FC.O_EXCL|FC.O_WRONLY|FC.O_NOFOLLOW,0o600);
  try{let offset=0;while(offset<data.length){check();offset+=writeSync(fd,data,offset,data.length-offset);}check();fsyncSync(fd);}finally{closeSync(fd);}
  check();renameSync(temp,filename);check();const d=openSync(dir,FC.O_RDONLY);try{check();fsyncSync(d);}finally{closeSync(d);}
}
async function serializedKey(key,check){check();const privateKey=await exportJWK(key.privateKey);check();return {private:privateKey,public:key.jwk};}
async function generatedKey(check){check();const key=await keyPair();check();const saved=await serializedKey(key,check);check();return saved;}
export async function restoreKey(saved,check=()=>{}){
  check();if(['kty','crv','x','y'].some(k=>saved.private?.[k]!==saved.public?.[k]))bad('OWNER_KEYPAIR_IDENTITY');const publicValue=normalizePublicJwk(saved.public);
  const privateKey=await importJWK(saved.private,'ES256',{extractable:true});check();const publicKey=await importJWK(publicValue.jwk,'ES256');check();return {...publicValue,privateKey,publicKey};
}
export async function persistentBindings(owner){
  const {check}=owner.captureAdmission('setup');
  await owner.gate.require('create-owned-root');check();const file=owner.plan.artifactRoot+'/fixture-bindings.json';let state;
  try{const s=await fs.lstat(file);check();if(!s.isFile()||s.isSymbolicLink()||(s.mode&0o777)!==0o600||s.uid!==owner.plan.uid)bad('OWNER_BINDINGS_MODE');const raw=await fs.readFile(file,'utf8');check();state=JSON.parse(raw);}
  catch(e){if(e.code!=='ENOENT')throw e;check();state={version:1,runId:owner.plan.runId,server:await generatedKey(check),installation:await generatedKey(check),adminSubject:randomUUID(),ownership:[],families:{}};check();savePrivate(file,state,check);}
  check();
  if(state.version!==1||state.runId!==owner.plan.runId||!Array.isArray(state.ownership)||!state.families)bad('OWNER_BINDINGS_IDENTITY');
  const owners=new Map(state.ownership),capabilities=new WeakMap(),adminCapability=Object.freeze({});capabilities.set(adminCapability,state.adminSubject);
  const ownership={async verify({installationId,request,recipientFingerprint,signal}){
    if(signal?.aborted)reject('DEADLINE_EXCEEDED');const v=owners.get(request);
    if(!v||v.installationId!==installationId||v.recipientFingerprint!==recipientFingerprint)reject('OWNERSHIP_REQUIRED');
    return {installationId,profileKind:'normal',subject:v.subject};
  }};
  // Exactly one fixtureBindings call; replace generated private identities before
  // any handles/app/harness exist, and preserve the same config.trust object.
  let bindings;try{
  bindings=await fixtureBindings({clock:mutableClock(Math.floor(Date.now()/1000),true),ownership});check();
  const server=await restoreKey(state.server,check);check();const installation=await restoreKey(state.installation,check);check();
  bindings.serverKey=server;bindings.installationKey=installation;bindings.adminCapability=adminCapability;
  bindings.config.trust.publicKey=server.publicKey;
  bindings.config.signer={keyId:bindings.config.trust.keyId,algorithm:'ES256',async sign(claims,{signal}={}){
    if(signal?.aborted)reject('DEADLINE_EXCEEDED');return new CompactSign(Buffer.from(canonical(claims))).setProtectedHeader({alg:'ES256',kid:bindings.config.trust.keyId,typ:'aegis-provider+jws'}).sign(server.privateKey);
  }};
  bindings.config.administration={async verify(capability,{signal}={}){if(signal?.aborted)reject('DEADLINE_EXCEEDED');const subject=capabilities.get(capability);if(!subject)reject('UNAUTHORIZED');return {subject};}};
  bindings.grantOwnership=(installationId,key,subject=randomUUID())=>{
    const {check}=owner.captureAdmission();
    const request='fixture-owner-'+randomUUID(),value={installationId,recipientFingerprint:key.fingerprint,subject};
    const next=[...state.ownership,[request,value]];savePrivate(file,{...state,ownership:next},check);check();state.ownership=next;owners.set(request,value);return request;
  };
  bindings.family=async name=>{
    const {check}=owner.captureAdmission();
    if(typeof name!=='string'||name.length>256)bad('OWNER_FAMILY_NAME');const id=digest(name);
    if(!state.families[id]){const saved=await generatedKey(check);check();savePrivate(file,{...state,families:{...state.families,[id]:saved}},check);check();state.families[id]=saved;}
    const family=await restoreKey(state.families[id],check);check();return family;
  };
  check();owner.setBindingsFingerprint(digest(canonical(state.server.public)));return bindings;
  }catch(error){await bindings?.store.close();throw error;}
}
// Hooks observe actual harness resources. They never replace a public method
// or add admission branding to another object.
export function createResourceLifecycle(owner){
  const records=new Map(),contexts=new AsyncLocalStorage();
  const check=()=>{if(contexts.getStore()?.closed||owner.signal.aborted)bad('OWNER_CASE_SCOPE_ENDED');};
  const hooks=Object.freeze({check,reserve:(kind,count)=>{check();return owner.budget.reserve(kind,count);},
    track:(kind,value,close)=>{records.set(value,{kind,close});},settled:value=>records.delete(value)});
  const closeCase=async({deadline=performance.now()+2000}={})=>{
    const results=await settleClosures([...records.values()].map(({kind,close},i)=>({name:kind+'-'+i,close})),Math.min(deadline,performance.now()+2000));
    const failures=results.filter(r=>r.status!=='CLOSED');if(failures.length)throw Object.assign(new OwnerError('OWNER_CASE_CLEANUP_INCOMPLETE'),{failures});return results;
  };
  return {hooks,closeCase,runCase:callback=>{const token={closed:false};return contexts.run(token,async()=>{try{return await callback();}finally{token.closed=true;}});},
    state:()=>({stores:[...records.values()].filter(r=>r.kind==='store').length,workers:[...records.values()].filter(r=>r.kind==='worker').length,held:[...records.values()].filter(r=>r.kind==='held').length,pools:[...records.values()].filter(r=>r.kind==='pool').length,budget:owner.budget.state})};
}
export function budgetHarness(harness,owner){
  assertAdmitted(harness);const resources=createResourceLifecycle(owner);harness.bindResources(resources.hooks);return {harness,...resources};
}
export async function finishRuntime(runtime,{deadline=performance.now()+CAPS.cleanupMs}={}){
  const {owner,harness,resources}=runtime,failures=[];let cleanup;
  const local=async(name,close)=>{
    const end=Math.min(deadline,performance.now()+2000);
    const [result]=await settleClosures([{name,close:()=>close(end)}],end);
    if(result.status!=='CLOSED')failures.push(result);
  };
  // Let per-resource results settle before the enclosing safety deadline so a
  // stalled handle cannot erase already observed failures from other handles.
  try{if(resources)await local('resources',end=>resources.closeCase({deadline:end-10}));}
  finally{
    try{if(harness)await local('harness',()=>harness.close());}
    finally{
      try{cleanup=await ownedRace(()=>owner.cleanup({deadline}),{deadline});}
      catch(error){cleanup={status:'CLEANUP_INCOMPLETE_RETAINED',code:error instanceof OwnerError?error.code:'OWNER_TEARDOWN_FAILED'};}
    }
  }
  if(failures.length||cleanup?.status!=='STOPPED_RETAINED')throw Object.assign(new OwnerError('OWNER_CLEANUP_INCOMPLETE'),{cleanup,failures});return cleanup;
}
export async function prepareRuntime({owner}){
  await owner.preflight();await owner.provision();const bindings=await persistentBindings(owner);
  const harness=await admitPostgres({owner:owner.owner,verifyOwner:owner.verifyOwner.bind(owner),connections:owner.connections(),trust:bindings.config.trust,lifecycle:{restartDatabase:owner.restartDatabase.bind(owner)}});
  const resources=budgetHarness(harness,owner);
  return {owner,harness,bindings,resources};
}
export function integrationStages(runtime){
  const {owner,harness,bindings,resources}=runtime;
  return {signal:owner.signal,resources,owner,
    async initialize(){await owner.gate.require('start-sql-slice');owner.beginSql();await harness.initializeFresh();await owner.gate.require('run-clock-smoke');return clockSmoke(runtime);},
    async beginCase(name){
      bindings.installationKey=await bindings.family(name);
      const D=[harness.trust.issuer,harness.trust.realm,harness.trust.serviceEnvironment];
      const {rows:[row]}=await harness.query('SELECT highwater,pending_id FROM provider_b1.domain_clocks WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D);
      if(row.pending_id!==null)bad('OWNER_TERMINAL_FENCE');
      const high=Number(row.highwater);if(!Number.isSafeInteger(high))bad('OWNER_CLOCK_INTEGER');
      bindings.clock.now=Math.max(bindings.clock.now,high,Math.floor(Date.now()/1000));bindings.clock.uncertaintySeconds=0;
    },
    deadlock:()=>runDeadlock(runtime),issuanceAckLoss:()=>runIssuanceAckLoss(runtime),
    observationAckLoss:()=>runObservationAckLoss(runtime),markerAckLoss:()=>runMarkerAckLoss(runtime),
    finish:()=>finishRuntime(runtime),
  };
}
export async function runCli(argv=process.argv.slice(2)){
  const [phase,configPath,capabilityPath]=argv;if(!['plan','preflight','smoke','suite'].includes(phase)||!configPath)bad('OWNER_CLI_USAGE');
  const parsed=JSON.parse(await fs.readFile(configPath,'utf8'));const plan=createPlan(parsed);
  if(phase==='plan')return {status:'SOURCE_ONLY_PLAN_NO_RUNTIME_ADMISSION',plan,caps:CAPS,engine:'NOT_RUN'};
  if(!capabilityPath)bad('OWNER_RUNTIME_CAPABILITY_REQUIRED');const authorized=await capabilityAuthorizer(capabilityPath,plan);
  const owner=new OwnerSupervisor({plan,...authorized});let runtime;
  // Parent process owns the suite watchdog; no inherited service timer.
  const cancel=()=>owner.cancel();process.once('SIGINT',cancel);process.once('SIGTERM',cancel);
  try{
    if(phase==='preflight')return await owner.preflight();runtime=await prepareRuntime({owner});const stages=integrationStages(runtime);
    if(phase==='smoke'){await runtime.resources.runCase(()=>stages.initialize());return {status:'MIGRATION_LOCK_CLOCK_SMOKE_COMPLETED',cleanup:await stages.finish()};}
    await owner.gate.require('run-suite');registerPostgresTests({...runtime,stages});
    // node:test owns serial execution and suite-final teardown registered below.
    return {status:'GENUINE_TESTS_REGISTERED_NOT_PASSED'};
  }catch(e){let teardown;try{teardown=await finishRuntime(runtime??{owner});}catch(error){teardown={cleanup:error.cleanup,failures:error.failures??[]};}throw Object.assign(new OwnerError(e instanceof OwnerError?e.code:'OWNER_PHASE_FAILED'),{cleanup:teardown});}
  finally{if(phase!=='suite'){process.removeListener('SIGINT',cancel);process.removeListener('SIGTERM',cancel);}}
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url){
  runCli().then(result=>process.stdout.write(JSON.stringify(result)+'\n'),e=>{
    process.stderr.write(JSON.stringify({code:e instanceof OwnerError?e.code:'OWNER_CLI_FAILED',cleanup:e.cleanup??null,engine:'NO_SUCCESS_CLAIM'})+'\n');process.exitCode=1;
  });
}
