// Copyright 2026 GCSA
import {sendWithPromise} from 'chrome://resources/js/cr.js';

type Settings = {
  enabled: boolean,
  showTrail: boolean,
  threshold: number,
  bindings: Record<string, string>,
  disabledSites: string[],
};
type Action = {id: string, label: string, pdfOnly: boolean};
type Snapshot = {settings: Settings, actions: Action[]};

function element<T extends Element = HTMLElement>(id: string): T {
  const value = document.querySelector<T>(`#${id}`);
  if (!value) {
    throw new Error(`缺少设置元素：${id}`);
  }
  return value;
}
const enabled = element<HTMLInputElement>('enabled');
const trail = element<HTMLInputElement>('showTrail');
const threshold = element<HTMLInputElement>('threshold');
const bindings = element('bindings');
const sites = element<HTMLTextAreaElement>('disabledSites');
const save = element<HTMLButtonElement>('save');
const status = element('status');
const practice = element('practice');
const patternLabel = element('practicePattern');
const resultLabel = element('practiceResult');
const line = element<SVGPolylineElement>('practiceLine');
let actions: Action[] = [];
let lastPattern = '';
let busy = false;

function arrows(pattern: string): string {
  const map = new Map([['L', '←'], ['R', '→'], ['U', '↑'], ['D', '↓']]);
  return Array.from(pattern, c => map.get(c) || c).join(' ');
}
function normalize(pattern: string): string {
  return pattern.trim().toUpperCase().replaceAll('←', 'L').replaceAll('→', 'R')
      .replaceAll('↑', 'U').replaceAll('↓', 'D').replaceAll(' ', '');
}
function message(text: string, error = false) {
  status.textContent = text;
  status.classList.toggle('error', error);
}
function dirty() {
  message('有未保存的修改');
}
function addBinding(pattern: string, action: string) {
  const row = document.createElement('div');
  row.className = 'binding';
  const input = document.createElement('input');
  input.value = pattern;
  input.maxLength = 16;
  input.placeholder = '例如 DR';
  input.setAttribute('aria-label', '手势方向');
  const preview = document.createElement('span');
  preview.className = 'arrows';
  preview.textContent = arrows(pattern);
  input.addEventListener('input', () => {
    preview.textContent = arrows(normalize(input.value));
    dirty();
  });
  const select = document.createElement('select');
  select.setAttribute('aria-label', '执行动作');
  for (const item of actions) {
    const option = document.createElement('option');
    option.value = item.id;
    option.textContent = item.label;
    select.appendChild(option);
  }
  select.value = action;
  select.addEventListener('change', dirty);
  const remove = document.createElement('button');
  remove.type = 'button';
  remove.className = 'remove';
  remove.textContent = '移除';
  remove.setAttribute('aria-label', `移除手势 ${arrows(pattern)}`);
  remove.addEventListener('click', () => {
    row.remove();
    dirty();
    updateRegion();
  });
  row.append(input, preview, select, remove);
  bindings.appendChild(row);
}
function render(snapshot: Snapshot) {
  const value = snapshot.settings;
  actions = snapshot.actions;
  enabled.checked = value.enabled;
  trail.checked = value.showTrail;
  threshold.value = String(value.threshold);
  element('thresholdValue').textContent = threshold.value;
  bindings.replaceChildren();
  for (const [pattern, action] of Object.entries(value.bindings)) {
    addBinding(pattern, action);
  }
  sites.value = value.disabledSites.join('\n');
  updateRegion();
}
function readSettings(): Settings {
  const mapping = new Map<string, string>();
  for (const row of bindings.querySelectorAll('.binding')) {
    const input = row.querySelector('input');
    const select = row.querySelector('select');
    if (!input || !select) {
      throw new Error('手势配置控件缺失，请重新打开此页面。');
    }
    const pattern = normalize(input.value);
    if (!/^[LRUD]{1,8}$/.test(pattern) || /(.)\1/.test(pattern)) {
      throw new Error('每条手势需包含 1–8 个方向，且相邻方向不能相同。');
    }
    if (mapping.has(pattern)) {
      throw new Error(`手势 ${arrows(pattern)} 已重复，请为它只保留一个动作。`);
    }
    mapping.set(pattern, select.value);
  }
  const disabledSites = sites.value.split('\n').map(s => s.trim().toLowerCase())
                            .filter(Boolean);
  return {
    enabled: enabled.checked, showTrail: trail.checked,
    threshold: Number(threshold.value),
    bindings: Object.fromEntries(mapping), disabledSites,
  };
}
async function persist(reset: boolean) {
  if (busy) {
    return;
  }
  busy = true;
  save.disabled = true;
  try {
    const snapshot: Snapshot = reset ?
        await sendWithPromise('aegisResetGestureSettings') :
        await sendWithPromise('aegisSaveGestureSettings', readSettings());
    render(snapshot);
    message(reset ? '已恢复并保存默认设置' : '已保存，下一次手势立即生效');
  } catch (error) {
    message(String(error), true);
  } finally {
    busy = false;
    save.disabled = false;
  }
}
save.addEventListener('click', () => void persist(false));
element('reset').addEventListener('click', () => void persist(true));
element('addBinding').addEventListener('click', () => {
  if (bindings.children.length >= 64) {
    message('最多添加 64 条手势。', true);
    return;
  }
  addBinding(lastPattern, actions[0]?.id || 'back');
  dirty();
  updateRegion();
});
for (const input of [enabled, trail, sites]) {
  input.addEventListener('input', dirty);
}
threshold.addEventListener('input', () => {
  element('thresholdValue').textContent = threshold.value;
  dirty();
});

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
new ResizeObserver(updateRegion).observe(practice);
window.addEventListener('resize', updateRegion);
window.addEventListener('scroll', updateRegion, {capture: true, passive: true});
function cancelPractice() {
  if (drawing) {
    cancelled = true;
    patternLabel.textContent = '已取消';
    resultLabel.textContent = '没有执行任何操作';
  }
}
practice.addEventListener('contextmenu', event => {
  event.preventDefault();
});
practice.addEventListener('pointerdown', event => {
  if (event.button !== 2) {
    return;
  }
  event.preventDefault();
  practice.focus({preventScroll: true});
  practice.setPointerCapture(event.pointerId);
  drawing = true;
  cancelled = ambiguous = moved = false;
  pattern = '';
  anchorX = event.clientX;
  anchorY = event.clientY;
  const bounds = practice.getBoundingClientRect();
  points = [`${event.clientX - bounds.left},${event.clientY - bounds.top}`];
  line.setAttribute('points', points.join(' '));
  patternLabel.textContent = '画出上下左右方向';
  resultLabel.textContent = '松开查看结果 · Esc 取消';
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
    patternLabel.textContent = moved ? '方向不明确' : '未画出手势';
    resultLabel.textContent = '不执行操作；请画清楚的水平或垂直方向。';
    return;
  }
  lastPattern = pattern;
  try {
    const mapping = new Map(Object.entries(readSettings().bindings));
    const action = actions.find(item => item.id === mapping.get(pattern));
    patternLabel.textContent = arrows(pattern);
    resultLabel.textContent = action ? `匹配：${action.label}（练习不执行）` :
        '尚未绑定；点击“添加手势”可使用这次方向。';
  } catch {
    resultLabel.textContent = '配置有重复或无效方向，请修正后再匹配。';
  }
});
practice.addEventListener('pointercancel', cancelPractice);
window.addEventListener('blur', cancelPractice);
window.addEventListener('keydown', event => {
  if (event.key === 'Escape') {
    cancelPractice();
  }
});
void sendWithPromise<Snapshot>('aegisGetGestureSettings').then(snapshot => {
  render(snapshot);
  save.disabled = false;
  message('设置已加载');
}).catch(() => {
  message('设置加载失败，请重新打开此页面。', true);
});
