// Copyright 2026 GCSA
import 'chrome://resources/cr_elements/cr_icon/cr_icon.js';
import '../icons.html.js';
import '../downloads_page/downloads_page.js';
import type {WebUiListener} from 'chrome://resources/js/cr.js';
import {addWebUiListener, removeWebUiListener, sendWithPromise} from 'chrome://resources/js/cr.js';
import {flush, PolymerElement} from 'chrome://resources/polymer/v3_0/polymer/polymer_bundled.min.js';
import {loadTimeData} from '../i18n_setup.js';
import type {SearchResult} from '../search_settings.js';
import {getTemplate} from './aegis_page.html.js';

type ReadingPreferences = {theme: string, family: string, font: number, spacing: number, width: number};
type LibraryRecord = {id: string, title: string, archived?: boolean, text?: string, url?: string};
type State = {error?: string, readingPreferences?: ReadingPreferences, markdownSites?: Record<string, boolean>, records?: LibraryRecord[]};

export class SettingsAegisPageElement extends PolymerElement {
  static get is() { return 'settings-aegis-page'; }
  static get template() { return getTemplate(); }
  static get properties() { return {mode: {type: String}}; }
  declare mode: string;
  private statusListener_: WebUiListener|undefined;
  private translate_: (value: string) => string = value => value;
  private cleanup_: (() => void)|undefined;
  protected isMode_(mode: string, expected: string): boolean { return mode === expected; }
  protected pageTitle_(mode: string): string {
    return loadTimeData.getString({home: 'aegisSettingsTitle', ai: 'aegisAiTitle', downloads: 'aegisDownloadsTitle', tools: 'aegisToolsTitle', enhancements: 'aegisEnhancementsTitle', reading: 'aegisReadingTitle', gestures: 'aegisGesturesTitle', privacy: 'aegisPrivacyTitle'}[mode] || 'aegisEnhancementsTitle');
  }
  override connectedCallback() {
    super.connectedCallback();
    window.addEventListener('message', this.onFrameMessage_);
    this.statusListener_ = addWebUiListener('aegis-status-changed', (status: unknown) => {
      this.shadowRoot?.querySelector<HTMLIFrameElement>('.legacy-frame')
          ?.contentWindow?.postMessage({type: 'aegis-settings-status', status}, 'chrome://aegis');
    });
    queueMicrotask(() => { flush(); void this.initialize_().catch(error => this.message_(String(error))); });
  }
  override disconnectedCallback() { if (this.statusListener_) removeWebUiListener(this.statusListener_); window.removeEventListener('message', this.onFrameMessage_); this.cleanup_?.(); super.disconnectedCallback(); }
  // 子框架没有 chrome.send 通道；只为当前受信任子页转发固定接口。
  private onFrameMessage_ = (event: MessageEvent) => {
    for (const frame of this.shadowRoot?.querySelectorAll<HTMLIFrameElement>('iframe') || []) {
      const origin = frame.classList.contains('agent-frame') ? 'chrome-untrusted://aegis-agent' : 'chrome://aegis';
      if (event.source !== frame.contentWindow || event.origin !== origin) continue;
      if (event.data?.type === 'aegis-settings-request' && origin === 'chrome://aegis') {
        void this.forwardRequest_(frame, event.data);
        return;
      }
      if (event.data?.type !== 'aegis-settings-height') continue;
      const height = event.data.height;
      if (typeof height === 'number' && Number.isFinite(height)) frame.style.height = Math.max(320, Math.min(24000, Math.ceil(height))) + 'px';
    }
  };
  private async forwardRequest_(frame: HTMLIFrameElement, data: {id?: unknown, method?: unknown, args?: unknown}) {
    const {id, method, args} = data;
    if (typeof id !== 'string' || !/^settings-\d+$/.test(id) || typeof method !== 'string' || !Array.isArray(args)) return;
    const signatures: Record<string, string[]> = {
      getStatus: [], setModuleEnabled: ['string', 'boolean'],
      openBrowserAgent: [], updateFilterLists: [], summarizeActiveTab: [],
      completePreparedSummary: ['string', 'object'], cancelPreparedSummary: ['string'],
      setModelSettings: ['string', 'string', 'string', 'string', 'boolean'],
      listModels: ['string', 'string', 'string'], parseMetalink: ['string'],
      startMetalinkDownload: ['string'], parseTorrent: ['string'],
      parseMagnet: ['string'], startTorrent: ['string', 'array', 'object', 'boolean'],
      getTorrentStatus: ['string'], controlTorrent: ['string', 'string'],
    };
    const signature = Object.hasOwn(signatures, method) ? signatures[method] : undefined;
    const valid = signature && args.length === signature.length && signature.every((kind, i) =>
      kind === 'array' ? Array.isArray(args[i]) : kind === 'object' ?
        args[i] !== null && typeof args[i] === 'object' && !Array.isArray(args[i]) : typeof args[i] === kind);
    const source = frame.contentWindow;
    const reply = (response: object) => {
      if (this.isConnected && frame.isConnected && source === frame.contentWindow) {
        source?.postMessage({type: 'aegis-settings-response', id, ...response}, 'chrome://aegis');
      }
    };
    if (!valid) { reply({error: '设置请求无效'}); return; }
    try { reply({result: await sendWithPromise(method, ...args)}); }
    catch (error) { reply({error: String(error)}); }
  }
  private element_<T extends HTMLElement = HTMLElement>(id: string): T {
    const value = this.shadowRoot!.querySelector<T>('#' + id);
    if (!value) throw Error('设置控件不可用：' + id);
    return value;
  }
  private message_(value: string) {
    const target = this.shadowRoot?.querySelector('#result, #notice, #status');
    if (target) target.textContent = value;
  }
  private async request_(request: object): Promise<State> {
    const result = await sendWithPromise<State>('aegisEnhancements', request);
    if (result.error) throw Error(result.error);
    return result;
  }
  searchContents(query: string): Promise<SearchResult> {
    flush();
    const categoryKeywords: Record<string, string> = {
      home: 'Aegis 功能 设置 settings',
      privacy: '跟踪器拦截 钓鱼网站防护 指纹防护 挖矿脚本检测 清理跟踪参数 Cookie 伪装跟踪防护 跳转跟踪防护 本地隐私处理 自动更新过滤列表 广告与跟踪过滤规则 防护记录 隱私 指紋 過濾規則 phishing privacy tracking fingerprint filter lists mining',
      ai: 'AI 助手 网页摘要 模型池 模型路由 服务地址 API 密钥 自定义模型 模型列表 质量 延迟 费用 推理档位 TypeSafe 本机翻译 语言包 实验模型 MINIM PhishLang 網頁摘要 語言包 模型連線 金鑰 model pool routing API key endpoint translation language pack',
      downloads: '下载 镜像 种子 磁力链接 DHT PEX 限速 下载记录 下載 種子 磁力連結 torrent magnet metalink download bandwidth',
      tools: '本机工具连接 允许本机 AI 工具读取和操作网页 连接状态 权限 本機工具連線 CDP AI tools connection permissions',
    };
    const keywords = categoryKeywords[this.mode] || (this.mode === 'enhancements' ? '复制 右键 脚本 user.js copy context menu scripts' : this.mode === 'reading' ? 'Markdown 阅读 字体 图片 文档 reading library' : this.mode === 'privacy' ? '跟踪 指纹 Cookie 隐私 privacy tracking fingerprint' : '鼠标 手势 mouse gestures');
    const text = (this.shadowRoot?.textContent || '') + keywords;
    const match = !query || text.toLocaleLowerCase().includes(query.toLocaleLowerCase());
    // 搜索命中时展开管理分类，避免结果藏在折叠标题下。
    if (query && match) this.shadowRoot?.querySelectorAll<HTMLDetailsElement>('details').forEach(node => node.open = true);
    return Promise.resolve({canceled: false, matchCount: match ? 1 : 0, wasClearSearch: !query});
  }
  private async initialize_() {
    const i18nModule = await import('/' + 'aegis/enhancements_shared/i18n.js');
    void i18nModule;
    if (!this.isConnected) return;
    const i18n = (globalThis as unknown as {AegisI18n: {t: (value: string) => string, translate: (root: ShadowRoot) => void, setLocale: (value: string) => void}}).AegisI18n;
    i18n.setLocale(loadTimeData.getString('aegisLocale'));
    this.translate_ = i18n.t;
    i18n.translate(this.shadowRoot!);
    if (this.mode === 'enhancements') {
      for (const path of ['aegis/enhancements_shared/core.js', 'aegis/enhancements_shared/vendor/acorn.js']) await import('/' + path);
      const module = await import('/' + 'aegis/enhancements.js');
      if (!this.isConnected) return;
      await module.initializeEnhancements(this.shadowRoot);
    } else if (this.mode === 'gestures') {
      const module = await import('/' + 'aegis/gestures.js');
      if (!this.isConnected) return;
      this.cleanup_ = module.initializeGestures(this.shadowRoot);
    } else if (this.mode === 'reading') {
      const state = await this.request_({op: 'state'});
      if (!this.isConnected) return;
      const prefs = state.readingPreferences || {theme: 'system', family: 'sans', font: 17, spacing: 180, width: 820};
      for (const key of ['theme', 'family', 'font', 'spacing', 'width'] as const) {
        const control = this.element_<HTMLInputElement|HTMLSelectElement>('reading-' + key);
        control.value = String(prefs[key]);
        control.onchange = () => { void this.saveReading_(); };
      }
      const sites = this.element_('markdown-sites');
      for (const [origin, enabled] of Object.entries(state.markdownSites || {})) {
        if (!enabled) continue;
        const label = document.createElement('label'); label.className = 'setting-row';
        const text = document.createElement('span'); text.textContent = origin;
        const control = document.createElement('input'); control.type = 'checkbox'; control.checked = true;
        control.onchange = async () => {
          control.disabled = true;
          try { await this.request_({op: 'markdown-site', origin, enabled: control.checked}); this.message_(this.translate_('网站预览设置已保存。')); }
          catch (error) { control.checked = !control.checked; this.message_(String(error)); }
          finally { control.disabled = false; }
        };
        label.append(text, control); sites.append(label);
      }
      if (!sites.childElementCount) sites.textContent = this.translate_('尚未授权自动预览网站。可以从在线文档的来源菜单开启。');
      this.element_('refresh-library').onclick = () => { void this.library_().catch(error => this.message_(String(error))); };
      await this.library_();

    }
  }
  private async saveReading_() {
    const read = (key: string) => this.element_<HTMLInputElement|HTMLSelectElement>('reading-' + key).value;
    try {
      await this.request_({op: 'reading-preferences', preferences: {theme: read('theme'), family: read('family'), font: Number(read('font')), spacing: Number(read('spacing')), width: Number(read('width'))}});
      this.message_(this.translate_('阅读外观已保存，下次打开文档时应用。'));
    } catch (error) { this.message_(String(error)); }
  }
  private async library_() {
    const result = await this.request_({op: 'library-list'});
    const list = this.element_('library'); list.replaceChildren();
    for (const record of result.records || []) {
      if (record.archived) continue;
      const row = document.createElement('div'); row.className = 'item';
      const title = document.createElement('span'); title.textContent = record.title;
      const open = document.createElement('a'); open.textContent = record.text ? this.translate_('阅读已保存原文') : this.translate_('打开来源');
      open.href = record.text ? 'chrome://aegis/markdown.html#record=' + encodeURIComponent(record.id) : '#';
      if (!record.text) open.onclick = event => { event.preventDefault(); void this.request_({op: 'library-open', id: record.id}).catch(error => this.message_(String(error))); };
      row.append(title, open);
      if (record.text) {
        const detail = document.createElement('details'); const label = document.createElement('summary'); label.textContent = this.translate_('已保存的原文');
        const text = document.createElement('pre'); text.textContent = record.text; detail.append(label, text); row.append(detail);
      }
      list.append(row);
    }
    if (!list.childElementCount) list.textContent = this.translate_('阅读库为空。在文档的更多操作中保存原文。');
  }

}
customElements.define(SettingsAegisPageElement.is, SettingsAegisPageElement);
