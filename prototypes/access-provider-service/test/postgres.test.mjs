// SOURCE ONLY: nothing is registered or skipped on import. A future admitted
// owner imports registerPostgresTests and supplies the exact isolated harness.
import nodeTest from 'node:test';
import assert from 'node:assert/strict';
import { pathToFileURL } from 'node:url';
import { assertAdmitted } from './pg-harness.mjs';
import { launch,keyPair,register,registerArgs,prepared,issue,profileArgs,request,challenge } from './fixtures.mjs';
import { performance } from 'node:perf_hooks';
import { randomUUID } from 'node:crypto';
import { reject } from '../proof.mjs';
import { OwnerError,ownedRace,settleClosures } from './owner/owner.mjs';

export function registerPostgresTests({harness,bindings,stages}) {
  assertAdmitted(harness);
  if(bindings.config.trust!==harness.trust||bindings.clock.live!==true||!stages?.owner||typeof stages.initialize!=='function'||typeof stages.resources?.closeCase!=='function'||typeof bindings.family!=='function')reject('SQL_NOT_ADMITTED');
  const D=[harness.trust.issuer,harness.trust.realm,harness.trust.serviceEnvironment];
  const apps=new Set(),accounting=[];let ready=false,failed=false,caseController;
  const caseSignal=()=>caseController?.signal??stages.signal;
  function test(name,body,{initial=false,final=false,terminal=false}={}) {
    const record={name,status:'REGISTERED_NOT_RUN'};accounting.push(record);
    nodeTest(name,{concurrency:false,timeout:120000,signal:final?undefined:stages.signal},async t=>{
      caseController=new AbortController();const abort=()=>caseController.abort();
      stages.signal.addEventListener('abort',abort,{once:true});t.signal.addEventListener('abort',abort,{once:true});
      if(stages.signal.aborted)abort();
      let caseFailure;
      try {
        if(!initial&&!final&&(!ready||failed)){record.status='NOT_RUN_DEPENDENCY_FAILED';throw new OwnerError('OWNER_PRIOR_GATE_FAILED');}
        if(!initial&&!final&&!terminal)await stages.beginCase(name);
        record.status='RUNNING';await stages.resources.runCase(()=>ownedRace(()=>body(t),{signal:final?undefined:caseSignal(),deadline:performance.now()+120000}));record.status='PASS';if(initial)ready=true;
      }catch(error){caseFailure={name:'case',status:'FAILED',code:/^[A-Z0-9_]{1,80}$/.test(error.code??'')?error.code:'OWNER_CASE_FAILED'};if(record.status!=='NOT_RUN_DEPENDENCY_FAILED')record.status='FAIL';failed=true;if(!final)stages.owner.cancel('OWNER_CASE_FAILED');throw error;}
      finally {
        caseController.abort();stages.signal.removeEventListener('abort',abort);t.signal.removeEventListener('abort',abort);
        const results=await settleClosures([...apps].map((f,i)=>({name:'app-'+i,close:()=>f.close()})),performance.now()+2000);apps.clear();
        const failures=results.filter(r=>r.status!=='CLOSED');
        try{await stages.resources.closeCase();}catch(error){failures.push(...(error.failures??[{name:'resources',status:'UNCERTAIN',code:error instanceof OwnerError?error.code:'OWNER_CLOSE_FAILED'}]));}
        if(failures.length){record.status='FAIL_CLEANUP';failed=true;}
        if(final){for(const entry of accounting)if(entry.status==='REGISTERED_NOT_RUN')entry.status='NOT_RUN_CANCELLED';await stages.owner.record('suite-accounting',{cases:accounting,registered:accounting.length,passed:accounting.filter(r=>r.status==='PASS').length,notRun:accounting.filter(r=>r.status.startsWith('NOT_RUN')).length,zeroTestsSuccess:false});}
        if(failures.length)throw Object.assign(new OwnerError('OWNER_APP_CLEANUP_INCOMPLETE'),{failures,...(caseFailure?{caseFailure}:{})});
      }
    });
  }
  async function app(overrides={}) {
    const db=overrides.db??harness.newStore();let f;
    try{f=await ownedRace(()=>launch({...bindings,config:{...bindings.config,...overrides,db}}),{signal:caseSignal(),deadline:performance.now()+2000,onLate:x=>x.close()});}
    catch(error){await db.close();throw error;}
    assert.equal(f.app.storeKind,'postgresql');apps.add(f);return f;
  }
  async function counts() {
    const result={};for(const table of ['installations','pools','profiles','credentials','operations','challenges'])
      result[table]=(await harness.query('SELECT count(*)::int AS n FROM provider_b1.'+table+' WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D)).rows[0].n;
    return result;
  }
  test('GENUINE PG: owned fresh migration, least privilege, row locks and restart clock smoke',async()=>{await stages.initialize();},{initial:true});
  test('GENUINE PG: separate pools wait on live lifecycle ownership and release session advisory locks',async()=>{
    const a=harness.newStore(),b=harness.newStore();let entered,release;
    const ready=new Promise(resolve=>{entered=resolve;}),gate=new Promise(resolve=>{release=resolve;});
    const context=()=>({trust:harness.trust,deadline:performance.now()+4000,signal:caseSignal()});
    try {
      const one=a.observeTime(context(),async()=>{entered();await gate;return bindings.clock.observe();});await ready;
      const two=b.observeTime(context(),()=>bindings.clock.observe());
      const locks=(await harness.query("SELECT count(*)::int AS n FROM pg_locks WHERE locktype='advisory' AND classid=1110520113::oid AND objsubid=2 AND granted")).rows[0].n;
      assert.equal(locks,1);await new Promise(resolve=>setTimeout(resolve,30));release();
      const intervals=await Promise.all([one,two]);assert.ok(intervals[1].latest>=intervals[0].latest);
      assert.equal((await harness.query("SELECT count(*)::int AS n FROM pg_locks WHERE locktype='advisory' AND classid=1110520113::oid AND objsubid=2 AND granted")).rows[0].n,0);
    }finally{release?.();await a.close();await b.close();}
  });
  test('GENUINE PG: final DB-only expiry crosses a second with same-client keepalives within all session limits',async()=>{
    let armed=false,postAdmission=false,expectedExpiry,observedFloor,oracle;
    const db=harness.newStore({afterCommit:async()=>{if(armed){armed=false;postAdmission=true;
      expectedExpiry=Number((await harness.query("SELECT result_deadline FROM provider_b1.operations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND idem_key='pg-db-only-expiry'",D)).rows[0].result_deadline);
      observedFloor=Number((await harness.query('SELECT highwater FROM provider_b1.domain_clocks WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D)).rows[0].highwater);
    }}},async(client,sql,values)=>{
      if(postAdmission&&sql.startsWith('SELECT installation_id FROM provider_b1.credentials')) {
        postAdmission=false;
        const probe=async()=>{const row=(await client.query("SELECT extract(epoch from clock_timestamp())::double precision AS now,current_setting('lock_timeout') AS lock_timeout,current_setting('statement_timeout') AS statement_timeout,current_setting('idle_in_transaction_session_timeout') AS idle_timeout")).rows[0];
          assert.equal(row.lock_timeout,'250ms');assert.equal(row.statement_timeout,'1s');assert.equal(row.idle_timeout,'1s');return row.now;};
        let before=await probe();const started=performance.now();
        while(before<expectedExpiry-.15) {
          assert.ok(performance.now()-started<2000,'boundary setup missed within bounded oracle');
          await new Promise(resolve=>setTimeout(resolve,50));before=await probe();
        }
        assert.ok(before<expectedExpiry,'DB boundary already passed before the host gap');
        const gap=Math.ceil((expectedExpiry-before)*1000)+20;assert.ok(gap>0&&gap<=200);
        await new Promise(resolve=>setTimeout(resolve,gap));const after=await probe();
        assert.ok(after>=expectedExpiry,'DB clock did not cross expiry');oracle={before,after,gap,expectedExpiry,observedFloor};
      }
      return client.query(sql,values);
    });
    const f=await app({limits:{...bindings.config.limits,installationSeconds:1},db});f.installationKey=await keyPair();
    // Align outside a request/transaction; no session timeout is lengthened.
    const minimumFloor=Number((await harness.query('SELECT highwater FROM provider_b1.domain_clocks WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D)).rows[0].highwater);
    let now,alignStart=performance.now();
    do {now=(await harness.query('SELECT extract(epoch from clock_timestamp())::double precision AS now')).rows[0].now;
      if(Math.floor(now)>=minimumFloor&&now-Math.floor(now)<=.06)break;assert.ok(performance.now()-alignStart<1500);await new Promise(resolve=>setTimeout(resolve,20));
    }while(true);
    const fixed=Math.floor(now),observe=bindings.clock.observe;bindings.clock.now=fixed;
    bindings.clock.observe=()=>({now:fixed,uncertaintySeconds:0});
    try {
      const p=await prepared(f,'register',registerArgs(f),'pg-db-only-expiry');assert.equal(p.challenge.status,200,JSON.stringify(p.challenge.json));
      armed=true;const start=performance.now(),result=await issue(f,p);assert.equal(result.json.code,'EXPIRED');
      assert.ok(performance.now()-start<5000);assert.equal(expectedExpiry,fixed+1);assert.equal(observedFloor,fixed);assert.ok(oracle);
    }finally{bindings.clock.observe=observe;bindings.clock.now=Math.max(bindings.clock.now,Math.floor(Date.now()/1000)+1);await f.close();apps.delete(f);}
    // Real DB time + measured host gap <=200ms, not a server lock-wait claim.
  });
  test('GENUINE PG: independent app pools concurrently register one installation/pool; restart and lost-response retry recover exact bytes',async()=>{
    const a=await app(),b=await app();const before=await counts();
    const pa=await prepared(a,'register',registerArgs(a),'pg-concurrent-a');const pb=await prepared(b,'register',registerArgs(b),'pg-concurrent-b');
    const [ra,rb]=await Promise.all([issue(a,pa),issue(b,pb)]);
    assert.equal(ra.status,201,JSON.stringify(ra.json));assert.equal(rb.status,201,JSON.stringify(rb.json));assert.deepEqual(ra.body,rb.body);
    const after=await counts();assert.equal(after.installations-before.installations,1);assert.equal(after.pools-before.pools,1);assert.equal(after.credentials-before.credentials,1);
    await a.close();await b.close();apps.delete(a);apps.delete(b);await harness.restartDatabase('clean');
    const restarted=await app();assert.deepEqual((await register(restarted,'pg-concurrent-a')).body,ra.body);
    assert.deepEqual((await issue(restarted,await prepared(restarted,'register',registerArgs(restarted),'pg-lost-response'))).body,ra.body);
  });
  test('GENUINE PG: independent Profile credentials share one pool; composite FKs refuse foreign domain and pool',async()=>{
    const f=await app(),root=await register(f,'pg-profile-root'),ka=await keyPair(),kb=await keyPair();
    const aa=profileArgs(f,root,ka,'pg-profile-a'),bb=profileArgs(f,root,kb,'pg-profile-b');
    const a=await issue(f,await prepared(f,'profile-issue',aa,'pg-profile-a',root,ka));
    const b=await issue(f,await prepared(f,'profile-issue',bb,'pg-profile-b',root,kb));
    assert.equal(a.status,201,JSON.stringify(a.json));assert.equal(b.status,201,JSON.stringify(b.json));
    assert.notEqual(a.json.credential,b.json.credential);assert.notEqual(a.json.claims.principalId,b.json.claims.principalId);
    assert.equal(a.json.claims.entitlementAccountId,b.json.claims.entitlementAccountId);
    await assert.rejects(harness.query("INSERT INTO provider_b1.pools (issuer,realm,service_environment,id,installation_id,kind) VALUES ($1,$2,$3,$4,$5,'installation_guest')",[D[0],'foreign',D[2],randomUUID(),root.json.claims.installationRef]));
    await assert.rejects(harness.query("INSERT INTO provider_b1.profiles (issuer,realm,service_environment,id,installation_id,pool_id,ownership_hash,profile_binding,key_id,key_hash,public_jwk) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11)",[...D,randomUUID(),root.json.claims.installationRef,randomUUID(),Buffer.alloc(32),randomUUID(),ka.keyId,Buffer.alloc(32,1),ka.jwk]));
  });
  test('GENUINE PG: process kill before and after COMMIT proves atomic allocation/nonce and byte-identical recovery after DB crash restart',async()=>{
    for(const phase of ['before-commit','after-commit']) {
      const key=await keyPair();const f=await app();f.installationKey=key;
      const idem='pg-crash-'+phase,p=await prepared(f,'register',registerArgs(f),idem),before=await counts();
      // Worker replaces the prepared application's pool; its original origin
      // remains a proof binding, not a live listener in the worker.
      await f.close();apps.delete(f);
      const child=await harness.issuanceWorker(f,p);await child.event('before-commit');
      if(phase==='after-commit'){child.continue();await child.event('after-commit');}
      await child.kill();await harness.restartDatabase('crash');
      const op=(await harness.query('SELECT body FROM provider_b1.operations WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND idem_key=$4',[...D,idem])).rows;
      const ch=(await harness.query('SELECT consumed_operation_id FROM provider_b1.challenges WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4',[...D,p.data.challengeId])).rows[0];
      const after=await counts();
      if(phase==='before-commit'){assert.equal(op.length,0);assert.equal(ch.consumed_operation_id,null);assert.equal(after.credentials,before.credentials);assert.equal(after.installations,before.installations);}
      else {assert.equal(op.length,1);assert.notEqual(ch.consumed_operation_id,null);assert.equal(after.credentials,before.credentials+1);}
      const recoveredApp=await app();recoveredApp.installationKey=key;
      const fresh=await prepared(recoveredApp,'register',registerArgs(recoveredApp),idem);
      const recovered=await issue(recoveredApp,fresh);assert.equal(recovered.status,201,JSON.stringify(recovered.json));
      if(op.length)assert.deepEqual(recovered.body,op[0].body);
      assert.equal((await counts()).credentials,before.credentials+1);await recoveredApp.close();apps.delete(recoveredApp);
    }
  });
  test('GENUINE PG: concurrent exact retries recover persisted response; nonce substitution and expiration reject',async()=>{
    const f=await app(),p=await prepared(f,'register',registerArgs(f),'pg-retry');
    const [a,b]=await Promise.all([issue(f,p),issue(f,p)]);assert.equal(a.status,201);assert.equal(b.status,201);assert.deepEqual(a.body,b.body);
    assert.equal((await request(f,p.path,{...p.data,nonce:'A'.repeat(43)},p.headers)).json.code,'BINDING_MISMATCH');
    const old=bindings.clock.now;bindings.clock.now=p.challenge.json.expiresAt;
    assert.equal((await issue(f,p)).json.code,'EXPIRED');
    const fresh=await prepared(f,'register',registerArgs(f),'pg-retry');assert.deepEqual((await issue(f,fresh)).body,a.body);
    // Time remains monotonic for all subsequent real-DB tests.
    assert.ok(bindings.clock.now>=old);
  });
  test('GENUINE PG: revocation orders against issuance and replay; parent tombstone and receipt survive app restart',async()=>{
    const f=await app(),key=await keyPair(),root=await register(f,'pg-revoke-root');
    const args=profileArgs(f,root,key,'pg-revoked-profile'),p=await prepared(f,'profile-issue',args,'pg-revoke-p',root,key);
    assert.equal((await issue(f,p)).status,201);
    const input={installationId:root.json.claims.installationRef,capability:bindings.adminCapability};
    const receipt=await f.app.revokeInstallation(input);assert.equal((await issue(f,p)).json.code,'REVOKED');
    await f.close();apps.delete(f);const restarted=await app();
    assert.deepEqual((await restarted.app.revokeInstallation(input)).body,receipt.body);
    assert.equal((await register(restarted,'pg-replace-revoked')).json.code,'REVOKED');
    const replacement=await keyPair(),newApp=await app();newApp.installationKey=replacement;
    const root2=await register(newApp,'pg-revoke-before-root');const p2=await prepared(newApp,'profile-issue',profileArgs(newApp,root2,key,'pg-before-owner'),'pg-before',root2,key);
    await newApp.app.revokeInstallation({installationId:root2.json.claims.installationRef,capability:bindings.adminCapability});
    assert.equal((await issue(newApp,p2)).json.code,'REVOKED');
  });
  test('GENUINE PG: rejected parent observation survives business rollback and database/app restart',async()=>{
    const f=await app();f.installationKey=await keyPair();
    const root=await register(f,'pg-rejected-floor-root'),key=await keyPair(),args=profileArgs(f,root,key,'pg-rejected-clock-owner');
    const prior=bindings.clock.now;bindings.clock.now=root.json.claims.expiresAt;
    assert.equal((await challenge(f,'profile-issue',args,'pg-rejected-parent',root)).json.code,'EXPIRED');
    const high=(await harness.query('SELECT highwater,pending_id FROM provider_b1.domain_clocks WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D)).rows[0];
    assert.ok(Number(high.highwater)>=root.json.claims.expiresAt);assert.equal(high.pending_id,null);
    await f.close();apps.delete(f);await harness.restartDatabase('clean');bindings.clock.now=prior+1;
    const restarted=await app();restarted.installationKey=f.installationKey;
    assert.equal((await challenge(restarted,'profile-issue',args,'pg-floor-after-restart',root)).json.code,'CLOCK_UNTRUSTED');
    bindings.clock.now=Number(high.highwater)+1;
  });
  test('GENUINE PG: both concurrent revocation/issuance lock orders remain terminal',async()=>{
    for(const first of ['issue','revoke']) {
      let armed=false,entered,release;
      const barrier=new Promise(resolve=>{entered=resolve;});
      const gate=new Promise(resolve=>{release=resolve;});
      const db=harness.newStore({beforeCommit:async()=>{if(armed){armed=false;entered();await gate;}}});
      const f=await app({db});f.installationKey=await keyPair();
      const root=await register(f,'pg-race-root-'+first),key=await keyPair();
      const p=await prepared(f,'profile-issue',profileArgs(f,root,key,'pg-race-owner-'+first),'pg-race-'+first,root,key);
      const revoke=()=>f.app.revokeInstallation({installationId:root.json.claims.installationRef,capability:bindings.adminCapability});
      armed=true;
      const one=first==='issue'?issue(f,p):revoke();await barrier;
      const two=first==='issue'?revoke():issue(f,p);release();
      const [a,b]=await Promise.all([one,two]);const issued=first==='issue'?a:b,receipt=first==='issue'?b:a;
      assert.equal(receipt.status,200);
      if(first==='revoke')assert.equal(issued.json.code,'REVOKED');
      else assert.ok(issued.status===201||issued.json.code==='REVOKED');
      assert.equal((await issue(f,p)).json.code,'REVOKED');
      await f.close();apps.delete(f);
    }
  });
  test('GENUINE PG: expiry during a domain lock/sign/commit wait leaves no admitted expired credential or partial issuance',async()=>{
    const f=await app({limits:{...bindings.config.limits,installationSeconds:10}});f.installationKey=await keyPair();
    const root=await register(f,'pg-time-root'),key=await keyPair();
    const p=await prepared(f,'profile-issue',profileArgs(f,root,key,'pg-time-owner'),'pg-time-p',root,key);
    const held=await harness.holdDomain();let pending;
    try{pending=issue(f,p);await new Promise(resolve=>setTimeout(resolve,10));bindings.clock.now=root.json.claims.expiresAt;}
    finally{await held.release();}
    assert.equal((await pending).json.code,'EXPIRED');await f.close();apps.delete(f);
    const f2=await app({limits:{...bindings.config.limits,installationSeconds:10}});f2.installationKey=await keyPair();
    const root2=await register(f2,'pg-sign-root'),key2=await keyPair();
    const p2=await prepared(f2,'profile-issue',profileArgs(f2,root2,key2,'pg-sign-owner'),'pg-sign-p',root2,key2),before=await counts();
    const original=bindings.config.signer.sign;
    bindings.config.signer.sign=async claims=>{const signed=await original(claims);bindings.clock.now=root2.json.claims.expiresAt;return signed;};
    try{assert.equal((await issue(f2,p2)).json.code,'EXPIRED');}finally{bindings.config.signer.sign=original;}
    assert.equal((await counts()).credentials,before.credentials);assert.equal((await counts()).profiles,before.profiles);
    assert.equal((await harness.query('SELECT consumed_operation_id FROM provider_b1.challenges WHERE issuer=$1 AND realm=$2 AND service_environment=$3 AND id=$4',[...D,p2.data.challengeId])).rows[0].consumed_operation_id,null);
    await f2.close();apps.delete(f2);
    let armed=false;
    const f3=await app({db:harness.newStore({beforeCommit:()=>{if(armed){armed=false;bindings.clock.now+=600;}}})});f3.installationKey=await keyPair();
    const p3=await prepared(f3,'register',registerArgs(f3),'pg-commit-expiry');armed=true;
    assert.equal((await issue(f3,p3)).json.code,'EXPIRED');
    // COMMIT may have persisted an expired result, but post-commit admission
    // rejects it and every fresh-challenge retry checks its original deadline.
    assert.equal((await register(f3,'pg-commit-expiry')).json.code,'EXPIRED');
  });
  test('GENUINE PG: real concurrent SERIALIZABLE aborts exhaust at most three transaction attempts with one reserved pair',async()=>{
    const context={trust:harness.trust,deadline:performance.now()+5000,signal:caseSignal()};
    const result=await harness.exhaustSerialization({context,maximumAttempts:3});
    assert.equal(result.attempts,3);assert.deepEqual(result.sqlStates,['40001','40001','40001']);
  });
  test('GENUINE PG: b1_app can lock all business authority tables while immutable mutations and clock DML remain forbidden',async()=>{
    for(const table of ['domains','installations','pools','profiles','credentials','challenges','operations']) {
      await harness.query('SELECT * FROM provider_b1.'+table+' WHERE issuer=$1 AND realm=$2 AND service_environment=$3 FOR UPDATE',D);
    }
    for(const table of ['installations','pools','profiles','operations']) {
      const privilege=(await harness.query("SELECT has_column_privilege(current_user,$1,'id','UPDATE') AS lock_grant,has_table_privilege(current_user,$1,'UPDATE') AS broad_grant",['provider_b1.'+table])).rows[0];
      assert.equal(privilege.lock_grant,true);assert.equal(privilege.broad_grant,false);
      // Existing preceding cases have populated every table; changed IDs must reject.
      await assert.rejects(harness.query('UPDATE provider_b1.'+table+' SET id=$4 WHERE issuer=$1 AND realm=$2 AND service_environment=$3',[...D,randomUUID()]));
    }
    await assert.rejects(harness.query('UPDATE provider_b1.domain_clocks SET highwater=highwater WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D),e=>e.code==='42501');
    await assert.rejects(harness.query('UPDATE provider_b1.domains SET time_highwater=time_highwater+1 WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D),e=>e.code==='42501');
    const functions=(await harness.query("SELECT p.proname,p.prosecdef,p.proconfig,r.rolname FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_roles r ON r.oid=p.proowner WHERE n.nspname='provider_b1' AND p.proname IN ('clock_begin','clock_finish','seed_clock','clock_try_lock','clock_unlock','clock_key','clock_owned','clock_assert_owned')")).rows;
    assert.equal(functions.length,8);for(const f of functions){assert.equal(f.prosecdef,true);assert.equal(f.rolname,'b1_migrator');assert.deepEqual(f.proconfig,['search_path=pg_catalog']);}
  });
  test('GENUINE PG: independent clock commits progress while the business domain lock is held',async()=>{
    const store=harness.newStore(),held=await harness.holdDomain();
    try {
      const interval=await store.observeTime({trust:harness.trust,deadline:performance.now()+3000,signal:caseSignal()},()=>bindings.clock.observe());
      assert.ok(interval.latest>=bindings.clock.now-1);
    } finally {await held.release();await store.close();}
    assert.equal((await harness.query('SELECT pending_id FROM provider_b1.domain_clocks WHERE issuer=$1 AND realm=$2 AND service_environment=$3',D)).rows[0].pending_id,null);
  });
  test('GENUINE PG: checked-out idle timeout during cooperative adapter wait is contained and discards without late SQL',async()=>{
    let entered,release;const ready=new Promise(resolve=>{entered=resolve;}),gate=new Promise(resolve=>{release=resolve;});
    const store=harness.newStore(),c={trust:harness.trust,deadline:performance.now()+4000,signal:caseSignal()};
    const result=store.transaction(c,async tx=>{entered();await gate;await tx.capacity('installations',128);});
    const failure=assert.rejects(result,e=>e.code==='DB_UNAVAILABLE');await ready;await failure;release();await store.close();
  });
  test('GENUINE PG: idle Pool backend termination is contained and subsequent borrowing recovers',async()=>{
    let pid;
    const store=harness.newStore({},async(client,sql,values)=>{
      if(!pid&&sql==='BEGIN ISOLATION LEVEL SERIALIZABLE')pid=(await client.query('SELECT pg_backend_pid() AS pid')).rows[0].pid;
      return client.query(sql,values);
    });
    const context=()=>({trust:harness.trust,deadline:performance.now()+4000,signal:caseSignal()});
    await store.transaction(context(),async()=>{});
    assert.equal((await harness.query('SELECT pg_terminate_backend($1) AS terminated',[pid])).rows[0].terminated,true);
    await new Promise(resolve=>setTimeout(resolve,50));
    await store.transaction(context(),async()=>{});await store.close();
  });
  test('GENUINE PG: real backend 40P01 on A, measured barrier/victim and bounded retry counts',async()=>{await stages.deadlock();});
  test('GENUINE PG: wire-observed issuance COMMIT ACK loss and fresh-challenge byte recovery after crash',async()=>{await stages.issuanceAckLoss();});
  test('GENUINE PG: wire-observed clock observation COMMIT ACK loss retains floor across restart',async()=>{await stages.observationAckLoss();});
  test('GENUINE PG: terminal wire-observed marker COMMIT ACK loss retains unresolved fence without sampling',async()=>{await stages.markerAckLoss();},{terminal:true});
  test('GENUINE PG: close all owned apps/pools/workers (external owner retains container/data receipt)',async()=>{
    await stages.finish();
  },{final:true});
  return {registeredCases:accounting,engine:'REGISTERED_NOT_PASSED'};
}
if(process.argv[1]&&pathToFileURL(process.argv[1]).href===import.meta.url)reject('SQL_NOT_ADMITTED');
