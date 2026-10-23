// 浏览器内的真实 IndexedDB 验收页。运行后打开打印出的本机地址；只使用合成文件。
import http from 'node:http';
import fs from 'node:fs/promises';
import {createHash} from 'node:crypto';
import {spawnSync} from 'node:child_process';
const root = new URL('../overlay/chrome/browser/resources/aegis_agent/local_ai/', import.meta.url);
const digest = bytes => createHash('sha256').update(bytes).digest('hex');
const assets = new Map();
const rows = version => ['fr', 'de'].flatMap(targetLanguage => ['model', 'lex', 'vocab'].map(fileType => {
  const name = fileType === 'vocab' ? 'shared-vocab' : targetLanguage + '-' + fileType + '-' + version;
  const bytes = Buffer.from(name + '\n' + '这是存储与故障恢复测试文件，不用于推理。'.repeat(12));
  const compressed = spawnSync('zstd', ['-q', '-c'], {input: bytes});
  if (compressed.status !== 0) throw Error('需要 zstd 命令来生成合成测试文件');
  assets.set(name, compressed.stdout);
  return {sourceLanguage: 'en', targetLanguage, fileType, version: String(version),
    decompressedSize: bytes.length, decompressedHash: digest(bytes),
    attachment: {location: name, size: compressed.stdout.length, hash: digest(compressed.stdout)}};
}));
const manifests = new Map([[1, rows(1)], [2, rows(2)]]);
let version = 1, fault = '', report;
const browserTest = `
const results = [];
const check = (condition, name) => { if (!condition) throw Error(name); results.push(name); };
async function control(value) { await fetch('/control?' + new URLSearchParams(value)); }
function operation(request, inject = '') {
  const worker = new Worker('/fixture-worker.mjs', {type: 'module'});
  let resolve, reject; const done = new Promise((a,b) => {resolve=a; reject=b;});
  worker.onmessage = ({data}) => { if (data.progress) return; worker.terminate(); data.error ? reject(Error(data.error)) : resolve(data.result); };
  worker.onerror = event => {worker.terminate(); reject(Error(event.message));};
  worker.postMessage({...request, inject, downloadJob: crypto.randomUUID()});
  return {done, worker};
}
const run = (request, inject) => operation(request, inject).done;
const ready = () => run({op:'status',direction:'en-fr'});
async function reject(request, inject, pattern) { try { await run(request, inject); throw Error('应拒绝'); } catch(error) { check(pattern.test(error.message), '故障已拒绝：' + error.message); } }
async function probeWorker(url, name) {
  const worker = new Worker(url);
  try {
    await new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(Error(name + ' 启动超时')), 5000);
      worker.onmessage = ({data}) => { clearTimeout(timer); data === 'ready' ? resolve() : reject(Error(name)); };
      worker.onerror = () => { clearTimeout(timer); reject(Error(name + ' 启动失败')); };
    });
    check(true, name + ' 正常启动');
  } finally { worker.terminate(); }
}
try {
  await probeWorker('/probe-worker.js', '普通 Worker');
  const blob = URL.createObjectURL(new Blob(['postMessage("ready")'], {type:'text/javascript'}));
  try { await probeWorker(blob, 'Blob Worker'); } finally { URL.revokeObjectURL(blob); }
  await control({version:1,fault:''});
  await new Promise((resolve,reject) => { const r=indexedDB.deleteDatabase('aegis-local-translation-v1'); r.onsuccess=resolve; r.onerror=reject; });
  check(!(await ready()).ready, '首次未安装');
  await run({op:'download',direction:'en-fr'});
  check((await ready()).ready, '完整下载后新 Worker 回读可用');
  await run({op:'download',direction:'en-de'});
  await control({version:2});
  check((await ready()).update, '新目录识别已安装旧版本');
  for (const mode of ['offline','corrupt']) {
    await control({fault:mode});
    await reject({op:'download',direction:'en-fr'}, '', /download_failed|package_corrupt/);
    const previous=await ready(); check(previous.ready && previous.update, mode + '失败后旧版可用');
  }
  await control({fault:''});
  await reject({op:'download',direction:'en-fr'}, 'quota', /storage_full/);
  check((await ready()).update, '空间不足保留旧版');
  await reject({op:'download',direction:'en-fr'}, 'abort', /storage_full/);
  check((await ready()).update, '写入中止原子回退');
  await control({fault:'slow'});
  const pending=operation({op:'download',direction:'en-fr'});
  await new Promise(resolve => setTimeout(resolve,150)); pending.worker.terminate();
  await control({fault:''});
  const cancelled=await ready(); check(cancelled.ready && cancelled.update, '终止下载不提交半套文件');
  await run({op:'download',direction:'en-fr'});
  check((await ready()).ready && !(await ready()).update, '更新成功并由新 Worker 校验');
  await run({op:'remove',direction:'en-fr'});
  check(!(await ready()).ready, '移除后不可用');
  check((await run({op:'status',direction:'en-de'})).ready, '移除不破坏其他包共用词表');
  await new Promise((resolve,reject) => { const r=indexedDB.deleteDatabase('aegis-local-translation-v1'); r.onsuccess=resolve; r.onerror=reject; });
  const report={passed:true,results}; document.body.textContent='语言包真实存储验收通过：'+results.length+' 项。\\n'+results.join('\\n');
  await fetch('/result',{method:'POST',body:JSON.stringify(report)});
} catch(error) {
  document.body.textContent='验收失败：'+error.message; await fetch('/result',{method:'POST',body:JSON.stringify({passed:false,error:error.message,results})});
}
`;
const wrapper = `import {execute} from '/local_ai/worker.js';
self.onmessage = async ({data}) => {
  if (data.inject === 'quota') Object.defineProperty(navigator, 'storage', {value:{estimate:async()=>({usage:10,quota:11})}});
  if (data.inject === 'abort') {
    const put=IDBObjectStore.prototype.put; let scheduled=false;
    IDBObjectStore.prototype.put=function(...args){ const result=put.apply(this,args); if(!scheduled){scheduled=true;queueMicrotask(()=>this.transaction.abort());} return result; };
  }
  try { self.postMessage({result:await execute(data)}); } catch(error) {self.postMessage({error:error.message});}
};`;
const server = http.createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://localhost');
    if (url.pathname === '/control') {
      if (url.searchParams.has('version')) version=Number(url.searchParams.get('version'));
      if (url.searchParams.has('fault')) fault=url.searchParams.get('fault');
      response.end('ok'); return;
    }
    if (url.pathname === '/result') {
      let body=''; for await (const bytes of request) body+=bytes;
      report=JSON.parse(body); console.log(JSON.stringify(report,null,2));
      if (process.argv[2]) await fs.writeFile(process.argv[2],JSON.stringify(report,null,2)+'\n');
      response.end('recorded'); return;
    }
    if (url.pathname === '/') {response.setHeader('Content-Type','text/html; charset=utf-8');response.end('<!doctype html><meta charset="utf-8"><title>语言包真实存储验收</title><body>正在执行合成存储测试…<script type="module" src="/test.mjs"></script>');return;}
    response.setHeader('Content-Type','text/javascript');
    if (url.pathname === '/probe-worker.js') {response.end('postMessage("ready")');return;}
    if (url.pathname === '/test.mjs') {response.end(browserTest);return;}
    if (url.pathname === '/fixture-worker.mjs') {response.end(wrapper);return;}
    if (url.pathname === '/local_ai/translation_manifest.json') {response.end(JSON.stringify(manifests.get(version)));return;}
    if (url.pathname.startsWith('/local_ai/download/')) {
      const bytes=assets.get(url.pathname.split('/').at(-1));
      if (!bytes) {response.writeHead(404);response.end();return;}
      if (fault === 'offline') {response.writeHead(503);response.end();return;}
      if (fault === 'corrupt') {response.end(Buffer.alloc(bytes.length));return;}
      if (fault === 'slow') {setTimeout(()=>response.end(bytes),2000);return;}
      response.end(bytes);return;
    }
    const relative=url.pathname.replace(/^\/local_ai\//,'');
    if (!['worker.js','catalog.js','vendor/fzstd.js'].includes(relative)) {response.writeHead(404);response.end();return;}
    response.end(await fs.readFile(new URL(relative,root)));
  } catch(error) {response.writeHead(500);response.end(error.message);}
});
server.listen(0,'127.0.0.1',()=>console.log('请用测试浏览器打开：http://127.0.0.1:'+server.address().port+'/'));
process.on('SIGINT',()=>server.close(()=>process.exit(report?.passed ? 0 : 1)));
