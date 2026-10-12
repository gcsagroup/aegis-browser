// 冻结语料的独立完整性检查；不把译文字符相似度当作准确性断言。
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {createHash} from 'node:crypto';
const root = new URL('./testdata/translation-quality/', import.meta.url);
const freeze = JSON.parse(readFileSync(new URL('freeze-v1.json', root)));
const cases = [];
for (const name of ['short-v1.json', 'long-v1.json']) {
  const raw = readFileSync(new URL(name, root));
  assert.equal(createHash('sha256').update(raw).digest('hex'), freeze.files[name]);
  cases.push(...JSON.parse(raw).cases);
}
assert.equal(cases.length, 260);
assert.equal(new Set(cases.map(row => row.id)).size, cases.length);
for (const [category, count] of Object.entries({negation: 80, title: 60, numbers: 100, long: 20})) {
  assert.equal(cases.filter(row => row.category === category).length, count);
  assert.equal(cases.filter(row => row.category === category && row.direction === 'en-zh').length, count / 2);
}
assert.equal(cases.filter(row => row.split === 'development').length, 196);
assert.equal(cases.filter(row => row.split === 'holdout').length, 64);
for (const row of cases) {
  assert.ok(['en-zh', 'zh-en'].includes(row.direction));
  assert.ok(['development', 'holdout'].includes(row.split));
  assert.ok(row.paragraphs.length > 0 && row.paragraphs.length <= 128);
  assert.ok(row.paragraphs.every(text => typeof text === 'string' && text.trim()));
  assert.ok(Buffer.byteLength(row.paragraphs.join('\n')) <= 32768, row.id);
  if (row.reference) assert.equal(row.reference.length, row.paragraphs.length);
  const related = cases.filter(other => other.family === row.family);
  assert.equal(related.length, 2, row.family);
  assert.ok(related.every(other => other.split === row.split), '同义双向语料不得跨组');
}
console.log('翻译语料冻结检查通过：240 条短文本、20 篇长文，196 开发 / 64 封存。');
