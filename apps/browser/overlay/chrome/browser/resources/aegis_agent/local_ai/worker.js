// Copyright 2026 GCSA
// 固定来源、摘要校验、原子保存。正文只进入本机 Worker，不参与网络请求。
import {decompress} from './vendor/fzstd.js';
import {languagePacks, routePacks} from './catalog.js';

const CDN = new URL('./download/', import.meta.url).href;
const digest = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)),
    n => n.toString(16).padStart(2, '0')).join('');
const progress = text => self.postMessage({progress: text});
const manifest = async () => (await fetch(new URL('./translation_manifest.json', import.meta.url))).json();
function openStore() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('aegis-local-translation-v1', 2);
    request.onupgradeneeded = () => {
      for (const name of ['files', 'packs']) if (!request.result.objectStoreNames.contains(name)) request.result.createObjectStore(name);
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(Error('storage_unavailable'));
  });
}
async function readEntries(name, keys) {
  const db = await openStore();
  try {
    return await Promise.all(keys.map(key => new Promise((resolve, reject) => {
      const request = db.transaction(name).objectStore(name).get(key);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(Error('storage_unavailable'));
    })));
  } finally { db.close(); }
}
async function verified(rows) {
  if (!rows.length) throw Error('package_missing_or_corrupt');
  const files = await readEntries('files', rows.map(row => row.decompressedHash));
  for (let i = 0; i < rows.length; ++i) {
    if (!(files[i] instanceof ArrayBuffer) || files[i].byteLength !== rows[i].decompressedSize ||
        await digest(files[i]) !== rows[i].decompressedHash) throw Error('package_missing_or_corrupt');
  }
  return files;
}
async function installed(pack) {
  try { return {rows: pack.rows, files: await verified(pack.rows), update: false}; } catch {}
  const [previous] = await readEntries('packs', [pack.id]);
  if (previous?.rows) {
    try { return {rows: previous.rows, files: await verified(previous.rows), update: true}; } catch (error) { if (error.message.startsWith('storage')) throw error; }
  }
  throw Error('package_missing_or_corrupt');
}
async function savePack(pack, files, remove = false) {
  const all = languagePacks(await manifest());
  const metadata = await readEntries('packs', all.map(value => value.id));
  const previous = metadata[all.findIndex(value => value.id === pack.id)];
  const shared = new Set(all.filter(value => value.id !== pack.id).flatMap(value => value.rows.map(row => row.decompressedHash)));
  metadata.forEach((value, index) => { if (all[index].id !== pack.id) value?.rows?.forEach(row => shared.add(row.decompressedHash)); });
  const db = await openStore();
  try {
    await new Promise((resolve, reject) => {
      const transaction = db.transaction(['files', 'packs'], 'readwrite');
      const store = transaction.objectStore('files');
      const keep = new Set(remove ? [] : pack.rows.map(row => row.decompressedHash));
      for (const row of [...pack.rows, ...(previous?.rows || [])]) {
        if (!keep.has(row.decompressedHash) && !shared.has(row.decompressedHash)) store.delete(row.decompressedHash);
      }
      if (remove) transaction.objectStore('packs').delete(pack.id);
      else {
        pack.rows.forEach((row, index) => store.put(files[index], row.decompressedHash));
        transaction.objectStore('packs').put({version: pack.version, rows: pack.rows}, pack.id);
      }
      transaction.oncomplete = resolve;
      transaction.onabort = transaction.onerror = () => reject(Error('storage_full'));
    });
  } finally { db.close(); }
}
async function download(pack, job) {
  if (typeof job !== 'string' || !/^[0-9a-f-]{36}$/.test(job)) throw Error('invalid_input');
  const estimate = await self.navigator?.storage?.estimate?.();
  if (estimate?.quota && estimate.quota - (estimate.usage || 0) < pack.installedBytes) throw Error('storage_full');
  const files = [], total = pack.bytes;
  let complete = 0;
  for (const row of pack.rows) {
    let response;
    try {
      response = await fetch(CDN + job + '/' + row.attachment.location, {credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error'});
    } catch { throw Error('download_failed'); }
    if (!response.ok || !response.body) throw Error('download_failed');
    const reader = response.body.getReader(), chunks = [];
    let received = 0;
    while (true) {
      const {done, value} = await reader.read();
      if (done) break;
      received += value.byteLength;
      if (received > row.attachment.size) { await reader.cancel(); throw Error('package_corrupt'); }
      chunks.push(value);
      progress('download:' + Math.floor((complete + received) * 100 / total));
    }
    const compressed = new Uint8Array(received);
    let offset = 0;
    for (const chunk of chunks) { compressed.set(chunk, offset); offset += chunk.length; }
    progress('verify:' + row.fileType);
    if (received !== row.attachment.size || await digest(compressed) !== row.attachment.hash) throw Error('package_corrupt');
    const bytes = decompress(compressed);
    if (bytes.length !== row.decompressedSize || await digest(bytes) !== row.decompressedHash) throw Error('package_corrupt');
    files.push(bytes.slice().buffer);
    complete += received;
  }
  // 新版本全部成功才与元数据一起提交；失败、断网及取消均保留旧版本。
  await savePack(pack, files);
  return {ready: true, update: false};
}
export function splitText(text, limit = 800, language = 'en') {
  if (!Number.isInteger(limit) || limit < 1) throw Error('invalid_input');
  const sentences = [], result = [];
  for (const {segment} of new Intl.Segmenter(language, {granularity: 'sentence'}).segment(text)) {
    // ICU 会将部分称谓误判为句尾；只合并边界，不修改原文或译文。
    if (sentences.length && /\b(?:Mr|Mrs|Ms|Dr|Prof|Sr|Jr|e\.g|i\.e)\.\s*$/iu.test(sentences.at(-1))) {
      sentences[sentences.length - 1] += segment;
    } else sentences.push(segment);
  }
  for (const sentence of sentences) {
    const chars = Array.from(sentence);
    while (chars.length) {
      let end = Math.min(limit, chars.length);
      if (end < chars.length) {
        for (let i = end - 1; i > limit / 2; --i) {
          // 超长单句优先在空白/分句标点处分块，不在小数点处分块。
          if (/[\s，,；;。！？!?]/u.test(chars[i])) { end = i + 1; break; }
        }
      }
      result.push(chars.splice(0, end).join(''));
    }
  }
  return result;
}
function translateWithMarkers(translator, models, paragraph, markerPrefix) {
  const from = models[0].from, to = models.at(-1).to;
  // 用保留地址中的占位网址保留句子上下文；它们只进入模型，绝不请求网络。
  // 译文必须原样保留每个标记且只出现一次，否则拒绝保存，避免代码或链接被改写。
  let prefix = markerPrefix;
  while (paragraph.includes(prefix)) prefix += '0/';
  const protectedText = [];
  const input = paragraph.replace(/(```[\s\S]*?```|`[^`\n]+`|https?:\/\/[^\s<>\])}]+)/g, text => {
    const id = protectedText.push(text) - 1;
    return prefix + id;
  });
  const pieces = [];
  for (const text of splitText(input, 800, from)) {
    if (!text.trim()) { pieces.push(text); continue; }
    const [output] = translator.translate({models, texts: [{text, html: false, qualityScores: false}]});
    if (!output.target.text.trim()) throw Error('translation_incomplete');
    pieces.push(output.target.text);
  }
  const output = pieces.join(['zh', 'ja'].includes(to) ? '' : ' ');
  const seen = Array(protectedText.length).fill(0);
  const marker = new RegExp(prefix.replace(/[.*+?^${}()|[\]\\]/g, '\\$&') + '(\\d+)\\b', 'g');
  const restored = output.replace(marker, (_, id) => {
    const index = Number(id);
    if (!Object.hasOwn(protectedText, index)) throw Error('translation_incomplete');
    ++seen[index]; return protectedText[index];
  });
  if (seen.some(count => count !== 1)) throw Error('translation_incomplete');
  return restored;
}
function translateParagraph(translator, models, paragraph) {
  // 个别模型会本地化占位网址的域名；只在完整性校验失败时用第二组标记重试。
  // 两次都失败则保留原文并报告错误，绝不提交被改写的代码或链接。
  for (const prefix of ['https://aegis.invalid/', 'https://example.com/']) {
    try { return translateWithMarkers(translator, models, paragraph, prefix); }
    catch (error) { if (error.message !== 'translation_incomplete') throw error; }
  }
  throw Error('translation_incomplete');
}
async function execute(request) {
  if (request.op === 'research') {
    const {analyze} = await import('./research.js');
    return analyze(request, progress);
  }
  const rows = await manifest();
  if (request.op === 'statuses') {
    const statuses = [];
    for (const pack of languagePacks(rows)) {
      try { const result = await installed(pack); statuses.push({id: pack.id, ready: true, update: result.update}); }
      catch (error) { if (error.message.startsWith('storage')) throw error; statuses.push({id: pack.id, ready: false, update: false}); }
    }
    return {statuses};
  }
  const packs = routePacks(rows, request.direction);
  if (request.op === 'status') {
    try { const values = await Promise.all(packs.map(installed)); return {ready: true, update: values.some(value => value.update)}; }
    catch { return {ready: false, update: false}; }
  }
  // 安装与移除按直接包操作，避免中转方向悄悄删除其他方向共用的包。
  if (['remove', 'download'].includes(request.op) && packs.length !== 1) throw Error('unsupported_language');
  if (request.op === 'remove') { await savePack(packs[0], [], true); return {ready: false}; }
  if (request.op === 'download') return download(packs[0], request.downloadJob);
  if (request.op !== 'translate' || !Array.isArray(request.paragraphs) || !request.paragraphs.length ||
      request.paragraphs.length > 128 || request.paragraphs.some(p => typeof p !== 'string') ||
      new TextEncoder().encode(request.paragraphs.join('\n')).length > 32768) throw Error('invalid_input');
  const installedPacks = await Promise.all(packs.map(installed));
  const {BergamotTranslatorWorker} = await import('./bergamot/worker/translator-worker.js');
  const translator = new BergamotTranslatorWorker();
  await translator.initialize({});
  const loaded = [];
  return await (async () => {
    for (let index = 0; index < packs.length; ++index) {
      const {rows, files} = installedPacks[index], {from, to} = packs[index];
      const parts = Object.fromEntries(rows.map((row, i) => [row.fileType, files[i]]));
      translator.loadTranslationModel({from, to}, {model: parts.model, shortlist: parts.lex,
        vocabs: parts.vocab ? [parts.vocab] : [parts.srcvocab, parts.trgvocab], qualityModel: null, config: {'beam-size': packs[index].beamSize, 'skip-cost': packs[index].beamSize === 1}});
      loaded.push({from, to});
    }
    const to = packs.at(-1).to, translations = [];
    for (const paragraph of request.paragraphs) {
      translations.push(translateParagraph(translator, loaded, paragraph));
      progress('translate:' + translations.length + '/' + request.paragraphs.length);
    }
    if (new TextEncoder().encode(translations.join('\n')).length > 65536) throw Error('translation_too_long');
    return {translations, language: to === 'zh' ? 'zh-CN' : to};
  })().finally(() => { loaded.forEach(pair => translator.freeTranslationModel(pair)); translator.service.delete(); });
}
self.onmessage = async ({data}) => {
  try { self.postMessage({result: await execute(data)}); }
  catch (error) { self.postMessage({error: error.message || 'runtime_unavailable'}); }
};

export {execute, translateParagraph};
