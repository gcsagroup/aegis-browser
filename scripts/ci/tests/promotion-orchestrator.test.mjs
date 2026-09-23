import assert from 'node:assert/strict';
import {mkdtempSync, readFileSync, rmSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import {join, resolve} from 'node:path';
import {spawnSync} from 'node:child_process';
import test from 'node:test';
import YAML from 'yaml';
import {MODE, createCandidatePull, classifyBranchRelationship, inspectOpenPromotionPulls, loadPromotionConfig,
  mirrorMain, publishCandidate, runPromotionCycle, validateActivePull} from '../promotion-orchestrator.mjs';
import {assertRemoteHeads, listPulls} from '../promotion-github.mjs';
import {buildCandidate} from '../promotion-candidate.mjs';

const root = resolve(import.meta.dirname, '../../..');
const config = {personalRepo:'quinn521/aegis-browser',upstreamRepo:'gcsagroup/aegis-browser',readToken:'read',forkToken:'fork',upstreamToken:'upstream'};
const B = 'a'.repeat(40), D = 'b'.repeat(40), H = 'c'.repeat(40);
const state = {state:'same',originMain:B,upstreamMain:B,develop:D};
const candidate = buildCandidate('promotion',D,B,()=>true);
function operations(overrides={}) {
  return {refresh:async()=>state,inventory:async()=>null,validateActive:async()=>true,
    mirror:async()=>{throw new Error('unexpected mirror');},green:async()=>true,
    ancestor:()=>true,sameTree:()=>false,create:async()=>{},assertHeads:async()=>{},log:()=>{},...overrides};
}
function pull(branch=candidate.branch, head=H) {
  return {number:12,head:{ref:branch,sha:head,repo:{full_name:config.personalRepo}},
    base:{ref:'main',sha:B,repo:{full_name:config.upstreamRepo}}};
}

test('v2 controller rejects old mode, main, other repositories and untrusted events',()=>{
  const env={GITHUB_REPOSITORY:config.personalRepo,GITHUB_REF:'refs/heads/develop',GITHUB_EVENT_NAME:'push',
    AEGIS_PROMOTION_AUTOMATION:MODE,GH_TOKEN:'read',AEGIS_FORK_AUTOMATION_TOKEN:'fork',AEGIS_UPSTREAM_TOKEN:'upstream'};
  assert.deepEqual(loadPromotionConfig(env),config);
  for (const [key,value] of [['GITHUB_REF','refs/heads/main'],['GITHUB_REPOSITORY',config.upstreamRepo],
    ['GITHUB_EVENT_NAME','pull_request_target'],['AEGIS_PROMOTION_AUTOMATION','enabled'],['GH_TOKEN','']]) {
    assert.throws(()=>loadPromotionConfig({...env,[key]:value}));
  }
});

test('mirror equality is commit identity, never README/product similarity',()=>{
  assert.equal(classifyBranchRelationship({originMain:B,upstreamMain:B}),'same');
  assert.equal(classifyBranchRelationship({originMain:B,upstreamMain:D,originMainAncestor:true}),'origin-behind');
  assert.equal(classifyBranchRelationship({originMain:D,upstreamMain:B,upstreamMainAncestor:true}),'origin-ahead');
  assert.equal(classifyBranchRelationship({originMain:B,upstreamMain:D}),'diverged');
});

test('any existing fork upstream PR blocks a second batch, including legacy/manual PRs',()=>{
  for (const branch of ['main','automation/export-legacy','manual-feature',candidate.branch]) {
    assert.equal(inspectOpenPromotionPulls({...config,personalOpen:[],upstreamOpen:[pull(branch)]}).pr.number,12);
  }
  const dev={...pull('codex/feature'),base:{ref:'develop'}};
  assert.equal(inspectOpenPromotionPulls({...config,personalOpen:[dev],upstreamOpen:[]}),null);
  assert.throws(()=>inspectOpenPromotionPulls({...config,personalOpen:[{...dev,base:{ref:'main'}}],upstreamOpen:[pull()]}),/Multiple/u);
});

test('active candidate accepts descendant fix independently of moving develop; rejects rewrites and auto-merge',async()=>{
  const active={repo:config.upstreamRepo,pr:pull()};
  const deps={fetchBranch:()=>H,isAncestor:(source,head)=>[D,B].includes(source)&&head===H,assertHeads:async()=>{}};
  assert.equal(await validateActivePull(active,config,deps),true);
  await assert.rejects(validateActivePull({...active,pr:{...active.pr,auto_merge:{}}},config,deps),/auto-merge/u);
  await assert.rejects(validateActivePull(active,config,{...deps,isAncestor:()=>false}),/frozen source/u);
  await assert.rejects(validateActivePull(active,config,{...deps,fetchBranch:()=>D}),/changed/u);
  assert.equal(await validateActivePull({repo:config.upstreamRepo,pr:pull('automation/export-legacy')},config,deps),false);
});

test('existing review batch never causes branch writes even during legacy main-ahead migration',async()=>{
  assert.equal(await runPromotionCycle(config,operations({refresh:async()=>({...state,state:'origin-ahead'}),
    inventory:async()=>({repo:config.upstreamRepo,pr:pull('automation/export-legacy')}),
    create:async()=>{throw new Error('must not write');}})),'waiting');
});

test('ahead/diverged main fails closed without deleting or rewriting personal commits',async()=>{
  for (const relationship of ['origin-ahead','diverged']) {
    await assert.rejects(runPromotionCycle(config,operations({refresh:async()=>({...state,state:relationship})})),/not a mirror/u);
  }
});

test('mirror precedes CI; a failed upstream run cannot redefine what main mirrors',async()=>{
  let mirrored=false;
  assert.equal(await runPromotionCycle(config,operations({refresh:async()=>({...state,state:'origin-behind'}),
    mirror:async()=>{mirrored=true;},green:async()=>{throw new Error('must not require CI before mirror');}})),'mirrored');
  assert.equal(mirrored,true);
});

test('backflow precedes new promotion and carries actual upstream source without squash',async()=>{
  let actual;
  assert.equal(await runPromotionCycle(config,operations({ancestor:()=>false,create:async(c,s,batch)=>{actual=batch;}})),'backflow');
  assert.equal(actual.source,B); assert.equal(actual.base,D); assert.equal(actual.kind,'backflow');
});

test('promotion uses frozen develop directly and verifies both upstream and develop push runs',async()=>{
  const calls=[];
  assert.equal(await runPromotionCycle(config,operations({green:async(...args)=>{calls.push(args.slice(0,3));return true;},
    create:async(c,s,batch)=>{assert.deepEqual(batch,candidate);}})),'promotion');
  assert.deepEqual(calls,[[config.upstreamRepo,'main',B],[config.personalRepo,'develop',D]]);
});

test('pending/failed quality, unchanged trees and remote drift cannot publish a batch',async()=>{
  const never=async()=>{throw new Error('must not publish');};
  assert.equal(await runPromotionCycle(config,operations({green:async()=>false,create:never})),'waiting-quality');
  assert.equal(await runPromotionCycle(config,operations({sameTree:()=>true,create:never})),'idle');
  await assert.rejects(runPromotionCycle(config,operations({assertHeads:async()=>{throw new Error('drift');},create:never})),/drift/u);
  await assert.rejects(runPromotionCycle(config,operations({green:async()=>{throw new Error('failed');},create:never})),/failed/u);
});

test('publication creates only a ref and safely reuses appended fixes without PATCH or force',async()=>{
  for (const existing of [null,H]) {
    const writes=[];const expected=existing??D;
    const head=await publishCandidate(config,candidate,state,{assertHeads:async()=>{},remoteBranch:async()=>existing,
      fetchBranch:()=>expected,isAncestor:()=>true,api:async(repo,path,args)=>{writes.push({path,...args});}});
    assert.equal(head,expected);
    assert.deepEqual(writes.map(x=>[x.method,x.path]),existing?[]:[['POST','/git/refs']]);
  }
  await assert.rejects(publishCandidate(config,candidate,state,{assertHeads:async()=>{},remoteBranch:async()=>null,
    api:async()=>{throw new Error('ref collision');}}),/collision/u);
});

test('publication rejects fetched-head races and source movement',async()=>{
  await assert.rejects(publishCandidate(config,candidate,state,{assertHeads:async()=>{},remoteBranch:async()=>H,fetchBranch:()=>D}),/changed/u);
  await assert.rejects(assertRemoteHeads([{repo:config.personalRepo,branch:'develop',sha:D}],async()=>({object:{sha:H}})),/Remote changed/u);
});

function mirrorApi({locked=true,mergeType='fast-forward',different=false}={}) {
  const writes=[];
  const api=async(repo,path,args)=>{
    if(path==='')return {parent:{full_name:config.upstreamRepo}};
    if(path==='/branches/main/protection')return {lock_branch:{enabled:locked},allow_fork_syncing:{enabled:true},enforce_admins:{enabled:true}};
    if(path==='/merge-upstream'){writes.push(args);return {merge_type:mergeType};}
    if(path==='/git/ref/heads/main')return {object:{sha:different&&repo===config.personalRepo?D:B}};
    throw new Error(`Unexpected ${path}`);
  };
  return {api,writes,assertHeads:async()=>{}};
}

test('mirror only invokes upstream sync on an enforced locked branch and verifies equality',async()=>{
  const deps=mirrorApi();
  assert.equal(await mirrorMain(config,{...state,state:'origin-behind'},deps),B);
  assert.deepEqual(deps.writes,[{token:'fork',method:'POST',body:{branch:'main'}}]);
  for (const options of [{locked:false},{mergeType:'merge'},{different:true}]) {
    await assert.rejects(mirrorMain(config,{...state,state:'origin-behind'},mirrorApi(options)));
  }
});

test('open PR inventory follows pagination rather than overlooking an older active batch',async()=>{
  const seen=[];
  const all=await listPulls(config.personalRepo,'token','state=open',async(repo,path)=>{
    seen.push(path);return path.endsWith('page=1')?Array(100).fill({number:1}):[{number:22}];
  });
  assert.equal(all.length,101);assert.equal(seen.length,2);assert.equal(all.at(-1).number,22);
});

test('workflow validator rejects old enablement, main/PR triggers and write-token contexts',()=>{
  const original=YAML.parse(readFileSync(join(root,'.github/workflows/promotion-orchestrator.yml'),'utf8'));
  const dir=mkdtempSync(join(tmpdir(),'aegis-workflow-'));
  try {
    const validate=(workflow)=>{
      const path=join(dir,'workflow.yml');writeFileSync(path,YAML.stringify(workflow));
      return spawnSync(process.execPath,[join(root,'scripts/ci/validate-promotion-workflow.mjs'),path],{cwd:root,encoding:'utf8'});
    };
    assert.equal(validate(original).status,0);
    for (const mutate of [w=>w.on.push.branches.push('main'),w=>{w.on.pull_request={};},
      w=>{w.jobs.promote.if="${{ vars.AEGIS_PROMOTION_AUTOMATION == 'enabled' }}";},
      w=>{w.permissions.contents='write';},w=>{w.jobs.promote.steps[0].with['persist-credentials']=true;}]) {
      const changed=structuredClone(original);mutate(changed);assert.notEqual(validate(changed).status,0);
    }
  } finally {rmSync(dir,{recursive:true,force:true});}
});

function creationDependencies(overrides = {}) {
  let inventories = 0;
  const pr = pull(candidate.branch, D);
  return {listPulls: async () => [], publish: async () => D,
    git: () => 'feat(core): frozen product batch', command: () => {}, assertHeads: async () => {},
    inventory: async () => ++inventories < 3 ? null : {repo: config.upstreamRepo, pr},
    api: async () => pr, log: () => {}, ...overrides};
}

for (const kind of ['promotion', 'backflow']) {
  test(`actual ${kind} PR creation requests Draft in the destination repository`, async () => {
    const promotion = kind === 'promotion';
    const selected = promotion ? candidate : buildCandidate(kind, B, D);
    const repo = promotion ? config.upstreamRepo : config.personalRepo;
    const base = promotion ? 'main' : 'develop';
    const pr = {number: 12, head: {ref: selected.branch, sha: selected.source,
      repo: {full_name: config.personalRepo}},
    base: {ref: base, sha: selected.base, repo: {full_name: repo}}};
    const writes = [];
    await createCandidatePull(config, state, selected, creationDependencies({
      publish: async () => selected.source,
      inventory: async () => writes.length ? {repo, pr} : null,
      api: async (destination, path, args) => {writes.push({destination, path, ...args}); return pr;},
    }));
    assert.equal(writes.length, 1);
    assert.equal(writes[0].destination, repo);
    assert.equal(writes[0].path, '/pulls');
    assert.equal(writes[0].method, 'POST');
    assert.equal(writes[0].body.base, base);
    assert.equal(writes[0].body.head, `quinn521:${selected.branch}`);
    assert.equal(writes[0].body.draft, true);
  });
}

test('actual PR creation rechecks external writers after preparation before POST', async () => {
  let competing = false, posts = 0;
  await assert.rejects(createCandidatePull(config, state, candidate, creationDependencies({
    publish: async () => {competing = true; return D;},
    inventory: async () => competing ? {repo: config.upstreamRepo, pr: pull('manual-promotion')} : null,
    api: async () => {posts++; return pull();},
  })), /before PR creation/u);
  assert.equal(posts, 0);
});

test('actual PR creation detects an external writer racing POST without mutating either PR', async () => {
  let posted = false; const writes = [];
  await assert.rejects(createCandidatePull(config, state, candidate, creationDependencies({
    api: async (repo, path, args) => {posted = true; writes.push([path, args.method]); return pull(candidate.branch, D);},
    inventory: async () => {
      if (posted) return inspectOpenPromotionPulls({...config, personalOpen: [],
        upstreamOpen: [pull(candidate.branch, D), {...pull('manual-promotion'), number: 13}]});
      return null;
    },
  })), /Multiple/u);
  assert.deepEqual(writes, [['/pulls', 'POST']]);
});

test('actual PR creation verifies its single active path and refuses closed batches or moved heads', async () => {
  await createCandidatePull(config, state, candidate, creationDependencies());
  await assert.rejects(createCandidatePull(config, state, candidate, creationDependencies({
    listPulls: async () => [{state: 'closed'}],
    api: async () => {throw new Error('unexpected write');},
  })), /Existing\/closed/u);
  await assert.rejects(createCandidatePull(config, state, candidate, creationDependencies({
    api: async () => pull(candidate.branch, H),
  })), /identity/u);
});
