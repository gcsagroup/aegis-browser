// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {html} from 'chrome://resources/lit/v3_0/lit.rollup.js';

import type {SettingsDownloadsPageElement} from './downloads_page.js';

export function getHtml(this: SettingsDownloadsPageElement) {
  return html`<!--_html_template_start_-->
<settings-section ?hidden="${this.aegisOnly}" page-title="$i18n{downloadsPageTitle}"
    class="cr-centered-card-container">
  <div class="cr-row first">
    <div class="flex cr-padded-text">
      <div id="locationLabel" aria-hidden="true">
        $i18n{downloadLocation}
      </div>
      <div class="secondary" id="defaultDownloadPath" aria-hidden="true">
<if expr="not is_chromeos">
        ${this.downloadDefaultDirectoryPref_?.value}
</if>
<if expr="is_chromeos">
        ${this.downloadLocation_}
</if>
      </div>
    </div>
    <div class="separator"></div>
    <controlled-button id="changeDownloadsPath"
        label="$i18n{changeDownloadLocation}"
        aria-labelledby="locationLabel defaultDownloadPath"
        @click="${this.onChangeDownloadsPathClick_}"
        pref-key="download.default_directory"
        end-justified>
    </controlled-button>
  </div>
  <settings-toggle-button
      class="hr"
      pref-key="download.prompt_for_download"
      label="$i18n{promptForDownload}">
  </settings-toggle-button>
  ${this.autoOpenDownloads_ ? html`
    <div class="cr-row">
      <div class="flex">$i18n{openFileTypesAutomatically}</div>
      <div class="separator"></div>
      <cr-button id="resetAutoOpenFileTypes"
          @click="${this.onClearAutoOpenFileTypesClick_}">
        $i18n{clear}
      </cr-button>
    </div>
  ` : ''}
  ${this.downloadBubblePartialViewControlledByPref_ ? html`
    <settings-toggle-button id="showDownloadsToggle"
        class="hr"
        pref-key="download_bubble.partial_view_enabled"
        label="$i18n{showDownloadsWhenFinished}">
    </settings-toggle-button>
  ` : ''}
</settings-section>
  <div class="cr-row" ?hidden="${this.aegisOnly}"><a href="/aegisDownloads">${this.aegisStrings_.link}</a></div>
  <p role="status" aria-live="polite" ?hidden="${!this.aegisOnly}">${this.aegisSaveStatus_}</p>
  <cr-button ?hidden="${!this.aegisOnly || this.aegisSettingsReady_}" @click="${this.onAegisRetryClick_}">${this.aegisStrings_.retry}</cr-button>
  <settings-section page-title="${this.aegisStrings_.title}"
      class="cr-centered-card-container" ?hidden="${!this.aegisOnly || !this.aegisSettingsReady_}">
    <div class="cr-row first">
      <div class="flex cr-padded-text">
        <div class="aegis-heading">${this.aegisStrings_.httpTitle}</div>
        <div class="aegis-description">${this.aegisStrings_.httpDescription}</div>
      </div>
    </div>
    <div class="cr-row">
      <div class="flex cr-padded-text">${this.aegisStrings_.mode}</div>
      <select aria-label="${this.aegisStrings_.mode}" class="aegis-select" .value="${String(this.aegisParallelMode_)}"
          @change="${this.onAegisParallelModeChange_}">
        <option value="0">${this.aegisStrings_.smart}</option>
        <option value="1">${this.aegisStrings_.single}</option>
        <option value="3">${this.aegisStrings_.three}</option>
        <option value="6">${this.aegisStrings_.six}</option>
      </select>
    </div>
    <div class="cr-row">
      <div class="flex cr-padded-text">${this.aegisStrings_.metered}</div>
      <cr-toggle id="aegisReduceOnMetered" aria-label="${this.aegisStrings_.metered}"
          .checked="${this.aegisReduceOnMetered_}"
          @change="${this.onAegisToggleChange_}">
      </cr-toggle>
    </div>
    <div class="cr-row">
      <div class="flex cr-padded-text">${this.aegisStrings_.battery}</div>
      <cr-toggle id="aegisReduceOnBattery" aria-label="${this.aegisStrings_.battery}"
          .checked="${this.aegisReduceOnBattery_}"
          @change="${this.onAegisToggleChange_}">
      </cr-toggle>
    </div>
    <div class="aegis-fixed">${this.aegisStrings_.thermal}</div>

    <div class="cr-row">
      <div class="flex cr-padded-text">
        <div class="aegis-heading">${this.aegisStrings_.btTitle}</div>
        <div class="aegis-description">${this.aegisStrings_.btDescription}</div>
      </div>
    </div>
    <div class="cr-row">
      <div class="flex cr-padded-text">${this.aegisStrings_.dht}</div>
      <cr-toggle id="aegisTorrentDhtEnabled" aria-label="${this.aegisStrings_.dht}"
          .checked="${this.aegisTorrentDhtEnabled_}"
          @change="${this.onAegisToggleChange_}">
      </cr-toggle>
    </div>
    <div class="cr-row">
      <div class="flex cr-padded-text">${this.aegisStrings_.pex}</div>
      <cr-toggle id="aegisTorrentPexEnabled" aria-label="${this.aegisStrings_.pex}"
          .checked="${this.aegisTorrentPexEnabled_}"
          @change="${this.onAegisToggleChange_}">
      </cr-toggle>
    </div>
    <div class="aegis-rate-row">
      ${(['Download', 'Upload'] as const).map(kind => html`
        <div>
          <label for="aegis${kind}Mode">${kind === 'Download' ? this.aegisStrings_.downloadLimit : this.aegisStrings_.uploadLimit}</label>
          <select id="aegis${kind}Mode" class="aegis-select"
              .value="${(kind === 'Download' ? this.aegisTorrentDownloadLimitKib_ : this.aegisTorrentUploadLimitKib_) === 0 ? 'unlimited' : 'custom'}"
              @change="${this.onAegisLimitModeChange_}">
            <option value="unlimited">${this.aegisStrings_.unlimited}</option>
            <option value="custom">${this.aegisStrings_.custom}</option>
          </select>
          <cr-input id="aegisTorrent${kind}Limit" type="number" min="1"
              max="1000000" .value="${String(kind === 'Download' ? this.aegisTorrentDownloadLimitKib_ : this.aegisTorrentUploadLimitKib_)}"
              label="KiB/s" error-message="${this.aegisStrings_.invalidLimit}"
              ?hidden="${(kind === 'Download' ? this.aegisTorrentDownloadLimitKib_ : this.aegisTorrentUploadLimitKib_) === 0}"
              @change="${this.onAegisLimitChange_}">
          </cr-input>
        </div>`)}
    </div>
    <div class="aegis-fixed">
      <div>${this.aegisStrings_.stopSeeding}</div>

    </div>
  </settings-section>
<!--_html_template_end_-->`;
}
