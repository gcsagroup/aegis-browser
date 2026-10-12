// 使用产品中的真实 Bergamot/WASM 跑离线语料。只提供文件读取适配，不代替 WebUI 实机验收。
import fs from 'node:fs/promises';
import path from 'node:path';
import {pathToFileURL} from 'node:url';
import {createHash} from 'node:crypto';
import {performance} from 'node:perf_hooks';

const args = Object.fromEntries(process.argv.slice(2).map(arg => {
  const at = arg.indexOf('=');
  if (!arg.startsWith('--') || at < 0) throw Error('参数使用 --名称=值');
  return [arg.slice(2, at), arg.slice(at + 1)];
}));
const required = ['assets', 'models', 'corpus', 'output'];
for (const key of required) if (!args[key]) throw Error('缺少参数：' + key);
const selectedSplit = args.split || 'development';
const family = args.family || 'current';
const segmentation = args.segmentation || 'baseline';
const beam = Number(args.beam || 1);
if (!['development', 'holdout', 'all'].includes(selectedSplit) ||
    !['current', 'mozilla-alternative'].includes(family) ||
    !['baseline', 'sentence', 'sentence-pack', 'product'].includes(segmentation) || ![1, 2, 4].includes(beam)) throw Error('不支持的实验参数');
const assetRoot = path.resolve(args.assets), modelRoot = path.resolve(args.models);
const corpusRoot = path.resolve(args.corpus);
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const freeze = JSON.parse(await fs.readFile(path.join(corpusRoot, 'freeze-v1.json')));
let cases = [];
for (const name of ['short-v1.json', 'long-v1.json']) {
  const bytes = await fs.readFile(path.join(corpusRoot, name));
  if (sha(bytes) !== freeze.files[name]) throw Error('语料冻结摘要不匹配：' + name);
  cases.push(...JSON.parse(bytes).cases);
}
cases = cases.filter(row => selectedSplit === 'all' || row.split === selectedSplit);
if (args.only) cases = cases.filter(row => row.id.includes(args.only));
if (!cases.length) throw Error('没有匹配的样本');

// CLI 适配限于本地 WASM 读取；评测推理没有网络回退。
globalThis.self = globalThis;
globalThis.fetch = async input => {
  const url = new URL(input);
  if (url.protocol !== 'file:') throw Error('评测禁止访问网络');
  return new Response(await fs.readFile(url), {headers: {'Content-Type': 'application/wasm'}});
};
const {splitText: baselineSplit} = await import(pathToFileURL(path.join(assetRoot, 'worker.js')));
const {BergamotTranslatorWorker} = await import(pathToFileURL(path.join(assetRoot, 'bergamot/worker/translator-worker.js')));
function split(text, language) {
  if (segmentation === 'product') return baselineSplit(text, 800, language);
  if (segmentation === 'baseline') return baselineSplit(text);
  const sentences = [...new Intl.Segmenter(language, {granularity: 'sentence'}).segment(text)].map(x => x.segment);
  const pieces = sentences.flatMap(sentence => baselineSplit(sentence));
  if (segmentation === 'sentence') return pieces;
  const packed = [];
  for (const piece of pieces) {
    if (packed.length && Array.from(packed.at(-1) + piece).length <= 800) packed[packed.length - 1] += piece;
    else packed.push(piece);
  }
  return packed;
}
const engine = new BergamotTranslatorWorker();
const initStart = performance.now(); await engine.initialize({});
const report = {schema: 1, family, beam, segmentation, split: selectedSplit,
  scope: '产品 WASM 的本机 CLI 对照；不代表浏览器安装或发布验收',
  corpusHashes: freeze.files, node: process.version, architecture: process.arch,
  workerHash: sha(await fs.readFile(path.join(assetRoot, 'worker.js'))),
  initialization_ms: performance.now() - initStart, model_loads: [], results: []};
const baselineManifest = JSON.parse(await fs.readFile(path.join(assetRoot, 'translation_manifest.json')));
await fs.mkdir(path.dirname(path.resolve(args.output)), {recursive: true});
const started = performance.now();
for (const direction of ['en-zh', 'zh-en']) {
  if (!cases.some(row => row.direction === direction)) continue;
  const [from, to] = direction.split('-');
  const parts = {}, hashes = {};
  if (family === 'current') {
    for (const row of baselineManifest.filter(row => row.sourceLanguage === (from === 'zh' ? 'zh-Hans' : from))) {
      const data = await fs.readFile(path.join(modelRoot, 'current', row.name));
      if (sha(data) !== row.decompressedHash) throw Error('基线模型摘要不匹配：' + row.name);
      parts[row.fileType] = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength);
      hashes[row.fileType] = sha(data);
    }
  } else {
    const id = direction === 'en-zh' ? 'mozilla-en-zh-base' : 'mozilla-zh-en-base-memory';
    const desc = JSON.parse(await fs.readFile(path.join(modelRoot, id, 'descriptor.json')));
    const map = {model:'model', lexicalShortlist:'lex', srcVocab:'srcvocab', trgVocab:'trgvocab', vocab:'vocab'};
    for (const [kind, file] of Object.entries(desc.files)) {
      const data = await fs.readFile(file); parts[map[kind]] = data.buffer.slice(data.byteOffset, data.byteOffset + data.byteLength); hashes[kind] = sha(data);
    }
  }
  const before = performance.now();
  engine.loadTranslationModel({from, to}, {model: parts.model, shortlist: parts.lex,
    vocabs: parts.vocab ? [parts.vocab] : [parts.srcvocab, parts.trgvocab], qualityModel: null,
    config: {'beam-size': beam, 'skip-cost': beam === 1}});
  report.model_loads.push({direction, milliseconds: performance.now() - before, hashes});
  for (const row of cases.filter(row => row.direction === direction)) {
    const t = performance.now(), translations = [];
    let chunks = 0, error = null;
    try {
      for (const paragraph of row.paragraphs) {
        const pieces = [];
        for (const text of split(paragraph, from)) {
          ++chunks;
          const [output] = engine.translate({models: [{from, to}], texts: [{text, html: false, qualityScores: false}]});
          if (!output?.target?.text?.trim()) throw Error('空译文');
          pieces.push(output.target.text);
        }
        translations.push(pieces.join(to === 'zh' ? '' : ' '));
      }
    } catch (e) { error = String(e); }
    report.results.push({id:row.id, category:row.category, direction, split:row.split,
      translations, error, chunks, elapsed_ms:performance.now()-t,
      source_bytes:Buffer.byteLength(row.paragraphs.join('\n')), rss_bytes:process.memoryUsage().rss});
    await fs.writeFile(args.output, JSON.stringify(report, null, 2) + '\n');
    if (report.results.length % 20 === 0) console.log(JSON.stringify({completed:report.results.length, total:cases.length, last:row.id}));
  }
  engine.freeTranslationModel({from, to});
}
engine.service.delete();
report.elapsed_ms = performance.now() - started;
report.max_rss_bytes = process.resourceUsage().maxRSS * 1024;
report.complete = true;
await fs.writeFile(args.output, JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify({complete:true, count:report.results.length, errors:report.results.filter(x=>x.error).length, elapsed_ms:report.elapsed_ms, max_rss_bytes:report.max_rss_bytes}));
