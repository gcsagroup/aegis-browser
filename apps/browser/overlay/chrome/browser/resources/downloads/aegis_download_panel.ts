// Copyright 2026 GCSA

import {sendWithPromise} from 'chrome://resources/js/cr.js';
import {loadTimeData} from 'chrome://resources/js/load_time_data.js';
import {CrLitElement} from 'chrome://resources/lit/v3_0/lit.rollup.js';

import {getCss} from './aegis_download_panel.css.js';
import {getHtml} from './aegis_download_panel.html.js';

interface AegisStatus {
  profileAvailable?: boolean;
  torrentDisclosureAcknowledged?: boolean;
  torrentTaskId?: string;
  torrentSupported?: boolean;
}

interface MetalinkPreview {
  ok: boolean;
  error?: string;
  requestId?: string;
  fileName?: string;
  fileSize?: number;
  hashAlgorithm?: string;
  hashHex?: string;
  mirrorOrigins?: string[];
}

interface TorrentFile {
  index: number;
  path: string;
  size: number;
}

interface TorrentPreview {
  ok: boolean;
  error?: string;
  requestId?: string;
  name?: string;
  totalSize?: number;
  hasV1?: boolean;
  hasV2?: boolean;
  trackerCount?: number;
  files?: TorrentFile[];
}

interface TorrentStatus {
  found: boolean;
  error?: string;
  name?: string;
  state?: string;
  totalBytes?: number;
  completedBytes?: number;
  progressPpm?: number;
  downloadRate?: number;
  uploadRate?: number;
  peers?: number;
  seeds?: number;
  paused?: boolean;
  finished?: boolean;
}

interface TorrentStartResult {
  ok: boolean;
  error?: string;
  taskId?: string;
}

function formatBytes(value: number): string {
  if (!Number.isFinite(value) || value < 0) {
    return '—';
  }
  if (value < 1024) {
    return `${value} B`;
  }
  if (value < 1024 * 1024) {
    return `${(value / 1024).toFixed(1)} KiB`;
  }
  if (value < 1024 * 1024 * 1024) {
    return `${(value / (1024 * 1024)).toFixed(1)} MiB`;
  }
  return `${(value / (1024 * 1024 * 1024)).toFixed(1)} GiB`;
}

function fileAsBase64(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.addEventListener('error', () => reject(reader.error), {once: true});
    reader.addEventListener('load', () => {
      if (typeof reader.result !== 'string') {
        reject(new Error('torrent read failed'));
        return;
      }
      const comma = reader.result.indexOf(',');
      resolve(comma >= 0 ? reader.result.slice(comma + 1) : '');
    }, {once: true});
    reader.readAsDataURL(file);
  });
}

export class AegisDownloadPanelElement extends CrLitElement {
  static get is() {
    return 'aegis-download-panel';
  }

  static override get styles() {
    return getCss();
  }

  override render() {
    return getHtml.bind(this)();
  }

  static override get properties() {
    return {
      expanded_: {type: Boolean},
      working_: {type: Boolean},
      previewText_: {type: String},
      errorDetails_: {type: String},
      previewKind_: {type: String},
      previewFiles_: {type: Array},
      requestId_: {type: String},
      taskId_: {type: String},
      taskStatus_: {type: Object},
      profileAvailable_: {type: Boolean},
      torrentSupported_: {type: Boolean},
      disclosureAcknowledged_: {type: Boolean},
      controlPending_: {type: Boolean},
      torrentDhtDefault_: {type: Boolean},
      torrentPexDefault_: {type: Boolean},
      torrentDownloadLimitDefault_: {type: Number},
      torrentUploadLimitDefault_: {type: Number},
    };
  }

  protected accessor expanded_ = false;
  protected accessor working_ = false;
  protected accessor previewText_ = '';
  protected accessor errorDetails_ = '';
  protected accessor previewKind_: ''|'metalink'|'torrent' = '';
  protected accessor previewFiles_: TorrentFile[] = [];
  protected accessor requestId_ = '';
  protected accessor taskId_ = '';
  protected accessor taskStatus_: TorrentStatus|null = null;
  protected accessor profileAvailable_ = false;
  protected accessor torrentSupported_ = false;
  protected accessor disclosureAcknowledged_ = false;
  protected accessor controlPending_ = false;
  protected accessor torrentDhtDefault_ =
      loadTimeData.getBoolean('aegisTorrentDhtDefault');
  protected accessor torrentPexDefault_ =
      loadTimeData.getBoolean('aegisTorrentPexDefault');
  protected accessor torrentDownloadLimitDefault_ =
      loadTimeData.getInteger('aegisTorrentDownloadLimitKibDefault');
  protected accessor torrentUploadLimitDefault_ =
      loadTimeData.getInteger('aegisTorrentUploadLimitKibDefault');

  private selectedFiles_ = new Set<number>();
  private pollTimer_ = 0;
  private readonly visibilityListener_ = () => {
    window.clearTimeout(this.pollTimer_);
    if (!document.hidden && this.taskId_) {
      void this.refreshTask_();
    }
  };

  override connectedCallback() {
    super.connectedCallback();
    document.addEventListener('visibilitychange', this.visibilityListener_);
    void this.restoreTask_();
  }

  override disconnectedCallback() {
    window.clearTimeout(this.pollTimer_);
    document.removeEventListener('visibilitychange', this.visibilityListener_);
    super.disconnectedCallback();
  }

  protected isZh_(): boolean {
    return document.documentElement.lang.startsWith('zh');
  }

  private errorText_(error: unknown): string {
    const detail = String(error).replace(/^Error:\s*/, '');
    const locale = document.documentElement.lang;
    if (!locale.startsWith('zh') || /[\u3400-\u9fff]/.test(detail)) {
      return detail;
    }
    const tw = /^zh-(?:TW|HK|Hant)/i.test(locale);
    if (detail.includes('magnet link is invalid or too large')) {
      return tw ? '磁力連結無效或過長，請檢查後重試。' :
                  '磁力链接无效或过长，请检查后重试。';
    }
    return tw ? '無法完成此操作，請重試或展開技術詳情查看原因。' :
                '无法完成此操作，请重试或展开技术详情查看原因。';
  }

  private formatPreviewError_(error: unknown): string {
    this.errorDetails_ = String(error).replace(/^Error:\s*/, '');
    return this.errorText_(error);
  }

  protected onToggleClick_() {
    if (!this.profileAvailable_) {
      return;
    }
    this.expanded_ = !this.expanded_;
  }

  private descriptor_(): HTMLInputElement|null {
    return this.shadowRoot.querySelector<HTMLInputElement>('#descriptor');
  }

  protected onDescriptorChange_() {
    if (this.descriptor_()?.files?.length) {
      const magnet =
          this.shadowRoot.querySelector<HTMLTextAreaElement>('#magnet');
      if (magnet) {
        magnet.value = '';
      }
    }
    this.resetPreview_();
  }

  protected onMagnetInput_(event: Event) {
    const input = event.target as HTMLTextAreaElement;
    if (input.value.trim()) {
      const descriptor = this.descriptor_();
      if (descriptor) {
        descriptor.value = '';
      }
    }
    this.resetPreview_();
  }

  private resetPreview_() {
    this.requestId_ = '';
    this.previewKind_ = '';
    this.previewText_ = '';
    this.errorDetails_ = '';
    this.previewFiles_ = [];
    this.selectedFiles_.clear();
    this.requestUpdate();
  }

  protected async onInspectClick_() {
    const zh = document.documentElement.lang.startsWith('zh');
    if (!this.profileAvailable_) {
      this.previewText_ = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '當前瀏覽器配置不支援 Aegis。' : '当前浏览器配置不支持 Aegis。') :
                               'Aegis is unavailable for this browser profile.';
      return;
    }
    const file = this.descriptor_()?.files?.item(0) || null;
    const magnet =
        this.shadowRoot.querySelector<HTMLTextAreaElement>('#magnet')
            ?.value.trim() ||
        '';
    this.resetPreview_();
    this.working_ = true;
    try {
      if (magnet) {
        if (!this.torrentSupported_) {
          throw new Error(zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '此平臺不支援 種子與磁力連結。' : '此平台不支持 种子与磁力链接。') :
                              'Torrent and magnet downloads are unavailable on this platform.');
        }
        const preview: TorrentPreview =
            await sendWithPromise('parseMagnet', magnet);
        this.setTorrentPreview_(preview, zh);
      } else if (file) {
        const name = file.name.toLowerCase();
        if (name.endsWith('.torrent')) {
          if (!this.torrentSupported_) {
            throw new Error(zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '此平臺不支援 種子與磁力連結。' : '此平台不支持 种子与磁力链接。') :
                                'Torrent and magnet downloads are unavailable on this platform.');
          }
          if (file.size > 4 * 1024 * 1024) {
            throw new Error(
                zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'Torrent 後設資料超過 4 MiB。' : 'Torrent 元数据超过 4 MiB。') :
                     'Torrent metadata exceeds 4 MiB.');
          }
          const preview: TorrentPreview =
              await sendWithPromise('parseTorrent', await fileAsBase64(file));
          this.setTorrentPreview_(preview, zh);
        } else if (name.endsWith('.meta4') || name.endsWith('.metalink')) {
          if (file.size > 1024 * 1024) {
            throw new Error(
                zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'Metalink 檔案超過 1 MiB。' : 'Metalink 文件超过 1 MiB。') : 'Metalink exceeds 1 MiB.');
          }
          const preview: MetalinkPreview =
              await sendWithPromise('parseMetalink', await file.text());
          this.setMetalinkPreview_(preview, zh);
        } else {
          throw new Error(
              zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '請選擇 Metalink 或 Torrent 檔案。' : '请选择 Metalink 或 Torrent 文件。') :
                   'Choose a Metalink or Torrent file.');
        }
      } else {
        throw new Error(
            zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '請選擇檔案或貼上 磁力連結。' : '请选择文件或粘贴 磁力链接。') :
                 'Choose a file or paste a Magnet link.');
      }
    } catch (error) {
      this.previewText_ = this.formatPreviewError_(error);
    } finally {
      this.working_ = false;
    }
  }

  private setMetalinkPreview_(preview: MetalinkPreview, zh: boolean) {
    if (!preview.ok) {
      this.previewText_ = this.formatPreviewError_(preview.error || 'invalid Metalink');
      return;
    }
    this.previewKind_ = 'metalink';
    this.requestId_ = preview.requestId || '';
    this.previewText_ = [
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '檔案：' : '文件：') : 'File: '}${preview.fileName || '—'}`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '大小：' : '大小：') : 'Size: '}${formatBytes(preview.fileSize ?? -1)}`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '校驗：' : '校验：') : 'Integrity: '}${
          (preview.hashAlgorithm ||
           '').toUpperCase()} ${preview.hashHex || ''}`,
      zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '映象來源（隱藏路徑與查詢引數）：' : '镜像来源（隐藏路径与查询参数）：') :
           'Mirror origins (paths and queries hidden):',
      ...(preview.mirrorOrigins || []).map(origin => `• ${origin}`),
    ].join('\n');
  }

  private setTorrentPreview_(preview: TorrentPreview, zh: boolean) {
    if (!preview.ok) {
      this.previewText_ = this.formatPreviewError_(preview.error || 'invalid torrent');
      return;
    }
    const versions = [
      preview.hasV1 ? 'v1' : '', preview.hasV2 ? 'v2' : ''
    ].filter(Boolean).join(' + ');
    this.previewKind_ = 'torrent';
    this.requestId_ = preview.requestId || '';
    this.previewFiles_ = preview.files || [];
    this.selectedFiles_ = new Set(this.previewFiles_.map(file => file.index));
    this.previewText_ = [
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '名稱：' : '名称：') : 'Name: '}${preview.name || '—'}`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '大小：' : '大小：') : 'Size: '}${
          preview.totalSize ? formatBytes(preview.totalSize) :
                              (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '等待後設資料' : '等待元数据') : 'waiting for metadata')}`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '協議：' : '协议：') : 'Protocol: '}${versions || '—'}`,
      `${
          zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 'Tracker 數量（地址不顯示）：' : 'Tracker 数量（地址不显示）：') :
               'Tracker count (addresses hidden): '}${
          preview.trackerCount || 0}`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '檔案數：' : '文件数：') : 'Files: '}${this.previewFiles_.length}`,
    ].join('\n');
  }

  protected onFileSelectionChange_(event: Event) {
    const input = event.target as HTMLInputElement;
    const index = Number(input.dataset['fileIndex']);
    if (!Number.isInteger(index) || index < 0) {
      return;
    }
    if (input.checked) {
      this.selectedFiles_.add(index);
    } else {
      this.selectedFiles_.delete(index);
    }
  }

  protected async onStartMetalinkClick_() {
    if (!this.requestId_) {
      return;
    }
    const zh = document.documentElement.lang.startsWith('zh');
    this.working_ = true;
    const requestId = this.requestId_;
    this.requestId_ = '';
    try {
      const result: {ok: boolean, error?: string} =
          await sendWithPromise('startMetalinkDownload', requestId);
      this.previewText_ = result.ok ?
          (zh ?
               (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '已新增到下方原生下載列表；完成後自動校驗雜湊並在需要時切換映象。' : '已添加到下方原生下载列表；完成后自动校验散列并在需要时切换镜像。') :
               'Added to the native download list below. Integrity and mirror failover are automatic.') :
          this.formatPreviewError_(result.error || 'download start failed');
    } catch (error) {
      this.previewText_ = this.formatPreviewError_(error);
    } finally {
      this.working_ = false;
    }
  }

  private readLimit_(id: string): number|null {
    const value = Number(
        this.shadowRoot.querySelector<HTMLInputElement>(`#${id}`)?.value);
    return Number.isInteger(value) && value >= 0 && value <= 1000000 ? value :
                                                                       null;
  }

  protected async onStartTorrentClick_() {
    if (!this.requestId_) {
      return;
    }
    const zh = document.documentElement.lang.startsWith('zh');
    const downloadLimit = this.readLimit_('download-limit');
    const uploadLimit = this.readLimit_('upload-limit');
    const disclosure =
        this.shadowRoot.querySelector<HTMLInputElement>('#disclosure')
            ?.checked === true;
    if (this.previewFiles_.length && !this.selectedFiles_.size) {
      this.previewText_ =
          zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '請至少選擇一個檔案。' : '请至少选择一个文件。') : 'Select at least one file.';
      return;
    }
    if (downloadLimit === null || uploadLimit === null) {
      this.previewText_ = zh ?
          (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '速度上限必須是 0–1000000 的整數。' : '速度上限必须是 0–1000000 的整数。') :
          'Rate limits must be integers from 0 to 1000000.';
      return;
    }
    if (!disclosure) {
      this.previewText_ = zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '開始前請確認 BT 網路隱私說明。' : '开始前请确认 BT 网络隐私说明。') :
                               'Acknowledge the BT privacy disclosure first.';
      return;
    }
    this.working_ = true;
    const requestId = this.requestId_;
    this.requestId_ = '';
    try {
      const result: TorrentStartResult = await sendWithPromise(
          'startTorrent', requestId, [...this.selectedFiles_], {
            enableDht: this.shadowRoot.querySelector<HTMLInputElement>('#dht')
                           ?.checked === true,
            enablePex: this.shadowRoot.querySelector<HTMLInputElement>('#pex')
                           ?.checked === true,
            downloadLimitKib: downloadLimit,
            uploadLimitKib: uploadLimit,
          },
          disclosure);
      if (!result.ok || !result.taskId) {
        this.previewText_ = this.formatPreviewError_(result.error || 'torrent start failed');
        return;
      }
      this.taskId_ = result.taskId;
      this.disclosureAcknowledged_ = true;
      this.expanded_ = false;
      await this.refreshTask_();
    } catch (error) {
      this.previewText_ = this.formatPreviewError_(error);
    } finally {
      this.working_ = false;
    }
  }

  private async restoreTask_() {
    try {
      const status: AegisStatus = await sendWithPromise('getStatus');
      this.profileAvailable_ = status.profileAvailable === true;
      this.torrentSupported_ =
          this.profileAvailable_ && status.torrentSupported === true;
      if (!this.profileAvailable_) {
        this.expanded_ = false;
        this.resetPreview_();
        return;
      }
      this.disclosureAcknowledged_ =
          status.torrentDisclosureAcknowledged === true;
      if (this.torrentSupported_ && status.torrentTaskId) {
        this.taskId_ = status.torrentTaskId;
        await this.refreshTask_();
      }
    } catch {
      // The ordinary downloads list remains usable if Aegis is unavailable.
    }
  }

  private schedulePoll_() {
    window.clearTimeout(this.pollTimer_);
    if (!this.taskId_ || document.hidden || this.controlPending_) {
      return;
    }
    this.pollTimer_ = window.setTimeout(() => void this.refreshTask_(), 2000);
  }

  private async refreshTask_() {
    if (!this.taskId_ || this.controlPending_) {
      return;
    }
    const requestedId = this.taskId_;
    try {
      const status: TorrentStatus =
          await sendWithPromise('getTorrentStatus', requestedId);
      if (requestedId !== this.taskId_) {
        return;
      }
      this.taskStatus_ = status;
      if (status.found && !status.finished) {
        this.schedulePoll_();
      }
    } catch (error) {
      this.taskStatus_ = {found: false, error: String(error)};
    }
  }

  protected async controlTask_(action: 'pause'|'resume'|'cancel') {
    if (!this.taskId_ || this.controlPending_) {
      return;
    }
    this.controlPending_ = true;
    window.clearTimeout(this.pollTimer_);
    try {
      const result: {ok: boolean} =
          await sendWithPromise('controlTorrent', this.taskId_, action);
      if (result.ok && action === 'cancel') {
        this.taskId_ = '';
        this.taskStatus_ = null;
        return;
      }
    } catch (error) {
      this.taskStatus_ = {found: false, error: String(error)};
    } finally {
      this.controlPending_ = false;
    }
    if (this.taskId_) {
      await this.refreshTask_();
    }
  }

  protected onPauseClick_() {
    void this.controlTask_('pause');
  }

  protected onResumeClick_() {
    void this.controlTask_('resume');
  }

  protected onCancelClick_() {
    void this.controlTask_('cancel');
  }

  protected formatBytes_(value: number): string {
    return formatBytes(value);
  }

  protected formatTaskStatus_(zh: boolean, status: TorrentStatus|null): string {
    if (!status) {
      return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '正在讀取任務狀態…' : '正在读取任务状态…') : 'Loading task status…';
    }
    if (!status.found) {
      return (status.error ? this.errorText_(status.error) : '') || (zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '任務不可用。' : '任务不可用。') : 'Task unavailable.');
    }
    const labels: Record<string, [string, string, string]> = {
      checking: ['校验文件', 'Checking files', '校驗檔案'],
      metadata: ['获取元数据', 'Fetching metadata', '獲取後設資料'],
      downloading: ['下载中', 'Downloading', '下載中'],
      finished: ['已完成', 'Finished', '已完成'],
      seeding: ['已完成并停止做种', 'Complete; seeding stopped', '已完成並停止做種'],
      resuming: ['恢复中', 'Resuming', '恢復中'],
    };
    const state = status.state || '—';
    const label = labels[state]?.[zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? 2 : 0) : 1] || state;
    return [
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '狀態：' : '状态：') : 'State: '}${label}`,
      `${formatBytes(status.completedBytes || 0)} / ${
          formatBytes(status.totalBytes || 0)} · ${
          ((status.progressPpm || 0) / 10000).toFixed(1)}%`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '下載：' : '下载：') : 'Down: '}${
          formatBytes(status.downloadRate || 0)}/s · ${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '上傳：' : '上传：') : 'Up: '}${
          formatBytes(status.uploadRate || 0)}/s`,
      `${zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '節點：' : '节点：') : 'Peers: '}${status.peers || 0} · ${
          zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '種子：' : '种子：') : 'Seeds: '}${status.seeds || 0}`,
      status.error ? this.errorText_(status.error) : '',
    ].filter(Boolean)
        .join('\n');
  }
}

customElements.define(AegisDownloadPanelElement.is, AegisDownloadPanelElement);

declare global {
  interface HTMLElementTagNameMap {
    'aegis-download-panel': AegisDownloadPanelElement;
  }
}
