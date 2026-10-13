// Copyright 2026 GCSA
import {sendWithPromise} from 'chrome://resources/js/cr.js';
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
  private translate_: (value: string) => string = value => value;
  private cleanup_: (() => void)|undefined;
  protected isMode_(mode: string, expected: string): boolean { return mode === expected; }
  protected pageTitle_(mode: string): string {
    return loadTimeData.getString({enhancements: 'aegisEnhancementsTitle', reading: 'aegisReadingTitle', gestures: 'aegisGesturesTitle', privacy: 'aegisPrivacyTitle'}[mode] || 'aegisEnhancementsTitle');
  }
  override connectedCallback() {
    super.connectedCallback();
    queueMicrotask(() => { flush(); void this.initialize_().catch(error => this.message_(String(error))); });
  }
  override disconnectedCallback() { this.cleanup_?.(); super.disconnectedCallback(); }
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
    const keywords = this.mode === 'enhancements' ? '复制 右键 脚本 user.js copy context menu scripts' : this.mode === 'reading' ? 'Markdown 阅读 字体 图片 文档 reading library' : this.mode === 'privacy' ? '跟踪 指纹 Cookie 隐私 privacy tracking fingerprint' : '鼠标 手势 mouse gestures';
    const text = (this.shadowRoot?.textContent || '') + keywords;
    const match = !query || text.toLocaleLowerCase().includes(query.toLocaleLowerCase());
    // 搜索命中时展开管理分类，避免结果藏在折叠标题下。
    if (query && match) this.shadowRoot?.querySelectorAll<HTMLDetailsElement>('details').forEach(node => node.open = true);
    return Promise.resolve({canceled: false, matchCount: match ? 1 : 0, wasClearSearch: !query});
  }
  private async initialize_() {
    const i18nModule = await import('/' + 'aegis/enhancements_shared/i18n.js');
    void i18nModule;
    const i18n = (globalThis as unknown as {AegisI18n: {t: (value: string) => string, translate: (root: ShadowRoot) => void, setLocale: (value: string) => void}}).AegisI18n;
    i18n.setLocale(loadTimeData.getString('aegisLocale'));
    this.translate_ = i18n.t;
    i18n.translate(this.shadowRoot!);
    if (this.mode === 'enhancements') {
      for (const path of ['aegis/enhancements_shared/core.js', 'aegis/enhancements_shared/vendor/acorn.js']) await import('/' + path);
      const module = await import('/' + 'aegis/enhancements.js');
      await module.initializeEnhancements(this.shadowRoot);
    } else if (this.mode === 'gestures') {
      const module = await import('/' + 'aegis/gestures.js');
      this.cleanup_ = module.initializeGestures(this.shadowRoot);
    } else if (this.mode === 'reading') {
      const state = await this.request_({op: 'state'});
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
    } else if (this.mode === 'privacy') {
      await this.privacy_();
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
  private async privacy_() {
    const status = await sendWithPromise<Record<string, unknown>>('getStatus');
    const list = this.element_('protections'); list.replaceChildren();
    const labels: Record<string, string> = {trackerBlocking: this.translate_('拦截跟踪请求'), phishInterstitial: this.translate_('钓鱼网站保护'), fingerprintGuard: this.translate_('指纹防护'), linkSanitize: this.translate_('清理链接参数'), cookieJanitor: this.translate_('清理跟踪 Cookie'), cnameUncloak: this.translate_('识别别名跟踪'), bounceTracking: this.translate_('跳转跟踪清理'), minerGuard: this.translate_('挖矿风险观察'), filterListAutoUpdate: this.translate_('自动更新过滤规则')};
    for (const [key, name] of Object.entries(labels)) {
      const row = document.createElement('label'); row.className = 'setting-row';
      const title = document.createElement('span'); title.textContent = name;
      const control = document.createElement('input'); control.type = 'checkbox'; control.checked = status[key] === true;
      control.disabled = status['profileAvailable'] === false;
      control.onchange = async () => {
        control.disabled = true;
        try {
          const next = await sendWithPromise<Record<string, unknown>>('setModuleEnabled', key, control.checked);
          control.checked = next[key] === true;
          this.message_(next['ok'] === false ? '设置未保存，请重试。' : this.translate_('设置已保存。'));
        } catch (error) { control.checked = !control.checked; this.message_(String(error)); }
        finally { control.disabled = false; }
      };
      row.append(title, control); list.append(row);
    }
    const events = this.element_('events'); events.replaceChildren();
    for (const event of (status['recentEvents'] || []) as Array<{kind: string, domain: string, count: number}>) {
      const row = document.createElement('li'); row.textContent = event.domain + ' · ' + event.kind + ' × ' + event.count; events.append(row);
    }
    if (!events.childElementCount) events.textContent = this.translate_('暂无防护记录。');
  }
}
customElements.define(SettingsAegisPageElement.is, SettingsAegisPageElement);
