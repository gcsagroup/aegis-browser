#!/usr/bin/env node
import {existsSync, readFileSync, writeFileSync} from 'node:fs';
import {dirname, resolve, relative, isAbsolute} from 'node:path';
import {fileURLToPath} from 'node:url';

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const platforms = ['macOS', 'Windows', 'Android', 'iOS'];
const languages = ['zh-CN', 'en', 'zh-TW'];
const statuses = ['source', 'partial', 'not-ported', 'system'];
const validationStates = ['not-run', 'simulator', 'native'];

export function validateCatalog(catalog, contract, fileExists = (path) => existsSync(resolve(root, path))) {
  const errors = [];
  const translated = (value) => languages.every((lang) => typeof value?.[lang] === 'string' && value[lang].trim());
  const safePath = (path) => typeof path === 'string' && path.length > 0 && !isAbsolute(path) && !relative(root, resolve(root, path)).startsWith('..') && fileExists(path);
  if (catalog.schemaVersion !== 1 || JSON.stringify(catalog.platforms) !== JSON.stringify(platforms)) errors.push('四端目录结构或平台不完整');
  if (!Array.isArray(catalog.features) || catalog.features.length === 0) return [...errors, '功能目录为空'];
  const ids = new Set();
  for (const feature of catalog.features) {
    if (typeof feature.id !== 'string' || !feature.id || ids.has(feature.id)) errors.push(`功能 ID 缺失或重复：${feature.id}`);
    ids.add(feature.id);
    if (!translated(feature.name)) errors.push(`${feature.id} 缺少三语名称`);
    for (const platform of platforms) {
      const item = feature.platforms?.[platform];
      if (!item || !statuses.includes(item.status) || !translated(item.reason)) {
        errors.push(`${feature.id}/${platform} 缺少状态或三语说明`); continue;
      }
      if (!Array.isArray(item.source) || item.source.length === 0 || !item.source.every(safePath)) errors.push(`${feature.id}/${platform} 源码依据不存在或路径无效`);
      if (!validationStates.includes(item.validation) || !Array.isArray(item.evidence) || !item.evidence.every(safePath)) errors.push(`${feature.id}/${platform} 验证依据无效`);
      if (item.validation !== 'not-run' && item.evidence?.length === 0) errors.push(`${feature.id}/${platform} 不能在没有依据时声称验收`);
      if (item.validation === 'simulator' && platform !== 'iOS') errors.push(`${feature.id}/${platform} 不能引用 iOS 模拟器作为本端验收`);
    }
  }
  for (const feature of contract.features ?? []) if (!ids.has(feature.id)) errors.push(`发布合同新增功能尚未登记四端状态：${feature.id}`);
  return errors;
}

const copy = {
  'zh-CN': {
    title: '四端功能对照清单', feature: '功能', details: 'iOS 范围与依据', source: '源码', evidence: '验收依据',
    intro: '本清单记录当前工作区的实现范围，不代表正式发行资格。各功能的本轮验证范围分别记录，具体测试与未验收项见对应报告。源码存在、模拟器通过和真机验收分别记录。',
    legend: '源码接入：有源码或产品合同依据；部分：与对应能力存在明确差异；未移植：尚未接入本端；系统：由平台负责。详细的四端原因、源码及验证状态保存在 JSON 中。',
    maintenance: '维护方式：修改 JSON 后运行 `node scripts/check-platform-features.mjs --write` 生成三语页面，再运行 `node scripts/check-platform-features.mjs` 检查。现有发布合同新增功能时，缺少任意一端的说明会使仓库检查失败。',
    status: {'source':'源码接入','partial':'部分','not-ported':'未移植','system':'系统'},
    validation: {'not-run':'本项未完成本轮运行验收','simulator':'iOS 模拟器证据','native':'本端原生证据'},
  },
  en: {
    title: 'Feature comparison across four platforms', feature: 'Feature', details: 'iOS scope and evidence', source: 'Source', evidence: 'Validation evidence',
    intro: 'This catalog describes the current working tree and does not establish release eligibility. Validation scope is recorded per feature; consult its linked report for exact tests and unverified items. Source integration, Simulator results and physical-device acceptance are recorded separately.',
    legend: 'Source: supported by source or the product contract. Partial: defined differences remain. Not ported: unavailable in this port. System: managed by the platform. The JSON records the reasons, source paths and validation state for all four platforms.',
    maintenance: 'Maintenance: edit the JSON, run `node scripts/check-platform-features.mjs --write` to generate all three pages, then run `node scripts/check-platform-features.mjs`. A new release-contract feature fails repository checks until every platform has a recorded status and explanation.',
    status: {'source':'Source','partial':'Partial','not-ported':'Not ported','system':'System'},
    validation: {'not-run':'Runtime acceptance not completed for this item in this work','simulator':'iOS Simulator evidence','native':'Native platform evidence'},
  },
  'zh-TW': {
    title: '四端功能對照清單', feature: '功能', details: 'iOS 範圍與依據', source: '原始碼', evidence: '驗收依據',
    intro: '本清單記錄目前工作區的實作範圍，不代表正式發行資格。各功能的本輪驗證範圍分別記錄，具體測試與未驗收項見對應報告。原始碼存在、模擬器通過和實機驗收分別記錄。',
    legend: '原始碼接入：有原始碼或產品合同依據；部分：與對應能力存在明確差異；未移植：尚未接入本端；系統：由平台負責。詳細的四端原因、原始碼及驗證狀態保存在 JSON 中。',
    maintenance: '維護方式：修改 JSON 後執行 `node scripts/check-platform-features.mjs --write` 產生三語頁面，再執行 `node scripts/check-platform-features.mjs` 檢查。現有發行合同新增功能時，缺少任意一端的說明會使儲存庫檢查失敗。',
    status: {'source':'原始碼接入','partial':'部分','not-ported':'未移植','system':'系統'},
    validation: {'not-run':'本項未完成本輪執行驗收','simulator':'iOS 模擬器證據','native':'本端原生證據'},
  },
};
export function renderCatalog(catalog, language) {
  const text = copy[language];
  const links = (paths) => paths.map((path) => `[${path}](../${path})`).join(' · ');
  const escape = (value) => value.replaceAll('|', '\\|').replaceAll('\n', ' ');
  const lines = [`# ${text.title}`, '', '[简体中文](platform-features.zh-CN.md) · [繁體中文](platform-features.zh-TW.md) · [English](platform-features.en.md) · [JSON](platform-features.json)', '', text.intro, '', text.legend, '', `| ${text.feature} | macOS | Windows | Android | iOS |`, '| --- | --- | --- | --- | --- |'];
  for (const feature of catalog.features) lines.push(`| ${escape(feature.name[language])} | ${platforms.map((platform) => text.status[feature.platforms[platform].status]).join(' | ')} |`);
  lines.push('', `## ${text.details}`, '');
  for (const feature of catalog.features) {
    const item = feature.platforms.iOS;
    lines.push(`### ${feature.name[language]}`, '', '`' + feature.id + '` — ' + item.reason[language], '', `${text.source}：${links(item.source)}`, '', `${text.validation[item.validation]}${item.evidence.length ? `：${links(item.evidence)}` : '。'}`, '');
  }
  lines.push(text.maintenance, '');
  return lines.join('\n');
}

export function checkPlatformFeatures({write = false} = {}) {
  const catalog = JSON.parse(readFileSync(resolve(root, 'docs/platform-features.json'), 'utf8'));
  const contract = JSON.parse(readFileSync(resolve(root, 'apps/browser/release-feature-contract.json'), 'utf8'));
  const errors = validateCatalog(catalog, contract);
  if (errors.length) return errors;
  for (const lang of languages) {
    const output = resolve(root, `docs/platform-features.${lang}.md`);
    const expected = renderCatalog(catalog, lang);
    if (write) writeFileSync(output, expected);
    else if (!existsSync(output) || readFileSync(output, 'utf8') !== expected) errors.push(`四端清单三语页面未同步：${lang}`);
  }
  return errors;
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const errors = checkPlatformFeatures({write: process.argv.includes('--write')});
  if (errors.length) { console.error(errors.join('\n')); process.exitCode = 1; }
  else console.log('四端功能清单通过：功能覆盖、三语说明、源码依据和页面同步。');
}
