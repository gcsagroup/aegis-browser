// Copyright 2026 GCSA
// 语言包独立排队；不会终止阅读器中的翻译或改写原文、批注。
import {loadTimeData} from '//resources/js/load_time_data.js';
import {LocalAiClient} from './local_ai_client.js';
import {languagePacks, translationRoutes, detectSource} from 'chrome-untrusted://aegis-agent/local_ai/catalog.js';
import type {LanguagePack, TranslationRoute} from 'chrome-untrusted://aegis-agent/local_ai/catalog.js';
export function packText(zh: string, en: string, tw: string): string {
  const locale = loadTimeData.getString('aegisLocale');
  return /^zh-(TW|HK|Hant)/i.test(locale) ? tw : locale.startsWith('zh') ? zh : en;
}
const languageNames: Record<string, string> = {en: 'English', zh: '简体中文', ja: '日本語', ko: '한국어', fr: 'Français', de: 'Deutsch', es: 'Español', ru: 'Русский'};
const name = (code: string) => languageNames[code] || code;
const mb = (bytes: number) => (bytes / 1000000).toFixed(1) + ' MB';
const make = <K extends keyof HTMLElementTagNameMap>(tag: K, text = '') => {
  const node = document.createElement(tag); node.textContent = text; return node;
};
export class LanguagePacks {
  private packs: LanguagePack[] = [];
  private routes: TranslationRoute[] = [];
  private statusKnown = false;
  private statuses = new Map<string, {ready: boolean, update: boolean}>();
  private selected = new Set<string>();
  private errors = new Map<string, string>();
  private active = '';
  private queue: string[] = [];
  private progress = '';
  private client = new LocalAiClient();
  private statusClient = new LocalAiClient();
  private channel = new BroadcastChannel('aegis-language-packs');
  private list = make('div');
  private status = make('p');
  private total = make('p');
  private source = make('select');
  private target = make('select');
  private filter = make('select');
  private preferred = make('select');
  private batch = make('button');
  private cancel = make('button');
  readonly loaded: Promise<void>;
  constructor(private root: HTMLElement) {
    this.status.setAttribute('role', 'status'); this.status.setAttribute('aria-live', 'polite');
    this.list.className = 'language-pack-list';
    const controls = make('div'); controls.className = 'language-pack-filters';
    for (const [field, title] of [[this.source, packText('源语言', 'Source language', '來源語言')], [this.target, packText('目标语言', 'Target language', '目標語言')],
      [this.filter, packText('显示', 'Show', '顯示')], [this.preferred, packText('常用目标语言', 'Preferred target', '常用目標語言')]] as const) {
      const label = make('label', title); label.append(field); controls.append(label);
    }
    for (const [value, title] of [['all', packText('全部语言包', 'All packs', '全部語言包')], ['installed', packText('已安装', 'Installed', '已安裝')]]) {
      const option = make('option', title); option.value = value!; this.filter.append(option);
    }
    for (const field of [this.source, this.target, this.filter]) field.addEventListener('change', () => this.render());
    this.preferred.addEventListener('change', () => {
      try { localStorage.setItem('aegis-translation-target', this.preferred.value); }
      catch { this.status.textContent = packText('无法保存常用语言，请检查存储权限。', 'Cannot save the preferred language. Check storage access.', '無法儲存常用語言，請檢查儲存權限。'); }
    });
    this.batch.type = this.cancel.type = 'button';
    this.batch.textContent = packText('下载所选语言包', 'Download selected', '下載所選語言包');
    this.cancel.textContent = packText('取消剩余下载', 'Cancel remaining downloads', '取消剩餘下載');
    this.batch.addEventListener('click', () => void this.download([...this.selected]));
    this.cancel.addEventListener('click', () => { this.queue = []; this.client.cancel(); });
    const actions = make('div'); actions.className = 'reading-actions'; actions.append(this.batch, this.cancel);
    const help = make('p', packText('离线翻译按方向安装。中转翻译需要两个包，误译可能累积；请核对原文。下载和校验完成后才可使用。',
      'Install each offline direction separately. Pivot translation needs two packs and may compound errors; check the original. A pack is usable after download and verification.',
      '離線翻譯按方向安裝。中轉翻譯需要兩個包，誤譯可能累積；請核對原文。下載及校驗完成後才可使用。'));
    const limits = make('p', packText('日语→中文、中文→德语的英语中转未通过质量检查，暂不提供；日英、德英直接翻译仍可使用。短标题与歧义句可能误译，请保留原文核对。', 'Japanese → Chinese and Chinese → German via English did not pass quality checks and are unavailable. Direct Japanese ↔ English and German ↔ English remain supported. Short titles and ambiguous text may be mistranslated; check the original.', '日語→中文、中文→德語的英語中轉未通過品質檢查，暫不提供；日英、德英直接翻譯仍可使用。短標題與歧義句可能誤譯，請保留原文核對。'));
    this.root.replaceChildren(help, limits, controls, this.total, actions, this.status, this.list);
    this.channel.onmessage = () => { if (!this.active) void this.refresh(); };
    window.addEventListener('pagehide', () => { this.queue = []; this.client.cancel(); this.statusClient.cancel(); this.channel.close(); });
    this.render();
    this.loaded = this.initialize();
  }
  private async initialize() {
    this.status.textContent = packText('正在读取语言包…', 'Loading language packs…', '正在讀取語言包…');
    try {
      const response = await fetch('./local_ai/translation_manifest.json');
      if (!response.ok) throw Error('catalog');
      this.packs = languagePacks(await response.json()); this.routes = translationRoutes(this.packs);
      const languages = [...new Set(this.packs.flatMap(pack => [pack.from, pack.to]))];
      for (const field of [this.source, this.target, this.preferred]) {
        field.replaceChildren();
        if (field !== this.preferred) { const all = make('option', packText('全部', 'All', '全部')); all.value = ''; field.append(all); }
        for (const language of languages) { const option = make('option', name(language)); option.value = language; field.append(option); }
      }
      let preferred = 'zh'; try { preferred = localStorage.getItem('aegis-translation-target') || preferred; } catch {}
      this.preferred.value = languages.includes(preferred) ? preferred : (languages[0] || '');
      await this.refresh();
    } catch {
      this.status.textContent = packText('语言包目录读取失败。', 'Could not load the language catalog.', '語言包目錄讀取失敗。');
      const retry = make('button', packText('重试', 'Retry', '重試')); retry.type = 'button';
      retry.addEventListener('click', () => { retry.remove(); void this.initialize(); }); this.status.append(retry);
    }
  }
  private async refresh() {
    this.statusKnown = false; this.render();
    try {
      const result = await this.statusClient.run({op: 'statuses'}, () => {});
      this.statuses = new Map((result.statuses || []).map(value => [value.id, value]));
      this.statusKnown = true; this.status.textContent = '';
    } catch {
      this.status.textContent = packText('无法读取安装状态，请重试。', 'Cannot read installed packs. Retry.', '無法讀取安裝狀態，請重試。');
      const retry = make('button', packText('重试', 'Retry', '重試')); retry.type = 'button';
      retry.onclick = () => { retry.disabled = true; void this.refresh(); }; this.status.append(retry);
    }
    this.render();
  }
  routeTitle(route: TranslationRoute): string {
    return name(route.from) + ' → ' + name(route.to) + (route.pivot ? packText('（经英语中转）', ' (via English)', '（經英語中轉）') : '');
  }
  async fillDirections(select: HTMLSelectElement, text = '', selected = '') {
    await this.loaded;
    if (!select.isConnected) return;
    const previous = selected || select.value;
    select.replaceChildren();
    for (const route of this.routes) { const option = make('option', this.routeTitle(route)); option.value = route.id; select.append(option); }
    const from = detectSource(text);
    const recommended = this.routes.find(route => route.from === from && route.to === this.preferred.value);
    select.value = previous && this.routes.some(route => route.id === previous) ? previous : (recommended?.id || this.routes[0]?.id || '');
  }
  async showRoute(direction: string) {
    await this.loaded;
    const route = this.routes.find(value => value.id === direction);
    if (route) {
      this.source.value = ''; this.target.value = ''; this.filter.value = 'all';
      this.selected = new Set(route.packs.filter(id => !this.statuses.get(id)?.ready || this.statuses.get(id)?.update));
      this.render();
      this.status.textContent = this.routeTitle(route) + ' · ' + route.packs.map(id => { const pack = this.packs.find(value => value.id === id)!; return name(pack.from) + ' → ' + name(pack.to); }).join(' + ');
    }
    this.root.scrollIntoView({block: 'nearest'});
  }
  private render() {
    this.list.replaceChildren();
    const visible = this.packs.filter(pack => (!this.source.value || pack.from === this.source.value) && (!this.target.value || pack.to === this.target.value) && (this.filter.value !== 'installed' || this.statuses.get(pack.id)?.ready));
    if (!visible.length) this.list.append(make('p', packText('没有符合条件的语言包。', 'No matching language packs.', '沒有符合條件的語言包。')));
    for (const pack of visible) {
      const state = this.statuses.get(pack.id), row = make('section'); row.className = 'language-pack-row'; row.dataset['pack'] = pack.id;
      const check = make('input'); check.type = 'checkbox'; check.checked = this.selected.has(pack.id); check.disabled = !this.statusKnown || !!this.active || (state?.ready === true && !state.update);
      const title = make('label'); title.append(check, make('strong', name(pack.from) + ' → ' + name(pack.to)));
      check.addEventListener('change', () => { check.checked ? this.selected.add(pack.id) : this.selected.delete(pack.id); this.updateTotals(); });
      const detail = make('p', packText('下载 ', 'Download ', '下載 ') + mb(pack.bytes) + ' · ' + packText('安装 ', 'Installed ', '安裝 ') + mb(pack.installedBytes) + ' · v' + pack.version + ' · Mozilla / MPL 2.0');
      const status = make('p', this.errors.get(pack.id) || (!this.statusKnown ? packText('安装状态未确认', 'Installed state unknown', '安裝狀態未確認') : this.active === pack.id ? this.progress : this.queue.includes(pack.id) ? packText('等待下载', 'Queued', '等待下載') : state?.update ? packText('可更新，旧版本仍可使用', 'Update available; installed version remains usable', '可更新，舊版本仍可使用') : state?.ready ? packText('可用', 'Ready', '可用') : packText('未下载', 'Not downloaded', '未下載')));
      status.setAttribute('role', 'status');
      const actions = make('div'); actions.className = 'reading-actions';
      const download = make('button', state?.update ? packText('更新', 'Update', '更新') : this.errors.has(pack.id) ? packText('重试下载', 'Retry download', '重試下載') : packText('下载', 'Download', '下載'));
      download.type = 'button'; download.disabled = !this.statusKnown || !!this.active || (state?.ready === true && !state.update);
      download.addEventListener('click', () => void this.download([pack.id]));
      const both = make('button', packText('选择双向', 'Select both directions', '選擇雙向')); both.type = 'button'; both.disabled = !this.statusKnown || !!this.active;
      both.addEventListener('click', () => { for (const id of [pack.id, pack.to + '-' + pack.from]) if (this.packs.some(value => value.id === id) && (!this.statuses.get(id)?.ready || this.statuses.get(id)?.update)) this.selected.add(id); this.render(); });
      const remove = make('button', packText('移除', 'Remove', '移除')); remove.type = 'button'; remove.disabled = !this.statusKnown || !!this.active || !state?.ready;
      remove.addEventListener('click', () => void this.remove(pack));
      actions.append(download, both, remove); row.append(title, detail, status, actions); this.list.append(row);
    }
    this.updateTotals();
  }
  private updateTotals() {
    const chosen = this.packs.filter(pack => this.selected.has(pack.id));
    this.total.textContent = packText('已选 ', 'Selected ', '已選 ') + chosen.length + ' · ' + packText('下载 ', 'Download ', '下載 ') + mb(chosen.reduce((n, pack) => n + pack.bytes, 0)) + ' · ' + packText('新增安装空间约 ', 'Additional storage about ', '新增安裝空間約 ') + mb(chosen.reduce((n, pack) => n + pack.installedBytes, 0));
    this.batch.disabled = !this.statusKnown || !chosen.length || !!this.active; this.cancel.disabled = !this.active;
  }
  private error(error: unknown): string {
    const code = error instanceof Error ? error.message : '';
    if (code === 'cancelled') return packText('已取消；原有版本保留。', 'Cancelled; the installed version is preserved.', '已取消；原有版本保留。');
    if (code.startsWith('storage')) return packText('存储空间不足或不可用。释放空间后重试。', 'Storage is full or unavailable. Free space and retry.', '儲存空間不足或不可用。釋放空間後重試。');
    if (code === 'package_corrupt') return packText('文件校验失败，请重试。', 'File verification failed. Retry the download.', '檔案校驗失敗，請重試。');
    return packText('下载未完成，请检查网络后重试；原有版本保留。', 'Download failed. Check the connection and retry; the installed version is preserved.', '下載未完成，請檢查網路後重試；原有版本保留。');
  }
  private async download(ids: string[]) {
    if (!this.statusKnown || this.active) return;
    this.queue = [...new Set(ids)];
    while (this.queue.length) {
      const id = this.queue.shift()!; this.active = id; this.progress = packText('下载中…', 'Downloading…', '下載中…'); this.errors.delete(id); this.render();
      try {
        const result = await this.client.run({op: 'download', direction: id}, message => {
          const [kind, value] = message.split(':');
          this.progress = kind === 'verify' ? packText('校验中…', 'Verifying…', '校驗中…') : packText('下载中 ', 'Downloading ', '下載中 ') + value + '%';
          // 只改进度文本，避免下载回调反复替换焦点所在按钮。
          const row = [...this.list.children].find(element => element.getAttribute('data-pack') === id);
          const status = row?.querySelector('[role="status"]'); if (status) status.textContent = this.progress;
        });
        this.statuses.set(id, {ready: !!result.ready, update: false}); this.selected.delete(id); this.channel.postMessage('changed');
      } catch (error) { this.errors.set(id, this.error(error)); }
      this.active = ''; this.render();
    }
  }
  private async remove(pack: LanguagePack) {
    if (!this.statusKnown || this.active || !window.confirm(packText('移除 ', 'Remove ', '移除 ') + name(pack.from) + ' → ' + name(pack.to) + packText('？依赖此包的中转翻译也将不可用。', '? Pivot routes using this pack will also be unavailable.', '？依賴此包的中轉翻譯也將不可用。'))) return;
    this.active = pack.id; this.progress = packText('正在移除…', 'Removing…', '正在移除…'); this.render();
    try { await this.client.run({op: 'remove', direction: pack.id}, () => {}); this.statuses.set(pack.id, {ready: false, update: false}); this.errors.delete(pack.id); this.channel.postMessage('changed'); }
    catch { this.errors.set(pack.id, packText('移除失败，请重试。', 'Removal failed. Retry.', '移除失敗，請重試。')); }
    finally { this.active = ''; this.render(); }
  }
}
