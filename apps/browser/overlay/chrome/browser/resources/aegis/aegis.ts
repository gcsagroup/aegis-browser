// Copyright 2026 GCSA

import {sendWithPromise} from 'chrome://resources/js/cr.js';
import {getRequiredElement} from 'chrome://resources/js/util.js';
import './policy_worker.js';

interface PrivacyEvent {
  kind: string;
  label: string;
  time: number;
}

interface AegisStatus {
  enabled: boolean;
  trackerBlocking: boolean;
  phishInterstitial: boolean;
  fingerprintGuard: boolean;
  filterListAutoUpdate: boolean;
  filterListUpdating: boolean;
  filterListHostCount: number;
  filterListLastUpdated: number;
  filterListLastError: string;
  linkSanitize: boolean;
  cookieJanitor: boolean;
  cnameUncloak: boolean;
  bounceTracking: boolean;
  policyWorker: boolean;
  policyWorkerReady: boolean;
  policyWorkerError: string;
  privacyAi: boolean;
  aiControl?: boolean;
  aiControlRunning?: boolean;
  aiControlPort?: number;
  aiControlAddress?: string;
  aiControlLoopbackOnly?: boolean;
  aiControlClients?: number;
  ollamaUrl?: string;
  ollamaModel?: string;
  isAndroid?: boolean;
  recentEvents?: PrivacyEvent[];
  ok?: boolean;
  error?: string;
}

interface PageSnapshot {
  url?: string;
  title?: string;
  textSample?: string;
  passwordFields?: number;
  forms?: number;
  error?: string;
}

declare global {
  interface Window {
    aegisEvaluate?: (requestJson: string) => string;
  }
}

interface SummarizeResult {
  ok: boolean;
  error?: string;
  url?: string;
  summary?: string;
  bullets?: string[];
  risks?: string[];
  backend?: string;
  modelReady?: boolean;
  workerReady?: boolean;
  charsIn?: number;
  charsSent?: number;
  stayedOnDevice?: boolean;
  destination?: string;
}

interface OllamaProbeResult {
  ok: boolean;
  error?: string;
  ollamaUrl?: string;
  ollamaModel?: string;
  models?: string[];
}

type ModuleName =
    'trackerBlocking'|'phishInterstitial'|'fingerprintGuard'|
    'filterListAutoUpdate'|'linkSanitize'|'cookieJanitor'|'cnameUncloak'|
    'bounceTracking'|'policyWorker'|'privacyAi'|'aiControl';

function checkbox(id: string): HTMLInputElement {
  const el = getRequiredElement(id);
  if (!(el instanceof HTMLInputElement)) {
    throw new Error(`Missing checkbox #${id}`);
  }
  return el;
}

function textField(id: string): HTMLInputElement {
  const el = getRequiredElement(id);
  if (!(el instanceof HTMLInputElement)) {
    throw new Error(`Missing input #${id}`);
  }
  return el;
}

function actionButton(id: string): HTMLButtonElement {
  const el = getRequiredElement(id);
  if (!(el instanceof HTMLButtonElement)) {
    throw new Error(`Missing button #${id}`);
  }
  return el;
}

function formatMeta(status: AegisStatus): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const count = status.filterListHostCount || 0;
  const zh = lang.startsWith('zh');
  if (!status.filterListLastUpdated) {
    if (count) {
      return zh ? `已编译 ${count} 条主机规则。` :
                  `Compiled ${count} host rules.`;
    }
    return zh ? '尚未下载过滤列表。' : 'No compiled filter list yet.';
  }
  const when = new Date(status.filterListLastUpdated * 1000).toLocaleString();
  const err = status.filterListLastError
      ? (zh ? ` 上次错误：${status.filterListLastError}` :
              ` Last error: ${status.filterListLastError}`)
      : '';
  return zh ? `已编译 ${count} 条主机规则 · 更新于 ${when}${err}` :
              `Compiled ${count} host rules · updated ${when}${err}`;
}

function formatPrivacyMeta(status: AegisStatus): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const zh = lang.startsWith('zh');
  if (!status.privacyAi) {
    return zh ? '本地隐私摘要已关闭。' : 'Local privacy summary is off.';
  }
  if (status.policyWorkerReady) {
    return zh ? '策略 worker 已就绪。有 Ollama 时会优先用本地模型。' :
                'Policy worker ready. Uses local Ollama when available.';
  }
  const err = status.policyWorkerError ? ` (${status.policyWorkerError})` : '';
  return zh ? `策略 worker 未就绪，使用 C++ 回退摘要。${err}` :
              `Policy worker not ready; using C++ fallback.${err}`;
}

function fillModelList(models: string[]) {
  const list = getRequiredElement('ollama-models');
  list.replaceChildren();
  for (const name of models) {
    const option = document.createElement('option');
    option.value = name;
    list.appendChild(option);
  }
}

function formatOllamaStatus(probe: OllamaProbeResult): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const zh = lang.startsWith('zh');
  if (!probe.ok) {
    return zh ? `未检测到 Ollama，将使用启发式摘要。${
                    probe.error ? `（${probe.error}）` : ''}` :
                `Ollama not found; using heuristics.${
                    probe.error ? ` (${probe.error})` : ''}`;
  }
  const models = probe.models || [];
  if (models.length === 0) {
    return zh ? '已连接 Ollama，但还没有已安装的模型。' :
                'Connected to Ollama, but no models are installed.';
  }
  return zh ? `已连接 Ollama，可用模型：${models.join('、')}` :
              `Connected to Ollama. Models: ${models.join(', ')}`;
}

function applyStatus(status: AegisStatus) {
  checkbox('tracker').checked = status.trackerBlocking;
  checkbox('phish').checked = status.phishInterstitial;
  checkbox('fingerprint').checked = status.fingerprintGuard;
  checkbox('link-sanitize').checked = status.linkSanitize;
  checkbox('cookie-janitor').checked = status.cookieJanitor;
  checkbox('cname-uncloak').checked = status.cnameUncloak;
  checkbox('bounce-tracking').checked = status.bounceTracking;
  checkbox('policy-worker').checked = status.policyWorker;
  checkbox('privacy-ai').checked = status.privacyAi;
  const android = !!status.isAndroid;
  const ollamaFields = document.getElementById('ollama-fields');
  if (ollamaFields instanceof HTMLElement) {
    ollamaFields.hidden = android;
  }
  const aiSection = document.getElementById('ai-control-section');
  if (aiSection instanceof HTMLElement) {
    aiSection.hidden = android;
  }
  actionButton('ollama-probe').hidden = android;
  actionButton('ollama-save').hidden = android;
  if (!android) {
    checkbox('ai-control').checked = !!status.aiControl;
    if (status.ollamaUrl) {
      textField('ollama-url').value = status.ollamaUrl;
    }
    if (status.ollamaModel) {
      textField('ollama-model').value = status.ollamaModel;
    }
    const aiOn = status.privacyAi;
    textField('ollama-url').disabled = !aiOn;
    textField('ollama-model').disabled = !aiOn;
    actionButton('ollama-probe').disabled = !aiOn;
    actionButton('ollama-save').disabled = !aiOn;
    fillAiControl(status);
  }
  checkbox('filter-auto').checked = status.filterListAutoUpdate;
  getRequiredElement('filter-meta').textContent = formatMeta(status);
  getRequiredElement('privacy-meta').textContent = formatPrivacyMeta(status);
  fillActivityLog(status.recentEvents || []);
  actionButton('filter-update').disabled = status.filterListUpdating;
  actionButton('summarize').disabled = !status.privacyAi;
}

async function setModule(module: ModuleName, enabled: boolean) {
  const status: AegisStatus =
      await sendWithPromise('setModuleEnabled', module, enabled);
  applyStatus(status);
  if (module === 'privacyAi' && enabled) {
    void probeOllama();
  }
}

function bindToggle(id: string, module: ModuleName) {
  const el = checkbox(id);
  el.addEventListener('change', () => {
    void setModule(module, el.checked);
  });
}

function showResult(text: string) {
  const el = getRequiredElement('privacy-result');
  el.hidden = false;
  el.textContent = text;
}

function formatSummary(result: SummarizeResult): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const zh = lang.startsWith('zh');
  if (!result.ok) {
    return result.error || 'error';
  }
  const onDevice = result.stayedOnDevice !== false;
  const backend = result.backend === 'ollama' ?
      (zh ? '本机 Ollama' : 'Local Ollama') :
      (zh ? '启发式摘要（未调用模型）' : 'Heuristic summary (no model)');
  const lines = [
    onDevice ? (zh ? '本机处理 · 未出网' : 'On-device · did not leave this computer') :
               (zh ? '已离开本机' : 'Left this device'),
    (zh ? '后端：' : 'Backend: ') + backend,
  ];
  if (result.destination && result.destination !== 'local') {
    lines.push((zh ? '目标：' : 'Destination: ') + result.destination);
  }
  if (result.charsIn) {
    lines.push((zh ? '处理字数：' : 'Characters read: ') + String(result.charsIn));
  }
  if (result.charsSent) {
    lines.push((zh ? '发给模型：' : 'Sent to model: ') + String(result.charsSent));
  }
  lines.push('');
  if (result.url) {
    lines.push(`URL: ${result.url}`);
  }
  if (result.summary) {
    lines.push(result.summary);
  }
  for (const b of result.bullets || []) {
    lines.push(`• ${b}`);
  }
  for (const r of result.risks || []) {
    lines.push(`! ${r}`);
  }
  return lines.filter((line, i, arr) => line !== '' || arr[i - 1] !== '').join('\n');
}

function kindLabel(kind: string, zh: boolean): string {
  if (kind === 'cookie') {
    return 'Cookie';
  }
  if (kind === 'bounce') {
    return zh ? '跳转' : 'Bounce';
  }
  if (kind === 'block') {
    return zh ? '拦截' : 'Block';
  }
  if (kind === 'phish') {
    return zh ? '钓鱼' : 'Phish';
  }
  if (kind === 'cdp') {
    return zh ? '控制' : 'CDP';
  }
  return zh ? '参数' : 'Param';
}

function fillAiControl(status: AegisStatus) {
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const statusEl = getRequiredElement('ai-control-status');
  const connectEl = getRequiredElement('ai-control-connect');
  const on = !!status.aiControl && !!status.aiControlRunning;
  const port = status.aiControlPort || 9222;
  const address = status.aiControlAddress || `127.0.0.1:${port}`;
  const loopback = status.aiControlLoopbackOnly !== false;
  const clients = status.aiControlClients || 0;
  if (!status.aiControl) {
    statusEl.textContent = zh ? 'AI 控制已关闭（默认）。' :
                                'AI control is off (default).';
    connectEl.hidden = true;
    return;
  }
  const clientsText = zh ?
      (clients ? `当前 ${clients} 个本机 agent 已连接` :
                 '当前没有 agent 连接') :
      (clients ? `${clients} local agent(s) connected` :
                 'no agent connected');
  statusEl.textContent = zh ?
      `调试端口 ${port} · 绑定 ${address} · ${
          loopback ? '仅 loopback' : '绑定范围未知'} · ${clientsText}` :
      `Port ${port} · bind ${address} · ${
          loopback ? 'loopback only' : 'bind scope unknown'} · ${clientsText}`;
  connectEl.hidden = !on;
  if (on) {
    connectEl.textContent =
        `await chromium.connectOverCDP('http://127.0.0.1:${port}')`;
  }
}

function fillActivityLog(events: PrivacyEvent[]) {
  const list = getRequiredElement('activity-log');
  const empty = getRequiredElement('activity-empty');
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  list.replaceChildren();
  if (!events.length) {
    empty.hidden = false;
    return;
  }
  empty.hidden = true;
  for (const event of events) {
    const li = document.createElement('li');
    const kind = document.createElement('span');
    kind.className = 'kind';
    kind.textContent = kindLabel(event.kind, zh);
    li.appendChild(kind);
    li.appendChild(document.createTextNode(event.label));
    list.appendChild(li);
  }
}

function hashText(text: string): string {
  let h = 2166136261;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return (h >>> 0).toString(16).padStart(8, '0');
}

function probeCanvas(): string {
  const canvasEl = getRequiredElement('fp-canvas');
  if (!(canvasEl instanceof HTMLCanvasElement)) {
    return '';
  }
  const canvas = canvasEl;
  canvas.hidden = false;
  const ctx = canvas.getContext('2d');
  if (!ctx) {
    return '';
  }
  ctx.fillStyle = '#0b6e4f';
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.fillStyle = '#e8eef3';
  ctx.font = '16px sans-serif';
  ctx.fillText('GCSA-aegis ' + window.location.host, 10, 30);
  return hashText(canvas.toDataURL());
}

function asText(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function probeWebGL(): {line: string, marked: boolean} {
  const canvas = document.createElement('canvas');
  const gl = canvas.getContext('webgl');
  if (!gl) {
    return {line: '', marked: false};
  }
  const ext = gl.getExtension('WEBGL_debug_renderer_info');
  if (!ext) {
    return {line: 'WebGL —', marked: false};
  }
  const vendor = asText(gl.getParameter(ext.UNMASKED_VENDOR_WEBGL));
  const renderer = asText(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL));
  const blob = `${vendor} ${renderer}`;
  return {
    line: `WebGL ${vendor} / ${renderer}`,
    marked: blob.toLowerCase().includes('aegis'),
  };
}

let lastAudioHash = '';

function hashAudioSamples(data: Float32Array): string {
  let raw = '';
  const n = Math.min(data.length, 512);
  for (let i = 0; i < n; i++) {
    const sample = data[i];
    if (sample === undefined) {
      continue;
    }
    raw += sample.toFixed(6);
  }
  return hashText(raw);
}

async function probeAudio(): Promise<{hash: string, sameRead: boolean}> {
  const Offline = window.OfflineAudioContext;
  if (!Offline) {
    return {hash: '', sameRead: true};
  }
  const ctx = new Offline(1, 44100, 44100);
  const osc = ctx.createOscillator();
  osc.type = 'triangle';
  osc.frequency.value = 10000;
  osc.connect(ctx.destination);
  osc.start(0);
  const buf = await ctx.startRendering();
  const first = buf.getChannelData(0);
  const hash = hashAudioSamples(first);
  const second = buf.getChannelData(0);
  return {hash, sameRead: hash === hashAudioSamples(second)};
}

async function probeWebGPU(): Promise<{line: string, marked: boolean}> {
  const gpu = Reflect.get(navigator, 'gpu');
  if (!gpu || typeof gpu !== 'object') {
    return {line: '', marked: false};
  }
  const requestAdapter = Reflect.get(gpu, 'requestAdapter');
  if (typeof requestAdapter !== 'function') {
    return {line: '', marked: false};
  }
  const adapter = await requestAdapter.call(gpu);
  if (!adapter || typeof adapter !== 'object') {
    return {line: 'WebGPU —', marked: false};
  }
  const info = Reflect.get(adapter, 'info');
  if (!info || typeof info !== 'object') {
    return {line: 'WebGPU —', marked: false};
  }
  const vendor = asText(Reflect.get(info, 'vendor'));
  const architecture = asText(Reflect.get(info, 'architecture'));
  const subgroupMax = Reflect.get(info, 'subgroupMaxSize');
  const limitsObj = Reflect.get(adapter, 'limits');
  let maxBuffer = '';
  if (limitsObj && typeof limitsObj === 'object') {
    const value = Reflect.get(limitsObj, 'maxBufferSize');
    if (typeof value === 'number' || typeof value === 'bigint') {
      maxBuffer = String(value);
    }
  }
  const blob = `${vendor} ${architecture}`;
  const extras: string[] = [];
  if (maxBuffer) {
    extras.push(`maxBufferSize=${maxBuffer}`);
  }
  if (typeof subgroupMax === 'number') {
    extras.push(`subgroupMax=${subgroupMax}`);
  }
  return {
    line: `WebGPU vendor=${vendor} arch=${architecture}${
        extras.length ? ' ' + extras.join(' ') : ''}`,
    marked: blob.toLowerCase().includes('aegis'),
  };
}

async function probeFingerprint() {
  const result = getRequiredElement('fp-result');
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const on = checkbox('fingerprint').checked;
  actionButton('fp-probe').disabled = true;
  result.textContent = zh ? '正在读取本页指纹…' : 'Reading this page…';
  try {
    const canvas = probeCanvas();
    const webgl = probeWebGL();
    const audio = await probeAudio();
    const webgpu = await probeWebGPU();
    const lines: string[] = [];
    if (on) {
      lines.push(
          zh ? 'Fingerprint Guard 开着：读数按站点稳定化。关开后请刷新本页再测。' :
               'Fingerprint Guard is on: readings are stabilized per site. Toggle, reload, then probe again.');
    } else {
      lines.push(
          zh ? 'Fingerprint Guard 关着：这是浏览器原始读数。关开后请刷新本页再测。' :
               'Fingerprint Guard is off: this is the raw browser reading. Toggle, reload, then probe again.');
    }
    if (canvas) {
      lines.push(zh ? `Canvas 读数 ${canvas}` : `Canvas ${canvas}`);
    }
    if (webgl.line) {
      lines.push(webgl.line);
    }
    if (audio.hash) {
      let note = '';
      if (!audio.sameRead) {
        note = zh ? '（同一缓冲读两次不一致）' :
                    ' (same buffer changed on second read)';
      } else if (lastAudioHash && lastAudioHash === audio.hash) {
        note = zh ? '（与上次相同，已按站点稳定）' :
                    ' (same as last probe; stable per site)';
      }
      lastAudioHash = audio.hash;
      lines.push(
          (zh ? `Audio 读数 ${audio.hash}` : `Audio ${audio.hash}`) + note);
    }
    if (webgpu.line) {
      lines.push(webgpu.line);
    }
    if (on && (webgl.marked || webgpu.marked)) {
      lines.push(
          zh ? 'WebGL / WebGPU 已换成带 Aegis 的稳定化字符串。' :
               'WebGL / WebGPU strings are replaced with Aegis-stable values.');
    } else if (on && (webgl.line || webgpu.line)) {
      lines.push(
          zh ? '未看到 Aegis 标记。关掉再打开防护后，请刷新本页再测。' :
               'No Aegis marker yet. Toggle the guard, reload, then probe again.');
    }
    result.textContent = lines.filter(Boolean).join('\n');
  } catch (err) {
    result.textContent =
        zh ? `读取失败：${String(err)}` : `Probe failed: ${String(err)}`;
  } finally {
    actionButton('fp-probe').disabled = false;
  }
}

function piiLine(text: string, zh: boolean): string {
  const scan = workerEvaluate('scanPii', {text});
  const raw = scan && Array.isArray(scan['matches']) ? scan['matches'] : [];
  const matches: string[] = [];
  for (const item of raw) {
    if (typeof item !== 'object' || item === null) {
      continue;
    }
    const kind = (item as Record<string, unknown>)['kind'];
    if (typeof kind === 'string') {
      matches.push(kind);
    }
  }
  if (!matches.length) {
    return zh ? '脱敏：未发现邮箱/电话等' : 'Redaction: no email/phone found';
  }
  const counts = new Map<string, number>();
  for (const kind of matches) {
    counts.set(kind, (counts.get(kind) || 0) + 1);
  }
  const parts = [...counts.entries()].map(([kind, n]) => `${kind}×${n}`);
  return (zh ? '脱敏：' : 'Redacted: ') + parts.join('、');
}

function workerEvaluate(op: string, payload: Record<string, unknown>):
    Record<string, unknown>|null {
  const fn = window.aegisEvaluate;
  if (!fn) {
    return null;
  }
  try {
    return JSON.parse(fn(JSON.stringify({op, ...payload}))) as
        Record<string, unknown>;
  } catch {
    return null;
  }
}

function localeCode(): 'zh-CN'|'zh-TW'|'en' {
  const lang = document.documentElement.lang || 'zh-CN';
  if (lang.startsWith('zh-TW') || lang.startsWith('zh-HK')) {
    return 'zh-TW';
  }
  if (lang.startsWith('zh')) {
    return 'zh-CN';
  }
  return 'en';
}

async function summarizeActiveTab() {
  const snap: PageSnapshot = await sendWithPromise('captureActiveTab');
  if (snap.error) {
    showResult(snap.error);
    return;
  }
  const snapshot = {
    url: snap.url ?? '',
    title: snap.title ?? '',
    textSample: snap.textSample ?? '',
    passwordFields: snap.passwordFields ?? 0,
    forms: snap.forms ?? 0,
  };
  const local = workerEvaluate('summarize', {locale: localeCode(), snapshot});
  if (local && !local['error']) {
    const result: SummarizeResult = {
      ok: true,
      url: snap.url,
      summary: String(local['summary'] ?? ''),
      bullets: Array.isArray(local['bullets']) ? local['bullets'] as string[] :
                                                [],
      risks: Array.isArray(local['risks']) ? local['risks'] as string[] : [],
      backend: String(local['backend'] ?? 'mock'),
      modelReady: Boolean(local['modelReady'] ?? true),
      workerReady: true,
      charsIn: snapshot.textSample.length,
      charsSent: 0,
      stayedOnDevice: true,
      destination: 'local',
    };
    const zh = localeCode().startsWith('zh');
    showResult(piiLine(snapshot.textSample, zh) + '\n' + formatSummary(result));
    const prompt =
        workerEvaluate('buildPrompt', {locale: localeCode(), snapshot});
    if (prompt && prompt['system'] && prompt['user']) {
      const refined: SummarizeResult = await sendWithPromise(
          'ollamaChat', String(prompt['system']), String(prompt['user']));
      if (refined.ok && refined.backend === 'ollama' && refined.summary) {
        refined.url = snap.url;
        showResult(
            piiLine(snapshot.textSample, localeCode().startsWith('zh')) + '\n' +
            formatSummary(refined));
      }
    }
    return;
  }
  const fallback: SummarizeResult =
      await sendWithPromise('summarizeActiveTab');
  showResult(
      piiLine(snapshot.textSample, localeCode().startsWith('zh')) + '\n' +
      formatSummary(fallback));
}

async function init() {
  const status: AegisStatus = await sendWithPromise('getStatus');
  applyStatus(status);
  bindToggle('tracker', 'trackerBlocking');
  bindToggle('phish', 'phishInterstitial');
  bindToggle('fingerprint', 'fingerprintGuard');
  bindToggle('link-sanitize', 'linkSanitize');
  bindToggle('cookie-janitor', 'cookieJanitor');
  bindToggle('cname-uncloak', 'cnameUncloak');
  bindToggle('bounce-tracking', 'bounceTracking');
  bindToggle('policy-worker', 'policyWorker');
  bindToggle('privacy-ai', 'privacyAi');
  bindToggle('ai-control', 'aiControl');
  bindToggle('filter-auto', 'filterListAutoUpdate');
  actionButton('filter-update').addEventListener('click', () => {
    void (async () => {
      actionButton('filter-update').disabled = true;
      const next: AegisStatus = await sendWithPromise('updateFilterLists');
      applyStatus(next);
    })();
  });
  actionButton('summarize').addEventListener('click', () => {
    void (async () => {
      actionButton('summarize').disabled = true;
      try {
        await summarizeActiveTab();
      } catch (err) {
        showResult(String(err));
      }
      const next: AegisStatus = await sendWithPromise('getStatus');
      applyStatus(next);
    })();
  });
  actionButton('ollama-save').addEventListener('click', () => {
    void (async () => {
      const next: AegisStatus = await sendWithPromise(
          'setOllamaSettings', textField('ollama-url').value.trim(),
          textField('ollama-model').value.trim());
      applyStatus(next);
      if (next.ok === false) {
        const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
        getRequiredElement('ollama-status').textContent =
            next.error ||
            (zh ? '地址必须是本机 loopback。' : 'URL must be loopback.');
        return;
      }
      await probeOllama();
    })();
  });
  actionButton('ollama-probe').addEventListener('click', () => {
    void probeOllama();
  });
  actionButton('fp-probe').addEventListener('click', () => {
    void probeFingerprint();
  });
  if (status.privacyAi) {
    void probeOllama();
  }
  window.setInterval(() => {
    void (async () => {
      const next: AegisStatus = await sendWithPromise('getStatus');
      fillActivityLog(next.recentEvents || []);
      fillAiControl(next);
      getRequiredElement('filter-meta').textContent = formatMeta(next);
    })();
  }, 2000);
}

async function probeOllama() {
  actionButton('ollama-probe').disabled = true;
  try {
    const probe: OllamaProbeResult = await sendWithPromise(
        'probeOllama', textField('ollama-url').value.trim());
    getRequiredElement('ollama-status').textContent = formatOllamaStatus(probe);
    fillModelList(probe.models || []);
    if (probe.ok && probe.ollamaModel && !textField('ollama-model').value) {
      textField('ollama-model').value = probe.ollamaModel;
    }
  } catch (err) {
    getRequiredElement('ollama-status').textContent = String(err);
  }
  const next: AegisStatus = await sendWithPromise('getStatus');
  applyStatus(next);
}

document.addEventListener('DOMContentLoaded', () => {
  void init();
});
