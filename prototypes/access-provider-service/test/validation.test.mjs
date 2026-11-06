import test from 'node:test';
import assert from 'node:assert/strict';
import { performance } from 'node:perf_hooks';
import { EventEmitter } from 'node:events';
import { spawn } from 'node:child_process';
import { DatabaseError } from 'pg';
import { randomUUID } from 'node:crypto';
import { createConnection } from 'node:net';
import { CompactSign,base64url } from 'jose';
import { createApp } from '../app.mjs';
import { start } from '../start.mjs';
import { PostgresStore, createOwnedPool } from '../store.mjs';
import { migrate } from '../migrate.mjs';
import { admitPostgres } from './pg-harness.mjs';
import { parseRequest, canonical, publicFailure, validatePublicJwk, ProviderError } from '../proof.mjs';
import { fixture,fixtureBindings,keyPair,request,prepared,issue,register,registerArgs,
  profileArgs,signProof,challenge,SyntheticStore,launch,deferred } from './fixtures.mjs';

const errorCode = code => error => error instanceof ProviderError && error.code===code;
async function owned(t,options) {const f=await fixture(options);t.after(()=>f.close());return f;}
function rejected(result,code) {
  assert.equal(result.json?.code,code,JSON.stringify(result.json));
  assert.deepEqual(Object.keys(result.json).sort(),['code','message','retryable']);
  assert.equal(result.json.message,'Provider request rejected.'); assert.equal(result.json.retryable,false);
}
test('imports construct nothing; production and missing adapters fail closed',async()=>{
  assert.throws(()=>createApp({}),errorCode('PRODUCTION_BINDINGS_UNAVAILABLE'));
  const b=await fixtureBindings();
  for(const field of ['db','trust','signer','clock','ownership','administration','limits']) {
    const c={...b.config};delete c[field];assert.throws(()=>createApp(c));
  }
  assert.throws(()=>createApp({...b.config,mode:'production',productionBindingsVerified:true}),errorCode('PRODUCTION_BINDINGS_UNAVAILABLE'));
  for(const limits of [{...b.config.limits,concurrentRequests:9},{...b.config.limits,requestMilliseconds:5001},{}])
    assert.throws(()=>createApp({...b.config,limits}));
  await b.store.close();
});
test('start requires branded app, numeric loopback and explicit port; owned close is repeatable',async()=>{
  const b=await fixtureBindings(),app=createApp(b.config);
  for(const input of [{app,host:'localhost',port:0},{app,host:'0.0.0.0',port:0},
    {app,host:'127.0.0.1'},{app,host:'127.0.0.1',port:-1},{app:{},host:'127.0.0.1',port:0}])
    await assert.rejects(start(input),errorCode('BINDING_REQUIRED'));
  const server=await start({app,host:'127.0.0.1',port:0});
  assert.match(server.origin,/^http:\/\/127\.0\.0\.1:[1-9][0-9]*$/);
  assert.equal(app.mode,'SYNTHETIC_FIXTURE_ONLY');assert.equal(app.storeKind,'synthetic-test-double');
  await assert.rejects(start({app,host:'127.0.0.1',port:0}),errorCode('BINDING_REQUIRED'));
  assert.equal((await challenge({...b,origin:server.origin},'register',registerArgs(b),'still-open')).status,200);
  await server.close();await server.close();assert.equal(b.store.closed,true);
});
for(const [name,input,code] of [
  ['decoded duplicate','{"version":1,"\\u0076ersion":1}','DUPLICATE_FIELD'],
  ['unknown member','{"version":1,"operation":"register","idempotencyKey":"a","arguments":{},"verified":true}','UNKNOWN_FIELD'],
  ['unsupported version','{"version":2,"operation":"register","idempotencyKey":"a","arguments":{}}','UNSUPPORTED_VERSION'],
  ['malformed utf8',Buffer.from([0xc3,0x28]),'INVALID_JSON'],
  ['depth bound','['.repeat(14)+'0'+']'.repeat(14),'INPUT_TOO_LARGE'],
  ['body bound',' '.repeat(65537),'INPUT_TOO_LARGE'],
]) test('strict request parser: '+name,()=>assert.throws(()=>parseRequest(input,true),errorCode(code)));
test('public JWK validation rejects private/extra members, wrong curve, noncanonical and invalid points',async()=>{
  const key=await keyPair();
  for(const jwk of [{...key.jwk,d:'private'},{...key.jwk,use:'sig'},{...key.jwk,crv:'P-384'},
    {...key.jwk,x:key.jwk.x+'='},{...key.jwk,x:'A'.repeat(43),y:'A'.repeat(43)}]) await assert.rejects(validatePublicJwk(jwk));
});
test('HTTP enforces exact paths, auth syntax, input/header bounds and explicit idempotency context',async t=>{
  const f=await owned(t),args=registerArgs(f),data={version:1,operation:'register',idempotencyKey:'a',arguments:args};
  rejected(await request(f,'/bootstrap/challenge?x=1',data),'NOT_AVAILABLE');
  rejected(await request(f,'/endpoint-leases',data),'NOT_AVAILABLE');
  rejected(await request(f,'/revoke-installation',data),'NOT_AVAILABLE');
  rejected(await request(f,'/bootstrap/challenge',data,{'idempotency-key':'b'}),'BINDING_MISMATCH');
  rejected(await request(f,'/bootstrap/challenge',data,{authorization:'Basic payload'}),'UNAUTHORIZED');
  rejected(await request(f,'/bootstrap/challenge',data,{'content-type':'text/plain'}),'INVALID_INPUT');
  rejected(await request(f,'/bootstrap/challenge',' '.repeat(65537)),'INPUT_TOO_LARGE');
  rejected(await request(f,'/bootstrap/challenge',data,{'x-aegis-pop':['one','two']}),'INVALID_INPUT');
  rejected(await request(f,'/bootstrap/challenge',data,{'idempotency-key':['a','a']}),'INVALID_INPUT');
  rejected(await request(f,'/bootstrap/challenge',data,{authorization:['Bearer a.b.c','Bearer a.b.c']}),'INVALID_INPUT');
});
test('actual signatures authorize one installation/pool and byte-identical idempotent results',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'first');
  const first=await issue(f,p);assert.equal(first.status,201,JSON.stringify(first.json));
  const again=await issue(f,p);assert.equal(again.status,201);assert.deepEqual(again.body,first.body);assert.deepEqual(again.headers,first.headers);
  assert.equal(first.headers.date,undefined);
  const secondKey=await register(f,'other-key');assert.deepEqual(secondKey.body,first.body);
  assert.equal(f.store.state.installations.length,1);assert.equal(f.store.state.pools.length,1);assert.equal(f.store.state.credentials.length,1);
  assert.equal(first.json.mode,'SYNTHETIC_FIXTURE_ONLY');assert.equal(first.json.claims.kind,'installation-credential');
  assert.deepEqual(first.json.claims.scope,['profile:issue']);
});
const substitutions={version:2,method:'GET',target:'http://127.0.0.1:1/bootstrap/register',operation:'profile-issue',
  issuer:'foreign',audience:'foreign',realm:'foreign',serviceEnvironment:'foreign',role:'recipient',
  keyFingerprint:'foreign',recipientFingerprint:'foreign',parentId:'foreign',parentRevision:2,
  challengeId:'foreign',nonce:'A'.repeat(43),requestDigest:'foreign',actor:'foreign',idempotencyKey:'foreign'};
test('PoP context substitution matrix uses valid cryptographic signatures',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'pop-matrix');
  for(const [field,value] of Object.entries(substitutions)) await t.test(field,async()=>{
    const proof=await signProof(f,p.challenge,f.installationKey,'installation',{[field]:value});
    rejected(await issue(f,{...p,headers:{'x-aegis-pop':proof}}),'BINDING_MISMATCH');
    assert.equal(f.store.state.credentials.length,0);
  });
});
test('PoP rejects wrong key, tamper, remote/embedded key, unknown alg, duplicate payload and deadline',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'negative-pop'),other=await keyPair();
  rejected(await issue(f,{...p,headers:{'x-aegis-pop':await signProof(f,p.challenge,other)}}),'PROOF_REJECTED');
  const parts=p.headers['x-aegis-pop'].split('.');parts[1]=Buffer.from('{}').toString('base64url');
  rejected(await issue(f,{...p,headers:{'x-aegis-pop':parts.join('.')}}),'PROOF_REJECTED');
  for(const patch of [{jku:'https://invalid.example/key'},{jwk:other.jwk},{alg:'HS256'},{kid:'foreign'}]) {
    if(patch.alg==='HS256') { const h=Buffer.from(canonical({alg:'HS256',kid:f.installationKey.keyId,typ:'aegis-b1-pop+jws'})).toString('base64url');
      rejected(await issue(f,{...p,headers:{'x-aegis-pop':h+'.'+p.headers['x-aegis-pop'].split('.').slice(1).join('.')}}),'PROOF_REJECTED');
    } else rejected(await issue(f,{...p,headers:{'x-aegis-pop':await signProof(f,p.challenge,f.installationKey,'installation',{},patch)}}),'PROOF_REJECTED');
  }
  rejected(await issue(f,{...p,headers:{'x-aegis-pop':await signProof(f,p.challenge,f.installationKey,'installation',{expiresAt:p.challenge.json.expiresAt+1})}}),'PROOF_REJECTED');
  rejected(await issue(f,{...p,headers:{'x-aegis-pop':await signProof(f,p.challenge,f.installationKey,'installation',{issuedAt:f.clock.now-2,notBefore:f.clock.now-2,expiresAt:f.clock.now})}}),'EXPIRED');
  const payload=Buffer.from(base64url.decode(p.headers['x-aegis-pop'].split('.')[1])).toString();
  const duplicate=await new CompactSign(Buffer.from(payload.slice(0,-1)+',"version":1}'))
    .setProtectedHeader({alg:'ES256',kid:f.installationKey.keyId,typ:'aegis-b1-pop+jws'}).sign(f.installationKey.privateKey);
  rejected(await issue(f,{...p,headers:{'x-aegis-pop':duplicate}}),'DUPLICATE_FIELD');
  rejected(await issue(f,{...p,headers:{'x-aegis-pop':await signProof(f,p.challenge,f.installationKey,'installation',{verified:true})}}),'UNKNOWN_FIELD');
});
test('challenge/idempotency/nonce substitution and expired challenge cannot issue; fresh challenge recovers exact committed bytes',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'retry');
  rejected(await issue(f,{...p,data:{...p.data,nonce:'A'.repeat(43)}}),'BINDING_MISMATCH');
  rejected(await issue(f,{...p,data:{...p.data,idempotencyKey:'other'}}),'BINDING_MISMATCH');
  const first=await issue(f,p);assert.equal(first.status,201);
  f.clock.now=p.challenge.json.expiresAt;
  rejected(await issue(f,p),'EXPIRED');
  const fresh=await prepared(f,'register',registerArgs(f),'retry');const recovered=await issue(f,fresh);
  assert.deepEqual(recovered.body,first.body);assert.equal(f.store.state.credentials.length,1);
  assert.equal(f.store.state.operations.length,1);assert.equal(f.store.state.challenges.filter(c=>c.consumed_operation_id).length,2);
});
test('same operation key with changed business arguments conflicts',async t=>{
  const f=await owned(t),root=await register(f),key=await keyPair();assert.equal(root.status,201);
  const a=profileArgs(f,root,key,'stable-owner');
  assert.equal((await issue(f,await prepared(f,'profile-issue',a,'profile-key',root,key))).status,201);
  const changed={...a,ownershipRequest:f.grantOwnership(root.json.claims.installationRef,key,'stable-owner')};
  rejected(await issue(f,await prepared(f,'profile-issue',changed,'profile-key',root,key)),'IDEMPOTENCY_CONFLICT');
  assert.equal(f.store.state.profiles.length,1);
});
test('two ordinary Profiles hold independent keys/principals and share exactly one pool',async t=>{
  const f=await owned(t),root=await register(f),a=await keyPair(),b=await keyPair();
  const aa=profileArgs(f,root,a,'owner-a'),bb=profileArgs(f,root,b,'owner-b');
  const pa=await issue(f,await prepared(f,'profile-issue',aa,'p-a',root,a));
  const pb=await issue(f,await prepared(f,'profile-issue',bb,'p-b',root,b));
  assert.equal(pa.status,201,JSON.stringify(pa.json));assert.equal(pb.status,201,JSON.stringify(pb.json));
  assert.notEqual(pa.json.credential,pb.json.credential);assert.notEqual(pa.json.claims.principalId,pb.json.claims.principalId);
  assert.notEqual(pa.json.claims.recipientKeyId,pb.json.claims.recipientKeyId);
  assert.equal(pa.json.claims.entitlementAccountId,pb.json.claims.entitlementAccountId);
  assert.equal(f.store.state.pools.length,1);assert.equal(f.store.state.profiles.length,2);
  const retry=await issue(f,await prepared(f,'profile-issue',aa,'p-a-2',root,a));assert.deepEqual(retry.body,pa.body);
  const rotated=profileArgs(f,root,b,'owner-a');
  rejected(await issue(f,await prepared(f,'profile-issue',rotated,'rotation',root,b)),'BINDING_MISMATCH');
});
test('ownership requests cannot invent ownership, reuse installation key or bypass second-key proof',async t=>{
  const f=await owned(t),root=await register(f),key=await keyPair();
  const a={profileKind:'normal',recipientJwk:key.jwk,ownershipRequest:'verified'};
  rejected(await issue(f,await prepared(f,'profile-issue',a,'spoof',root,key)),'OWNERSHIP_REQUIRED');
  rejected(await challenge(f,'profile-issue',{...a,verified:true},'bool',root),'UNKNOWN_FIELD');
  const same=profileArgs(f,root,f.installationKey,'same');
  rejected(await issue(f,await prepared(f,'profile-issue',same,'same',root,f.installationKey)),'BINDING_MISMATCH');
  const valid=await prepared(f,'profile-issue',profileArgs(f,root,key),'valid',root,key);
  rejected(await issue(f,{...valid,headers:{...valid.headers,'x-aegis-recipient-pop':valid.headers['x-aegis-pop']}}),'PROOF_REJECTED');
  const foreign=profileArgs(f,{json:{claims:{installationRef:'foreign-install'}}},key,'foreign');
  rejected(await issue(f,await prepared(f,'profile-issue',foreign,'foreign',root,key)),'OWNERSHIP_REQUIRED');
  assert.equal(f.store.state.profiles.length,0);
});
for(const [kind,code] of [['otr','PROFILE_UNAVAILABLE'],['guest','PROFILE_UNAVAILABLE'],['system','PROFILE_UNSUPPORTED']])
  test(kind+' Profile is explicitly unavailable',async t=>{
    const f=await owned(t),key=await keyPair();
    rejected(await challenge(f,'profile-issue',{profileKind:kind,recipientJwk:key.jwk,ownershipRequest:'fixture'},kind),code);
  });
test('adapter boolean cannot serve as native ownership evidence',async t=>{
  const f=await owned(t,{ownership:{async verify({installationId}){return {installationId,subject:'spoof',profileKind:'normal',verified:true};}}});
  const root=await register(f),key=await keyPair();
  rejected(await issue(f,await prepared(f,'profile-issue',profileArgs(f,root,key),'bad-adapter',root,key)),'OWNERSHIP_REQUIRED');
});
test('parent expiry/revision/content mismatch rejects cached results without reactivation',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'root'),root=await issue(f,p);
  f.store.state.credentials[0].revision=2;rejected(await issue(f,p),'STALE_AUTHORITY');
  f.store.state.credentials[0].revision=1;f.store.state.credentials[0].claims.scope=['lease:issue'];
  rejected(await issue(f,p),'STALE_AUTHORITY');
  f.store.state.credentials[0].claims.scope=['profile:issue'];
  f.clock.now=root.json.claims.expiresAt;
  const fresh=await prepared(f,'register',registerArgs(f),'fresh-after-expiry');
  rejected(await issue(f,fresh),'EXPIRED');assert.equal(f.store.state.credentials.length,1);
});
test('private administrative capability gives terminal parent revocation and stable receipt; issuance/replay reject',async t=>{
  const f=await owned(t),root=await register(f),key=await keyPair(),args=profileArgs(f,root,key);
  const p=await prepared(f,'profile-issue',args,'p',root,key);assert.equal((await issue(f,p)).status,201);
  await assert.rejects(f.app.revokeInstallation({installationId:root.json.claims.installationRef,capability:{verified:true}}),errorCode('UNAUTHORIZED'));
  const input={installationId:root.json.claims.installationRef,capability:f.adminCapability};
  const receipt=await f.app.revokeInstallation(input),again=await f.app.revokeInstallation(input);
  assert.deepEqual(receipt.body,again.body);assert.equal(f.store.state.domain.revocation_seq,1);
  rejected(await issue(f,p),'REVOKED');
  rejected(await register(f,'replace-root'),'REVOKED');assert.equal(f.store.state.credentials.length,2);
});
test('post-commit admission detects revocation before a credential response',async t=>{
  const f=await owned(t);f.store.afterCommit=state=>{
    if(state.operations.some(o=>o.operation==='register')) {state.credentials[0].revoked_at=f.clock.now;f.store.afterCommit=null;}
  };
  rejected(await register(f),'REVOKED');assert.equal(f.store.state.operations.length,1);
});
test('clock rollback rejects admission and preserves high-water; uncertainty conservatively rejects expiry',async t=>{
  const f=await owned(t),root=await register(f);f.clock.now--;
  rejected(await challenge(f,'register',registerArgs(f),'rollback'),'CLOCK_UNTRUSTED');
  f.clock.now=root.json.claims.expiresAt-1;f.clock.uncertaintySeconds=1;
  const key=await keyPair();rejected(await challenge(f,'profile-issue',profileArgs(f,root,key),'uncertain',root),'EXPIRED');
});
test('signer failure or expiry during signing rolls back rows and nonce consumption',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'sign');
  const original=f.config.signer.sign;f.config.signer.sign=async()=>{throw new Error('SQL password private-key secret');};
  const failed=await issue(f,p);rejected(failed,'DB_UNAVAILABLE');assert.doesNotMatch(failed.body.toString(),/password|private-key|secret/);
  assert.equal(f.store.state.credentials.length,0);assert.equal(f.store.state.installations.length,0);
  assert.equal(f.store.state.challenges[0].consumed_operation_id,null);
  f.config.signer.sign=async claims=>{const jws=await original(claims);f.clock.now=p.challenge.json.expiresAt;return jws;};
  rejected(await issue(f,p),'EXPIRED');assert.equal(f.store.state.installations.length,0);assert.equal(f.store.state.operations.length,0);
});
for(const kind of ['installation','profile'])for(const mode of ['replacement','in-place'])test('signed '+kind+' payload '+mode+' cannot exceed the expected lifetime',async t=>{
  const f=await owned(t);let root=null,recipient=null,args=registerArgs(f),operation='register';
  if(kind==='profile'){root=await register(f);recipient=await keyPair();args=profileArgs(f,root,recipient);operation='profile-issue';}
  const p=await prepared(f,operation,args,'signer-payload-'+kind+'-'+mode,root,recipient),original=f.config.signer.sign;
  f.config.signer.sign=async claims=>{
    const changed=mode==='in-place'?claims:structuredClone(claims);
    changed.expiresAt+=kind==='installation'?3600:50;
    return original(changed);
  };
  rejected(await issue(f,p),'UNAUTHORIZED');
  assert.equal(f.store.state.credentials.length,root?1:0);assert.equal(f.store.state.installations.length,root?1:0);
  assert.equal(f.store.state.profiles.length,0);assert.equal(f.store.state.operations.length,root?1:0);
  assert.equal(f.store.state.challenges.find(row=>row.id===p.challenge.json.challengeId).consumed_operation_id,null);
  // Failed signing must not consume the challenge or leave partial rows.
  f.config.signer.sign=original;const retried=await issue(f,p);assert.equal(retried.status,201,JSON.stringify(retried.json));
  const maximum=kind==='installation'?f.config.limits.installationSeconds:f.config.limits.profileSeconds;
  assert.equal(retried.json.claims.expiresAt-retried.json.claims.notBefore,maximum);
});
test('signed payload must retain the complete expected credential identity',async t=>{
  const f=await owned(t),p=await prepared(f,'register',registerArgs(f),'signer-identity'),original=f.config.signer.sign;
  f.config.signer.sign=async claims=>original({...claims,credentialId:randomUUID()});
  rejected(await issue(f,p),'UNAUTHORIZED');assert.equal(f.store.state.credentials.length,0);assert.equal(f.store.state.operations.length,0);
});
test('signed stored token must match its persisted claims at subsequent admission',async t=>{
  const f=await owned(t),root=await register(f),row=f.store.state.credentials[0];
  row.jws=await f.config.signer.sign({...row.claims,expiresAt:row.claims.expiresAt+3600});
  const supplied={json:{...root.json,credential:row.jws}},key=await keyPair();
  rejected(await challenge(f,'profile-issue',profileArgs(f,supplied,key),'stored-signer-payload',supplied),'UNAUTHORIZED');
  assert.equal(f.store.state.profiles.length,0);assert.equal(f.store.state.credentials.length,1);
});
test('bounded request aborts a stalled signer and does not later commit',async t=>{
  const f=await owned(t,{limits:{requestMilliseconds:80}}),p=await prepared(f,'register',registerArgs(f),'stall');
  let release;f.config.signer.sign=()=>new Promise(resolve=>{release=resolve;});
  const began=performance.now();try{const r=await issue(f,p);rejected(r,'DEADLINE_EXCEEDED');}catch(e){assert.match(e.code??e.message,/ECONNRESET|socket hang up/);}
  assert.ok(performance.now()-began<1000);release?.('late-invalid-jws');
  await new Promise(resolve=>setTimeout(resolve,25));assert.equal(f.store.state.credentials.length,0);assert.equal(f.store.state.operations.length,0);
});
test('slow body is cut off within the same request deadline and owned cleanup',async t=>{
  const f=await owned(t,{limits:{requestMilliseconds:80}}),url=new URL(f.origin),began=performance.now();
  await new Promise((resolve,fail)=>{
    const socket=createConnection({host:'127.0.0.1',port:Number(url.port)},()=>socket.write(
      'POST /bootstrap/challenge HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: 100\r\nIdempotency-Key: slow\r\n\r\n{'));
    socket.on('data',()=>{});socket.on('error',fail);socket.on('close',resolve);
  });
  assert.ok(performance.now()-began<1000);assert.equal(f.store.state.challenges.length,0);
});
test('capacity retains retry/tombstones and reserves revocation independently',async t=>{
  const f=await owned(t,{limits:{installations:1,profiles:1,operations:1,revocations:1}}),root=await register(f);
  assert.equal((await register(f)).status,201);
  rejected(await register(f,'new-operation'),'STATE_CAPACITY');
  const receipt=await f.app.revokeInstallation({installationId:root.json.claims.installationRef,capability:f.adminCapability});
  assert.equal(receipt.status,200);assert.equal(f.store.state.operations.length,2);
});
test('synthetic concurrent registrations serialize to a single authority identity (not SQL evidence)',async t=>{
  const f=await owned(t),ps=await Promise.all(['a','b','c'].map(id=>prepared(f,'register',registerArgs(f),id)));
  const results=await Promise.all(ps.map(p=>issue(f,p)));
  for(const r of results){assert.equal(r.status,201);assert.deepEqual(r.body,results[0].body);}
  assert.equal(f.store.state.installations.length,1);assert.equal(f.store.state.pools.length,1);
});
test('installation/Profile/challenge capacity rejects only new allocation',async t=>{
  const f=await owned(t,{limits:{installations:1,profiles:1}}),root=await register(f),key=await keyPair();
  const args=profileArgs(f,root,key,'one'),p=await prepared(f,'profile-issue',args,'one',root,key);
  assert.equal((await issue(f,p)).status,201);
  const second=await keyPair();
  rejected(await issue(f,await prepared(f,'profile-issue',profileArgs(f,root,second,'two'),'two',root,second)),'STATE_CAPACITY');
  assert.equal((await issue(f,p)).status,201);
  f.installationKey=second;rejected(await register(f,'other-install'),'STATE_CAPACITY');
  assert.equal(f.store.state.installations.length,1);assert.equal(f.store.state.profiles.length,1);
  const c=await owned(t,{limits:{challenges:1}}),cp=await prepared(c,'register',registerArgs(c),'one');
  assert.equal((await issue(c,cp)).status,201);
  rejected(await challenge(c,'register',registerArgs(c),'two'),'STATE_CAPACITY');assert.equal((await issue(c,cp)).status,201);
});
test('concurrent request limit rejects while a bounded signer occupies its only slot',async t=>{
  const f=await owned(t,{limits:{concurrentRequests:1,requestMilliseconds:120}}),p=await prepared(f,'register',registerArgs(f),'busy');
  let entered,release;const waiting=new Promise(resolve=>{entered=resolve;});
  f.config.signer.sign=()=>{entered();return new Promise(resolve=>{release=resolve;});};
  const pending=issue(f,p).catch(error=>({code:error.code}));await waiting;
  rejected(await challenge(f,'register',registerArgs(f),'busy-second'),'STATE_CAPACITY');
  await pending;release?.('late-invalid');assert.equal(f.store.state.credentials.length,0);
});
test('escaped scripted transaction cannot continue after rollback; invalid bigint decode fails closed',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool});let escaped;
  await assert.rejects(store.transaction(context(b.config.trust),async tx=>{escaped=tx;throw new Error('rollback');}));
  await assert.rejects(escaped.capacity('installations',128),errorCode('DB_UNAVAILABLE'));assert.equal(d.clients[0].calls.at(-1).sql,'ROLLBACK');
  await store.close();
  const overflow=driver(b.config.trust,{query:async(_client,sql)=>sql.startsWith('SELECT * FROM provider_b1.domains')?
    {rows:[{audience:b.config.trust.audience,trust_epoch:'9007199254740993',time_highwater:'0',revocation_seq:'0'}]}:undefined});
  const bad=new PostgresStore({pool:overflow.pool});await assert.rejects(bad.transaction(context(b.config.trust),async()=>{}),errorCode('INVALID_INPUT'));await bad.close();
});
test('unknown errors are sanitized without SQL values or credential bytes',()=>{
  assert.deepEqual(publicFailure(new Error('secret SQL token')).body,{code:'DB_UNAVAILABLE',message:'Provider request rejected.',retryable:false});
});

// Scripted driver-protocol tests: these execute no SQL engine and prove no
// migration validity, PostgreSQL durability, locking or crash behavior.
function driver(trust,{failCommit,failRollback,query:intercept,ledger:sharedLedger}={}) {
  const clients=[],pool=new EventEmitter();let ended=0;
  const ledger=sharedLedger??{pending:null,highwater:0,dbNow:0,owner:null};
  pool.connect=async()=>{
    const client=new EventEmitter();client.calls=[];client.released=[];client.destroyed=0;client._txStatus='I';
    client.connection={stream:{destroy(){client.destroyed++;if(ledger.owner===client)ledger.owner=null;}}};
    let business=false;
    const query=async(sql,values=[])=>{
      client.calls.push({sql,values});
      if(sql==='BEGIN ISOLATION LEVEL SERIALIZABLE')business=true;
      const supplied=await intercept?.(client,sql,values);if(supplied)return supplied;
      if(sql.startsWith('SELECT * FROM provider_b1.domains'))return {rows:[{audience:trust.audience,trust_epoch:'1',time_highwater:'0',revocation_seq:'0'}]};
      if(sql.includes('provider_b1.clock_try_lock(')) {
        if(ledger.owner===client)throw serverFailure('P0001');
        const acquired=!ledger.owner;if(acquired)ledger.owner=client;return {rows:[{acquired}]};
      }
      if(sql.includes('provider_b1.clock_unlock(')) {
        const released=ledger.owner===client;if(released)ledger.owner=null;return {rows:[{released}]};
      }
      if(sql.includes('provider_b1.clock_begin(')) {
        const ready=ledger.pending===null;if(ready)ledger.pending=values[5];return {rows:[{ready}]};
      }
      if(sql.includes('provider_b1.clock_finish(')) {
        const completed=ledger.pending===values[5],rollback_detected=values[6]<ledger.highwater;
        if(completed){ledger.highwater=Math.max(ledger.highwater,values[6],ledger.dbNow);ledger.pending=null;}
        return {rows:[{completed,highwater:String(ledger.highwater),db_now:String(ledger.dbNow),rollback_detected}]};
      }
      if(sql==='COMMIT'&&business&&failCommit)throw Object.assign(new Error('ambiguous'),{code:'ECONNRESET'});
      if(sql==='ROLLBACK'&&failRollback)throw new Error('rollback unavailable');
      if(sql==='COMMIT'||sql==='ROLLBACK')business=false;
      return {rows:[]};
    };
    client.query=async(sql,values=[])=>{
      try{const result=await query(sql,values);if(sql.startsWith('BEGIN'))client._txStatus='T';
        if(sql==='COMMIT'||sql==='ROLLBACK')client._txStatus='I';return result;
      }catch(error){if(error instanceof DatabaseError)client._txStatus='E';throw error;}
    };
    client.release=(discard=false)=>{client.released.push(discard);if(discard&&ledger.owner===client)ledger.owner=null;};clients.push(client);return client;
  };
  pool.end=async()=>{ended++;};
  return {pool,clients,ledger,get ended(){return ended;}};
}
function serverFailure(code){const error=new DatabaseError('scripted server ErrorResponse',0,'error');error.code=code;return error;}
function context(trust) {return {trust,deadline:performance.now()+5000,signal:new AbortController().signal};}
test('driver protocol reserves two clients, fixed SQL parameters and prevents escaped transaction reuse',async()=>{
  const b=await fixtureBindings(),trust={...b.config.trust,issuer:"issuer';SELECT secret;--"},d=driver(trust),store=new PostgresStore({pool:d.pool});
  let escaped;
  await store.transaction(context(trust),async tx=>{escaped=tx;await tx.insertInstallation({id:'id',channel:'channel',key_id:'key',key_hash:'00'.repeat(32),public_jwk:{},registration_digest:'11'.repeat(32)});});
  assert.equal(d.clients.length,2);const c=d.clients[0];assert.equal(c.calls[0].sql,'BEGIN ISOLATION LEVEL SERIALIZABLE');
  assert.equal(c.calls.at(-1).sql,'COMMIT');assert.deepEqual(c.released,[false]);
  for(const call of c.calls)assert.ok(!call.sql.includes(trust.issuer));
  assert.equal(c.calls.find(c=>c.sql.startsWith('INSERT')).values[0],trust.issuer);
  await assert.rejects(escaped.capacity('installations',128),errorCode('DB_UNAVAILABLE'));
  await store.close();await store.close();assert.equal(d.ended,1);
});
test('driver protocol retries only aborted serialization/deadlock and bounds attempts',async()=>{
  const b=await fixtureBindings();let attempts=0,exhaust=false;
  const d=driver(b.config.trust,{query:async(_c,sql)=>{if(sql.startsWith('SELECT * FROM provider_b1.domains')){
    attempts++;if(exhaust||attempts<3)throw serverFailure(attempts===1?'40001':'40P01');
  }}}),store=new PostgresStore({pool:d.pool});
  await store.transaction(context(b.config.trust),async()=>{});
  assert.equal(attempts,3);assert.equal(d.clients.length,2);assert.equal(d.clients[0].calls.filter(c=>c.sql==='ROLLBACK').length,2);
  exhaust=true;await assert.rejects(store.transaction(context(b.config.trust),async()=>{}));
  assert.equal(attempts,6);assert.equal(d.clients.length,4);await store.close();
});
test('driver protocol does not blindly retry ambiguous COMMIT and discards a rollback-failed client',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust,{failCommit:true,failRollback:true}),store=new PostgresStore({pool:d.pool});
  await assert.rejects(store.transaction(context(b.config.trust),async()=>{}));
  assert.equal(d.clients.length,2);assert.deepEqual(d.clients[0].released,[true]);await store.close();
});
test('SQL connection construction has no ambient defaults and never connects in this suite',async()=>{
  for(const connection of [{},{host:'localhost',port:5432,database:'b1',user:'b1_app',password:'fixture'},
    {host:'127.0.0.1',port:5432,database:'existing',user:'b1_app',password:'fixture'}])assert.throws(()=>createOwnedPool(connection),errorCode('SQL_NOT_ADMITTED'));
  const pool=createOwnedPool({host:'127.0.0.1',port:1,database:'b1',user:'b1_app',password:'non-secret-synthetic'});
  assert.equal(pool.totalCount,0);await pool.end();
});
test('migration requires explicit owner admission before acquiring a client',async()=>{
  const b=await fixtureBindings();let connects=0;
  await assert.rejects(migrate({pool:{async connect(){connects++;}},trust:b.config.trust,owner:{},verifyOwner:async()=>{throw new ProviderError('SQL_NOT_ADMITTED');}}),errorCode('SQL_NOT_ADMITTED'));
  assert.equal(connects,0);
});
test('future PostgreSQL harness refuses unadmitted resources before connecting; SQL test import registers no run',async()=>{
  await assert.rejects(admitPostgres({owner:{},verifyOwner:async()=>true}),errorCode('SQL_NOT_ADMITTED'));
  const source=await import('./postgres.test.mjs');assert.equal(typeof source.registerPostgresTests,'function');
  assert.throws(()=>source.registerPostgresTests({harness:{},bindings:{}}),errorCode('SQL_NOT_ADMITTED'));
});

test('repair P1: rejected expiry must preserve clock high-water across request rollback',async t=>{
  const f=await owned(t),root=await register(f),key=await keyPair(),args=profileArgs(f,root,key,'clock-owner');
  const previous=f.clock.now;f.clock.now=root.json.claims.expiresAt;
  assert.equal((await challenge(f,'profile-issue',args,'expired-parent',root)).json.code,'EXPIRED');
  f.clock.now=previous+1;
  const ledger=f.store.clockLedger;
  const reconstructed=new SyntheticStore();reconstructed.state=f.store.state;reconstructed.clockLedger=ledger;
  const resumed=await launch({...f,config:{...f.config,db:reconstructed}});t.after(()=>resumed.close());
  const rollback=await challenge(resumed,'profile-issue',args,'clock-rollback',root);
  assert.equal(rollback.json?.code,'CLOCK_UNTRUSTED');
});
for(const role of ['installation','recipient','installation-profile'])test('repair P2: '+role+' PoP deadline remains required after signing',async t=>{
  const f=await owned(t);let root,key,args;
  if(role!=='installation'){root=await register(f);key=await keyPair();args=profileArgs(f,root,key,'proof-owner');}
  else args=registerArgs(f);
  const p=await prepared(f,root?'profile-issue':'register',args,'short-'+role,root,key);
  const name=role==='recipient'?'x-aegis-recipient-pop':'x-aegis-pop';
  p.headers[name]=await signProof(f,p.challenge,role==='recipient'?key:f.installationKey,role==='recipient'?'recipient':'installation',{expiresAt:f.clock.now+1});
  const original=f.config.signer.sign;
  f.config.signer.sign=async claims=>{const token=await original(claims);f.clock.now+=2;return token;};
  const result=await issue(f,p);assert.equal(result.json?.code,'EXPIRED');
});
test('repair P2: combined DB clock is refreshed after final hierarchy await',async t=>{
  const f=await owned(t);let dbNow=f.clock.now,armed=false;
  const transaction=f.store.transaction.bind(f.store);
  f.store.transaction=(context,work)=>transaction(context,async tx=>{
    const time=tx.time.bind(tx),hierarchy=tx.hierarchy.bind(tx);
    tx.time=async raw=>{const interval=await time(raw);return {...interval,latest:Math.max(interval.latest,dbNow)};};
    tx.hierarchy=async id=>{const chain=await hierarchy(id);if(armed)dbNow=chain.credential.expires_at;return chain;};
    return work(tx);
  });
  f.store.afterCommit=state=>{if(state.credentials.length)armed=true;};
  const result=await register(f,'hierarchy-wait');assert.equal(result.json?.code,'EXPIRED');
});

for(const phase of ['before-marker','after-marker','before-observation','after-observation'])
  test('synthetic clock interruption at '+phase+' retains resolved floor or unresolved fence',async()=>{
    const b=await fixtureBindings(),store=b.store,c=context(b.config.trust);let samples=0;
    store.clockHook=at=>{if(at===phase)throw new Error('interrupted');};
    await assert.rejects(store.observeTime(c,()=>{samples++;return {now:100,uncertaintySeconds:0};}));
    store.clockHook=null;
    const restarted=new SyntheticStore();restarted.clockLedger=store.clockLedger;
    if(phase==='before-marker') {
      assert.equal(samples,0);assert.equal(restarted.clockLedger.pending,null);
      assert.equal((await restarted.observeTime(c,()=>({now:99,uncertaintySeconds:0}))).latest,99);
    } else {
      assert.equal(samples,phase==='after-marker'?0:1);
      await assert.rejects(restarted.observeTime(c,()=>({now:99,uncertaintySeconds:0})),errorCode('CLOCK_UNTRUSTED'));
      if(phase==='after-observation'){assert.equal(restarted.clockLedger.highwater,100);assert.equal(restarted.clockLedger.pending,null);}
      else assert.notEqual(restarted.clockLedger.pending,null);
    }
    await store.close();await restarted.close();
  });
test('construction never samples the injected clock; guarded invalid sample leaves a fence',async()=>{
  const b=await fixtureBindings();let samples=0;
  const app=createApp({...b.config,clock:{observe(){samples++;return {now:NaN,uncertaintySeconds:0};}}});
  assert.equal(samples,0);await assert.rejects(b.store.observeTime(context(b.config.trust),()=>{samples++;return {now:NaN,uncertaintySeconds:0};}),errorCode('CLOCK_UNTRUSTED'));
  assert.notEqual(b.store.clockLedger.pending,null);await app.close();
});
for(const role of ['installation','recipient'])for(const stage of ['cached-consumption','post-commit'])
  test('short '+role+' proof expires during '+stage+' despite live challenge/result',async t=>{
    const f=await owned(t);let root,key,args;
    if(role==='recipient'){root=await register(f);key=await keyPair();args=profileArgs(f,root,key,'cached-proof-owner');}
    else args=registerArgs(f);
    const operation=root?'profile-issue':'register',idem='proof-'+stage;
    if(stage==='cached-consumption')assert.equal((await issue(f,await prepared(f,operation,args,idem,root,key))).status,201);
    const p=await prepared(f,operation,args,idem,root,key);
    p.headers[role==='recipient'?'x-aegis-recipient-pop':'x-aegis-pop']=await signProof(f,p.challenge,role==='recipient'?key:f.installationKey,role==='recipient'?'recipient':'installation',{expiresAt:f.clock.now+1});
    if(stage==='post-commit')f.store.afterCommit=()=>{f.clock.now+=2;f.store.afterCommit=null;};
    else {
      const transact=f.store.transaction.bind(f.store);
      f.store.transaction=(c,work)=>transact(c,tx=>{const consume=tx.consumeChallenge.bind(tx);tx.consumeChallenge=async(...args)=>{await consume(...args);f.clock.now+=2;};return work(tx);});
    }
    rejected(await issue(f,p),'EXPIRED');
    assert.equal(f.store.state.operations.filter(o=>o.operation===operation).length,1);
  });
for(const adapter of ['signer','ownership'])test('driver Client error during '+adapter+' wait aborts local signal and forbids late SQL',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool});
  let entered,release,escaped;const ready=new Promise(resolve=>{entered=resolve;}),gate=new Promise(resolve=>{release=resolve;});
  const pending=store.transaction(context(b.config.trust),async tx=>{escaped=tx;entered();await gate;await tx.capacity('installations',128);});
  const failure=assert.rejects(pending,errorCode('DB_UNAVAILABLE'));await ready;
  assert.doesNotThrow(()=>{d.clients[0].emit('error',new Error('synthetic disconnect'));d.clients[0].emit('error',new Error('repeat disconnect'));});
  await failure;assert.equal(escaped.signal.aborted,true);assert.deepEqual(d.clients[0].released,[true]);assert.equal(d.clients[0].destroyed,1);
  release();await new Promise(resolve=>setTimeout(resolve,10));assert.ok(!d.clients[0].calls.some(c=>c.sql==='COMMIT'||c.sql.startsWith('SELECT count')));
  await store.close();assert.deepEqual(d.clients[0].released,[true]);
});
test('idle Pool errors and post-release Client errors are contained without raw diagnostics',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool});
  assert.doesNotThrow(()=>d.pool.emit('error',new Error('idle secret')));
  await store.transaction(context(b.config.trust),async()=>{});
  assert.doesNotThrow(()=>d.clients[0].emit('error',new Error('after release')));
  await store.close();
});
test('late acquisition is discarded once after deadline, without BEGIN',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),acquire=d.pool.connect;let deliver;
  d.pool.connect=()=>new Promise(resolve=>{deliver=async()=>resolve(await acquire());});
  const store=new PostgresStore({pool:d.pool}),c={...context(b.config.trust),deadline:performance.now()+35};
  await assert.rejects(store.transaction(c,async()=>{}),errorCode('DEADLINE_EXCEEDED'));
  await deliver();await new Promise(resolve=>setTimeout(resolve,10));
  assert.deepEqual(d.clients[0].released,[true]);assert.equal(d.clients[0].calls.length,0);assert.equal(d.clients[0].destroyed,1);await store.close();
});
test('hanging query is destroyed on deadline; no queued ROLLBACK or late COMMIT',async()=>{
  const b=await fixtureBindings();let release;
  const d=driver(b.config.trust,{query:async(_c,sql)=>sql.startsWith('SELECT * FROM provider_b1.domains')?new Promise(resolve=>{release=resolve;}):undefined});
  const store=new PostgresStore({pool:d.pool}),began=performance.now();
  await assert.rejects(store.transaction({...context(b.config.trust),deadline:began+35},async()=>{}),errorCode('DEADLINE_EXCEEDED'));
  assert.ok(performance.now()-began<600);assert.deepEqual(d.clients[0].released,[true]);
  assert.ok(!d.clients[0].calls.some(c=>['ROLLBACK','COMMIT'].includes(c.sql)));
  release({rows:[]});await new Promise(resolve=>setTimeout(resolve,10));await store.close();
});
test('hanging healthy ROLLBACK is bounded and then discarded exactly once',async()=>{
  const b=await fixtureBindings();let release;
  const d=driver(b.config.trust,{query:async(_c,sql)=>sql==='ROLLBACK'?new Promise(resolve=>{release=resolve;}):undefined});
  const store=new PostgresStore({pool:d.pool}),began=performance.now();
  await assert.rejects(store.transaction(context(b.config.trust),async()=>{throw new Error('rollback');}));
  assert.ok(performance.now()-began<700);assert.deepEqual(d.clients[0].released,[true]);
  release({rows:[]});await new Promise(resolve=>setTimeout(resolve,10));await store.close();
});
for(const action of ['abort','close'])test(action+' rejects active work and queued borrowers without late commit',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool}),controller=new AbortController();
  let entered,release;const ready=new Promise(resolve=>{entered=resolve;}),gate=new Promise(resolve=>{release=resolve;});
  const c={...context(b.config.trust),signal:controller.signal};
  const active=store.transaction(c,async()=>{entered();await gate;});const rejectedActive=assert.rejects(active,errorCode(action==='close'?'SERVER_CLOSED':'DEADLINE_EXCEEDED'));
  await ready;
  const queued=store.transaction(action==='close'?context(b.config.trust):c,async()=>{});
  const rejectedQueued=assert.rejects(queued,errorCode(action==='close'?'SERVER_CLOSED':'DEADLINE_EXCEEDED'));
  if(action==='close')await store.close();else controller.abort();
  await Promise.all([rejectedActive,rejectedQueued]);assert.equal(d.clients.length,2);
  release();await new Promise(resolve=>setTimeout(resolve,10));
  assert.ok(d.clients.every(c=>!c.calls.some(q=>q.sql==='COMMIT')));assert.ok(d.clients.every(c=>c.released.length===1));await store.close();
});
test('clock protocol samples only after marker COMMIT, independently persists rejected floor, and blocks unresolved sampling',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool});
  let observed=0;
  const c=context(b.config.trust);
  await assert.rejects(store.transaction(c,async tx=>{await tx.time(()=>{observed++;assert.equal(d.clients[1].calls.at(-1).sql,'COMMIT');return {now:100,uncertaintySeconds:0};});throw new ProviderError('EXPIRED');}),errorCode('EXPIRED'));
  assert.equal(observed,1);assert.equal(d.ledger.highwater,100);
  await assert.rejects(store.observeTime(c,()=>({now:99,uncertaintySeconds:0})),errorCode('CLOCK_UNTRUSTED'));
  await assert.rejects(store.observeTime(c,()=>{throw new Error('clock lost');}),errorCode('CLOCK_UNTRUSTED'));
  assert.notEqual(d.ledger.pending,null);let sampled=false;
  await assert.rejects(store.observeTime(c,()=>{sampled=true;return {now:101,uncertaintySeconds:0};}),errorCode('CLOCK_UNTRUSTED'));
  assert.equal(sampled,false);await store.close();
});
test('clock COMMIT uncertainty never retries the business callback',async()=>{
  const b=await fixtureBindings();let commits=0,callbacks=0,samples=0;
  const d=driver(b.config.trust,{query:async(client,sql)=>{if(sql==='COMMIT'&&client===d.clients[1]&&++commits===1)throw Object.assign(new Error('clock transport lost'),{code:'40001'});}});
  const store=new PostgresStore({pool:d.pool});
  await assert.rejects(store.transaction(context(b.config.trust),async tx=>{callbacks++;await tx.time(()=>{samples++;return {now:100,uncertaintySeconds:0};});}),errorCode('CLOCK_UNTRUSTED'));
  assert.equal(callbacks,1);assert.equal(samples,0);assert.notEqual(d.ledger.pending,null);await store.close();
});
test('shared owned pool serializes business borrowers before reserving both connections',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),a=new PostgresStore({pool:d.pool}),bStore=new PostgresStore({pool:d.pool});
  let entered,release;const ready=new Promise(resolve=>{entered=resolve;}),gate=new Promise(resolve=>{release=resolve;});
  const first=a.transaction(context(b.config.trust),async()=>{entered();await gate;});await ready;
  const second=bStore.transaction(context(b.config.trust),async()=>{});await new Promise(resolve=>setTimeout(resolve,10));
  assert.equal(d.clients.length,2);release();await Promise.all([first,second]);assert.equal(d.clients.length,4);await a.close();await bStore.close();
});
function receiptFixture() {
  const runId=randomUUID(),owner={runId,uid:process.getuid(),imageDigest:'sha256:a85953d6f830fd55a12929df3b7a4fa94dc96d652de62d2d714e0867ccb3670d',platform:'linux/arm64',containerId:'a'.repeat(64),networkId:'b'.repeat(64),artifactRoot:'/Volumes/ExternalSSD/.artifacts/b1-pg-'+runId,host:'127.0.0.1',port:1};
  const receipt={...owner,storageFreeBytes:6*1024**3,dataQuotaBytes:2*1024**3,connectionLimit:12,cpuLimit:2,memoryLimitBytes:1024**3,shmBytes:128*1024**2,wallBudgetSeconds:1800,resultsQuotaBytes:128*1024**2,durabilityMountVerified:true,loopbackPublicationVerified:true,roleGrantsVerified:true,secretFileModesVerified:true};
  const connections=Object.fromEntries(['b1_bootstrap','b1_migrator','b1_app'].map(user=>[user,{host:'127.0.0.1',port:1,database:'b1',user,password:'synthetic-not-connected'}]));
  return {owner,receipt,connections};
}
for(const [name,value] of [['missing',undefined],['NaN',NaN],['Infinity',Infinity],['negative Infinity',-Infinity],['string','6442450944'],['null',null],['negative',-1],['fractional',6*1024**3+.5],['unsafe',Number.MAX_SAFE_INTEGER+1],['below threshold',6*1024**3-1]])
  test('storage receipt rejects '+name+' before any connection or lifecycle work',async()=>{
    const {owner,receipt,connections}=receiptFixture();receipt.storageFreeBytes=value;let lifecycle=0;
    await assert.rejects(admitPostgres({owner,connections,trust:{},verifyOwner:async()=>receipt,lifecycle:{restartDatabase:async()=>{lifecycle++;}}}),errorCode('SQL_NOT_ADMITTED'));assert.equal(lifecycle,0);
  });
test('exact storage threshold admits metadata; refreshed invalid receipt blocks health, migration and restart before access',async()=>{
  const {owner,receipt,connections}=receiptFixture();let lifecycle=0;
  const harness=await admitPostgres({owner,connections,trust:{},verifyOwner:async()=>receipt,lifecycle:{restartDatabase:async()=>{lifecycle++;}}});
  receipt.storageFreeBytes=NaN;
  await assert.rejects(harness.health(),errorCode('SQL_NOT_ADMITTED'));
  await assert.rejects(harness.initializeFresh(),errorCode('SQL_NOT_ADMITTED'));
  await assert.rejects(harness.restartDatabase('clean'),errorCode('SQL_NOT_ADMITTED'));
  assert.equal(lifecycle,0);await harness.close();
});

test('Client error synchronously emitted by release rejects the still-active borrower',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),connect=d.pool.connect;
  d.pool.connect=async()=>{const client=await connect(),release=client.release;client.release=discard=>{client.emit('error',new Error('release disconnect'));release(discard);};return client;};
  const store=new PostgresStore({pool:d.pool});
  await assert.rejects(store.transaction(context(b.config.trust),async()=>({wouldBeAccepted:true})),errorCode('DB_UNAVAILABLE'));
  assert.ok(d.clients.every(c=>c.released.length===1));await store.close();
});
for(const adapter of ['signer','ownership'])test('synthetic authority '+adapter+' receives abort on checked-out driver error and cannot persist late result',async t=>{
  const b=await fixtureBindings(),base=b.store,d=driver(b.config.trust),pg=new PostgresStore({pool:d.pool});
  // Compose two labeled test doubles; this is no SQL engine or durability evidence.
  const db={kind:'synthetic-test-double',transaction:(c,work)=>pg.transaction(c,tx=>base.transaction(tx.context,work)),
    observeTime:(...args)=>base.observeTime(...args),proofBinding:(...args)=>base.proofBinding(...args),
    close:async()=>{await base.close();await pg.close();}};
  const f=await launch({...b,config:{...b.config,db}});t.after(()=>f.close());
  let root,key,args;
  if(adapter==='ownership'){root=await register(f);key=await keyPair();args=profileArgs(f,root,key,'event-owner');}
  else args=registerArgs(f);
  const p=await prepared(f,root?'profile-issue':'register',args,'event-'+adapter,root,key);
  let entered,release,adapterSignal;
  const ready=new Promise(resolve=>{entered=resolve;}),gate=new Promise(resolve=>{release=resolve;});
  const target=f.config[adapter],method=adapter==='signer'?'sign':'verify',original=target[method];
  target[method]=async(...args)=>{adapterSignal=adapter==='signer'?args[1].signal:args[0].signal;entered();await gate;return original(...args);};
  const count=base.state.credentials.length,operations=base.state.operations.length,pending=issue(f,p);
  await ready;const client=d.clients.at(-2);client.emit('error',new Error('synthetic idle timeout'));
  rejected(await pending,'DB_UNAVAILABLE');assert.equal(adapterSignal.aborted,true);assert.deepEqual(client.released,[true]);
  release();await new Promise(resolve=>setTimeout(resolve,20));
  assert.equal(base.state.credentials.length,count);assert.equal(base.state.operations.length,operations);
  assert.equal(base.state.challenges.find(c=>c.id===p.data.challengeId).consumed_operation_id,null);
});

test('R2 migration EventEmitter child contains checked-out failure and discards exactly once',async()=>{
  const code=`import {EventEmitter} from 'node:events';
    import {migrate} from ${JSON.stringify(new URL('../migrate.mjs',import.meta.url).href)};
    import {fixtureBindings} from ${JSON.stringify(new URL('./fixtures.mjs',import.meta.url).href)};
    const b=await fixtureBindings(),pool=new EventEmitter(),client=new EventEmitter();
    client._txStatus='I';let releases=[],destroyed=0,ended=0;const calls=[];
    client.connection={stream:{destroy(){destroyed++;}}};client.release=x=>releases.push(x);
    client.query=sql=>{calls.push(sql);queueMicrotask(()=>client.emit('error',new Error('synthetic migration disconnect')));return new Promise(()=>{});};
    pool.connect=async()=>client;pool.end=async()=>{ended++;};
    const timer=setTimeout(()=>process.exit(2),750);
    try{await migrate({pool,trust:b.config.trust,owner:{},verifyOwner:async()=>{}});process.exitCode=3;}
    catch(error){client.emit('error',new Error('repeat'));const result={code:error.code,releases,destroyed,ended,calls};process.stdout.write(JSON.stringify(result));
      if(error.code!=='DB_UNAVAILABLE'||releases.length!==1||releases[0]!==true||destroyed!==1||ended!==1||calls.includes('COMMIT'))process.exitCode=4;}
    finally{clearTimeout(timer);await b.store.close();}`;
  const child=spawn(process.execPath,['--input-type=module','-e',code],{stdio:['ignore','pipe','pipe']});let stdout='',stderr='';
  child.stdout.on('data',b=>stdout+=b);child.stderr.on('data',b=>stderr+=b);
  const exit=await new Promise(resolve=>child.once('exit',resolve));assert.equal(exit,0,stderr);assert.equal(JSON.parse(stdout).code,'DB_UNAVAILABLE');
});
test('R2 separate owned pools serialize one live clock lifecycle and still refuse an abandoned fence',async()=>{
  const b=await fixtureBindings(),ledger={pending:null,highwater:0,dbNow:0,owner:null},aDriver=driver(b.config.trust,{ledger}),bDriver=driver(b.config.trust,{ledger});
  const a=new PostgresStore({pool:aDriver.pool}),other=new PostgresStore({pool:bDriver.pool}),ready=deferred(),gate=deferred();
  const one=a.observeTime(context(b.config.trust),async()=>{ready.resolve();await gate.promise;return {now:100,uncertaintySeconds:0};});await ready.promise;
  let sampled=false;const two=other.observeTime(context(b.config.trust),()=>{sampled=true;return {now:101,uncertaintySeconds:0};});
  await new Promise(resolve=>setTimeout(resolve,25));assert.equal(sampled,false);assert.notEqual(ledger.owner,null);
  gate.resolve();assert.equal((await one).latest,100);assert.equal((await two).latest,101);assert.equal(ledger.owner,null);
  assert.ok(bDriver.clients[1].calls.filter(c=>c.sql.includes('clock_try_lock')).length>=2);
  ledger.pending='abandoned';sampled=false;
  await assert.rejects(other.observeTime(context(b.config.trust),()=>{sampled=true;return {now:102,uncertaintySeconds:0};}),errorCode('CLOCK_UNTRUSTED'));
  assert.equal(sampled,false);assert.equal(ledger.pending,'abandoned');assert.equal(ledger.owner,null);await a.close();await other.close();
});
test('R2 synthetic independent stores share lifecycle ownership outside business drafts',async()=>{
  const b=await fixtureBindings(),a=b.store,other=new SyntheticStore();other.clockLedger=a.clockLedger;
  const ready=deferred(),gate=deferred(),c=context(b.config.trust);
  const one=a.observeTime(c,async()=>{ready.resolve();await gate.promise;return {now:100,uncertaintySeconds:0};});await ready.promise;
  let sampled=false;const two=other.observeTime(c,()=>{sampled=true;return {now:101,uncertaintySeconds:0};});
  await new Promise(resolve=>setTimeout(resolve,15));assert.equal(sampled,false);gate.resolve();await one;assert.equal((await two).latest,101);
  await a.close();await other.close();
});
for(const role of ['installation','recipient','installation-profile'])for(const stage of ['cached','new-signing','post-commit'])
  test('R2 '+stage+' '+role+' PoP notBefore is rechecked when lower bound regresses',async t=>{
    const f=await owned(t),base=f.clock.now;let root,key,args;
    if(role!=='installation'){root=await register(f);key=await keyPair();args=profileArgs(f,root,key,'lower-owner');}else args=registerArgs(f);
    const operation=root?'profile-issue':'register',idem='lower-'+role+'-'+stage;let original;
    if(stage==='cached'){original=await issue(f,await prepared(f,operation,args,idem,root,key));assert.equal(original.status,201);}
    const p=await prepared(f,operation,args,idem,root,key);f.clock.now=base+10;
    const oldWindow={issuedAt:base,notBefore:base};
    p.headers['x-aegis-pop']=await signProof(f,p.challenge,f.installationKey,'installation',role==='recipient'?oldWindow:{});
    if(root)p.headers['x-aegis-recipient-pop']=await signProof(f,p.challenge,key,'recipient',role==='recipient'?{}:oldWindow);
    const regress=()=>{f.clock.now=base+11;f.clock.uncertaintySeconds=2;};
    if(stage==='cached'){
      const transact=f.store.transaction.bind(f.store);f.store.transaction=(c,work)=>transact(c,tx=>{const hierarchy=tx.hierarchy.bind(tx),ch=tx.challenge.bind(tx);let verified=false;
        tx.challenge=async id=>{const row=await ch(id);verified=true;return row;};
        tx.hierarchy=async id=>{const chain=await hierarchy(id);if(verified&&id===original.json.claims.credentialId)regress();return chain;};return work(tx);});
    }else if(stage==='new-signing'){const sign=f.config.signer.sign;f.config.signer.sign=async(...args)=>{const token=await sign(...args);regress();return token;};}
    else f.store.afterCommit=()=>{f.store.afterCommit=null;regress();};
    rejected(await issue(f,p),'NOT_YET_VALID');
  });
test('R2 adapter-thrown SQLSTATE text is not retried as a server-confirmed abort',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool});let attempts=0;
  await assert.rejects(store.transaction(context(b.config.trust),async()=>{attempts++;throw Object.assign(new Error('adapter'),{code:'40001'});}));
  assert.equal(attempts,1);assert.equal(d.clients[0].calls.filter(c=>c.sql.startsWith('BEGIN')).length,1);await store.close();
});
for(const phase of ['marker','observation','unlock'])test('R2 uncertain '+phase+' acknowledgement discards lifecycle owner without blind retry',async()=>{
  const b=await fixtureBindings();let commits=0;
  const d=driver(b.config.trust,{query:async(_client,sql)=>{
    if(sql==='COMMIT')commits++;
    if((phase==='marker'&&sql==='COMMIT'&&commits===1)||(phase==='observation'&&sql==='COMMIT'&&commits===2)||(phase==='unlock'&&sql.includes('clock_unlock')))
      throw Object.assign(new Error('transport lost'),{code:'ECONNRESET'});
  }}),store=new PostgresStore({pool:d.pool});let samples=0;
  await assert.rejects(store.observeTime(context(b.config.trust),()=>{samples++;return {now:100,uncertaintySeconds:0};}),errorCode('CLOCK_UNTRUSTED'));
  assert.equal(samples,phase==='marker'?0:1);assert.equal(d.ledger.owner,null);assert.deepEqual(d.clients[1].released,[true]);assert.equal(d.clients[1].destroyed,1);
  assert.ok(!d.clients[1].calls.some(c=>c.sql==='ROLLBACK'));await store.close();
});
test('R2 false unlock acknowledgement poisons the owned client',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust,{query:async(_client,sql)=>sql.includes('clock_unlock')?{rows:[{released:false}]}:undefined}),store=new PostgresStore({pool:d.pool});
  await assert.rejects(store.observeTime(context(b.config.trust),()=>({now:100,uncertaintySeconds:0})),errorCode('CLOCK_UNTRUSTED'));
  assert.deepEqual(d.clients[1].released,[true]);assert.equal(d.ledger.owner,null);await store.close();
});
test('R2 cancellation while waiting for another session owner does not inspect or clear its live fence',async()=>{
  const b=await fixtureBindings(),ledger={pending:null,highwater:0,dbNow:0,owner:null},aD=driver(b.config.trust,{ledger}),bD=driver(b.config.trust,{ledger}),a=new PostgresStore({pool:aD.pool}),other=new PostgresStore({pool:bD.pool}),ready=deferred(),gate=deferred(),abort=new AbortController();
  const one=a.observeTime(context(b.config.trust),async()=>{ready.resolve();await gate.promise;return {now:100,uncertaintySeconds:0};});await ready.promise;
  const marker=ledger.pending;const two=other.observeTime({...context(b.config.trust),signal:abort.signal},()=>{throw new Error('must not sample');});const failure=assert.rejects(two,errorCode('DEADLINE_EXCEEDED'));
  await new Promise(resolve=>setTimeout(resolve,15));abort.abort();await failure;assert.equal(ledger.pending,marker);assert.equal(ledger.owner,aD.clients[1]);
  gate.resolve();await one;assert.equal(ledger.owner,null);await a.close();await other.close();
});

function migrationDriver(trust,query) {
  return driver(trust,{query:async(client,sql,values)=>{
    const result=await query?.(client,sql,values);if(result)return result;
    if(sql.startsWith('SELECT current_user'))return {rows:[{role:'b1_bootstrap',database:'b1',schema:null}]};
  }});
}
test('R2 migration consumes and closes its dedicated pool once on success and admission failure',async()=>{
  const b=await fixtureBindings(),d=migrationDriver(b.config.trust);await migrate({pool:d.pool,trust:b.config.trust,owner:{},verifyOwner:async()=>{}});
  assert.equal(d.clients.length,1);assert.deepEqual(d.clients[0].released,[false]);assert.equal(d.ended,1);
  const denied=migrationDriver(b.config.trust);await assert.rejects(migrate({pool:denied.pool,trust:b.config.trust,owner:{},verifyOwner:async()=>{throw new ProviderError('SQL_NOT_ADMITTED');}}),errorCode('SQL_NOT_ADMITTED'));
  assert.equal(denied.clients.length,0);assert.equal(denied.ended,1);
});
for(const phase of ['admission','acquisition','DDL'])test('R2 migration abort during '+phase+' prevents late COMMIT and discards late work',async()=>{
  const b=await fixtureBindings(),gate=deferred(),ready=deferred(),abort=new AbortController();
  const d=migrationDriver(b.config.trust,async(_c,sql)=>{if(phase==='DDL'&&sql.startsWith('-- SOURCE ONLY')){ready.resolve();return gate.promise;}});
  const acquire=d.pool.connect;
  if(phase==='acquisition')d.pool.connect=async()=>{ready.resolve();await gate.promise;return acquire();};
  const verifyOwner=phase==='admission'?async()=>{ready.resolve();await gate.promise;}:async()=>{};
  const pending=migrate({pool:d.pool,trust:b.config.trust,owner:{},verifyOwner,signal:abort.signal}),failure=assert.rejects(pending,errorCode('DEADLINE_EXCEEDED'));
  await ready.promise;abort.abort();await failure;gate.resolve({rows:[]});await new Promise(resolve=>setTimeout(resolve,15));
  assert.equal(d.ended,1);assert.ok(d.clients.every(c=>!c.calls.some(q=>q.sql==='COMMIT')));
  if(phase==='admission')assert.equal(d.clients.length,0);
  else {assert.deepEqual(d.clients[0].released,[true]);assert.equal(d.clients[0].destroyed,1);}
});
test('R2 migration uncertain COMMIT is not rolled back or initialized again',async()=>{
  const b=await fixtureBindings(),d=migrationDriver(b.config.trust,async(_c,sql)=>{if(sql==='COMMIT')throw Object.assign(new Error('ack lost'),{code:'ECONNRESET'});});
  await assert.rejects(migrate({pool:d.pool,trust:b.config.trust,owner:{},verifyOwner:async()=>{}}));
  assert.equal(d.clients[0].calls.filter(c=>c.sql==='COMMIT').length,1);assert.ok(!d.clients[0].calls.some(c=>c.sql==='ROLLBACK'));
  assert.deepEqual(d.clients[0].released,[true]);assert.equal(d.ended,1);
});
test('R2 migration hanging rollback is bounded before dedicated pool close',async()=>{
  const b=await fixtureBindings(),gate=deferred();
  const d=migrationDriver(b.config.trust,async(_c,sql)=>{if(sql.startsWith('-- SOURCE ONLY'))throw serverFailure('42501');if(sql==='ROLLBACK')return gate.promise;});
  const start=performance.now();await assert.rejects(migrate({pool:d.pool,trust:b.config.trust,owner:{},verifyOwner:async()=>{}}));
  assert.ok(performance.now()-start<750);assert.deepEqual(d.clients[0].released,[true]);assert.equal(d.ended,1);gate.resolve({rows:[]});
});
test('R2 client end during owned clock sampling rejects and releases session ownership once',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust),store=new PostgresStore({pool:d.pool}),ready=deferred(),gate=deferred();
  const pending=store.observeTime(context(b.config.trust),async()=>{ready.resolve();await gate.promise;return {now:100,uncertaintySeconds:0};});
  const failure=assert.rejects(pending,errorCode('DB_UNAVAILABLE'));await ready.promise;d.clients[1].emit('end');await failure;
  assert.deepEqual(d.clients[1].released,[true]);assert.equal(d.ledger.owner,null);const count=d.clients[1].calls.length;
  gate.resolve();await new Promise(resolve=>setTimeout(resolve,15));assert.equal(d.clients[1].calls.length,count);await store.close();
});

test('R2 recursive or leftover lifecycle ownership is refused and discarded instead of incremented',async()=>{
  const b=await fixtureBindings(),d=driver(b.config.trust,{query:async(client,sql)=>{if(sql.includes('clock_try_lock'))d.ledger.owner=client;}}),store=new PostgresStore({pool:d.pool});let sampled=false;
  await assert.rejects(store.observeTime(context(b.config.trust),()=>{sampled=true;return {now:100,uncertaintySeconds:0};}),errorCode('CLOCK_UNTRUSTED'));
  assert.equal(sampled,false);assert.equal(d.ledger.owner,null);assert.equal(d.ledger.pending,null);assert.deepEqual(d.clients[1].released,[true]);await store.close();
});
test('R2 migration pool drainage is bounded and failure is not reported as completed migration',async()=>{
  const b=await fixtureBindings(),d=migrationDriver(b.config.trust),drain=deferred();d.pool.end=()=>drain.promise;
  const start=performance.now();await assert.rejects(migrate({pool:d.pool,trust:b.config.trust,owner:{},verifyOwner:async()=>{}}),errorCode('DB_UNAVAILABLE'));
  assert.ok(performance.now()-start<1500);assert.equal(d.clients[0].calls.filter(c=>c.sql==='COMMIT').length,1);drain.resolve();
});

async function r3Prepared(f, operation, args, idem, root, recipient) {
  const p = await prepared(f, operation, args, idem, root, recipient);
  if (p.challenge.status !== 200) return p;
  const window = { issuedAt: p.challenge.json.issuedAt, notBefore: p.challenge.json.issuedAt };
  p.headers['x-aegis-pop'] = await signProof(f,p.challenge,f.installationKey,'installation',window);
  if (root) p.headers['x-aegis-recipient-pop'] = await signProof(f,p.challenge,recipient,'recipient',window);
  return p;
}

// R3: duration is measured from the issuance lower bound, including cached reuse.
for (const kind of ['challenge','installation','profile']) test('R3 bounded '+kind+' lifetime survives narrowed uncertainty',async t=>{
  const f=await owned(t);f.clock.now=100;
  let root,key,args,p;
  if(kind==='profile') { root=await register(f,'r3-root');key=await keyPair();args=profileArgs(f,root,key,'r3-profile-owner'); }
  else args=registerArgs(f);
  f.clock.now=110;f.clock.uncertaintySeconds=10;
  p=await r3Prepared(f,kind==='profile'?'profile-issue':'register',args,'r3-'+kind,root,key);
  if(kind==='challenge') {
    f.clock.now=161;f.clock.uncertaintySeconds=0;
    rejected(await issue(f,p),'EXPIRED');
    assert.equal(p.challenge.json.issuedAt,100);assert.equal(p.challenge.json.expiresAt,160);
  } else {
    const issued=await issue(f,p);assert.equal(issued.status,201);
    f.clock.now=kind==='installation'?711:411;f.clock.uncertaintySeconds=0;
    const retry=await r3Prepared(f,kind==='profile'?'profile-issue':'register',args,'r3-'+kind,root,key);
    rejected(await issue(f,retry),'EXPIRED');
    assert.equal(issued.json.claims.issuedAt,100);assert.equal(issued.json.claims.notBefore,100);
    assert.equal(issued.json.claims.expiresAt,kind==='installation'?700:400);
  }
});
test('R3 challenge refuses uncertainty reaching its entire lifetime without creating rows',async t=>{
  const f=await owned(t);f.clock.now=130;f.clock.uncertaintySeconds=30;
  rejected(await challenge(f,'register',registerArgs(f),'r3-wide-challenge'),'EXPIRED');
  assert.equal(f.store.state.challenges.length,0);
});
for (const kind of ['installation','profile']) for (const width of [20,22])
  test('R3 '+kind+' refuses '+(width===20?'expiry equality':'excess uncertainty')+' before signing',async t=>{
    const f=await owned(t,{limits:{installationSeconds:kind==='installation'?20:600,profileSeconds:20}});
    f.clock.now=100;let root,key,args;
    if(kind==='profile'){root=await register(f,'r3-wide-parent');key=await keyPair();args=profileArgs(f,root,key,'r3-wide-profile');}
    else args=registerArgs(f);
    f.clock.now=111;f.clock.uncertaintySeconds=width/2;
    const p=await r3Prepared(f,kind==='profile'?'profile-issue':'register',args,'r3-wide-'+kind,root,key);
    let signs=0;const original=f.config.signer.sign;f.config.signer.sign=async(...a)=>{signs++;return original(...a);};
    const credentials=f.store.state.credentials.length,installations=f.store.state.installations.length;
    rejected(await issue(f,p),'EXPIRED');assert.equal(signs,0);
    assert.equal(f.store.state.credentials.length,credentials);assert.equal(f.store.state.installations.length,installations);
    assert.equal(f.store.state.profiles.length,0);assert.equal(f.store.state.challenges.at(-1).consumed_operation_id,null);
  });
test('R3 Profile expiry remains capped by its parent, including equality',async t=>{
  const f=await owned(t,{limits:{installationSeconds:40}});f.clock.now=100;
  const root=await register(f,'r3-cap-parent'),key=await keyPair(),args=profileArgs(f,root,key,'r3-cap-profile');
  f.clock.now=110;f.clock.uncertaintySeconds=2;
  const issued=await issue(f,await r3Prepared(f,'profile-issue',args,'r3-cap',root,key));assert.equal(issued.status,201);
  assert.equal(issued.json.claims.expiresAt,root.json.claims.expiresAt);assert.equal(issued.json.claims.expiresAt,140);
  f.clock.now=140;f.clock.uncertaintySeconds=0;
  rejected(await challenge(f,'profile-issue',args,'r3-cap',root),'EXPIRED');
});
test('R3 cached fresh admission returns original bytes and never extends the lower-bound lifetime',async t=>{
  const f=await owned(t);f.clock.now=110;f.clock.uncertaintySeconds=10;
  const args=registerArgs(f),first=await issue(f,await r3Prepared(f,'register',args,'r3-cache'));assert.equal(first.status,201);
  f.clock.now=121;f.clock.uncertaintySeconds=0;
  const cached=await issue(f,await r3Prepared(f,'register',args,'r3-cache'));assert.equal(cached.status,201);
  assert.deepEqual(cached.body,first.body);assert.equal(cached.json.claims.expiresAt,700);
  f.clock.now=700;rejected(await issue(f,await r3Prepared(f,'register',args,'r3-cache')),'EXPIRED');
  assert.equal(f.store.state.operations.length,1);assert.equal(f.store.state.credentials.length,1);
});
test('R3 issuance rejects unsafe integer expiry arithmetic',async t=>{
  const f=await owned(t);f.clock.now=Number.MAX_SAFE_INTEGER-1;
  rejected(await challenge(f,'register',registerArgs(f),'r3-overflow'),'CLOCK_UNTRUSTED');
  assert.equal(f.store.state.challenges.length,0);
});
