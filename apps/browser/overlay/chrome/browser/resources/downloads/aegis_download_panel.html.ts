// Copyright 2026 GCSA

import {html, nothing} from '//resources/lit/v3_0/lit.rollup.js';

import type {AegisDownloadPanelElement} from './aegis_download_panel.js';

export function getHtml(this: AegisDownloadPanelElement) {
  // clang-format off
  return html`<!--_html_template_start_-->
<div class="card">
  <div class="header">
    <div>
      <div class="title">${this.isZh_() ? 'Aegis 下载中心' : 'Aegis downloads'}</div>
      <div class="subtitle">${this.isZh_() ?
          'HTTP 自动并行 · Metalink 镜像 · BT / Magnet' :
          'Parallel HTTP · Metalink mirrors · BT / Magnet'}</div>
    </div>
    <button @click="${this.onToggleClick_}">
      ${this.expanded_ ? (this.isZh_() ? '收起' : 'Close') :
                        (this.isZh_() ? '新建高级下载' : 'New advanced download')}
    </button>
  </div>
  ${this.expanded_ ? html`
    <div class="composer">
      <div class="hint">${this.isZh_() ?
          '选择 .meta4、.metalink、.torrent，或粘贴 Magnet。检查通过后才会开始。' :
          'Choose a .meta4, .metalink, or .torrent file, or paste a Magnet link. Nothing starts before inspection.'}</div>
      <label class="field">
        <span>${this.isZh_() ? '本地描述文件' : 'Local descriptor file'}</span>
        <input id="descriptor" type="file"
            accept=".meta4,.metalink,.torrent,application/metalink4+xml,application/x-bittorrent"
            @change="${this.onDescriptorChange_}">
      </label>
      <label class="field">
        <span>${this.isZh_() ? 'Magnet 链接' : 'Magnet link'}</span>
        <textarea id="magnet" rows="2" spellcheck="false"
            placeholder="magnet:?xt=urn:btih:…"
            @input="${this.onMagnetInput_}"></textarea>
      </label>
      <div class="actions">
        <button class="primary" ?disabled="${this.working_}"
            @click="${this.onInspectClick_}">${this.isZh_() ? '检查内容' : 'Inspect'}</button>
      </div>
      ${this.previewText_ ? html`
        <div class="preview">${this.previewText_}</div>` : nothing}
      ${this.previewKind_ === 'metalink' && this.requestId_ ? html`
        <div class="actions">
          <button class="primary" ?disabled="${this.working_}"
              @click="${this.onStartMetalinkClick_}">
            ${this.isZh_() ? '添加到下载列表' : 'Add to downloads'}
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
            ${this.isZh_() ? '启用 DHT' : 'Enable DHT'}</label>
          <label class="toggle"><input id="pex" type="checkbox"
              .checked="${this.torrentPexDefault_}">
            ${this.isZh_() ? '启用 PEX' : 'Enable PEX'}</label>
          <label class="field">${this.isZh_() ? '下载上限（KiB/s，0 不限）' :
                                     'Download limit (KiB/s, 0 unlimited)'}
            <input id="download-limit" type="number" min="0" max="1000000"
                step="128" .value="${String(this.torrentDownloadLimitDefault_)}">
          </label>
          <label class="field">${this.isZh_() ? '上传上限（KiB/s，0 不限）' :
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
              '我知道 BT 会向节点、Tracker 或 DHT 公开本机 IP；我只下载有权取得的内容。完成后 Aegis 自动停止做种。' :
              'I understand that BT exposes my IP to peers, trackers, or DHT. I will only download authorized content. Aegis stops seeding on completion.'}</span>
        </label>
        <div class="actions">
          <button class="primary" ?disabled="${this.working_}"
              @click="${this.onStartTorrentClick_}">
            ${this.isZh_() ? '开始 BT 下载' : 'Start BT download'}
          </button>
        </div>` : nothing}
    </div>` : nothing}
  ${this.taskId_ || this.taskStatus_ ? html`
    <div class="task">
      <div class="task-heading">
        <span class="protocol-badge">BT</span>
        <span class="title">${this.taskStatus_?.name ||
            (this.isZh_() ? '正在恢复任务' : 'Restoring task')}</span>
      </div>
      <progress max="1000000" value="${this.taskStatus_?.progressPpm || 0}"></progress>
      <div class="task-status">${this.formatTaskStatus_(this.isZh_(), this.taskStatus_)}</div>
      <div class="actions">
        <button ?disabled="${!this.taskStatus_?.found ||
                            !!this.taskStatus_.paused ||
                            !!this.taskStatus_.finished || this.controlPending_}"
            @click="${this.onPauseClick_}">
          ${this.isZh_() ? '暂停' : 'Pause'}
        </button>
        <button ?disabled="${!this.taskStatus_?.found ||
                            !this.taskStatus_.paused ||
                            !!this.taskStatus_.finished || this.controlPending_}"
            @click="${this.onResumeClick_}">
          ${this.isZh_() ? '继续' : 'Resume'}
        </button>
        <button ?disabled="${!this.taskStatus_?.found ||
                            !!this.taskStatus_.finished ||
                            this.controlPending_}"
            @click="${this.onCancelClick_}">
          ${this.isZh_() ? '取消（保留文件）' : 'Cancel (keep files)'}
        </button>
      </div>
    </div>` : nothing}
</div>
<!--_html_template_end_-->`;
  // clang-format on
}
