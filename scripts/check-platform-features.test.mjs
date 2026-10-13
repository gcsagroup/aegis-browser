import test from 'node:test';
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {validateCatalog, checkPlatformFeatures} from './check-platform-features.mjs';
const catalog = JSON.parse(readFileSync(new URL('../docs/platform-features.json', import.meta.url)));
const contract = JSON.parse(readFileSync(new URL('../apps/browser/release-feature-contract.json', import.meta.url)));

test('实际四端目录及三语页面保持同步', () => assert.deepEqual(checkPlatformFeatures(), []));
test('发布合同新增功能必须登记四端', () => {
  const expanded = {...contract, features: [...contract.features, {id: 'future-feature'}]};
  assert.ok(validateCatalog(catalog, expanded).some((message) => message.includes('future-feature')));
});
test('缺端、重复 ID、缺译文和失效源码路径均失败', () => {
  const broken = structuredClone(catalog);
  delete broken.features[0].platforms.iOS;
  broken.features[1].id = broken.features[0].id;
  delete broken.features[2].platforms.Windows.reason.en;
  broken.features[3].platforms.macOS.source = ['missing-source.cc'];
  assert.equal(validateCatalog(broken, contract).filter((message) => /缺少|重复|不存在/.test(message)).length, 4);
});
test('不能把无依据或模拟器结果当作桌面验收', () => {
  const broken = structuredClone(catalog);
  broken.features[0].platforms.iOS.validation = 'native';
  broken.features[1].platforms.Windows.validation = 'simulator';
  assert.ok(validateCatalog(broken, contract).some((message) => message.includes('没有依据')));
  assert.ok(validateCatalog(broken, contract).some((message) => message.includes('不能引用')));
});
