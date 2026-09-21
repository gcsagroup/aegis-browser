// Copyright 2026 GCSA

import './policy_worker.js';

import {addWebUiListener, sendWithPromise} from 'chrome://resources/js/cr.js';
import {getRequiredElement} from 'chrome://resources/js/util.js';

interface PrivacyEvent {
  kind: string;
  reason: string;
  site: string;
  domain: string;
  count: number;
  firstTime: number;
  lastTime: number;
  details: string[];
}

type ModelApiFormat = 'openai'|'anthropic'|'gemini';
type ModelListState = 'idle'|'loading'|'loaded'|'empty'|'error';

interface ModelDraft {
  modelName: string;
}

interface AegisStatus {
  profileAvailable?: boolean;
  enabled: boolean;
  trackerBlocking: boolean;
  phishInterstitial: boolean;
  fingerprintGuard: boolean;
  minerGuard: boolean;
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
  aiControlAvailable?: boolean;
  aiControlRunning?: boolean;
  aiControlPort?: number;
  aiControlAddress?: string;
  aiControlLoopbackOnly?: boolean;
  aiControlClients?: number;
  browserAgentAvailable?: boolean;
  browserAgentEnabled?: boolean;
  modelProvider?: string;
  modelBaseUrl?: string;
  modelName?: string;
  modelApiKeyConfigured?: boolean;
  modelCredentialState?: string;
  isAndroid?: boolean;
  torrentSupported?: boolean;
  torrentDisclosureAcknowledged?: boolean;
  torrentTaskId?: string;
  recentEvents?: PrivacyEvent[];
  ok?: boolean;
  error?: string;
}

interface PageSnapshot {
  url: string;
  title: string;
  textSample: string;
  passwordFields: number;
  forms: number;
}

interface CapturedSummary {
  ok: boolean;
  error?: string;
  requestId?: string;
  snapshot?: PageSnapshot;
  modelProvider?: string;
  modelBaseUrl?: string;
  modelName?: string;
}

interface PreparedSummary {
  schemaVersion: 1;
  sanitizedSnapshot: PageSnapshot;
  heuristic: {summary: string; bullets: string[]; risks: string[];};
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

interface ModelListResult {
  ok: boolean;
  error?: string;
  modelProvider?: string;
  modelBaseUrl?: string;
  modelName?: string;
  modelApiKeyConfigured?: boolean;
  modelCredentialState?: string;
  models?: string[];
}

type ModuleName =
    'trackerBlocking'|'phishInterstitial'|'fingerprintGuard'|'minerGuard'|
    'filterListAutoUpdate'|'linkSanitize'|'cookieJanitor'|'cnameUncloak'|
    'bounceTracking'|'policyWorker'|'privacyAi'|'aiControl'|'browserAgent';

const CUSTOM_MODEL_VALUE = '__custom_model__';
const MODEL_ENDPOINTS: Record<ModelApiFormat, string> = {
  openai: 'https://api.openai.com/v1',
  anthropic: 'https://api.anthropic.com/v1',
  gemini: 'https://generativelanguage.googleapis.com/v1beta',
};
const SENSITIVE_HOST_LABEL_MARKERS = [
  'bank',
  'paypal',
  'alipay',
  'gov',
  'irs',
  'healthcare',
  'hospital',
  'clinic',
];
const modelDrafts = new Map<string, ModelDraft>();
const lastModelEndpoints = new Map<ModelApiFormat, string>();
const configuredCredentials = new Map<string, boolean>();
const credentialStates = new Map<string, string>();
let activeModelFormat: ModelApiFormat = 'openai';
let activeModelBaseUrl = MODEL_ENDPOINTS.openai;
let activeModelContextKey = '';
let modelFormInitialized = false;
let modelFormDirty = false;
let modelFormRevision = 0;
let modelListRequestSerial = 0;
let modelSettingsRequestSerial = 0;
let lastModelStatusSignature = '';
let modelControlsEnabled = false;
let modelControlsAndroid = false;
let summaryRequestRunning = false;

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

function selectField(id: string): HTMLSelectElement {
  const el = getRequiredElement(id);
  if (!(el instanceof HTMLSelectElement)) {
    throw new Error(`Missing select #${id}`);
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

function workerEvaluate(
    op: 'ping'|'prepareSummary',
    payload: Record<string, unknown> = {}): Record<string, unknown>|null {
  const evaluate = window.aegisEvaluate;
  if (!evaluate) {
    return null;
  }
  try {
    const value =
        JSON.parse(evaluate(JSON.stringify({op, ...payload}))) as unknown;
    return typeof value === 'object' && value !== null ?
        value as Record<string, unknown>:
        null;
  } catch {
    return null;
  }
}

function withRendererPolicyWorkerStatus(status: AegisStatus): AegisStatus {
  if (!status.policyWorker) {
    return {...status, policyWorkerReady: false, policyWorkerError: ''};
  }
  const ping = workerEvaluate('ping');
  const ready = ping?.['ok'] === true && ping?.['worker'] === 'aegis-policy';
  return {
    ...status,
    policyWorkerReady: ready,
    policyWorkerError: ready ? '' : 'renderer policy worker ping failed',
  };
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) &&
      value.every((item) => typeof item === 'string');
}

function hasExactKeys(value: Record<string, unknown>, keys: string[]): boolean {
  const actual = Object.keys(value).sort();
  return actual.length === keys.length &&
      actual.every((key, index) => key === keys[index]);
}

function parsePreparedSummary(value: Record<string, unknown>|null):
    PreparedSummary|null {
  if (!value || value['schemaVersion'] !== 1 ||
      !hasExactKeys(
          value, ['heuristic', 'sanitizedSnapshot', 'schemaVersion'])) {
    return null;
  }
  const snapshot = value['sanitizedSnapshot'];
  const heuristic = value['heuristic'];
  if (typeof snapshot !== 'object' || snapshot === null ||
      typeof heuristic !== 'object' || heuristic === null) {
    return null;
  }
  const safe = snapshot as Record<string, unknown>;
  const local = heuristic as Record<string, unknown>;
  if (!hasExactKeys(
          safe, ['forms', 'passwordFields', 'textSample', 'title', 'url']) ||
      !hasExactKeys(local, ['bullets', 'risks', 'summary']) ||
      typeof safe['url'] !== 'string' || typeof safe['title'] !== 'string' ||
      typeof safe['textSample'] !== 'string' ||
      typeof safe['passwordFields'] !== 'number' ||
      typeof safe['forms'] !== 'number' ||
      typeof local['summary'] !== 'string' ||
      !isStringArray(local['bullets']) || !isStringArray(local['risks'])) {
    return null;
  }
  return value as unknown as PreparedSummary;
}

function localeCode(): 'zh-CN'|'zh-TW'|'en' {
  const lang = document.documentElement.lang || 'zh-CN';
  if (/^zh-(?:TW|HK|Hant)/i.test(lang)) {
    return 'zh-TW';
  }
  return lang.startsWith('zh') ? 'zh-CN' : 'en';
}

function formatMeta(status: AegisStatus): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const count = status.filterListHostCount || 0;
  const zh = lang.startsWith('zh');
  if (!status.filterListLastUpdated) {
    if (count) {
      return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `已載入 ${count} 條主機規則。` : `已加载 ${count} 条主机规则。`) :
                  `Loaded ${count} filter rules.`;
    }
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '尚未下載過濾列表。' : '尚未下载过滤列表。') : 'No compiled filter list yet.';
  }
  const when = new Date(status.filterListLastUpdated * 1000).toLocaleString();
  const err = status.filterListLastError ?
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? ` 上次錯誤：${status.filterListLastError}` : ` 上次错误：${status.filterListLastError}`) :
            ` Last error: ${status.filterListLastError}`) :
      '';
  return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `已載入 ${count} 條主機規則 · 更新於 ${when}${err}` : `已加载 ${count} 条主机规则 · 更新于 ${when}${err}`) :
              `Loaded ${count} filter rules · updated ${when}${err}`;
}

function formatPrivacyMeta(status: AegisStatus): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const zh = lang.startsWith('zh');
  if (!status.privacyAi) {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '隱私摘要已關閉。' : '隐私摘要已关闭。') : 'Privacy summary is off.';
  }
  if (status.policyWorkerReady) {
    const format = normalizeModelApiFormat(status.modelProvider);
    const endpoint = status.modelBaseUrl || MODEL_ENDPOINTS[format];
    const model = status.modelName ? ` · ${status.modelName}` : '';
    const name = modelApiFormatLabel(format);
    if (isLocalModelEndpoint(endpoint)) {
      return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `本機服務：${name}${model}` : `本机服务：${name}${model}`) :
                  `Local service: ${name}${model}`;
    }
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `遠端 API 格式：${name}${model}` : `远程 API 格式：${name}${model}`) :
                `Remote API format: ${name}${model}`;
  }
  const err = status.policyWorkerError ? ` (${status.policyWorkerError})` : '';
  return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `本地隱私處理暫不可用，無法生成摘要。${err}` : `本地隐私处理暂不可用，无法生成摘要。${err}`) :
              `Local privacy processing is unavailable; summaries cannot be generated.${err}`;
}

function fillOverview(status: AegisStatus) {
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const events = status.recentEvents || [];
  let blocked = 0;
  let links = 0;
  let storage = 0;
  for (const event of events) {
    const count = Number.isFinite(event.count) ? Math.max(0, event.count) : 0;
    if (event.kind === 'block' || event.kind === 'phish') {
      blocked += count;
    } else if (event.kind === 'param') {
      links += count;
    } else if (event.kind === 'cookie' || event.kind === 'bounce') {
      storage += count;
    }
  }
  getRequiredElement('overview-blocked').textContent = String(blocked);
  getRequiredElement('overview-links').textContent = String(links);
  getRequiredElement('overview-storage').textContent = String(storage);

  const dot = getRequiredElement('health-dot');
  const state = getRequiredElement('health-state');
  if (!status.enabled) {
    dot.dataset['state'] = 'off';
    state.textContent = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'Aegis 總體防護已關閉' : 'Aegis 总体防护已关闭') : 'Aegis protection is off';
    return;
  }
  const policyUnavailable = status.policyWorker && !status.policyWorkerReady;
  const minerObserved = events.some((event) => event.kind === 'miner');
  if (status.minerGuard && minerObserved) {
    dot.dataset['state'] = 'warning';
    state.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本次會話曾有頁面符合挖礦風險組合規則（歷史提醒，未阻斷）' : '本次会话曾有页面符合挖矿风险组合规则（历史提醒，未阻断）') :
        'A page in this session matched the mining-risk rule (prior observe-only alert)';
    return;
  }
  if (status.filterListLastError || policyUnavailable) {
    dot.dataset['state'] = 'warning';
    state.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '核心防護執行中，部分能力需注意' : '核心防护运行中，部分能力需注意') :
        'Core protection active; some features need attention';
    return;
  }
  dot.dataset['state'] = 'ok';
  state.textContent = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'Aegis 防護正在執行' : 'Aegis 防护正在运行') : 'Aegis protection is active';
}

function normalizeModelApiFormat(value?: string): ModelApiFormat {
  if (value === 'anthropic' || value === 'gemini') {
    return value;
  }
  return 'openai';
}

function modelApiFormatLabel(format: ModelApiFormat): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const suffix = /^zh-(?:TW|HK|Hant)/i.test(lang) ? '相容' :
      lang.startsWith('zh')                                           ? '兼容' :
                              'compatible';
  if (format === 'openai') {
    return `OpenAI ${suffix}`;
  }
  if (format === 'anthropic') {
    return lang.startsWith('zh') ? `Claude（Anthropic）${suffix}` :
                                   'Anthropic (Claude) compatible';
  }
  return `Gemini ${suffix}`;
}

function normalizeModelEndpoint(endpoint: string): string {
  const trimmed = endpoint.trim();
  try {
    const url = new URL(trimmed);
    url.hash = '';
    return url.toString().replace(/\/+$/, '');
  } catch {
    return trimmed.replace(/\/+$/, '');
  }
}

function modelContextKey(format: ModelApiFormat, endpoint: string): string {
  return `${format}\n${normalizeModelEndpoint(endpoint)}`;
}

function isLocalModelEndpoint(endpoint: string): boolean {
  try {
    const url = new URL(endpoint);
    if ((url.protocol !== 'http:' && url.protocol !== 'https:') ||
        url.username || url.password || url.search || url.hash ||
        url.port === '0') {
      return false;
    }
    const host = url.hostname.replace(/^\[|\]$/g, '');
    if (host === '::1') {
      return true;
    }
    const octets = host.split('.');
    return octets.length === 4 && octets[0] === '127' &&
        octets.every((part) => /^\d{1,3}$/.test(part) && Number(part) <= 255);
  } catch {
    return false;
  }
}

function modelListPlaceholder(state: ModelListState): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const zh = lang.startsWith('zh');
  if (state === 'loading') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '正在載入模型…' : '正在加载模型…') : 'Loading models…';
  }
  if (state === 'loaded') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '請選擇模型' : '请选择模型') : 'Select a model';
  }
  if (state === 'empty') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '未返回可用模型' : '未返回可用模型') : 'No models returned';
  }
  if (state === 'error') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '模型載入失敗' : '模型加载失败') : 'Model loading failed';
  }
  return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '尚未載入模型' : '尚未加载模型') : 'Models not loaded';
}

function updateCustomModelVisibility() {
  const custom = selectField('model-select').value === CUSTOM_MODEL_VALUE;
  getRequiredElement('model-custom-field').hidden = !custom;
}

function fillModelList(
    models: string[], selectedModel: string, state: ModelListState = 'idle') {
  const select = selectField('model-select');
  const uniqueModels = Array.from(new Set(
      models.map((name) => name.trim()).filter((name) => name.length > 0)));
  uniqueModels.sort((left, right) => left.localeCompare(right));
  const selectedModelIsListed = uniqueModels.includes(selectedModel);

  const placeholder = document.createElement('option');
  placeholder.value = '';
  placeholder.disabled = true;
  placeholder.textContent = modelListPlaceholder(state);
  select.replaceChildren(placeholder);
  for (const name of uniqueModels) {
    const option = document.createElement('option');
    option.value = name;
    option.textContent = name;
    select.appendChild(option);
  }
  const custom = document.createElement('option');
  custom.value = CUSTOM_MODEL_VALUE;
  custom.textContent =
      (document.documentElement.lang || 'zh-CN').startsWith('zh') ?
      (localeCode() === 'zh-TW' ? '自訂模型…' : '自定义模型…') :
      'Custom model…';
  select.appendChild(custom);
  select.value = selectedModelIsListed ? selectedModel : '';
  if (selectedModel && !selectedModelIsListed) {
    select.value = CUSTOM_MODEL_VALUE;
    textField('model-custom').value = selectedModel;
  }
  updateCustomModelVisibility();
}

function selectedModelName(): string {
  const selected = selectField('model-select').value;
  return selected === CUSTOM_MODEL_VALUE ?
      textField('model-custom').value.trim() :
      selected.trim();
}

function rememberModelDraft() {
  if (!modelFormInitialized || !activeModelContextKey) {
    return;
  }
  modelDrafts.set(activeModelContextKey, {modelName: selectedModelName()});
  lastModelEndpoints.set(activeModelFormat, activeModelBaseUrl);
}

function activateModelContext(
    format: ModelApiFormat, baseUrl: string, modelName?: string) {
  activeModelFormat = format;
  activeModelBaseUrl = baseUrl.trim();
  activeModelContextKey = modelContextKey(format, activeModelBaseUrl);
  lastModelEndpoints.set(format, activeModelBaseUrl);
  if (modelName !== undefined) {
    modelDrafts.set(activeModelContextKey, {modelName});
  }
  selectField('model-provider').value = format;
  textField('model-endpoint').value = activeModelBaseUrl;
  textField('model-api-key').value = '';
  textField('model-custom').value = '';
  const draft = modelDrafts.get(activeModelContextKey);
  fillModelList([], draft?.modelName || '', 'idle');
}

function markModelFormChanged() {
  modelFormDirty = true;
  modelFormRevision += 1;
}

function renderCredentialState() {
  const state = getRequiredElement('model-api-key-state');
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const typed = textField('model-api-key').value.length > 0;
  const contextKey =
      modelContextKey(activeModelFormat, textField('model-endpoint').value);
  const configured = configuredCredentials.get(contextKey) === true;
  const detail = credentialStates.get(contextKey)?.trim();
  if (typed) {
    state.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '將使用新輸入的 API 金鑰；儲存成功後不會回顯。' : '将使用新输入的 API 密钥；保存成功后不会回显。') :
        'The new API key will be used and will not be shown after saving.';
    return;
  }
  if (configured) {
    state.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `當前 API 格式與地址已配置金鑰且不會回顯${
            detail ? ` · ${detail}` : ''}` : `当前 API 格式与地址已配置密钥且不会回显${
            detail ? ` · ${detail}` : ''}`) :
        `A key is configured for this API format and endpoint and is hidden${
            detail ? ` · ${detail}` : ''}`;
    return;
  }
  state.textContent = zh ?
      (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '尚未配置 API 金鑰；是否需要金鑰取決於所選服務。' : '尚未配置 API 密钥；是否需要密钥取决于所选服务。') :
      'No API key is configured. Key requirements depend on the selected service.';
}

function updateModelFormatPresentation() {
  const endpoint = textField('model-endpoint');
  const local = isLocalModelEndpoint(endpoint.value);
  const formatName = modelApiFormatLabel(activeModelFormat);
  endpoint.readOnly = false;
  endpoint.placeholder = MODEL_ENDPOINTS[activeModelFormat];
  getRequiredElement('model-api-key-field').hidden = false;
  actionButton('model-key-clear').hidden = modelControlsAndroid;
  const note = getRequiredElement('model-data-note');
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  note.textContent = local ?
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `在本機處理，使用 ${formatName}；` +
               '是否需要 API 金鑰取決於服務，儲存後不回顯。' : `在本机处理，使用 ${formatName}；` +
               '是否需要 API 密钥取决于服务，保存后不回显。') :
            `Processing on this device using ${formatName}; ` +
               'key requirements depend on the service. Saved keys are hidden.') :
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `脫敏後的頁面文字會發往當前地址，使用 ${formatName}；` +
               '是否需要 API 金鑰取決於服務，儲存後不回顯。' : `脱敏后的页面文本会发往当前地址，使用 ${formatName}；` +
               '是否需要 API 密钥取决于服务，保存后不回显。') :
            `Redacted page text is sent to the current endpoint using ${
                formatName}; key requirements depend on the service. Saved keys are hidden.`);
  renderCredentialState();
  updateCustomModelVisibility();
}

function updateModelControlAvailability() {
  const available = modelControlsEnabled && !modelControlsAndroid;
  selectField('model-provider').disabled = !available;
  textField('model-endpoint').disabled = !available;
  textField('model-api-key').disabled = !available;
  selectField('model-select').disabled = !available;
  textField('model-custom').disabled = !available;
  actionButton('model-load').disabled = !available;
  actionButton('model-save').disabled = !available;
  actionButton('model-key-clear').disabled = !available;
}

function modelStatusSignature(status: AegisStatus): string {
  const format = normalizeModelApiFormat(status.modelProvider);
  return [
    format,
    normalizeModelEndpoint(status.modelBaseUrl || MODEL_ENDPOINTS[format]),
    status.modelName || '',
    status.modelApiKeyConfigured ? '1' : '0',
    status.modelCredentialState || '',
  ].join('\n');
}

function applyModelStatus(status: AegisStatus, force = false) {
  const format = normalizeModelApiFormat(status.modelProvider);
  const baseUrl = (status.modelBaseUrl || MODEL_ENDPOINTS[format]).trim();
  const modelName = (status.modelName || '').trim();
  const contextKey = modelContextKey(format, baseUrl);
  configuredCredentials.set(contextKey, !!status.modelApiKeyConfigured);
  credentialStates.set(contextKey, status.modelCredentialState || '');
  const signature = modelStatusSignature(status);
  if (modelFormInitialized && !force && modelFormDirty) {
    if (contextKey === activeModelContextKey) {
      renderCredentialState();
    }
    return;
  }
  if (modelFormInitialized && !force &&
      signature === lastModelStatusSignature) {
    return;
  }

  activateModelContext(format, baseUrl, modelName);
  modelFormInitialized = true;
  modelFormDirty = false;
  modelFormRevision += 1;
  lastModelStatusSignature = signature;
  updateModelFormatPresentation();
}

function formatModelStatus(result: ModelListResult): string {
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const format =
      normalizeModelApiFormat(result.modelProvider || activeModelFormat);
  const name = modelApiFormatLabel(format);
  if (!result.ok) {
    const error = result.error ? ` (${result.error})` : '';
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `${name} 模型載入失敗${error}` : `${name} 模型加载失败${error}`) :
                `Failed to load ${name} models${error}`;
  }
  const count = result.models?.length || 0;
  if (count === 0) {
    return zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `當前地址已按 ${name} 連線，但未返回可用模型。` : `当前地址已按 ${name} 连接，但未返回可用模型。`) :
        `The current endpoint connected as ${name}, but returned no models.`;
  }
  return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `已從當前地址按 ${name} 載入 ${count} 個模型。` : `已从当前地址按 ${name} 加载 ${count} 个模型。`) :
              `Loaded ${count} models from the current endpoint as ${name}.`;
}

interface ModelFormSnapshot {
  format: ModelApiFormat;
  baseUrl: string;
  contextKey: string;
  modelName: string;
  revision: number;
}

function captureModelFormSnapshot(): ModelFormSnapshot {
  const baseUrl = textField('model-endpoint').value.trim();
  return {
    format: activeModelFormat,
    baseUrl,
    contextKey: modelContextKey(activeModelFormat, baseUrl),
    modelName: selectedModelName(),
    revision: modelFormRevision,
  };
}

function isCurrentModelSnapshot(snapshot: ModelFormSnapshot): boolean {
  const current = captureModelFormSnapshot();
  return current.format === snapshot.format &&
      current.baseUrl === snapshot.baseUrl &&
      current.contextKey === snapshot.contextKey &&
      current.modelName === snapshot.modelName &&
      current.revision === snapshot.revision;
}

function applyStatus(status: AegisStatus) {
  status = withRendererPolicyWorkerStatus(status);
  checkbox('tracker').checked = status.trackerBlocking;
  checkbox('phish').checked = status.phishInterstitial;
  checkbox('fingerprint').checked = status.fingerprintGuard;
  checkbox('miner-guard').checked = status.minerGuard;
  checkbox('link-sanitize').checked = status.linkSanitize;
  checkbox('cookie-janitor').checked = status.cookieJanitor;
  checkbox('cname-uncloak').checked = status.cnameUncloak;
  checkbox('bounce-tracking').checked = status.bounceTracking;
  checkbox('policy-worker').checked = status.policyWorker;
  checkbox('privacy-ai').checked = status.privacyAi;
  const android = !!status.isAndroid;
  modelControlsEnabled = status.privacyAi;
  modelControlsAndroid = android;
  const modelFields = document.getElementById('model-fields');
  if (modelFields instanceof HTMLElement) {
    modelFields.hidden = android;
  }
  const aiSection = document.getElementById('ai-control-section');
  if (aiSection instanceof HTMLElement) {
    aiSection.hidden = android;
  }
  actionButton('model-load').hidden = android;
  actionButton('model-save').hidden = android;
  actionButton('model-key-clear').hidden = android;
  applyModelStatus(status);
  updateModelFormatPresentation();
  updateModelControlAvailability();
  if (!android) {
    fillAiControl(status);
  }
  fillBrowserAgent(status);
  checkbox('filter-auto').checked = status.filterListAutoUpdate;
  getRequiredElement('filter-meta').textContent = formatMeta(status);
  getRequiredElement('privacy-meta').textContent = formatPrivacyMeta(status);
  fillOverview(status);
  fillActivityLog(status.recentEvents || []);
  actionButton('filter-update').disabled = status.filterListUpdating;
  actionButton('summarize').disabled =
      summaryRequestRunning || !status.privacyAi || !status.policyWorkerReady;
  if (status.profileAvailable === false) {
    document
        .querySelectorAll<HTMLInputElement|HTMLButtonElement|
                          HTMLSelectElement|HTMLTextAreaElement>(
            'input, button, select, textarea')
        .forEach(control => control.disabled = true);
    showResult(status.error ||
               (document.documentElement.lang.startsWith('zh') ?
                    (localeCode() === 'zh-TW' ? '目前瀏覽器設定不支援 Aegis。' : '当前浏览器配置不支持 Aegis。') :
                    'Aegis is unavailable for this browser profile.'));
  }
}

async function setModule(module: ModuleName, enabled: boolean) {
  const status: AegisStatus =
      await sendWithPromise('setModuleEnabled', module, enabled);
  applyStatus(status);
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

function siteFromUrl(value: string): string {
  try {
    const url = new URL(value);
    return url.hostname || url.origin;
  } catch {
    return document.documentElement.lang.startsWith('zh') ? (localeCode() === 'zh-TW' ? '目前頁面' : '当前页面') :
                                                            'current page';
  }
}

function apiFormatFromBackend(value?: string): ModelApiFormat|null {
  if (value === 'openai' || value === 'anthropic' || value === 'gemini') {
    return value;
  }
  return null;
}

function summaryBackendLabel(value: string|undefined, zh: boolean): string {
  const format = apiFormatFromBackend(value);
  if (format) {
    return modelApiFormatLabel(format);
  }
  if (value === 'heuristic') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本地文字摘要' : '本地文字摘要') : 'Local text summary';
  }
  return value ? (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '相容 API' : '兼容 API') : 'Compatible API') :
                 (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '未知' : '未知') : 'Unknown');
}

function summaryErrorLabel(value: string, zh: boolean): string {
  if (!zh) {
    return value;
  }
  if (value === 'model request timed out') {
    return localeCode() === 'zh-TW' ? '模型請求逾時' : '模型请求超时';
  }
  if (value === 'model request already in progress') {
    return localeCode() === 'zh-TW' ? '已有模型請求正在進行' : '已有模型请求正在进行';
  }
  if (value.startsWith('model network request failed')) {
    return value.replace('model network request failed', localeCode() === 'zh-TW' ? '模型網路請求失敗' : '模型网络请求失败');
  }
  if (value === 'model summary blocked: sensitive host label') {
    return localeCode() === 'zh-TW' ? '偵測到敏感網站，已略過模型呼叫' : '检测到敏感站点，已跳过模型调用';
  }
  if (value === 'model summary blocked: password field detected') {
    return localeCode() === 'zh-TW' ? '偵測到密碼欄位，已略過模型呼叫' : '检测到密码字段，已跳过模型调用';
  }
  return value;
}

function formatSummary(result: SummarizeResult, status: AegisStatus): string {
  const lang = document.documentElement.lang || 'zh-CN';
  const zh = lang.startsWith('zh');
  if (!result.ok) {
    return result.error || 'error';
  }
  const configuredFormat = normalizeModelApiFormat(status.modelProvider);
  const backendFormat = apiFormatFromBackend(result.backend);
  const remoteAttempted = result.stayedOnDevice === false;
  const modelAttempted =
      (result.charsSent || 0) > 0 && result.destination !== 'local';
  const usedFormat =
      backendFormat || (modelAttempted ? configuredFormat : null);
  const location = result.stayedOnDevice === true ?
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本機處理 · 未出網' : '本机处理 · 未出网') : 'On-device · did not leave this computer') :
      result.stayedOnDevice === false ?
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '遠端處理 · 脫敏文字已出網' : '远程处理 · 脱敏文本已出网') :
            'Remote processing · redacted text left this device') :
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '處理位置未知' : '处理位置未知') : 'Processing location unknown');
  const format = usedFormat ? modelApiFormatLabel(usedFormat) :
                              (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本地文書處理' : '本地文字处理') : 'On-device heuristic');
  const lines = [
    location,
    (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'API 格式：' : 'API 格式：') : 'API format: ') + format,
    (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '後端：' : '后端：') : 'Backend: ') +
        (result.backend === 'heuristic' && modelAttempted ?
             (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本地文字摘要（模型呼叫失敗後降級）' : '本地文字摘要（模型调用失败后降级）') :
                   'Heuristic summary (fallback after model failure)') :
             summaryBackendLabel(result.backend, zh)),
  ];
  if (usedFormat && status.modelName) {
    lines.push((zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '模型：' : '模型：') : 'Model: ') + status.modelName);
  }
  const destination =
      result.destination || (remoteAttempted ? status.modelBaseUrl : 'local');
  lines.push(
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '目標：' : '目标：') : 'Destination: ') +
      (destination === 'local' ? (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本機' : '本机') : 'On-device') :
                                 (destination || '—')));
  if (result.charsIn) {
    lines.push(
        (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '處理字數：' : '处理字数：') : 'Characters read: ') + String(result.charsIn));
  }
  if (result.charsSent) {
    lines.push(
        (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '發給模型：' : '发给模型：') : 'Sent to model: ') + String(result.charsSent));
  }
  lines.push('');
  if (result.url) {
    lines.push((zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '來源站點：' : '来源站点：') : 'Source site: ') + siteFromUrl(result.url));
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
  if (result.error) {
    lines.push(
        (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '降級原因：' : '降级原因：') : 'Fallback reason: ') +
        summaryErrorLabel(result.error, zh));
  }
  return lines.filter((line, i, arr) => line !== '' || arr[i - 1] !== '')
      .join('\n');
}

function isSensitiveSummarySource(snapshot: PageSnapshot): boolean {
  if (snapshot.passwordFields > 0) {
    return true;
  }
  try {
    const url = new URL(snapshot.url);
    if ((url.protocol !== 'http:' && url.protocol !== 'https:') ||
        !url.hostname) {
      return true;
    }
    return url.hostname.toLowerCase().split('.').some(
        (label) => SENSITIVE_HOST_LABEL_MARKERS.some(
            (marker) => label.includes(marker)));
  } catch {
    return true;
  }
}

async function confirmSummaryPreview(
    captured: CapturedSummary, prepared: PreparedSummary,
    status: AegisStatus): Promise<boolean> {
  if (!captured.snapshot) {
    return false;
  }
  const dialog = getRequiredElement('summary-preview');
  if (!(dialog instanceof HTMLDialogElement)) {
    return false;
  }
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const format = normalizeModelApiFormat(status.modelProvider);
  const endpoint = status.modelBaseUrl || MODEL_ENDPOINTS[format];
  const model = status.modelName || (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '未選擇模型' : '未选择模型') : 'No model selected');
  const local = isLocalModelEndpoint(endpoint);
  const formatName = modelApiFormatLabel(format);
  let destination: string;
  if (isSensitiveSummarySource(captured.snapshot)) {
    destination = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `敏感頁面：強制本機處理 · API 格式：本地文書處理 · 模型：不呼叫` +
            `（已配置 ${formatName} · ${model}）· 目標：本機；不傳送到外網。` : `敏感页面：强制本机处理 · API 格式：本地文字处理 · 模型：不调用` +
            `（已配置 ${formatName} · ${model}）· 目标：本机；不发送到外网。`) :
        `Sensitive page: forced on-device · API format: on-device heuristic · ` +
            `Model: not used (configured ${formatName} · ${model}) · ` +
            'Destination: on-device; nothing is sent remotely.';
  } else if (local) {
    destination = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `本機處理 · API 格式：${formatName} · 模型：${model} · ` +
            `目標：${endpoint}` : `本机处理 · API 格式：${formatName} · 模型：${model} · ` +
            `目标：${endpoint}`) :
        `On-device · API format: ${formatName} · Model: ${model} · ` +
            `Destination: ${endpoint}`;
  } else {
    destination = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `遠端處理 · API 格式：${formatName} · 模型：${model} · ` +
            `目標：${endpoint}；僅傳送脫敏文字。` : `远程处理 · API 格式：${formatName} · 模型：${model} · ` +
            `目标：${endpoint}；仅发送脱敏文本。`) :
        `Remote · API format: ${formatName} · Model: ${model} · ` +
            `Destination: ${endpoint}; only redacted text is sent.`;
  }
  getRequiredElement('summary-preview-site').textContent =
      (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '來源站點：' : '来源站点：') : 'Source site: ') +
      siteFromUrl(captured.snapshot.url);
  getRequiredElement('summary-preview-read').textContent =
      String(captured.snapshot.textSample.length);
  getRequiredElement('summary-preview-redacted').textContent =
      String(prepared.sanitizedSnapshot.textSample.length);
  getRequiredElement('summary-preview-destination').textContent = destination;

  return await new Promise<boolean>((resolve) => {
    dialog.addEventListener('close', () => {
      resolve(dialog.returnValue === 'confirm');
    }, {once: true});
    dialog.returnValue = 'cancel';
    dialog.showModal();
  });
}

function kindLabel(kind: string, zh: boolean): string {
  if (kind === 'cookie') {
    return 'Cookie';
  }
  if (kind === 'bounce') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '跳轉' : '跳转') : 'Bounce';
  }
  if (kind === 'block') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '攔截' : '拦截') : 'Block';
  }
  if (kind === 'phish') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '釣魚' : '钓鱼') : 'Phish';
  }
  if (kind === 'miner') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '挖礦風險' : '挖矿风险') : 'Mining risk';
  }
  if (kind === 'cdp') {
    return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '控制' : '控制') : 'CDP';
  }
  return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '引數' : '参数') : 'Param';
}

function fillAiControl(status: AegisStatus) {
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  const toggle = checkbox('ai-control');
  toggle.checked = !!status.aiControl;
  toggle.disabled = status.aiControlAvailable === false;
  const statusEl = getRequiredElement('ai-control-status');
  const connectEl = getRequiredElement('ai-control-connect');
  if (status.aiControlAvailable === false) {
    statusEl.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '為保護無痕分頁，無痕視窗開啟期間暫停本機工具連線；內建 AI 助手仍可使用。' : '为保护无痕标签页，无痕窗口打开期间暂停本机工具连接；内置 AI 助手仍可使用。') :
        'Local tool connections pause while an Incognito window is open to protect private tabs. The built-in AI assistant remains available.';
    connectEl.hidden = true;
    return;
  }
  const on = !!status.aiControl && !!status.aiControlRunning;
  if (!status.aiControl) {
    statusEl.textContent =
        zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'AI 控制已關閉（預設）。' : 'AI 控制已关闭（默认）。') : 'AI control is off (default).';
    connectEl.hidden = true;
    return;
  }
  if (!on) {
    statusEl.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '正在準備本機連線，連線入口暫不可用。' : '正在准备本机连接，连接入口暂不可用。') :
        'Preparing the local connection. Connection details are not available yet.';
    connectEl.hidden = true;
    return;
  }
  const port = status.aiControlPort;
  const address = status.aiControlAddress || '';
  const loopback = status.aiControlLoopbackOnly === true;
  const clients = status.aiControlClients || 0;
  const clientsText = zh ?
      (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? (clients ? `當前 ${clients} 個本機工具 已連線` :
                 '當前沒有工具 連線') : (clients ? `当前 ${clients} 个本机工具 已连接` :
                 '当前没有工具 连接')) :
      (clients ? `${clients} local agent(s) connected` : 'no agent connected');
  statusEl.textContent = clientsText;
  connectEl.hidden = !on;
  if (on) {
    connectEl.textContent =
        `Address: ${address} · Port: ${port} · ${loopback ? 'Loopback' : 'Unknown binding'}\n` +
        `await chromium.connectOverCDP('http://127.0.0.1:${port}')`;
  }
}

function fillBrowserAgent(status: AegisStatus) {
  const section = getRequiredElement('browser-agent-section');
  const toggle = checkbox('browser-agent');
  const open = actionButton('browser-agent-open');
  const statusEl = getRequiredElement('browser-agent-status');
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  section.hidden = false;
  toggle.checked = !!status.browserAgentEnabled;
  toggle.disabled = !status.browserAgentAvailable;
  open.disabled = !status.browserAgentAvailable || !status.browserAgentEnabled;
  if (!status.browserAgentAvailable) {
    statusEl.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '此版本暫無法使用 AI 助手。' : '此版本暂不可使用 AI 助手。') :
        'The AI assistant is unavailable in this build.';
  } else if (status.browserAgentEnabled) {
    statusEl.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '已啟用。高風險操作仍需逐項批准，付款必須手動接管。' : '已启用。高风险操作仍需逐项批准，付款必须手动接管。') :
        'Enabled. High-risk actions still require approval and payment requires takeover.';
  } else {
    statusEl.textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '預設關閉；啟用後可從瀏覽器選單、工具欄或此處開啟。' : '默认关闭；启用后可从浏览器菜单、工具栏或此处打开。') :
        'Off by default. Enable it to open from the browser menu, toolbar, or here.';
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
    const target =
        event.domain || event.site || (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '當前頁面' : '当前页面') : 'this page');
    const reason = event.reason ? ` · ${event.reason}` : '';
    const details =
        event.details?.length ? ` · ${event.details.join(', ')}` : '';
    const count = event.count > 1 ? ` ×${event.count}` : '';
    li.appendChild(
        document.createTextNode(`${target}${reason}${details}${count}`));
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
  result.textContent = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '正在讀取本頁指紋…' : '正在读取本页指纹…') : 'Reading this page…';
  try {
    const canvas = probeCanvas();
    const webgl = probeWebGL();
    const audio = await probeAudio();
    const webgpu = await probeWebGPU();
    const lines: string[] = [];
    if (on) {
      lines.push(
          zh ?
              (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '指紋防護設定已開啟。以下是目前頁面的 API 讀數，不能單獨證明跨站隔離。' : '指纹防护配置已开启。以下是当前页面的 API 读数，不能单独证明跨站隔离。') :
              'Fingerprint protection is configured on. These page API readings alone do not prove cross-site isolation.');
    } else {
      lines.push(
          zh ?
              (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'Fingerprint Guard 關著：這是瀏覽器原始讀數。關開後請重新整理本頁再測。' : 'Fingerprint Guard 关着：这是浏览器原始读数。关开后请刷新本页再测。') :
              'Fingerprint Guard is off: this is the raw browser reading. Toggle, reload, then probe again.');
    }
    if (canvas) {
      lines.push(zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `Canvas 讀數 ${canvas}` : `Canvas 读数 ${canvas}`) : `Canvas ${canvas}`);
    }
    if (webgl.line) {
      lines.push(webgl.line);
    }
    if (audio.hash) {
      let note = '';
      if (!audio.sameRead) {
        note = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '（同一緩衝讀兩次不一致）' : '（同一缓冲读两次不一致）') :
                    ' (same buffer changed on second read)';
      } else if (lastAudioHash && lastAudioHash === audio.hash) {
        note = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '（與本頁上次測量相同）' : '（与本页上次测量相同）') :
                    ' (same as the previous probe on this page)';
      }
      lastAudioHash = audio.hash;
      lines.push(
          (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `Audio 讀數 ${audio.hash}` : `Audio 读数 ${audio.hash}`) : `Audio ${audio.hash}`) + note);
    }
    if (webgpu.line) {
      lines.push(webgpu.line);
    }
    if (on && (webgl.line || webgpu.line)) {
      lines.push(zh ?
          (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ?
              '硬體識別欄位可能為空；是否含有品牌字串不能用來判斷防護效果。' :
              '硬件识别字段可能为空；是否包含品牌字符串不能用来判断防护效果。') :
          'Hardware identity fields may be empty. Brand strings do not establish protection effectiveness.');
    }
    result.textContent = lines.filter(Boolean).join('\n');
  } catch (err) {
    result.textContent =
        zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `讀取失敗：${String(err)}` : `读取失败：${String(err)}`) : `Probe failed: ${String(err)}`;
  } finally {
    actionButton('fp-probe').disabled = false;
  }
}

async function summarizeActiveTab() {
  const captured: CapturedSummary = await sendWithPromise('summarizeActiveTab');
  if (!captured.ok || !captured.requestId || !captured.snapshot) {
    showResult(captured.error || 'summary capture failed');
    return;
  }
  const prepared = parsePreparedSummary(workerEvaluate('prepareSummary', {
    locale: localeCode(),
    snapshot: captured.snapshot,
  }));
  if (!prepared) {
    // Consume the prepared browser request even when the renderer rejects its
    // own output; it must never remain reusable until TTL expiry.
    await sendWithPromise('completePreparedSummary', captured.requestId, {});
    showResult('renderer policy worker rejected the page snapshot');
    return;
  }
  const liveStatus: AegisStatus =
      withRendererPolicyWorkerStatus(await sendWithPromise('getStatus'));
  const status: AegisStatus = {
    ...liveStatus,
    modelProvider: captured.modelProvider || liveStatus.modelProvider,
    modelBaseUrl: captured.modelBaseUrl || liveStatus.modelBaseUrl,
    modelName: captured.modelName || liveStatus.modelName,
  };
  if (!await confirmSummaryPreview(captured, prepared, status)) {
    await sendWithPromise('cancelPreparedSummary', captured.requestId);
    return;
  }
  const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
  showResult(
      isSensitiveSummarySource(captured.snapshot) ?
          (zh ?
               (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '正在生成本機本地文字摘要，不呼叫模型…' : '正在生成本机本地文字摘要，不调用模型…') :
               'Generating an on-device heuristic summary without calling a model…') :
          isLocalModelEndpoint(status.modelBaseUrl || '') ?
          (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '本機模型正在生成，最長等待 3 分鐘…' : '本机模型正在生成，最长等待 3 分钟…') :
                'The local model is generating; allow up to 3 minutes…') :
          (zh ?
               (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '相容模型服務正在生成，最長等待 45 秒…' : '兼容模型服务正在生成，最长等待 45 秒…') :
               'The compatible model service is generating; allow up to 45 seconds…'));
  const result: SummarizeResult = await sendWithPromise(
      'completePreparedSummary', captured.requestId, prepared);
  showResult(formatSummary(result, status));
}

async function runSummaryAction() {
  summaryRequestRunning = true;
  actionButton('summarize').disabled = true;
  try {
    await summarizeActiveTab();
  } catch (err) {
    showResult(String(err));
  } finally {
    summaryRequestRunning = false;
    try {
      const next: AegisStatus = await sendWithPromise('getStatus');
      applyStatus(next);
    } catch (err) {
      actionButton('summarize').disabled = false;
      showResult(String(err));
    }
  }
}

function bindModelControls() {
  selectField('model-provider').addEventListener('change', () => {
    rememberModelDraft();
    const format = normalizeModelApiFormat(selectField('model-provider').value);
    const baseUrl = lastModelEndpoints.get(format) || MODEL_ENDPOINTS[format];
    activateModelContext(format, baseUrl);
    markModelFormChanged();
    updateModelFormatPresentation();
    updateModelControlAvailability();
    const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
    getRequiredElement('model-status').textContent = zh ?
        (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? `已切換到 ${modelApiFormatLabel(activeModelFormat)}，請載入模型。` : `已切换到 ${modelApiFormatLabel(activeModelFormat)}，请加载模型。`) :
        `Switched to ${
            modelApiFormatLabel(activeModelFormat)}. Load models to continue.`;
  });
  textField('model-endpoint').addEventListener('input', () => {
    rememberModelDraft();
    const baseUrl = textField('model-endpoint').value.trim();
    const contextKey = modelContextKey(activeModelFormat, baseUrl);
    const contextChanged = contextKey !== activeModelContextKey;
    activeModelBaseUrl = baseUrl;
    activeModelContextKey = contextKey;
    lastModelEndpoints.set(activeModelFormat, baseUrl);
    if (contextChanged) {
      textField('model-api-key').value = '';
      textField('model-custom').value = '';
      const draft = modelDrafts.get(contextKey);
      fillModelList([], draft?.modelName || '', 'idle');
      const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
      getRequiredElement('model-status').textContent = zh ?
          (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '服務地址已更改，請從當前地址重新載入模型。' : '服务地址已更改，请从当前地址重新加载模型。') :
          'The endpoint changed. Reload models from the current endpoint.';
    }
    markModelFormChanged();
    updateModelFormatPresentation();
    updateModelControlAvailability();
  });
  textField('model-api-key').addEventListener('input', () => {
    markModelFormChanged();
    renderCredentialState();
  });
  selectField('model-select').addEventListener('change', () => {
    updateCustomModelVisibility();
    markModelFormChanged();
  });
  textField('model-custom').addEventListener('input', () => {
    markModelFormChanged();
  });
  actionButton('model-load').addEventListener('click', () => {
    void loadModels();
  });
  actionButton('model-save').addEventListener('click', () => {
    void saveModelSettings(false);
  });
  actionButton('model-key-clear').addEventListener('click', () => {
    void saveModelSettings(true);
  });
}

async function loadModels() {
  if (modelControlsAndroid) {
    return;
  }
  const snapshot = captureModelFormSnapshot();
  const apiKey = textField('model-api-key').value.trim();
  const serial = ++modelListRequestSerial;
  actionButton('model-load').disabled = true;
  fillModelList([], snapshot.modelName, 'loading');
  try {
    const result: ModelListResult = await sendWithPromise(
        'listModels', snapshot.format, snapshot.baseUrl, apiKey);
    if (serial !== modelListRequestSerial ||
        !isCurrentModelSnapshot(snapshot)) {
      return;
    }
    if (apiFormatFromBackend(result.modelProvider) !== snapshot.format ||
        !result.modelBaseUrl ||
        modelContextKey(snapshot.format, result.modelBaseUrl) !==
            snapshot.contextKey) {
      return;
    }
    if (typeof result.modelApiKeyConfigured === 'boolean') {
      configuredCredentials.set(
          snapshot.contextKey, result.modelApiKeyConfigured);
    }
    if (typeof result.modelCredentialState === 'string') {
      credentialStates.set(snapshot.contextKey, result.modelCredentialState);
    }
    const models = result.models || [];
    const state: ModelListState = !result.ok ? 'error' :
        models.length > 0                    ? 'loaded' :
                                               'empty';
    fillModelList(models, snapshot.modelName, state);
    getRequiredElement('model-status').textContent = formatModelStatus(result);
    renderCredentialState();
  } catch (error) {
    if (serial === modelListRequestSerial && isCurrentModelSnapshot(snapshot)) {
      fillModelList([], snapshot.modelName, 'error');
      getRequiredElement('model-status').textContent = String(error);
    }
  } finally {
    if (serial === modelListRequestSerial) {
      updateModelControlAvailability();
    }
  }
}

async function saveModelSettings(clearKey: boolean) {
  if (modelControlsAndroid) {
    return;
  }
  const snapshot = captureModelFormSnapshot();
  const apiKey = clearKey ? '' : textField('model-api-key').value.trim();
  const serial = ++modelSettingsRequestSerial;
  actionButton('model-save').disabled = true;
  actionButton('model-key-clear').disabled = true;
  try {
    const next: AegisStatus = await sendWithPromise(
        'setModelSettings', snapshot.format, snapshot.baseUrl,
        snapshot.modelName, apiKey, clearKey);
    if (serial !== modelSettingsRequestSerial ||
        !isCurrentModelSnapshot(snapshot)) {
      return;
    }
    if (next.ok === false) {
      getRequiredElement('model-status').textContent =
          next.error || 'model settings rejected';
      return;
    }
    if (apiFormatFromBackend(next.modelProvider) !== snapshot.format ||
        !next.modelBaseUrl ||
        modelContextKey(snapshot.format, next.modelBaseUrl) !==
            snapshot.contextKey) {
      return;
    }
    const loadedModels =
        Array.from(selectField('model-select').options)
            .map((option) => option.value)
            .filter((value) => value && value !== CUSTOM_MODEL_VALUE);
    textField('model-api-key').value = '';
    modelFormDirty = false;
    applyModelStatus(next, true);
    fillModelList(
        loadedModels, next.modelName || snapshot.modelName,
        loadedModels.length > 0 ? 'loaded' : 'idle');
    const zh = (document.documentElement.lang || 'zh-CN').startsWith('zh');
    getRequiredElement('model-status').textContent = clearKey ?
        (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'API 金鑰已清除。' : 'API 密钥已清除。') : 'API key cleared.') :
        (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '模型設定已儲存。' : '模型设置已保存。') : 'Model settings saved.');
  } catch (error) {
    if (serial === modelSettingsRequestSerial &&
        isCurrentModelSnapshot(snapshot)) {
      getRequiredElement('model-status').textContent = String(error);
    }
  } finally {
    if (serial === modelSettingsRequestSerial) {
      updateModelControlAvailability();
    }
  }
}

async function init() {
  const status: AegisStatus =
      withRendererPolicyWorkerStatus(await sendWithPromise('getStatus'));
  applyStatus(status);
  bindToggle('tracker', 'trackerBlocking');
  bindToggle('phish', 'phishInterstitial');
  bindToggle('fingerprint', 'fingerprintGuard');
  bindToggle('miner-guard', 'minerGuard');
  bindToggle('link-sanitize', 'linkSanitize');
  bindToggle('cookie-janitor', 'cookieJanitor');
  bindToggle('cname-uncloak', 'cnameUncloak');
  bindToggle('bounce-tracking', 'bounceTracking');
  bindToggle('policy-worker', 'policyWorker');
  bindToggle('privacy-ai', 'privacyAi');
  bindToggle('browser-agent', 'browserAgent');
  bindToggle('ai-control', 'aiControl');
  bindToggle('filter-auto', 'filterListAutoUpdate');
  bindModelControls();
  actionButton('filter-update').addEventListener('click', () => {
    void (async () => {
      actionButton('filter-update').disabled = true;
      const next: AegisStatus = await sendWithPromise('updateFilterLists');
      applyStatus(next);
    })();
  });
  actionButton('summarize').addEventListener('click', () => {
    void runSummaryAction();
  });
  actionButton('fp-probe').addEventListener('click', () => {
    void probeFingerprint();
  });
  actionButton('browser-agent-open').addEventListener('click', () => {
    void (async () => {
      const next: AegisStatus = await sendWithPromise('openBrowserAgent');
      fillBrowserAgent(next);
      if (next.ok === false && next.error) {
        getRequiredElement('browser-agent-status').textContent = next.error;
      }
    })();
  });
  addWebUiListener('aegis-status-changed', (next: AegisStatus) => {
    next = withRendererPolicyWorkerStatus(next);
    applyModelStatus(next);
    fillOverview(next);
    fillActivityLog(next.recentEvents || []);
    fillBrowserAgent(next);
    fillAiControl(next);
    getRequiredElement('filter-meta').textContent = formatMeta(next);
    getRequiredElement('privacy-meta').textContent = formatPrivacyMeta(next);
    actionButton('summarize').disabled =
        summaryRequestRunning || !next.privacyAi || !next.policyWorkerReady;
  });
}

document.addEventListener('DOMContentLoaded', () => {
  void init();
});
