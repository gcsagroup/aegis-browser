// Copyright 2026 GCSA
// 只渲染原生返回的文本；网页内容不得作为 HTML 或操作指令执行。
import {loadTimeData} from '//resources/js/load_time_data.js';
import type {BrowserProxy} from './browser_proxy.js';
import {LocalAiClient} from './local_ai_client.js';
import {LanguagePacks, packText} from './language_packs.js';

interface ReadingRecord {
  id: string; url: string; title: string; kind: string; page: number;
  text: string; note: string; quote: string; group: string;
  paragraphs: string[]; translation: string[]; language: string;
  archived: boolean; created: string;
}
interface ReadingState {
  records?: ReadingRecord[]; revision?: string;
  tabs?: Array<{id: number, title: string, url: string}>;
  draft?: ReadingRecord; canTranslate?: boolean;
  destination?: string; model?: string;
  minimEnabled?: boolean; phishlangEnabled?: boolean;
  researchParagraphs?: string[];
}
const label = (key: string) => loadTimeData.getString('reading' + key);
function element<T extends HTMLElement = HTMLElement>(id: string): T {
  return document.getElementById('reading-' + id) as T;
}
function node<K extends keyof HTMLElementTagNameMap>(tag: K, text = ''):
    HTMLElementTagNameMap[K] {
  const result = document.createElement(tag);
  result.textContent = text;
  return result;
}
export function matchesReading(record: ReadingRecord, query: string): boolean {
  // 上限为 128 条，不建立额外的明文索引。
  return [record.title, record.url, record.text, record.note, record.quote,
          record.group, ...record.translation].join('\n').toLocaleLowerCase()
      .includes(query.trim().toLocaleLowerCase());
}
export function translationWarnings(source: string, translation: string): string[] {
  // 只提示可疑差异，不判断译文正确性，也不按规则改写数字或单位。
  const normalize = (text: string) => text.normalize('NFKC').replaceAll('−', '-');
  const numbers = (text: string) => (normalize(text).match(
      /(?<!\d)[+-]?(?:\d{1,3}(?:,\d{3})+|\d+)(?:\.\d+)?(?:[eE][+-]?\d+)?/gu) || [])
      .map(value => value.replaceAll(',', '').replace(/^\+/, '')
          .replace(/(\.\d*?)0+$/, '$1').replace(/\.$/, '')).sort().join('|');
  const warnings = [];
  if (numbers(source) !== numbers(translation)) warnings.push('NumberWarning');
  const units = [
    /%|\bpercent\b|百分之/iu,
    /\b(?:CNY|RMB|yuan)\b|人民币|人民幣|\d\s*元/iu,
    /\$|\b(?:USD|dollars?)\b|美元/iu,
    /€|\b(?:EUR|euros?)\b|欧元|歐元/iu,
    /°\s*C\b|摄氏|攝氏|\bcelsius\b/iu,
    /°\s*F\b|华氏|華氏|\bfahrenheit\b/iu,
    // B 与 b 含义不同，数据容量标记保留大小写。
    /\bGB\b|\d\s*GB\b/u, /\bMB\b|\d\s*MB\b/u, /\bKB\b|\d\s*KB\b/u,
    /\bGb\b|\d\s*Gb\b/u, /\bMb\b|\d\s*Mb\b/u, /\bKb\b|\d\s*Kb\b/u,
    /\bkg\b|\d\s*kg\b|千克|公斤/iu,
    /\bcm\b|\d\s*cm\b|厘米|公分|\bcentimet(?:er|re)s?\b/iu,
    /\bmm\b|\d\s*mm\b|毫米|\bmillimet(?:er|re)s?\b/iu,
    /\bmL\b|\d\s*mL\b|毫升|\bmillilit(?:er|re)s?\b/iu,
    /\bkm\/h\b|每小时\s*\d*\s*(?:公里|千米)|千米\/小时/iu,
    /\bfps\b|frames? per second|帧每秒|幀每秒|每秒\s*\d*\s*[帧幀]/iu,
  ];
  if (/\d/u.test(source + translation) && units.some(unit =>
      unit.test(normalize(source)) !== unit.test(normalize(translation)))) warnings.push('UnitWarning');
  // 两个字段都不超过 12 时，不替用户决定月/日顺序。
  if (/\b(?:0?[1-9]|1[0-2])\/(?:0?[1-9]|1[0-2])\/\d{4}\b/u.test(normalize(source))) {
    warnings.push('DateWarning');
  }
  return warnings;
}
export class ReadingWorkspace {
  private records: ReadingRecord[] = [];
  private revision = '';
  private selected = new Set<number>();
  private busy = false;
  private destination = '';
  private model = '';
  private canTranslate = false;
  private local = new LocalAiClient();
  private localBusy = false;
  private settingsLoaded = false;
  private minimEnabled = false;
  private phishlangEnabled = false;
  private packs: LanguagePacks;
  private edits = new Map<string, Record<string, string>>();
  private localDirections = new Map<string, string>();
  constructor(private proxy: BrowserProxy) {
    this.packs = new LanguagePacks(element('language-packs'));
    void this.describeExperiments();
    element('refresh').addEventListener('click', () => void this.refresh());
    element('search').addEventListener('input', () => this.renderRecords());
    element('archived').addEventListener('change', () => this.renderRecords());
    element('group').addEventListener('input', () => this.updateButtons());
    for (const op of ['stash', 'split', 'capture', 'restore']) {
      element(op).addEventListener('click', () => {
        void this.run({op, tabs: [...this.selected], tab: [...this.selected][0],
          page: Number(element<HTMLInputElement>('page').value),
          group: element<HTMLInputElement>('group').value.trim()});
      });
    }
    element('research-settings').addEventListener('toggle', () => {
      if (element<HTMLDetailsElement>('research-settings').open) { void this.refresh(); void this.verifyExperiments(); }
    });
    for (const name of ['minim', 'phishlang']) {
      element(name).addEventListener('change', () => {
        this.local.cancel();
        void this.run({op: 'research_settings',
          minim: element<HTMLInputElement>('minim').checked,
          phishlang: element<HTMLInputElement>('phishlang').checked}).then(ok => {
            element('research-settings-status').textContent = label(ok ? 'SettingsSaved' : 'Error');
          });
      });
    }
    window.addEventListener('pagehide', () => this.local.cancel());
    this.updateButtons();
  }
  private async describeExperiments() {
    element('minim-description').textContent = packText('按阅读目标评估段落的必要性与敏感性。仅提供人工参考，不删除或改写正文。', 'Scores paragraph relevance and sensitivity for a reading goal. For human review; it does not remove or rewrite text.', '依閱讀目標評估段落的必要性與敏感性。僅供人工參考，不刪除或改寫正文。');
    element('phishlang-description').textContent = packText('对提取的文字给出钓鱼风险参考。不是网页安全结论，不自动拦截页面。', 'Estimates phishing risk from extracted text. It is not a website safety verdict and never automatically blocks pages.', '對擷取的文字提供釣魚風險參考。並非網頁安全結論，不自動攔截頁面。');
    for (const link of document.querySelectorAll('.reading-experiment-link')) link.textContent = packText('前往阅读工作区手动分析', 'Open the reading workspace to analyze manually', '前往閱讀工作區手動分析');
    try {
      const response = await fetch('./local_ai/research_manifest.json');
      if (!response.ok) throw Error('unavailable');
      const manifest = await response.json() as Partial<Record<string, {bundled?: boolean}>>;
      for (const name of ['minim', 'phishlang']) element(name + '-resource').textContent = manifest[name]?.bundled === false ?
        packText('当前版本未包含模型资源；分发许可尚未确认，因此无法运行。开关只保存手动使用偏好，不会下载或启动分析。', 'This build does not include the model because distribution rights are unconfirmed. The toggle saves a preference only; it does not download or run analysis.', '目前版本未包含模型資源；分發許可尚未確認，因此無法執行。開關僅儲存手動使用偏好，不會下載或啟動分析。') :
        packText('模型清单已载入；手动分析时仍需校验资源。开启不会自动分析，关闭不会删除已有结果。', 'The model manifest is loaded; assets are verified when analysis is requested. Enabling does not run analysis; disabling preserves results.', '模型清單已載入；手動分析時仍需校驗資源。開啟不會自動分析，關閉不會刪除既有結果。');
    } catch { for (const name of ['minim', 'phishlang']) element(name + '-resource').textContent = packText('无法读取资源状态，请重新打开本页。', 'Cannot read resource status. Reopen this page.', '無法讀取資源狀態，請重新開啟本頁。'); }
  }
  private async verifyExperiments() {
    try {
      const response = await fetch('./local_ai/research_manifest.json');
      if (!response.ok) throw Error();
      const manifest = await response.json();
      const assetResponse = await fetch('./local_ai/asset_manifest.json');
      const assets = assetResponse.ok ? await assetResponse.json() : {files: {}};
      for (const name of ['minim', 'phishlang']) {
        if (manifest[name]?.bundled === false) continue;
        const files = name === 'minim' ? [['minim-mlp.json', manifest.minim.weights_sha256]] : [['phishlang.onnx', manifest.phishlang.onnx_sha256], ['phishlang-vocab.txt', assets.files['phishlang-vocab.txt']?.sha256]];
        element(name + '-resource').textContent = packText('正在校验本机资源…', 'Verifying local resources…', '正在校驗本機資源…');
        try {
          for (const [file, hash] of files) {
            const resource = await fetch('./local_ai/' + file); if (!resource.ok || !hash) throw Error();
            const digest = await crypto.subtle.digest('SHA-256', await resource.arrayBuffer());
            if (Array.from(new Uint8Array(digest), byte => byte.toString(16).padStart(2, '0')).join('') !== hash) throw Error();
          }
          element(name + '-resource').textContent = packText('本机资源校验通过；开启后可前往阅读工作区手动使用。', 'Local resources verified. Enable and open the reading workspace to use them manually.', '本機資源校驗通過；開啟後可前往閱讀工作區手動使用。');
        } catch { element(name + '-resource').textContent = packText('资源缺失或校验失败，当前不可用。请安装包含有效资源的版本。', 'Resources are missing or invalid. Install a build with verified resources.', '資源缺失或校驗失敗，目前無法使用。請安裝包含有效資源的版本。'); }
      }
    } catch { /* 清单读取错误由基础说明保留，绝不将未知状态标为就绪。 */ }
  }
  async refresh() {
    // 编辑中的草稿保留；原生会重新核对选中标签。
    await this.run({op: 'list'});
  }
  private updateButtons() {
    const count = this.selected.size, busy = this.busy || this.localBusy;
    element<HTMLButtonElement>('stash').disabled = busy || count < 1 ||
        count > 16 || !element<HTMLInputElement>('group').value.trim();
    element<HTMLButtonElement>('split').disabled = busy || count !== 2;
    element<HTMLButtonElement>('capture').disabled = busy || count !== 1;
    element<HTMLButtonElement>('restore').disabled = busy ||
        !element<HTMLInputElement>('group').value.trim();
    element<HTMLButtonElement>('refresh').disabled = busy;
    element<HTMLInputElement>('minim').disabled = busy || !this.settingsLoaded;
    element<HTMLInputElement>('phishlang').disabled = busy || !this.settingsLoaded;
    for (const button of document.querySelectorAll<HTMLButtonElement>('[data-local-translate]')) button.disabled = busy;
    for (const button of document.querySelectorAll<HTMLButtonElement>('[data-local-research]')) {
      button.disabled = busy || (!this.minimEnabled && !this.phishlangEnabled);
    }
  }
  private localError(error: unknown): string {
    const key = error instanceof Error ? error.message : '';
    const messages: Record<string, string> = {
      cancelled: 'Cancelled', package_missing_or_corrupt: 'PackMissing',
      package_corrupt: 'PackCorrupt', download_failed: 'DownloadFailed',
      storage_full: 'PackStorage', storage_unavailable: 'PackStorage',
      research_text_too_long: 'ResearchTooLong', research_disabled: 'ResearchDisabled',
      research_model_not_distributed: 'ResearchNotDistributed',
    };
    return label(messages[key] || 'LocalError');
  }
  private localProgress(target: HTMLElement, message: string) {
    const [kind, value = ''] = message.split(':');
    target.textContent = label(kind === 'download' ? 'Downloading' : kind === 'translate' ? 'Translating' : 'Analyzing') + ' ' + value + (kind === 'download' ? '%' : '');
  }
  private async run(request: Record<string, unknown>): Promise<boolean> {
    if (this.busy || this.localBusy) return false;
    this.busy = true;
    this.updateButtons();
    element('status').textContent = label('Busy');
    try {
      const reply = await this.proxy.handler.readingCommand(
          JSON.stringify({...request, revision: this.revision}));
      if (reply.error) {
        const messages: Record<string, string> = {
          library_changed: 'Changed', tabs_changed: 'TextUnavailable',
          page_text_unavailable: 'TextUnavailable',
          translation_unavailable: 'TranslationUnavailable',
          translation_incomplete: 'TranslationUnavailable',
          library_full_or_invalid: 'Full', invalid_selection: 'Selection',
          secure_storage_unavailable: 'Storage', stored_library_unreadable: 'Storage',
        };
        element('status').textContent = label(messages[reply.error] || 'Error');
        return false;
      }
      const state = JSON.parse(reply.result) as ReadingState;
      if (['save', 'update', 'translate_local'].includes(String(request['op']))) {
        this.edits.delete(String(request['id']));
      }
      if (state.minimEnabled !== undefined && state.phishlangEnabled !== undefined) this.settingsLoaded = true;
      if (state.minimEnabled !== undefined) this.minimEnabled = state.minimEnabled;
      if (state.phishlangEnabled !== undefined) this.phishlangEnabled = state.phishlangEnabled;
      element<HTMLInputElement>('minim').checked = this.minimEnabled;
      element<HTMLInputElement>('phishlang').checked = this.phishlangEnabled;
      if (state.revision !== undefined) this.revision = state.revision;
      if (state.records) {
        this.records = state.records;
        const ids = new Set(this.records.map(record => record.id));
        for (const id of this.edits.keys()) if (!ids.has(id)) this.edits.delete(id);
        this.renderRecords();
      }
      if (state.tabs) {
        this.selected.clear();
        element('tabs').replaceChildren();
        for (const tab of state.tabs) {
          const row = node('label');
          const check = node('input');
          check.type = 'checkbox';
          check.addEventListener('change', () => {
            if (check.checked) this.selected.add(tab.id);
            else this.selected.delete(tab.id);
            this.updateButtons();
          });
          row.append(check, node('span', tab.title + '\n' + tab.url));
          element('tabs').append(row);
        }
      }
      if (state.canTranslate !== undefined) this.canTranslate = state.canTranslate;
      if (state.destination !== undefined) this.destination = state.destination;
      if (state.model !== undefined) this.model = state.model;
      if (state.draft) {
        // 翻译完成后保留尚未保存的批注。
        const note = document.getElementById('reading-draft-note') as HTMLTextAreaElement|null;
        const quote = document.getElementById('reading-draft-quote') as HTMLTextAreaElement|null;
        if (request['op'] === 'translate') {
          state.draft.note = note?.value || '';
          state.draft.quote = quote?.value || '';
          state.draft.group = (document.getElementById('reading-draft-group') as HTMLTextAreaElement|null)?.value || '';
        }
        element('draft').replaceChildren(this.editor(state.draft, true));
      }
      element('status').textContent = label('Done');
      return true;
    } catch {
      element('status').textContent = label('Error');
      return false;
    } finally {
      this.busy = false;
      this.updateButtons();
    }
  }
  private renderRecords() {
    const opened = new Set([...element('records').querySelectorAll<HTMLDetailsElement>('details[open]')].map(item => item.dataset['id']));
    const query = element<HTMLInputElement>('search').value;
    const archived = element<HTMLInputElement>('archived').checked;
    const matching = this.records.filter(r => r.archived === archived && matchesReading(r, query));
    element('records').replaceChildren();
    if (!matching.length) element('records').append(node('p', label('Empty')));
    for (const record of matching.slice().reverse()) {
      const details = node('details');
      details.className = 'reading-entry';
      details.dataset['id'] = record.id;
      details.append(node('summary', record.title || record.url));
      // 惰性展开，避免同时创建所有正文节点。
      details.addEventListener('toggle', () => {
        if (details.open && details.childElementCount === 1)
          details.append(this.editor(record, false));
      });
      element('records').append(details);
      if (opened.has(record.id)) { details.open = true; details.append(this.editor(record, false)); }
    }
  }
  private editor(record: ReadingRecord, draft: boolean): HTMLElement {
    const section = node('section');
    section.className = 'reading-editor';
    section.append(node('h3', record.title), node('p', record.url +
        (record.kind === 'pdf' ? ' · PDF ' + record.page : '')));
    const original = node('div');
    original.className = 'reading-original';
    const originalText = node('pre');
    const position = record.quote ? record.text.indexOf(record.quote) : -1;
    if (position >= 0) {
      originalText.append(document.createTextNode(record.text.slice(0, position)),
          node('mark', record.quote),
          document.createTextNode(record.text.slice(position + record.quote.length)));
    } else originalText.textContent = record.text;
    original.append(node('h4', label('Original')), originalText);
    section.append(original);
    if (record.translation.length) {
      section.append(node('p', label('TranslationCaution')));
      const pairs = node('div');
      pairs.className = 'reading-pairs';
      pairs.append(node('h4', label('Original')), node('h4', label('Translation')));
      record.paragraphs.forEach((paragraph, index) => {
        const translated = record.translation[index] || '';
        const target = node('div');
        target.append(node('p', translated));
        for (const warning of translationWarnings(paragraph, translated)) {
          const message = node('p', label(warning));
          message.className = 'reading-translation-warning';
          target.append(message);
        }
        pairs.append(node('p', paragraph), target);
      });
      section.append(pairs);
    }
    const field = (name: string, value: string, limit: number) => {
      const wrapper = node('label', label(name));
      const input = node('textarea');
      input.value = (draft ? undefined : this.edits.get(record.id)?.[name]) ?? value;
      if (!draft) input.addEventListener('input', () => {
        const edits = this.edits.get(record.id) || {};
        edits[name] = input.value;
        this.edits.set(record.id, edits);
      });
      input.maxLength = limit;
      input.rows = name === 'Note' ? 3 : 2;
      if (draft) input.id = 'reading-draft-' + name.toLowerCase();
      wrapper.append(input); section.append(wrapper);
      return input;
    };
    const quote = field('Quote', record.quote, 2048);
    const note = field('Note', record.note, 4096);
    const group = field('Group', record.group || element<HTMLInputElement>('group').value, 128);
    if (record.text && record.paragraphs.length) {
      const controls = node('div'); controls.className = 'reading-local-controls';
      controls.append(node('strong', label('LocalTranslate')), node('p', label('LocalHelp')), node('p', packText('方向仅作建议，请确认原文与目标语言；无法可靠识别时请手动选择。', 'Confirm the source and target languages; select manually when detection is uncertain.', '方向僅作建議，請確認原文與目標語言；無法可靠識別時請手動選擇。')));
      const direction = node('select');
      const directionKey = draft ? 'draft' : record.id;
      void this.packs.fillDirections(direction, record.text, this.localDirections.get(directionKey));
      direction.addEventListener('change', () => this.localDirections.set(directionKey, direction.value));
      const directionLabel = node('label', label('Direction')); directionLabel.append(direction); controls.append(directionLabel);
      const status = node('p'); status.setAttribute('role', 'status'); status.setAttribute('aria-live', 'polite');
      const translate = node('button', label('LocalTranslate')); translate.type = 'button'; translate.dataset['localTranslate'] = '';
      translate.disabled = this.busy || this.localBusy;
      const cancel = node('button', label('Cancel')); cancel.type = 'button'; cancel.disabled = true;
      cancel.addEventListener('click', () => this.local.cancel());
      const settings = node('button', label('ManagePacks')); settings.type = 'button';
      settings.addEventListener('click', () => {
        element<HTMLDetailsElement>('ai-settings').open = true;
        void this.packs.showRoute(direction.value);
      });
      translate.addEventListener('click', async () => {
        if (this.localBusy || this.busy) return;
        this.localDirections.set(directionKey, direction.value);
        direction.disabled = true;
        this.localBusy = true; this.updateButtons(); cancel.disabled = false;
        status.textContent = label('Busy');
        try {
          const result = await this.local.run({op: 'translate', direction: direction.value, paragraphs: record.paragraphs}, text => this.localProgress(status, text));
          if (!Array.isArray(result.translations) || !result.language) throw new Error('invalid_result');
          this.localBusy = false;
          const ok = await this.run({op: 'translate_local', id: record.id, draft, language: result.language,
            translation: result.translations, quote: quote.value, note: note.value, group: group.value});
          if (!ok) status.textContent = element('status').textContent;
        } catch (error) { status.textContent = this.localError(error); }
        finally { this.localBusy = false; cancel.disabled = true; direction.disabled = false; this.updateButtons(); }
      });
      controls.append(translate, settings, cancel, status);
      if (!draft) controls.append(node('p', label('TranslationSaved')));
      const goalLabel = node('label', label('ResearchGoal'));
      const goal = node('select');
      for (const [value, title] of [['read_post', 'ReadArticle'], ['read_email', 'ReadEmail'],
        ['read_slack_message', 'ReadMessage'], ['read_reviews', 'ReadReviews']]) {
        const option = node('option', label(title!)); option.value = value!; goal.append(option);
      }
      goalLabel.append(goal); controls.append(goalLabel);
      const research = node('button', label('Analyze')); research.type = 'button'; research.dataset['localResearch'] = '';
      research.disabled = this.busy || this.localBusy || (!this.minimEnabled && !this.phishlangEnabled);
      const results = node('pre'); results.className = 'reading-research-results';
      research.addEventListener('click', async () => {
        if (this.localBusy || this.busy || (!this.minimEnabled && !this.phishlangEnabled)) return;
        this.localBusy = true; this.updateButtons(); cancel.disabled = false; results.textContent = '';
        try {
          const reply = await this.proxy.handler.readingCommand(JSON.stringify({op: 'research_input', id: record.id, draft}));
          if (reply.error) throw new Error(reply.error);
          const state = JSON.parse(reply.result) as ReadingState;
          const result = await this.local.run({op: 'research', minim: state.minimEnabled,
            phishlang: state.phishlangEnabled, paragraphs: state.researchParagraphs, goal: goal.value}, text => this.localProgress(status, text));
          const lines = [label('ResearchWarning')];
          if (result.phishlang) lines.push('PhishLang: ' + result.phishlang.score.toFixed(4) +
            ' · ' + label(result.phishlang.flagged ? 'ResearchFlagged' : 'ResearchUnflagged') +
            ' · ' + result.phishlang.windows + ' ' + label('ResearchWindows'));
          if (result.minim) {
            lines.push('MINIM · ' + label('MinimOption'));
            for (const row of result.minim) lines.push((row.index + 1) + ': ' + label('Necessity') + ' ' + row.necessity.toFixed(2) +
              ' / ' + label('Sensitivity') + ' ' + row.sensitivity.toFixed(2) + ' · ' + label('Recommendation_' + row.recommendation));
          }
          results.textContent = lines.join('\n'); status.textContent = label('Done');
        } catch (error) { status.textContent = this.localError(error); }
        finally { this.localBusy = false; cancel.disabled = true; this.updateButtons(); }
      });
      controls.append(research, results); section.append(controls);
    }
    const button = (name: string, action: () => void) => {
      const result = node('button', label(name));
      result.type = 'button'; result.addEventListener('click', action);
      section.append(result); return result;
    };
    button('QuoteSelection', () => {
      const selection = window.getSelection();
      const text = selection?.toString() || '';
      if (selection?.anchorNode && original.contains(selection.anchorNode) &&
          text && text.length <= 2048 && record.text.includes(text)) {
        quote.value = text;
        quote.dispatchEvent(new Event('input'));
      }
    });
    const save = (archived = record.archived) => this.run({
      op: draft ? 'save' : 'update', id: record.id,
      quote: quote.value, note: note.value, group: group.value, archived});
    button('Save', () => void save());
    if (!draft) {
      button(record.archived ? 'Unarchive' : 'Archive', () => void save(!record.archived));
      if (!record.archived) button('Open', () => void this.run({op: 'open', id: record.id}));
    } else {
      const targetLabel = node('label', label('Language'));
      const target = node('select');
      for (const [value, title] of [['zh-CN', '简体中文'], ['zh-TW', '繁體中文'], ['en', 'English']]) {
        const option = node('option', title); option.value = value!; target.append(option);
      }
      targetLabel.append(target); section.append(targetLabel);
      const consent = node('label', label('Consent') + '\n' + this.destination + ' · ' + this.model);
      const checked = node('input'); checked.type = 'checkbox'; consent.prepend(checked);
      section.append(consent);
      const translate = button('Translate', () => {
        if (checked.checked && this.canTranslate) {
          void this.run({op: 'translate', id: record.id, language: target.value,
            destination: this.destination, model: this.model});
        }
      });
      translate.disabled = true;
      checked.addEventListener('change', () => {
        translate.disabled = !checked.checked || !this.canTranslate;
      });
      if (!this.canTranslate) section.append(node('p', label('TranslationUnavailable')));
    }
    return section;
  }
}
