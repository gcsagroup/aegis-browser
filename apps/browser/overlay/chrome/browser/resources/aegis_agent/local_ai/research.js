// Copyright 2026 GCSA
// 实验评分只作用于阅读副本。不得把这些预测用于拦截、删除或 Agent 授权。
import './vendor/md5.js';

const hash = (text, buckets) => Number(BigInt('0x' + self.md5(text)) % BigInt(buckets));
const fetchBytes = async name => {
  const response = await fetch(new URL(name, import.meta.url));
  if (!response.ok) throw Error('research_model_missing');
  return response.arrayBuffer();
};
const sha = async bytes => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256', bytes)),
    n => n.toString(16).padStart(2, '0')).join('');

// 对齐 MobileBERT 的小写 BasicTokenizer 和 WordPiece。模型输入上限单独检查。
export function tokenize(text, vocab) {
  const cleaned = Array.from(text.replace(/(\[(?:PAD|UNK|CLS|SEP|MASK)\])/g, ' $1 ')).map(char => {
    const cp = char.codePointAt(0);
    if (cp === 0 || cp === 0xfffd || (/\p{C}/u.test(char) && !/[\t\n\r]/u.test(char))) return '';
    if (/\s|\p{Zs}/u.test(char)) return ' ';
    if ((cp >= 0x4e00 && cp <= 0x9fff) || (cp >= 0x3400 && cp <= 0x4dbf) ||
        (cp >= 0x20000 && cp <= 0x2a6df) || (cp >= 0x2a700 && cp <= 0x2b73f) ||
        (cp >= 0x2b740 && cp <= 0x2b81f) || (cp >= 0x2b820 && cp <= 0x2ceaf) ||
        (cp >= 0xf900 && cp <= 0xfaff) || (cp >= 0x2f800 && cp <= 0x2fa1f)) return ' ' + char + ' ';
    return char;
  }).join('');
  const ids = [];
  for (const word of cleaned.trim().split(/\s+/u).filter(Boolean)) {
    if (['[UNK]', '[SEP]', '[PAD]', '[CLS]', '[MASK]'].includes(word)) { ids.push(vocab.get(word)); continue; }
    const tokens = word.toLowerCase().normalize('NFD').replace(/\p{Mn}/gu, '')
        .replace(/([\p{P}!"#$%&'()*+,\-./:;<=>?@[\\\]^_`{|}~])/gu, ' $1 ').split(/\s+/u).filter(Boolean);
    for (const token of tokens) {
      const chars = Array.from(token), parts = [];
      if (chars.length > 100) { ids.push(vocab.get('[UNK]')); continue; }
      let start = 0;
      while (start < chars.length) {
        let end = chars.length, found;
        while (end > start) {
          const piece = (start ? '##' : '') + chars.slice(start, end).join('');
          if (vocab.has(piece)) { found = vocab.get(piece); break; }
          --end;
        }
        if (found === undefined) { parts.length = 0; parts.push(vocab.get('[UNK]')); break; }
        parts.push(found); start = end;
      }
      ids.push(...parts);
    }
  }
  return ids;
}
function dense(input, weights, bias, relu) {
  return weights.map((row, i) => {
    let value = bias[i];
    for (let j = 0; j < row.length; ++j) value += row[j] * input[j];
    return relu ? Math.max(0, value) : value;
  });
}
export function minimScores(weights, paragraphs, goal) {
  // 阅读段落视作同层静态文本节点，不能冒充原网页完整 AX 树。
  return paragraphs.map((paragraph, index) => {
    const tokens = paragraph.toLowerCase().match(/[\p{L}\p{N}]+/gu) || [];
    const bow = Array(128).fill(0);
    for (const token of tokens) bow[hash(token, 128)] += 1 / Math.max(1, tokens.length);
    let vector = [...weights['role_emb.weight'][hash('statictext', 256)],
      ...weights['goal_emb.weight'][hash(goal, 128)], ...bow, 0, 0, 0, 0];
    for (const layer of [0, 2, 4]) vector = dense(vector, weights['mlp.' + layer + '.weight'], weights['mlp.' + layer + '.bias'], layer !== 4);
    const sensitivity = 10 / (1 + Math.exp(-vector[0] / Math.max(.1, weights.temp_s)));
    const necessity = 10 / (1 + Math.exp(-vector[1] / Math.max(.1, weights.temp_n)));
    return {index, sensitivity, necessity, recommendation: necessity < 1 ? 'remove' : sensitivity >= 5 ? 'abstract' : 'keep'};
  });
}
export async function analyze(request, progress) {
  const {paragraphs, minim, phishlang, goal} = request;
  if ((!minim && !phishlang) || !Array.isArray(paragraphs) || paragraphs.length > 128 ||
      paragraphs.some(p => typeof p !== 'string') || new TextEncoder().encode(paragraphs.join('\n')).length > 32768 ||
      typeof goal !== 'string' || goal.length > 128) throw Error('invalid_input');
  const manifest = JSON.parse(new TextDecoder().decode(await fetchBytes('./research_manifest.json'))), result = {};
  // 公开源码不附带许可尚未明确的实验权重，必须在加载前明确拒绝。
  if ((minim && manifest.minim.bundled === false) ||
      (phishlang && manifest.phishlang.bundled === false)) throw Error('research_model_not_distributed');
  if (minim) {
    progress('research:MINIM');
    const bytes = await fetchBytes('./minim-mlp.json');
    if (await sha(bytes) !== manifest.minim.weights_sha256) throw Error('research_model_corrupt');
    result.minim = minimScores(JSON.parse(new TextDecoder().decode(bytes)), paragraphs, goal);
  }
  if (phishlang) {
    progress('research:PhishLang');
    const ort = await import('./vendor/ort.js');
    ort.env.wasm.numThreads = 1;
    ort.env.wasm.proxy = false;
    ort.env.wasm.wasmPaths = {
      mjs: new URL('./vendor/ort-wasm-simd-threaded.js', import.meta.url),
      wasm: new URL('./vendor/ort-wasm-simd-threaded.wasm', import.meta.url),
    };
    const bytes = await fetchBytes('./phishlang.onnx');
    if (await sha(bytes) !== manifest.phishlang.onnx_sha256) throw Error('research_model_corrupt');
    const vocab = new Map(new TextDecoder().decode(await fetchBytes('./phishlang-vocab.txt')).trimEnd().split('\n').map((word, i) => [word, i]));
    // 只分析当前已展示的段落，未收集隐藏 DOM、脚本、表单值或其他标签页。
    const text = paragraphs.map(p => 'P: { "text": "' + p.toLowerCase() + '" }').join(' ');
    const ids = tokenize(text, vocab);
    if (!ids.length || ids.length > 8192) throw Error('research_text_too_long');
    const session = await ort.InferenceSession.create(bytes, {executionProviders: ['wasm'], graphOptimizationLevel: 'all'});
    let score = 0, windows = 0;
    await (async () => {
      for (let offset = 0; offset < ids.length; offset += 64) {
        const values = [101, ...ids.slice(offset, offset + 126), 102], size = values.length;
        while (values.length < 128) values.push(0);
        const output = await session.run({
          input_ids: new ort.Tensor('int64', BigInt64Array.from(values.map(BigInt)), [1, 128]),
          attention_mask: new ort.Tensor('int64', BigInt64Array.from(values.map((_, i) => i < size ? 1n : 0n)), [1, 128]),
          token_type_ids: new ort.Tensor('int64', new BigInt64Array(128), [1, 128]),
        });
        const [a, b] = output.logits.data;
        score = Math.max(score, 1 / (1 + Math.exp(a - b))); ++windows;
        Object.values(output).forEach(tensor => tensor.dispose());
        progress('research:PhishLang ' + Math.min(offset + 126, ids.length) + '/' + ids.length);
        if (offset + 126 >= ids.length) break;
      }
    })().finally(async () => { await session.release(); });
    result.phishlang = {score, windows, tokens: ids.length, flagged: score > .5};
  }
  return result;
}
