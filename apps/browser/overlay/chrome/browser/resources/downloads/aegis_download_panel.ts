// Copyright 2026 GCSA

import {sendWithPromise} from 'chrome://resources/js/cr.js';
import {loadTimeData} from 'chrome://resources/js/load_time_data.js';
import {CrLitElement} from 'chrome://resources/lit/v3_0/lit.rollup.js';

import {getCss} from './aegis_download_panel.css.js';
import {getHtml} from './aegis_download_panel.html.js';

interface AegisStatus {
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
      previewKind_: {type: String},
      previewFiles_: {type: Array},
      requestId_: {type: String},
      taskId_: {type: String},
      taskStatus_: {type: Object},
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
  protected accessor previewKind_: ''|'metalink'|'torrent' = '';
  protected accessor previewFiles_: TorrentFile[] = [];
  protected accessor requestId_ = '';
  protected accessor taskId_ = '';
  protected accessor taskStatus_: TorrentStatus|null = null;
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

  protected onToggleClick_() {
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
    this.previewFiles_ = [];
    this.selectedFiles_.clear();
    this.requestUpdate();
  }

  protected async onInspectClick_() {
    const zh = document.documentElement.lang.startsWith('zh');
    const file = this.descriptor_()?.files?.item(0) || null;
    const magnet =
        this.shadowRoot.querySelector<HTMLTextAreaElement>('#magnet')
            ?.value.trim() ||
        '';
    this.resetPreview_();
    this.working_ = true;
    try {
      if (magnet) {
        const preview: TorrentPreview =
            await sendWithPromise('parseMagnet', magnet);
        this.setTorrentPreview_(preview, zh);
      } else if (file) {
        const name = file.name.toLowerCase();
        if (name.endsWith('.torrent')) {
          if (file.size > 4 * 1024 * 1024) {
            throw new Error(
                zh ? 'Torrent 元数据超过 4 MiB。' :
                     'Torrent metadata exceeds 4 MiB.');
          }
          const preview: TorrentPreview =
              await sendWithPromise('parseTorrent', await fileAsBase64(file));
          this.setTorrentPreview_(preview, zh);
        } else if (name.endsWith('.meta4') || name.endsWith('.metalink')) {
          if (file.size > 1024 * 1024) {
            throw new Error(
                zh ? 'Metalink 文件超过 1 MiB。' : 'Metalink exceeds 1 MiB.');
          }
          const preview: MetalinkPreview =
              await sendWithPromise('parseMetalink', await file.text());
          this.setMetalinkPreview_(preview, zh);
        } else {
          throw new Error(
              zh ? '请选择 Metalink 或 Torrent 文件。' :
                   'Choose a Metalink or Torrent file.');
        }
      } else {
        throw new Error(
            zh ? '请选择文件或粘贴 Magnet 链接。' :
                 'Choose a file or paste a Magnet link.');
      }
    } catch (error) {
      this.previewText_ = String(error);
    } finally {
      this.working_ = false;
    }
  }

  private setMetalinkPreview_(preview: MetalinkPreview, zh: boolean) {
    if (!preview.ok) {
      this.previewText_ = (zh ? '检查失败：' : 'Inspection failed: ') +
          (preview.error || 'invalid Metalink');
      return;
    }
    this.previewKind_ = 'metalink';
    this.requestId_ = preview.requestId || '';
    this.previewText_ = [
      `${zh ? '文件：' : 'File: '}${preview.fileName || '—'}`,
      `${zh ? '大小：' : 'Size: '}${formatBytes(preview.fileSize ?? -1)}`,
      `${zh ? '校验：' : 'Integrity: '}${
          (preview.hashAlgorithm ||
           '').toUpperCase()} ${preview.hashHex || ''}`,
      zh ? '镜像来源（隐藏路径与查询参数）：' :
           'Mirror origins (paths and queries hidden):',
      ...(preview.mirrorOrigins || []).map(origin => `• ${origin}`),
    ].join('\n');
  }

  private setTorrentPreview_(preview: TorrentPreview, zh: boolean) {
    if (!preview.ok) {
      this.previewText_ = (zh ? '检查失败：' : 'Inspection failed: ') +
          (preview.error || 'invalid torrent');
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
      `${zh ? '名称：' : 'Name: '}${preview.name || '—'}`,
      `${zh ? '大小：' : 'Size: '}${
          preview.totalSize ? formatBytes(preview.totalSize) :
                              (zh ? '等待元数据' : 'waiting for metadata')}`,
      `${zh ? '协议：' : 'Protocol: '}${versions || '—'}`,
      `${
          zh ? 'Tracker 数量（地址不显示）：' :
               'Tracker count (addresses hidden): '}${
          preview.trackerCount || 0}`,
      `${zh ? '文件数：' : 'Files: '}${this.previewFiles_.length}`,
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
               '已添加到下方原生下载列表；完成后自动校验散列并在需要时切换镜像。' :
               'Added to the native download list below. Integrity and mirror failover are automatic.') :
          (result.error || 'download start failed');
    } catch (error) {
      this.previewText_ = String(error);
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
          zh ? '请至少选择一个文件。' : 'Select at least one file.';
      return;
    }
    if (downloadLimit === null || uploadLimit === null) {
      this.previewText_ = zh ?
          '速度上限必须是 0–1000000 的整数。' :
          'Rate limits must be integers from 0 to 1000000.';
      return;
    }
    if (!disclosure) {
      this.previewText_ = zh ? '开始前请确认 BT 网络隐私说明。' :
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
        this.previewText_ = result.error || 'torrent start failed';
        return;
      }
      this.taskId_ = result.taskId;
      this.disclosureAcknowledged_ = true;
      this.expanded_ = false;
      await this.refreshTask_();
    } catch (error) {
      this.previewText_ = String(error);
    } finally {
      this.working_ = false;
    }
  }

  private async restoreTask_() {
    try {
      const status: AegisStatus = await sendWithPromise('getStatus');
      this.disclosureAcknowledged_ =
          status.torrentDisclosureAcknowledged === true;
      if (status.torrentSupported && status.torrentTaskId) {
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
      return zh ? '正在读取任务状态…' : 'Loading task status…';
    }
    if (!status.found) {
      return status.error || (zh ? '任务不可用。' : 'Task unavailable.');
    }
    const labels: Record<string, [string, string]> = {
      checking: ['校验文件', 'Checking files'],
      metadata: ['获取元数据', 'Fetching metadata'],
      downloading: ['下载中', 'Downloading'],
      finished: ['已完成', 'Finished'],
      seeding: ['已完成并停止做种', 'Complete; seeding stopped'],
      resuming: ['恢复中', 'Resuming'],
    };
    const state = status.state || '—';
    const label = labels[state]?.[zh ? 0 : 1] || state;
    return [
      `${zh ? '状态：' : 'State: '}${label}`,
      `${formatBytes(status.completedBytes || 0)} / ${
          formatBytes(status.totalBytes || 0)} · ${
          ((status.progressPpm || 0) / 10000).toFixed(1)}%`,
      `${zh ? '下载：' : 'Down: '}${
          formatBytes(status.downloadRate || 0)}/s · ${zh ? '上传：' : 'Up: '}${
          formatBytes(status.uploadRate || 0)}/s`,
      `${zh ? '节点：' : 'Peers: '}${status.peers || 0} · ${
          zh ? '种子：' : 'Seeds: '}${status.seeds || 0}`,
      status.error || '',
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
