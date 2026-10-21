// Copyright 2026 GCSA
import {sendWithPromise} from 'chrome://resources/js/cr.js';
type Settings = {enabled: boolean, showTrail: boolean, threshold: number, bindings: Record<string, string>, disabledSites: string[]};
type Action = {id: string, label: string, pdfOnly: boolean};
type Snapshot = {settings: Settings, defaults: Settings, actions: Action[]};
export function initializeGestures(root: Document|ShadowRoot = document) {
const events = new AbortController();
const t = (text: string) => (globalThis as unknown as {AegisI18n?: {t: (value: string) => string}}).AegisI18n?.t(text) || text;
function element<T extends HTMLElement = HTMLElement>(id: string): T {
  const result = root.querySelector<T>('#' + id); if (!result) throw Error('缺少设置控件：' + id); return result;
}
const enabled = element<HTMLInputElement>('enabled'), trail = element<HTMLInputElement>('showTrail');
const threshold = element<HTMLInputElement>('threshold'), sites = element<HTMLTextAreaElement>('disabledSites');
const bindings = element('bindings'), practice = element('practice');
const patternLabel = element('practicePattern'), resultLabel = element('practiceResult');
const line = root.querySelector<SVGPolylineElement>('#practiceLine')!;
let saved: Settings|null = null, defaults: Settings|null = null, actions: Action[] = [];
let lastPattern = '', lastAction: string|undefined;
let practiceSaving = false, pendingSaves = 0, optionSequence = 0;
function hasDraft() {
  return !!pendingSaves || drafts.size > 0 || !!element<HTMLInputElement>('newSite').value || (saved !== null && sites.value !== saved.disabledSites.join('\n')) || (!!lastPattern && !!element<HTMLSelectElement>('practiceAction').value && element<HTMLSelectElement>('practiceAction').value !== saved?.bindings[lastPattern]);
}
function reportDirty() {
  if (root instanceof ShadowRoot) root.host.dispatchEvent(new CustomEvent('aegis-form-dirty', {detail: hasDraft(), bubbles: true, composed: true}));
}
root.addEventListener('input', () => queueMicrotask(reportDirty), {signal: events.signal});
root.addEventListener('change', () => queueMicrotask(reportDirty), {signal: events.signal});
root.addEventListener('click', () => queueMicrotask(reportDirty), {signal: events.signal});
let saveChain = Promise.resolve();
let undo: {pattern: string, action: string}|null = null;
const drafts = new Map<string, string>();
function message(text: string, error = false, id = 'status') {
  const target = root.querySelector<HTMLElement>('#' + id) || element('status');
  target.textContent = t(text); target.classList.toggle('error', error);
}
function arrows(value: string): string {
  const symbols: Record<string, string> = {L: '←', R: '→', U: '↑', D: '↓'};
  return Array.from(value, letter => symbols[letter] || letter).join(' ');
}
function normalize(value: string) {
  return value.trim().toUpperCase().replaceAll('←', 'L').replaceAll('→', 'R').replaceAll('↑', 'U').replaceAll('↓', 'D').replaceAll(' ', '');
}
function actionSelect(select: HTMLSelectElement, current = '') {
  select.replaceChildren(new Option(t('请选择动作'), ''));
  const groups = new Map<string, HTMLOptGroupElement>();
  for (const item of actions) {
    const name = item.pdfOnly ? 'PDF' : /tab/.test(item.id) ? t('标签页') : /back|forward|reload/.test(item.id) ? t('导航') : t('页面');
    if (!groups.has(name)) { const group = document.createElement('optgroup'); group.label = name; groups.set(name, group); select.append(group); }
    groups.get(name)!.append(new Option(t(item.label) + (item.pdfOnly ? ' · PDF' : ''), item.id));
  }
  select.value = current;
}
function button(text: string, action: () => Promise<unknown>|void) {
  const node = document.createElement('button'); node.type = 'button'; node.textContent = t(text);
  node.onclick = async () => { node.disabled = true; try { await action(); } finally { node.disabled = false; } };
  return node;
}
// 每次提交只改变该操作涉及的字段；原生比较整份基线，拒绝跨页陈旧写入。
function persist(change: (next: Settings) => void, status: string): Promise<boolean> {
  let ok = false; ++pendingSaves; reportDirty();
  saveChain = saveChain.then(async () => {
    if (!saved) { --pendingSaves; reportDirty(); return; }
    const expected = structuredClone(saved), next = structuredClone(saved);
    try {
      change(next); message('正在保存…', false, status);
      const snapshot = await sendWithPromise<Snapshot>('aegisSaveGestureSettings', next, expected);
      saved = snapshot.settings; defaults = snapshot.defaults; ok = true;
      message('已保存，下一次手势生效。', false, status);
    } catch (error) { message(String(error), true, status); element('reloadSettings').hidden = false; }
    finally { --pendingSaves; reportDirty(); }
  });
  return saveChain.then(() => ok);
}
async function reload() {
  try {
    const snapshot = await sendWithPromise<Snapshot>('aegisGetGestureSettings');
    saved = snapshot.settings; defaults = snapshot.defaults; actions = snapshot.actions;
    enabled.checked = saved.enabled; trail.checked = saved.showTrail; threshold.value = String(saved.threshold);
    element('thresholdValue').textContent = threshold.value; sites.value = saved.disabledSites.join('\n');
    renderBindings(); renderSites(); clearPractice();
    for (const control of root.querySelectorAll<HTMLInputElement>('input,select,button,textarea')) control.disabled = false;
    element<HTMLButtonElement>('savePractice').disabled = true;
    element('reloadSettings').hidden = true; message('设置已加载');
  } catch (error) {
    message(String(error), true);
    element('reloadSettings').hidden = false;
    element<HTMLButtonElement>('reloadSettings').disabled = false;
  }
}
function renderBindings() {
  bindings.replaceChildren();
  for (const [pattern, action] of Object.entries(saved?.bindings || {})) {
    const row = document.createElement('div'); row.className = 'binding'; row.dataset['pattern'] = pattern;
    const direction = document.createElement('strong'); direction.textContent = arrows(pattern);
    const label = document.createElement('span'); label.textContent = t(actions.find(item => item.id === action)?.label || action);
    const controls = document.createElement('div'); controls.className = 'binding-controls';
    const editor = document.createElement('div'); editor.className = 'binding-edit'; editor.hidden = !drafts.has(pattern);
    const select = document.createElement('select'); select.setAttribute('aria-label', t('执行动作') + ' ' + arrows(pattern)); actionSelect(select, drafts.get(pattern) || action);
    select.onchange = () => drafts.set(pattern, select.value);
    const status = document.createElement('p'); status.setAttribute('role', 'status'); status.id = 'edit-' + pattern;
    editor.append(select, button('保存', async () => {
      if (!select.value) { status.textContent = t('请选择动作'); return; }
      const value = select.value;
      if (await persist(next => { next.bindings[pattern] = value; }, status.id)) { if (drafts.get(pattern) === value) drafts.delete(pattern); renderBindings(); reportDirty(); }
    }), button('取消', () => { drafts.delete(pattern); editor.hidden = true; }), status);
    controls.append(button('编辑', () => { drafts.set(pattern, action); editor.hidden = false; select.focus(); }), button('移除', async () => {
      if (await persist(next => { delete next.bindings[pattern]; }, 'binding-status')) {
        undo = {pattern, action}; drafts.delete(pattern); renderBindings(); element('undoBinding').hidden = false;
      }
    }));
    row.append(direction, label, controls, editor); bindings.append(row);
  }
  updateRegion(); reportDirty();
}
function clearPractice() {
  if (practiceSaving) return;
  lastPattern = ''; lastAction = undefined; element('practice-editor').hidden = true;
  element<HTMLButtonElement>('savePractice').disabled = true;
  line.setAttribute('points', ''); element<HTMLInputElement>('manualPattern').value = '';
  patternLabel.textContent = t('按住右键，在这里画一笔'); resultLabel.textContent = t('也可以使用下方方向按钮。'); reportDirty();
}
function choosePattern(value: string) {
  if (practiceSaving) return;
  value = normalize(value);
  if (!/^[LRUD]{1,8}$/.test(value) || /(.)\1/.test(value)) { clearPractice(); resultLabel.textContent = t('需包含 1–8 个方向，相邻方向不能相同。'); return; }
  lastPattern = value; lastAction = saved?.bindings[value];
  patternLabel.textContent = arrows(value); resultLabel.textContent = lastAction ? t('已绑定，可在下方修改；练习不执行操作。') : t('尚未绑定，请选择动作。');
  const select = element<HTMLSelectElement>('practiceAction'); actionSelect(select, lastAction || '');
  element('practice-editor').hidden = false; element('savePractice').textContent = t(lastAction ? '保存绑定修改' : '添加并保存');
  element<HTMLButtonElement>('savePractice').disabled = !select.value;
  message('', false, 'practice-status'); reportDirty();
}
element<HTMLSelectElement>('practiceAction').onchange = () => { element<HTMLButtonElement>('savePractice').disabled = !element<HTMLSelectElement>('practiceAction').value; reportDirty(); };
element('savePractice').onclick = async () => {
  const pattern = lastPattern, action = element<HTMLSelectElement>('practiceAction').value;
  if (!pattern || !action || practiceSaving) return;
  practiceSaving = true; element<HTMLSelectElement>('practiceAction').disabled = true;
  element<HTMLButtonElement>('savePractice').disabled = true;
  const ok = await persist(next => {
    if (!Object.hasOwn(next.bindings, pattern) && Object.keys(next.bindings).length >= 64) throw Error(t('最多添加 64 条手势。'));
    next.bindings[pattern] = action;
  }, 'practice-status');
  if (ok) { renderBindings(); lastAction = action; resultLabel.textContent = t('已绑定，可在下方修改；练习不执行操作。'); element('savePractice').textContent = t('保存绑定修改'); }
  practiceSaving = false; element<HTMLSelectElement>('practiceAction').disabled = false;
  element<HTMLButtonElement>('savePractice').disabled = false; reportDirty();
};
for (const node of root.querySelectorAll<HTMLButtonElement>('[data-direction]')) node.onclick = () => choosePattern(lastPattern + node.dataset['direction']);
element('redraw').onclick = clearPractice; element('cancelPractice').onclick = clearPractice;
element('usePattern').onclick = () => choosePattern(element<HTMLInputElement>('manualPattern').value);
element('undoBinding').onclick = async () => {
  if (!undo) return; const value = undo;
  if (await persist(next => { if (Object.hasOwn(next.bindings, value.pattern)) throw Error(t('这个方向已重新绑定，请先检查现有动作。')); next.bindings[value.pattern] = value.action; }, 'binding-status')) {
    undo = null; element('undoBinding').hidden = true; renderBindings();
  }
};
function saveOptions() {
  const values = {enabled: enabled.checked, showTrail: trail.checked, threshold: Number(threshold.value)};
  const sequence = ++optionSequence;
  void persist(next => Object.assign(next, values), 'options-status').then(ok => {
    if (!ok && sequence === optionSequence && saved) { enabled.checked = saved.enabled; trail.checked = saved.showTrail; threshold.value = String(saved.threshold); element('thresholdValue').textContent = threshold.value; }
  });
}
enabled.onchange = saveOptions; trail.onchange = saveOptions;
threshold.oninput = () => { element('thresholdValue').textContent = threshold.value; };
threshold.onchange = saveOptions;
element('resetOptions').onclick = async () => {
  if (!defaults || !confirm(t('恢复基本选项？手势绑定和网站例外保持不变。'))) return;
  const value = defaults;
  if (await persist(next => Object.assign(next, {enabled: value.enabled, showTrail: value.showTrail, threshold: value.threshold}), 'options-status')) {
    enabled.checked = value.enabled; trail.checked = value.showTrail; threshold.value = String(value.threshold); element('thresholdValue').textContent = threshold.value;
  }
};
element('resetBindings').onclick = async () => {
  if (!defaults || !confirm(t('恢复全部默认手势绑定？自定义绑定将被替换，其他选项保持不变。'))) return;
  const value = defaults.bindings;
  if (await persist(next => { next.bindings = structuredClone(value); }, 'binding-status')) { drafts.clear(); renderBindings(); }
};
function hostname(value: string) {
  const url = new URL(value.includes('://') ? value : 'https://' + value);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || !url.hostname) throw Error(t('请输入有效网站域名。'));
  return url.hostname.toLowerCase();
}
function renderSites() {
  const list = element('disabledSiteList'); list.replaceChildren();
  for (const domain of saved?.disabledSites || []) {
    const row = document.createElement('div'); row.className = 'site-entry'; const label = document.createElement('span'); label.textContent = domain;
    row.append(label, button('移除', async () => {
      if (await persist(next => { next.disabledSites = next.disabledSites.filter(item => item !== domain); }, 'sites-status')) { sites.value = saved!.disabledSites.join('\n'); renderSites(); }
    })); list.append(row);
  }
  if (!list.childElementCount) list.textContent = t('暂无网站例外。');
}
element<HTMLFormElement>('add-site-form').onsubmit = event => {
  event.preventDefault(); const input = element<HTMLInputElement>('newSite'); const value = input.value.trim();
  void persist(next => { const domain = hostname(value); if (!next.disabledSites.includes(domain)) next.disabledSites.push(domain); }, 'sites-status').then(ok => { if (ok) { if (input.value.trim() === value) input.value = ''; sites.value = saved!.disabledSites.join('\n'); renderSites(); reportDirty(); } });
};
element('saveSites').onclick = async () => {
  const input = sites.value;
  if (await persist(next => { next.disabledSites = [...new Set(input.split('\n').map(value => value.trim()).filter(Boolean).map(hostname))]; }, 'sites-status')) { sites.value = saved!.disabledSites.join('\n'); renderSites(); reportDirty(); }
};
element('cancelSites').onclick = () => { sites.value = saved?.disabledSites.join('\n') || ''; };
element('reloadSettings').onclick = () => { if (!confirm(t('重新读取会放弃当前未保存的手势编辑，继续？'))) return; drafts.clear(); void reload(); };
window.addEventListener('beforeunload', event => { if (hasDraft()) { event.preventDefault(); event.returnValue = ''; } }, {signal: events.signal});
for (const control of root.querySelectorAll<HTMLInputElement>('input,select,button,textarea')) control.disabled = true;
// 只在练习区处理页面事件；真实动作由浏览器原生输入层识别和执行。
let drawing = false;
let cancelled = false;
let ambiguous = false;
let moved = false;
let pattern = '';
let anchorX = 0;
let anchorY = 0;
let points: string[] = [];
function updateRegion() {
  requestAnimationFrame(() => {
    const bounds = practice.getBoundingClientRect();
    const x = Math.max(0, bounds.left);
    const y = Math.max(0, bounds.top);
    const width = Math.max(0, Math.min(innerWidth, bounds.right) - x);
    const height = Math.max(0, Math.min(innerHeight, bounds.bottom) - y);
    chrome.send('aegisGesturePracticeRegion', [
      Math.min(1, x / innerWidth), Math.min(1, y / innerHeight),
      width / innerWidth, height / innerHeight,
    ]);
  });
}
const observer = new ResizeObserver(updateRegion);
observer.observe(practice);
window.addEventListener('resize', updateRegion, {signal: events.signal});
window.addEventListener('scroll', updateRegion, {capture: true, passive: true, signal: events.signal});
function cancelPractice() {
  if (drawing || lastPattern) {
    cancelled = true;
    clearPractice();
    patternLabel.textContent = t('已取消');
    resultLabel.textContent = t('没有执行任何操作');
  }
}
practice.addEventListener('contextmenu', event => {
  event.preventDefault();
});
practice.addEventListener('pointerdown', event => {
  if (event.button !== 2 || practiceSaving || !saved) {
    return;
  }
  event.preventDefault();
  practice.focus({preventScroll: true});
  practice.setPointerCapture(event.pointerId);
  drawing = true;
  cancelled = ambiguous = moved = false;
  clearPractice();
  pattern = '';
  anchorX = event.clientX;
  anchorY = event.clientY;
  const bounds = practice.getBoundingClientRect();
  points = [`${event.clientX - bounds.left},${event.clientY - bounds.top}`];
  line.setAttribute('points', points.join(' '));
  patternLabel.textContent = t('画出上下左右方向');
  resultLabel.textContent = t('松开查看结果 · Esc 取消');
});
function practiceMove(event: PointerEvent) {
  if (!drawing || cancelled) {
    return;
  }
  const bounds = practice.getBoundingClientRect();
  if (event.clientX < bounds.left || event.clientX > bounds.right ||
      event.clientY < bounds.top || event.clientY > bounds.bottom) {
    cancelPractice();
    return;
  }
  if (points.length >= 256) {
    points = points.filter((_, i) => i % 2 === 0);
  }
  points.push(`${event.clientX - bounds.left},${event.clientY - bounds.top}`);
  line.setAttribute('points', points.join(' '));
  const dx = event.clientX - anchorX;
  const dy = event.clientY - anchorY;
  if (Math.hypot(dx, dy) < Number(threshold.value)) {
    return;
  }
  moved = true;
  const ax = Math.abs(dx);
  const ay = Math.abs(dy);
  ambiguous = Math.max(ax, ay) < 1.35 * Math.min(ax, ay);
  if (ambiguous) {
    return;
  }
  const direction = ax > ay ? (dx > 0 ? 'R' : 'L') : (dy > 0 ? 'D' : 'U');
  if (!pattern.endsWith(direction)) {
    pattern += direction;
  }
  anchorX = event.clientX;
  anchorY = event.clientY;
  if (pattern.length > 8) {
    cancelPractice();
  } else {
    patternLabel.textContent = arrows(pattern);
  }
}
practice.addEventListener('pointermove', practiceMove);
practice.addEventListener('pointerup', event => {
  if (event.button !== 2 || !drawing) {
    return;
  }
  practiceMove(event);
  drawing = false;
  if (cancelled) {
    return;
  }
  if (!moved || ambiguous) {
    lastPattern = '';
    patternLabel.textContent = t(moved ? '方向不明确' : '未画出手势');
    resultLabel.textContent = t('不执行操作；请画清楚的水平或垂直方向。');
    return;
  }
  choosePattern(pattern);

});
practice.addEventListener('pointercancel', cancelPractice);
window.addEventListener('blur', cancelPractice, {signal: events.signal});
window.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    cancelPractice();
    clearPractice();
  }
}, {signal: events.signal});
void reload();
return () => { events.abort(); observer.disconnect(); };
}
if (document.getElementById('practice')) {
  location.replace('chrome://settings/aegisGestures' + location.search + location.hash);
}
