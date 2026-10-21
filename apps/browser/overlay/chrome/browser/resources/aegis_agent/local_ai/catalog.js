// Copyright 2026 GCSA
// 界面、下载器与推理共用同一份受信模型清单，不猜测不存在的翻译方向。
export const normalizeLanguage = value => value === 'zh-Hans' || value === 'zh-CN' ? 'zh' : value;
export function languagePacks(rows) {
  const groups = new Map();
  for (const row of rows) {
    const from = normalizeLanguage(row.sourceLanguage), to = normalizeLanguage(row.targetLanguage);
    const id = from + '-' + to;
    if (!groups.has(id)) groups.set(id, {id, from, to, rows: []});
    groups.get(id).rows.push(row);
  }
  return [...groups.values()].filter(pack => pack.rows.some(row => row.fileType === 'model') &&
      pack.rows.some(row => row.fileType === 'lex') && (pack.rows.some(row => row.fileType === 'vocab') ||
      ['srcvocab', 'trgvocab'].every(type => pack.rows.some(row => row.fileType === type)))).map(pack => ({...pack,
    version: pack.rows.find(row => row.fileType === 'model').version,
    beamSize: pack.rows.find(row => row.fileType === 'model').aegisBeamSize || 1,
    bytes: pack.rows.reduce((total, row) => total + row.attachment.size, 0),
    installedBytes: pack.rows.reduce((total, row) => total + row.decompressedSize, 0)}));
}
export function translationRoutes(packs) {
  const routes = packs.map(pack => ({id: pack.id, from: pack.from, to: pack.to, packs: [pack.id], pivot: false}));
  // 中文与新增语言缺少直接模型，明确经英语中转；未评估的其他组合不开放。
  const languages = new Set(packs.flatMap(pack => [pack.from, pack.to]));
  for (const language of languages) {
    if (language === 'en' || language === 'zh') continue;
    for (const [from, to] of [['zh', language], [language, 'zh']]) {
      // 日中中转出现日期/段落含义偏移，中德中转把“保存”误作“收到”，暂不开放。
      if ((from === 'ja' && to === 'zh') || (from === 'zh' && to === 'de')) continue;
      if (routes.some(route => route.id === from + '-' + to)) continue;
      const path = [from + '-en', 'en-' + to];
      if (path.every(id => packs.some(pack => pack.id === id))) routes.push({id: from + '-' + to, from, to, packs: path, pivot: true});
    }
  }
  return routes;
}
export function routePacks(rows, direction) {
  const packs = languagePacks(rows), route = translationRoutes(packs).find(value => value.id === direction);
  if (!route) throw Error('unsupported_language');
  return route.packs.map(id => packs.find(pack => pack.id === id));
}
export function detectSource(text) {
  // 文字体系能确定时才给建议；拉丁字母语言不冒充自动识别结果。
  if (/[\u3040-\u30ff]/u.test(text)) return 'ja';
  if (/[\uac00-\ud7af]/u.test(text)) return 'ko';
  if (/[\u0400-\u04ff]/u.test(text)) return 'ru';
  if (/[\u3400-\u9fff]/u.test(text)) return 'zh';
  return '';
}
