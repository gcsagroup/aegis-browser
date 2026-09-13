// Copyright 2026 GCSA

import {html, nothing} from '//resources/lit/v3_0/lit.rollup.js';

import type {AegisDownloadPanelElement} from './aegis_download_panel.js';

export function getHtml(this: AegisDownloadPanelElement) {
  // clang-format off
  return html`<!--_html_template_start_-->
<div class="card">
  <div class="header">
    <div>
      <div class="title">${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '下載中心' : '下载中心') : 'Aegis downloads'}</div>
      <div class="subtitle">${this.isZh_() ?
          (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '普通下載、映象、種子與磁力連結' : '普通下载、镜像、种子与磁力链接') :
          'HTTP downloads, mirrors, torrents and magnet links'}</div>
    </div>
    <button ?disabled="${!this.profileAvailable_}"
        @click="${this.onToggleClick_}">
      ${this.expanded_ ? (this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '收起' : '收起') : 'Close') :
                        (this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '新建下載' : '新建下载') : 'New advanced download')}
    </button>
  </div>
  ${this.expanded_ ? html`
    <div class="composer">
      <div class="hint">${this.torrentSupported_ ?
          (this.isZh_() ?
               (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '選擇 .meta4、.metalink、.torrent，或貼上磁力連結。預覽並確認後開始下載。' : '选择 .meta4、.metalink、.torrent，或粘贴磁力链接。预览并确认后开始下载。') :
               'Choose a .meta4, .metalink, or .torrent file, or paste a Magnet link. Nothing starts before inspection.') :
          (this.isZh_() ?
               (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '選擇 .meta4 或 .metalink。預覽並確認後開始下載。' : '选择 .meta4 或 .metalink。预览并确认后开始下载。') :
               'Choose a .meta4 or .metalink file. Nothing starts before inspection.')}</div>
      <label class="field">
        <span>${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '種子或下載描述檔案' : '种子或下载描述文件') : 'Torrent or download description file'}</span>
        <input id="descriptor" type="file"
            accept="${this.torrentSupported_ ?
                '.meta4,.metalink,.torrent,application/metalink4+xml,application/x-bittorrent' :
                '.meta4,.metalink,application/metalink4+xml'}"
            @change="${this.onDescriptorChange_}">
      </label>
      ${this.torrentSupported_ ? html`<label class="field">
        <span>${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '磁力連結' : '磁力链接') : 'Magnet link'}</span>
        <textarea id="magnet" rows="2" spellcheck="false"
            placeholder="magnet:?xt=urn:btih:…"
            @input="${this.onMagnetInput_}"></textarea>
      </label>` : nothing}
      <div class="actions">
        <button class="primary" ?disabled="${this.working_}"
            @click="${this.onInspectClick_}">${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '預覽下載內容' : '预览下载内容') : 'Inspect'}</button>
      </div>
      ${this.previewText_ ? html`
        <div class="preview">${this.previewText_}</div>` : nothing}
      ${this.errorDetails_ && this.errorDetails_ !== this.previewText_ ? html`
        <details>
          <summary>${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '技術詳情' : '技术详情') : 'Technical details'}</summary>
          <div class="preview">${this.errorDetails_}</div>
        </details>` : nothing}
      ${this.previewKind_ === 'metalink' && this.requestId_ ? html`
        <div class="actions">
          <button class="primary" ?disabled="${this.working_}"
              @click="${this.onStartMetalinkClick_}">
            ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '新增到下載列表' : '添加到下载列表') : 'Add to downloads'}
          </button>
        </div>` : nothing}
      ${this.previewKind_ === 'torrent' && this.requestId_ ? html`
        ${this.previewFiles_.length ? html`
          <ul class="files">
            ${this.previewFiles_.map(file => html`
              <li><label>
                <input type="checkbox" checked data-file-index="${file.index}"
                    @change="${this.onFileSelectionChange_}">
                <span>${file.path} · ${this.formatBytes_(file.size)}</span>
              </label></li>`)}
          </ul>` : nothing}
        <div class="options">
          <label class="toggle"><input id="dht" type="checkbox"
              .checked="${this.torrentDhtDefault_}">
            ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '透過 DHT 查詢節點' : '通过 DHT 查找节点') : 'Enable DHT'}</label>
          <label class="toggle"><input id="pex" type="checkbox"
              .checked="${this.torrentPexDefault_}">
            ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '透過 PEX 交換節點' : '通过 PEX 交换节点') : 'Enable PEX'}</label>
          <label class="field">${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '下載上限（KiB/s，0 不限）' : '下载上限（KiB/s，0 不限）') :
                                     'Download limit (KiB/s, 0 unlimited)'}
            <input id="download-limit" type="number" min="0" max="1000000"
                step="128" .value="${String(this.torrentDownloadLimitDefault_)}">
          </label>
          <label class="field">${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '上傳上限（KiB/s，0 不限）' : '上传上限（KiB/s，0 不限）') :
                                     'Upload limit (KiB/s, 0 unlimited)'}
            <input id="upload-limit" type="number" min="0" max="1000000"
                step="128" .value="${String(this.torrentUploadLimitDefault_)}">
          </label>
        </div>
        <label class="disclosure">
          <input id="disclosure" type="checkbox"
              .checked="${this.disclosureAcknowledged_}"
              ?disabled="${this.disclosureAcknowledged_}">
          <span>${this.isZh_() ?
              (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '我知道 BT 會向節點、Tracker 或 DHT 公開本機 IP；我只下載有權取得的內容。完成後 Aegis 自動停止做種。' : '我知道 BT 会向节点、Tracker 或 DHT 公开本机 IP；我只下载有权取得的内容。完成后 Aegis 自动停止做种。') :
              'I understand that BT exposes my IP to peers, trackers, or DHT. I will only download authorized content. Aegis stops seeding on completion.'}</span>
        </label>
        <div class="actions">
          <button class="primary" ?disabled="${this.working_}"
              @click="${this.onStartTorrentClick_}">
            ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '開始 BT 下載' : '开始 BT 下载') : 'Start BT download'}
          </button>
        </div>` : nothing}
    </div>` : nothing}
  ${this.taskId_ || this.taskStatus_ ? html`
    <div class="task">
      <div class="task-heading">
        <span class="protocol-badge">BT</span>
        <span class="title">${this.taskStatus_?.name ||
            (this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '正在恢復任務' : '正在恢复任务') : 'Restoring task')}</span>
      </div>
      <progress max="1000000" value="${this.taskStatus_?.progressPpm || 0}"></progress>
      <div class="task-status">${this.formatTaskStatus_(this.isZh_(), this.taskStatus_)}</div>
      ${this.taskStatus_?.error ? html`
        <details>
          <summary>${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '技術詳情' : '技术详情') : 'Technical details'}</summary>
          <div class="preview">${this.taskStatus_.error}</div>
        </details>` : nothing}
      <div class="actions">
        <button ?disabled="${!this.taskStatus_?.found ||
                            !!this.taskStatus_.paused ||
                            !!this.taskStatus_.finished || this.controlPending_}"
            @click="${this.onPauseClick_}">
          ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '暫停' : '暂停') : 'Pause'}
        </button>
        <button ?disabled="${!this.taskStatus_?.found ||
                            !this.taskStatus_.paused ||
                            !!this.taskStatus_.finished || this.controlPending_}"
            @click="${this.onResumeClick_}">
          ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '繼續' : '继续') : 'Resume'}
        </button>
        <button ?disabled="${!this.taskStatus_?.found ||
                            !!this.taskStatus_.finished ||
                            this.controlPending_}"
            @click="${this.onCancelClick_}">
          ${this.isZh_() ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? '取消（保留檔案）' : '取消（保留文件）') : 'Cancel (keep files)'}
        </button>
      </div>
    </div>` : nothing}
</div>
<!--_html_template_end_-->`;
  // clang-format on
}
