// 测试真实产品函数和权重；预期结果由原始 PyTorch / MobileBERT 实现独立产生。
import assert from 'node:assert/strict';
import {existsSync, readFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {createHash, webcrypto} from 'node:crypto';
import vm from 'node:vm';

const root = new URL('../overlay/chrome/browser/resources/aegis_agent/local_ai/', import.meta.url);
const read = name => readFileSync(new URL(name, root), 'utf8');
const assets = JSON.parse(read('asset_manifest.json'));
for (const [name, expected] of Object.entries(assets.files)) {
  const bytes = readFileSync(new URL(name, root));
  assert.equal(bytes.length, expected.bytes, `${name} 资源大小必须与清单一致`);
  assert.equal(createHash('sha256').update(bytes).digest('hex'), expected.sha256,
      `${name} 资源摘要必须与清单一致`);
}
console.log(`本地 AI 资源清单校验通过：${Object.keys(assets.files).length} 项大小与 SHA-256 一致。`);
const context = vm.createContext({console, TextEncoder, TextDecoder, crypto: webcrypto, URL});
context.self = context;
vm.runInContext(read('vendor/md5.js'), context);
vm.runInContext(read('research.js').replace("import './vendor/md5.js';", '')
    .replaceAll('import.meta.url', JSON.stringify(root.href)).replaceAll('export ', ''), context);
const fixture = JSON.parse(readFileSync(new URL('./testdata/local-ai-parity.json', import.meta.url)));
const manifest = JSON.parse(read('research_manifest.json'));
const hasResearchAssets = ['minim-mlp.json', 'phishlang.onnx', 'phishlang-vocab.txt']
    .every(name => existsSync(new URL(name, root)));
if (hasResearchAssets) {
  const vocab = new Map(read('phishlang-vocab.txt').trimEnd().split('\n').map((word, i) => [word, i]));
  for (const row of fixture.tokenizer) {
    assert.deepEqual(Array.from(context.tokenize(row.text, vocab)), row.ids, row.text);
  }
  const scores = context.minimScores(JSON.parse(read('minim-mlp.json')), fixture.minim.paragraphs, fixture.minim.goal);
  scores.forEach((score, i) => {
    assert.ok(Math.abs(score.sensitivity - fixture.minim.sensitivity[i]) < 1e-5);
    assert.ok(Math.abs(score.necessity - fixture.minim.necessity[i]) < 1e-5);
  });
  for (const [name, hash] of [['minim-mlp.json', manifest.minim.weights_sha256], ['phishlang.onnx', manifest.phishlang.onnx_sha256]]) {
    assert.equal(createHash('sha256').update(readFileSync(new URL(name, root))).digest('hex'), hash);
  }
  assert.ok(readFileSync(fileURLToPath(new URL('phishlang.onnx', root))).length < 50 * 1024 * 1024);
  console.log(`本地实验资产对照通过：${fixture.tokenizer.length} 个分词样例、${scores.length} 个真实 MINIM 评分。`);
} else {
  assert.equal(manifest.minim.bundled, false);
  assert.equal(manifest.phishlang.bundled, false);
  const vocab = new Map([['[UNK]', 0], ['[CLS]', 1], ['hello', 2], ['world', 3], ['##s', 4], ['!', 5], ['中', 6]]);
  assert.deepEqual(Array.from(context.tokenize('[CLS] Héllo worlds! 中 unknown', vocab)), [1, 2, 3, 4, 5, 6, 0]);
  let fetches = 0;
  context.fetch = async url => {
    assert.equal(new URL(url).pathname.split('/').at(-1), 'research_manifest.json');
    ++fetches;
    return {ok: true, arrayBuffer: async () => new TextEncoder().encode(JSON.stringify(manifest)).buffer};
  };
  for (const [minim, phishlang] of [[true, false], [false, true], [true, true]]) {
    await assert.rejects(context.analyze({paragraphs: ['普通正文'], minim, phishlang, goal: '阅读'}, () => assert.fail('不能开始推理')),
        /research_model_not_distributed/);
  }
  assert.equal(fetches, 3, '缺少许可的公开版本只能读取清单，不能加载模型');
  console.log('公开源码分词及缺失模型拒绝回归通过；未运行真实实验权重对照。');
}
const worker = read('worker.js');
const split = worker.slice(worker.indexOf('export function splitText'), worker.indexOf('async function execute'));
vm.runInContext(split.replace('export ', ''), context);
for (const text of ['短文', '😀'.repeat(1700), 'This is a sentence. '.repeat(130), '汉字'.repeat(4096)]) {
  const pieces = context.splitText(text);
  assert.equal(pieces.join(''), text, '分段不得丢字、截断代理对或漏掉尾段');
  assert.ok(pieces.every(piece => Array.from(piece).length <= 800));
}
assert.deepEqual(Array.from(context.splitText('The size is 12.5 MB. Do not close this window.')),
    ['The size is 12.5 MB. ', 'Do not close this window.']);
assert.deepEqual(Array.from(context.splitText('Dr. Smith paid 12.5 USD on 2026-10-13. Please wait.')),
    ['Dr. Smith paid 12.5 USD on 2026-10-13. ', 'Please wait.']);
assert.deepEqual(Array.from(context.splitText('文件为12.5 MB。请勿关闭窗口。', 800, 'zh')),
    ['文件为12.5 MB。', '请勿关闭窗口。']);
for (const text of ['Version 1.2.3 is ready.', 'Meet at 9:30 a.m. tomorrow.', 'https://example.org/a.b is unchanged.']) {
  assert.deepEqual(Array.from(context.splitText(text)), [text], '小数、时间、版本和网址不拆成独立短句');
}
assert.equal(context.splitText('').length, 0);
assert.throws(() => context.splitText('x', 0), /invalid_input/);
console.log('本机翻译无损分段回归通过。');

// 代码与链接的保护标记必须逐一保留，不能接受丢失、重复或被模型改写的标记。
const protectedInput = 'Read https://aegis.invalid/docs and keep `const n = 12;` unchanged.';
const pair = [{from: 'en', to: 'zh'}];
const echo = {translate: ({texts}) => [{target: {text: texts[0].text}}]};
assert.equal(context.translateParagraph(echo, pair, protectedInput), protectedInput);
for (const alter of [text => text.replace(/https:\/\/[^ ]+/, ''), text => text + ' ' + text.match(/https:\/\/[^ ]+/)[0], text => text.replaceAll('https://', 'broken://')]) {
  assert.throws(() => context.translateParagraph({translate: ({texts}) => [{target: {text: alter(texts[0].text)}}]}, pair, protectedInput), /translation_incomplete/);
}
const retry = {translate: ({texts}) => [{target: {text: texts[0].text.replaceAll('aegis.invalid', 'changed.invalid')}}]};
assert.equal(context.translateParagraph(retry, pair, protectedInput), protectedInput);
console.log('翻译代码和链接保护回归通过：冲突标记、有界重试、遗漏、重复和改写检测。');
