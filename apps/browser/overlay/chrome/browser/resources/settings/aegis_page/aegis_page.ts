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
type SiteRule = {origin: string, menu: boolean, copy: boolean, debug: boolean, subdomains: boolean, disabled: boolean};
type State = {tabs?: Array<{id: string, title: string, url: string}>, error?: string, readingPreferences?: ReadingPreferences, markdownSites?: Record<string, boolean>, sites?: SiteRule[]};
const defaultReading: ReadingPreferences = {theme: 'system', family: 'sans', font: 17, spacing: 180, width: 820};

export class SettingsAegisPageElement extends PolymerElement {
  static get is() { return 'settings-aegis-page'; }
  static get template() { return getTemplate(); }
  static get properties() { return {mode: {type: String}}; }
  declare mode: string;
  private statusListener_: WebUiListener|undefined;
  private translate_: (value: string) => string = value => value;
  private cleanup_: (() => void)|undefined;
  private state_: State = {};
  private readingSave_: Promise<void> = Promise.resolve();
  private readingSequence_ = 0;
  private editingRule_: SiteRule|null = null;
  private formDirty_ = false;
  private readingDirty_ = false;
  private frameDirty_ = new Set<Window>();
  private savesPending_ = 0;
  private routeGuard_ = (event: Event) => {
    if (!this.formDirty_ && !this.readingDirty_ && !this.frameDirty_.size && !this.savesPending_) return;
    if (this.savesPending_) { event.preventDefault(); this.message_(this.translate_('正在保存，请完成后再离开。')); return; }
    if (!confirm(this.translate_('尚有未保存的修改。放弃修改并离开此分类？'))) event.preventDefault();
    else { this.formDirty_ = false; this.readingDirty_ = false; this.frameDirty_.clear(); }
  };
  private beforeUnload_ = (event: BeforeUnloadEvent) => {
    if (this.formDirty_ || this.readingDirty_ || this.frameDirty_.size || this.savesPending_) { event.preventDefault(); event.returnValue = ''; }
  };
  protected isMode_(mode: string, expected: string): boolean { return mode === expected; }
  protected pageTitle_(mode: string): string {
    return loadTimeData.getString({home: 'aegisSettingsTitle', ai: 'aegisAiTitle', experiments: 'aegisExperimentsTitle', downloads: 'aegisDownloadsTitle', tools: 'aegisToolsTitle', enhancements: 'aegisEnhancementsTitle', reading: 'aegisReadingTitle', gestures: 'aegisGesturesTitle', privacy: 'aegisPrivacyTitle'}[mode] || 'aegisEnhancementsTitle');
  }
  override connectedCallback() {
    super.connectedCallback();
    window.addEventListener('message', this.onFrameMessage_);
    window.addEventListener('beforeunload', this.beforeUnload_);
    window.addEventListener('aegis-settings-before-route', this.routeGuard_);
    this.addEventListener('aegis-form-dirty', event => { this.formDirty_ = !!(event as CustomEvent).detail; });
    this.statusListener_ = addWebUiListener('aegis-status-changed', (status: unknown) => {
      this.shadowRoot?.querySelector<HTMLIFrameElement>('.legacy-frame')
          ?.contentWindow?.postMessage({type: 'aegis-settings-status', status}, 'chrome://aegis');
    });
    queueMicrotask(() => { flush(); void this.initialize_().catch(error => this.message_(String(error))); });
  }
  override disconnectedCallback() { if (this.statusListener_) removeWebUiListener(this.statusListener_); window.removeEventListener('message', this.onFrameMessage_); window.removeEventListener('beforeunload', this.beforeUnload_); window.removeEventListener('aegis-settings-before-route', this.routeGuard_); this.cleanup_?.(); super.disconnectedCallback(); }
  // 子框架没有 chrome.send 通道；只为当前受信任子页转发固定接口。
  private onFrameMessage_ = (event: MessageEvent) => {
    for (const frame of this.shadowRoot?.querySelectorAll<HTMLIFrameElement>('iframe') || []) {
      const origin = frame.classList.contains('agent-frame') ? 'chrome-untrusted://aegis-agent' : 'chrome://aegis';
      if (event.source !== frame.contentWindow || event.origin !== origin) continue;
      if (event.data?.type === 'aegis-settings-dirty') {
        if (event.data.dirty === true) this.frameDirty_.add(frame.contentWindow!);
        else if (event.data.dirty === false) this.frameDirty_.delete(frame.contentWindow!);
        return;
      }
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
    ++this.savesPending_;
    try {
      const result = await sendWithPromise<State>('aegisEnhancements', request);
      if (result.error) throw Error(result.error);
      return result;
    } finally { --this.savesPending_; }
  }
  searchContents(query: string): Promise<SearchResult> {
    flush();
    const categoryKeywords: Record<string, string> = {
      home: 'Aegis 功能 设置 settings',
      privacy: '跟踪器拦截 钓鱼网站防护 指纹防护 挖矿脚本检测 清理跟踪参数 Cookie 伪装跟踪防护 跳转跟踪防护 本地隐私处理 自动更新过滤列表 广告与跟踪过滤规则 隱私 指紋 過濾規則 phishing privacy tracking fingerprint filter lists mining',
      ai: 'AI 助手 网页摘要 模型池 模型路由 服务地址 API 密钥 自定义模型 模型列表 质量 延迟 费用 推理档位 TypeSafe 網頁摘要 模型連線 金鑰 model pool routing API key endpoint ',
      experiments: '实验功能 实验模型 MINIM PhishLang 段落评分 风险分析 默认关闭 實驗功能 實驗模型 風險分析 experimental models paragraph scoring risk analysis',
      downloads: '下载 镜像 种子 磁力链接 DHT PEX 限速 下载记录 下載 種子 磁力連結 torrent magnet metalink download bandwidth',
      tools: '本机工具连接 允许本机 AI 工具读取和操作网页 连接状态 权限 本機工具連線 CDP AI tools connection permissions',
    };
    const keywords = categoryKeywords[this.mode] || (this.mode === 'enhancements' ? '复制 右键 脚本 user.js copy context menu scripts' : this.mode === 'reading' ? 'Markdown 阅读 字体 文档 自动预览 翻译 语言包 reading translation language packs' : this.mode === 'privacy' ? '跟踪 指纹 Cookie 隐私 privacy tracking fingerprint' : '鼠标 手势 mouse gestures');
    const text = (this.shadowRoot?.textContent || '') + keywords;
    const match = !query || text.toLocaleLowerCase().includes(query.toLocaleLowerCase());
    // 只展开命中项的祖先区域；嵌入内容各自定位，不展开无关高级选项。
    this.shadowRoot?.querySelectorAll('[data-search-match]').forEach(node => node.removeAttribute('data-search-match'));
    const needle = query.trim().toLocaleLowerCase();
    const target = needle ? [...this.shadowRoot!.querySelectorAll<HTMLElement>('label, summary, h3, p, a, button')].find(node => node.textContent?.toLocaleLowerCase().includes(needle)) : null;
    if (target) {
      target.dataset['searchMatch'] = 'true';
      let parent = target.parentElement;
      while (parent) { if (parent instanceof HTMLDetailsElement) parent.open = true; parent = parent.parentElement; }
      target.scrollIntoView({block: 'center'});
    }
    for (const frame of this.shadowRoot!.querySelectorAll<HTMLIFrameElement>('iframe')) {
      const origin = frame.src.startsWith('chrome-untrusted:') ? 'chrome-untrusted://aegis-agent' : 'chrome://aegis';
      frame.contentWindow?.postMessage({type: 'aegis-settings-search', query: needle}, origin);
    }
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
    if (this.mode === 'gestures') {
      const module = await import('/' + 'aegis/gestures.js');
      if (!this.isConnected) return;
      this.cleanup_ = module.initializeGestures(this.shadowRoot);
    } else if (this.mode === 'reading' || this.mode === 'enhancements') {
      const controls = [...this.shadowRoot!.querySelectorAll<HTMLInputElement>('input, select, button')];
      controls.forEach(control => control.disabled = true);
      try {
        this.state_ = await this.request_({op: 'state'});
        if (!this.isConnected) return;
        if (this.mode === 'reading') this.initializeReading_();
        else this.initializeRules_();
        this.message_('');
      } catch (error) {
        this.message_(String(error));
        const retry = document.createElement('button'); retry.textContent = this.translate_('重新读取设置');
        retry.onclick = () => location.reload();
        this.element_('result').append(' ', retry);
        return;
      }
      controls.forEach(control => control.disabled = false);
    }
  }
  private status_(id: string, text: string) { this.element_(id).textContent = this.translate_(text); }
  private input_(id: string): HTMLInputElement { return this.element_<HTMLInputElement>(id); }
  private button_(label: string, action: (button: HTMLButtonElement) => Promise<void>|void) {
    const button = document.createElement('button'); button.type = 'button'; button.textContent = this.translate_(label);
    button.onclick = async () => {
      button.disabled = true;
      try { await action(button); } catch (error) { this.message_(String(error)); }
      finally { button.disabled = false; }
    };
    return button;
  }
  private source_(value: string): string {
    let url: URL;
    try { url = new URL(value); } catch { throw Error(this.translate_('请输入完整网站地址，例如 https://example.com。')); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) throw Error(this.translate_('仅支持不含账号密码的 HTTP/HTTPS 网站。'));
    return url.origin;
  }
  private initializeReading_() {
    const prefs = this.state_.readingPreferences || defaultReading;
    for (const key of ['theme', 'family', 'font', 'spacing', 'width'] as const) {
      const control = this.input_('reading-' + key); control.value = String(prefs[key]);
      control.onchange = () => { this.previewReading_(); void this.saveReading_(); };
    }
    this.element_('preview-link').onclick = event => event.preventDefault();
    this.element_('reading-retry').onclick = () => void this.saveReading_();
    this.element_('reading-reset').onclick = () => {
      for (const [key, value] of Object.entries(defaultReading)) this.input_('reading-' + key).value = String(value);
      this.previewReading_(); void this.saveReading_();
    };
    this.element_('markdown-add').onclick = () => { this.element_('markdown-form').hidden = false; this.input_('markdown-origin').focus(); };
    this.element_('markdown-cancel').onclick = () => { this.element_('markdown-form').hidden = true; this.formDirty_ = false; };
    this.input_('markdown-origin').oninput = () => {
      this.formDirty_ = true;
      try { this.status_('markdown-scope', this.source_(this.input_('markdown-origin').value)); } catch { this.status_('markdown-scope', '路径不参与匹配，子域名需分别添加。'); }
    };
    this.input_('markdown-search').oninput = () => this.renderMarkdownSites_();
    this.element_<HTMLFormElement>('markdown-form').onsubmit = event => {
      event.preventDefault(); void this.addMarkdownSite_();
    };
    this.previewReading_(); this.renderMarkdownSites_();
  }
  private previewReading_() {
    const preview = this.element_('reading-preview');
    const theme = this.input_('reading-theme').value;
    preview.style.colorScheme = theme === 'system' ? 'light dark' : theme;
    preview.style.background = theme === 'dark' ? '#202124' : theme === 'light' ? '#ffffff' : 'light-dark(#ffffff, #202124)';
    preview.style.color = theme === 'dark' ? '#e8eaed' : theme === 'light' ? '#202124' : 'light-dark(#202124, #e8eaed)';
    preview.style.fontFamily = this.input_('reading-family').value === 'serif' ? 'Georgia, "Noto Serif CJK SC", serif' : 'system-ui, sans-serif';
    const font = Number(this.input_('reading-font').value);
    if (font >= 12 && font <= 28) preview.style.fontSize = font + 'px';
    preview.style.lineHeight = String(Number(this.input_('reading-spacing').value) / 100);
    // 样文按可用宽度等比例呈现宽／标准／窄的差异。
    preview.style.maxWidth = ({'680': '75%', '820': '88%', '1100': '100%'} as Record<string, string>)[this.input_('reading-width').value] || '100%';
  }
  private async saveReading_() {
    const sequence = ++this.readingSequence_;
    this.readingDirty_ = true;
    const read = (key: string) => this.input_('reading-' + key).value;
    const preferences = {theme: read('theme'), family: read('family'), font: Number(read('font')), spacing: Number(read('spacing')), width: Number(read('width'))};
    if (!Number.isInteger(preferences.font) || preferences.font < 12 || preferences.font > 28) {
      this.status_('reading-status', '字号必须是 12–28 之间的整数；尚未保存。'); return;
    }
    this.status_('reading-status', '正在保存…'); this.element_('reading-retry').hidden = true;
    this.readingSave_ = this.readingSave_.then(async () => {
      try {
        this.state_ = await this.request_({op: 'reading-preferences', preferences, expected: this.state_.readingPreferences || null});
        if (sequence === this.readingSequence_) { this.readingDirty_ = false; this.status_('reading-status', '已保存，新打开的文档使用此外观。'); }
      } catch (error) {
        if (sequence === this.readingSequence_) { this.status_('reading-status', String(error)); this.element_('reading-retry').hidden = false; }
      }
    });
    await this.readingSave_;
  }
  private async addMarkdownSite_() {
    const form = this.element_<HTMLFormElement>('markdown-form');
    if (!form.reportValidity()) return;
    const button = form.querySelector<HTMLButtonElement>('button[type="submit"]')!;
    button.disabled = true; this.input_('markdown-origin').disabled = true;
    try {
      const origin = this.source_(this.input_('markdown-origin').value);
      const expected = this.state_.markdownSites?.[origin] ?? null;
      this.state_ = await this.request_({op: 'markdown-site', origin, enabled: true, expected});
      this.formDirty_ = false; form.hidden = true; this.input_('markdown-origin').value = '';
      this.input_('markdown-search').value = ''; this.renderMarkdownSites_();
      this.status_('markdown-status', '已保存，下次访问 Markdown 原文时生效。');
    } catch (error) { this.status_('markdown-error', String(error)); }
    finally { button.disabled = false; this.input_('markdown-origin').disabled = false; }
  }
  private renderMarkdownSites_() {
    const list = this.element_('markdown-sites'); list.replaceChildren();
    const query = this.input_('markdown-search').value.trim().toLocaleLowerCase();
    for (const [origin, enabled] of Object.entries(this.state_.markdownSites || {})) {
      if (!origin.toLocaleLowerCase().includes(query)) continue;
      const row = document.createElement('div'); row.className = 'managed-row';
      const title = document.createElement('span'); title.textContent = origin;
      const toggle = document.createElement('input'); toggle.type = 'checkbox'; toggle.checked = enabled;
      toggle.setAttribute('aria-label', this.translate_('自动预览') + ' ' + origin);
      toggle.onchange = async () => {
        toggle.disabled = true;
        try {
          this.state_ = await this.request_({op: 'markdown-site', origin, enabled: toggle.checked, expected: enabled});
          this.status_('markdown-status', '已保存，下次访问 Markdown 原文时生效。'); this.renderMarkdownSites_();
        } catch (error) { toggle.checked = enabled; this.status_('markdown-status', String(error)); }
        finally { toggle.disabled = false; }
      };
      const remove = this.button_('移除', async () => {
        if (!confirm(this.translate_('移除这个网站的自动预览记录？') + '\n' + origin)) return;
        this.state_ = await this.request_({op: 'markdown-site-remove', origin, expected: enabled});
        this.renderMarkdownSites_(); this.status_('markdown-status', '网站预览记录已移除。');
      });
      row.append(title, toggle, remove); list.append(row);
    }
    if (!list.childElementCount) list.textContent = this.translate_(query ? '没有匹配的网站。' : '尚未添加网站。点击“添加网站”开启 Markdown 自动预览。');
  }
  private initializeRules_() {
    const tabs = this.element_<HTMLSelectElement>('rule-tab');
    for (const tab of this.state_.tabs || []) {
      const option = document.createElement('option'); option.value = tab.url;
      option.textContent = (tab.title || tab.url).slice(0, 80) + ' · ' + new URL(tab.url).host; tabs.append(option);
    }
    tabs.onchange = () => { if (!tabs.value) return; this.input_('rule-origin').value = tabs.value; this.formDirty_ = true; this.ruleScope_(); };
    this.element_('rule-new').onclick = () => this.editRule_(null);
    this.element_('rule-cancel').onclick = () => { this.element_('rule-editor').hidden = true; this.formDirty_ = false; };
    this.input_('rule-search').oninput = () => this.renderRules_();
    this.element_('rule-editor').oninput = () => {
      this.formDirty_ = true;
      this.ruleScope_();
    };
    this.element_<HTMLFormElement>('rule-editor').onsubmit = event => { event.preventDefault(); void this.saveRule_(); };
    this.renderRules_();
    const tab = new URLSearchParams(location.hash.slice(1)).get('tab');
    if (tab) this.message_(this.translate_('网站规则在此管理；脚本操作请打开用户脚本管理器。'));
  }
  private ruleScope_() {
    this.element_('rule-inherited').hidden = true;
    try {
      const origin = this.source_(this.input_('rule-origin').value), url = new URL(origin);
      const inherited = (this.state_.sites || []).filter(rule => {
        const parent = new URL(rule.origin);
        return rule.subdomains && !rule.disabled && parent.protocol === url.protocol && parent.port === url.port && url.hostname.endsWith('.' + parent.hostname);
      }).sort((a, b) => b.origin.length - a.origin.length)[0];
      this.status_('rule-scope', origin);
      if (inherited && !this.state_.sites?.some(rule => rule.origin === origin)) {
        this.element_('rule-scope').append(' · ' + this.translate_('当前继承自：') + inherited.origin + this.translate_('；保存后将建立当前网站的独立规则。'));
        this.element_('rule-inherited').hidden = false;
        this.element_('rule-inherited').onclick = () => this.editRule_(inherited);
      }
    } catch { this.status_('rule-scope', '保存前请检查完整网站地址。'); }
  }
  private editRule_(rule: SiteRule|null) {
    if (this.formDirty_ && !confirm(this.translate_('放弃尚未保存的网站规则修改？'))) return;
    this.editingRule_ = rule; this.formDirty_ = false;
    this.element_('rule-editor').hidden = false;
    this.status_('rule-title', rule ? '编辑网站规则' : '添加网站');
    this.status_('rule-error', ''); this.status_('rule-scope', rule?.origin || '路径不参与匹配。');
    this.input_('rule-origin').value = rule?.origin || '';
    this.input_('rule-origin').readOnly = !!rule;
    this.element_<HTMLSelectElement>('rule-tab').disabled = !!rule;
    this.element_<HTMLSelectElement>('rule-tab').value = '';
    this.element_('rule-inherited').hidden = true;
    for (const key of ['menu', 'copy', 'debug', 'subdomains', 'disabled'] as const) this.input_('rule-' + key).checked = rule?.[key] || false;
    this.input_('rule-origin').focus();
  }
  private async saveRule_() {
    if (!this.element_<HTMLFormElement>('rule-editor').reportValidity()) return;
    const controls = [...this.element_('rule-editor').querySelectorAll<HTMLInputElement>('input, select, button')];
    controls.forEach(control => control.disabled = true);
    try {
      const rule: SiteRule = {origin: this.source_(this.input_('rule-origin').value), menu: false, copy: false, debug: false, subdomains: false, disabled: false};
      for (const key of ['menu', 'copy', 'debug', 'subdomains', 'disabled'] as const) rule[key] = this.input_('rule-' + key).checked;
      const old = this.state_.sites?.find(item => item.origin === rule.origin) || null;
      if (!this.editingRule_ && old) { this.formDirty_ = false; this.editRule_(old); this.status_('rule-error', '此网站已存在，请编辑原规则。'); return; }
      this.state_ = await this.request_({op: 'site-save', rule, expected: this.editingRule_});
      this.formDirty_ = false; this.element_('rule-editor').hidden = true; this.renderRules_();
      this.message_(this.translate_('已保存，重新加载对应网页后生效。'));
    } catch (error) { this.status_('rule-error', String(error)); }
    finally { controls.forEach(control => control.disabled = false); this.element_<HTMLSelectElement>('rule-tab').disabled = !!this.editingRule_; }
  }
  private renderRules_() {
    const list = this.element_('rules'); list.replaceChildren();
    const query = this.input_('rule-search').value.trim().toLocaleLowerCase();
    for (const rule of this.state_.sites || []) {
      if (!rule.origin.toLocaleLowerCase().includes(query)) continue;
      const row = document.createElement('div'); row.className = 'managed-row';
      const title = document.createElement('span'); title.textContent = rule.origin;
      const detail = document.createElement('small');
      const labels = rule.disabled ? ['已暂停'] : [rule.menu ? '恢复右键' : '', rule.copy ? '选取和复制' : '', rule.debug ? '调试兼容' : '', rule.subdomains ? '含子域名' : ''].filter(Boolean);
      detail.textContent = labels.map(value => this.translate_(value)).join(' · ') || this.translate_('未启用增强选项'); title.append(detail);
      row.append(title, this.button_('编辑', () => this.editRule_(rule)), this.button_(rule.disabled ? '恢复' : '暂停', async () => {
        this.state_ = await this.request_({op: 'site-save', rule: {...rule, disabled: !rule.disabled}, expected: rule}); this.renderRules_(); this.message_(this.translate_('已保存，重新加载对应网页后生效。'));
      }), this.button_('移除', async () => {
        if (!confirm(this.translate_('移除此网站规则？不会删除用户脚本，也不会刷新网页。') + '\n' + rule.origin)) return;
        this.state_ = await this.request_({op: 'site-remove', origin: rule.origin, expected: rule}); this.renderRules_();
      }));
      list.append(row);
    }
    if (!list.childElementCount) list.textContent = this.translate_(query ? '没有匹配的网站。' : '还没有网站规则。点击“添加网站”开始。');
  }

}
customElements.define(SettingsAegisPageElement.is, SettingsAegisPageElement);
