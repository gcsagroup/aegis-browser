// Copyright 2026 GCSA
// 固定来源、摘要校验、原子保存。正文只进入本机 Worker，不参与网络请求。
import {decompress} from './vendor/fzstd.js';

const CDN = new URL('./download/', import.meta.url).href;
const digest = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)),
    n => n.toString(16).padStart(2, '0')).join('');
const progress = text => self.postMessage({progress: text});
const manifest = async () => (await fetch(new URL('./translation_manifest.json', import.meta.url))).json();
function openStore() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open('aegis-local-translation-v1', 1);
    request.onupgradeneeded = () => request.result.createObjectStore('files');
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(Error('storage_unavailable'));
  });
}
async function readFiles(rows) {
  const db = await openStore();
  return await (async () => {
    return await Promise.all(rows.map(row => new Promise((resolve, reject) => {
      const request = db.transaction('files').objectStore('files').get(row.decompressedHash);
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => reject(Error('storage_unavailable'));
    })));
  })().finally(async () => { db.close(); });
}
async function writeFiles(rows, files, remove = false) {
  const db = await openStore();
  return await (async () => {
    await new Promise((resolve, reject) => {
      const transaction = db.transaction('files', 'readwrite');
      const store = transaction.objectStore('files');
      rows.forEach((row, i) => remove ? store.delete(row.decompressedHash) : store.put(files[i], row.decompressedHash));
      transaction.oncomplete = resolve;
      transaction.onabort = transaction.onerror = () => reject(Error('storage_full'));
    });
  })().finally(async () => { db.close(); });
}
async function verified(rows) {
  const files = await readFiles(rows);
  for (let i = 0; i < rows.length; ++i) {
    if (!(files[i] instanceof ArrayBuffer) || files[i].byteLength !== rows[i].decompressedSize ||
        await digest(files[i]) !== rows[i].decompressedHash) throw Error('package_missing_or_corrupt');
  }
  return files;
}
async function download(rows) {
  const files = [], total = rows.reduce((sum, row) => sum + row.attachment.size, 0);
  let complete = 0;
  for (const row of rows) {
    let response;
    try {
      response = await fetch(CDN + row.attachment.location, {credentials: 'omit', referrerPolicy: 'no-referrer', redirect: 'error'});
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
    if (received !== row.attachment.size || await digest(compressed) !== row.attachment.hash) throw Error('package_corrupt');
    const bytes = decompress(compressed);
    if (bytes.length !== row.decompressedSize || await digest(bytes) !== row.decompressedHash) throw Error('package_corrupt');
    files.push(bytes.slice().buffer);
    complete += received;
  }
  // 全部成功才提交；取消、断网或损坏均不留下半套可用标记。
  await writeFiles(rows, files);
  return {ready: true};
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
async function execute(request) {
  if (request.op === 'research') {
    const {analyze} = await import('./research.js');
    return analyze(request, progress);
  }
  if (!['en-zh', 'zh-en'].includes(request.direction)) throw Error('unsupported_language');
  const [from, to] = request.direction.split('-');
  const rows = (await manifest()).filter(row => row.sourceLanguage === (from === 'zh' ? 'zh-Hans' : from) &&
      row.targetLanguage === (to === 'zh' ? 'zh-Hans' : to));
  if (request.op === 'status') {
    try { await verified(rows); return {ready: true}; } catch { return {ready: false}; }
  }
  if (request.op === 'remove') { await writeFiles(rows, [], true); return {ready: false}; }
  if (request.op === 'download') return download(rows);
  if (request.op !== 'translate' || !Array.isArray(request.paragraphs) || !request.paragraphs.length ||
      request.paragraphs.length > 128 || request.paragraphs.some(p => typeof p !== 'string') ||
      new TextEncoder().encode(request.paragraphs.join('\n')).length > 32768) throw Error('invalid_input');
  const files = await verified(rows);
  const {BergamotTranslatorWorker} = await import('./bergamot/worker/translator-worker.js');
  const translator = new BergamotTranslatorWorker();
  await translator.initialize({});
  const parts = Object.fromEntries(rows.map((row, i) => [row.fileType, files[i]]));
  translator.loadTranslationModel({from, to}, {model: parts.model, shortlist: parts.lex,
    vocabs: parts.vocab ? [parts.vocab] : [parts.srcvocab, parts.trgvocab], qualityModel: null, config: {}});
  const translations = [];
  return await (async () => {
    for (const paragraph of request.paragraphs) {
      const pieces = [];
      for (const text of splitText(paragraph, 800, from)) {
        const [output] = translator.translate({models: [{from, to}], texts: [{text, html: false, qualityScores: false}]});
        if (!output.target.text.trim()) throw Error('translation_incomplete');
        pieces.push(output.target.text);
      }
      translations.push(pieces.join(to === 'zh' ? '' : ' '));
      progress('translate:' + translations.length + '/' + request.paragraphs.length);
    }
    if (new TextEncoder().encode(translations.join('\n')).length > 65536) throw Error('translation_too_long');
    return {translations, language: to === 'zh' ? 'zh-CN' : 'en'};
  })().finally(async () => { translator.freeTranslationModel({from, to}); translator.service.delete(); });
}
self.onmessage = async ({data}) => {
  try { self.postMessage({result: await execute(data)}); }
  catch (error) { self.postMessage({error: error.message || 'runtime_unavailable'}); }
};
