// Copyright 2015 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

/**
 * @fileoverview
 * 'settings-downloads-page' is the settings page containing downloads
 * settings.
 */
import 'chrome://resources/cr_elements/cr_button/cr_button.js';
import 'chrome://resources/cr_elements/cr_input/cr_input.js';
import 'chrome://resources/cr_elements/cr_toggle/cr_toggle.js';
import 'chrome://resources/cr_elements/cr_shared_style.css.js';
import '../controls/controlled_button.js';
import '../controls/settings_toggle_button.js';
import '../settings_page/settings_section.js';
import '../settings_shared.css.js';

import {PrefsMixin} from '/shared/settings/prefs/prefs_mixin.js';
import type {CrInputElement} from 'chrome://resources/cr_elements/cr_input/cr_input.js';
import type {CrToggleElement} from 'chrome://resources/cr_elements/cr_toggle/cr_toggle.js';
import {WebUiListenerMixin} from 'chrome://resources/cr_elements/web_ui_listener_mixin.js';
import {PolymerElement} from 'chrome://resources/polymer/v3_0/polymer/polymer_bundled.min.js';

import {loadTimeData} from '../i18n_setup.js';
import {getSearchManager} from '../search_settings.js';
import type {SettingsPlugin} from '../settings_main/settings_plugin.js';

import type {AegisDownloadSettings, DownloadsBrowserProxy} from './downloads_browser_proxy.js';
import {DownloadsBrowserProxyImpl} from './downloads_browser_proxy.js';
import {getTemplate} from './downloads_page.html.js';

const SettingsDownloadsPageElementBase =
    WebUiListenerMixin(PrefsMixin(PolymerElement));

export class SettingsDownloadsPageElement extends
    SettingsDownloadsPageElementBase implements SettingsPlugin {
  static get is() {
    return 'settings-downloads-page';
  }

  static get template() {
    return getTemplate();
  }

  static get properties() {
    return {
      autoOpenDownloads_: {
        type: Boolean,
        value: false,
      },

      aegisSettingsReady_: {
        type: Boolean,
        value: false,
      },

      aegisParallelMode_: {
        type: Number,
        value: 0,
      },

      aegisReduceOnMetered_: {
        type: Boolean,
        value: true,
      },

      aegisReduceOnBattery_: {
        type: Boolean,
        value: true,
      },

      aegisTorrentDhtEnabled_: {
        type: Boolean,
        value: true,
      },

      aegisTorrentPexEnabled_: {
        type: Boolean,
        value: true,
      },

      aegisTorrentDownloadLimitKib_: {
        type: Number,
        value: 0,
      },

      aegisTorrentUploadLimitKib_: {
        type: Number,
        value: 256,
      },

      aegisStrings_: {
        type: Object,
        value: () => {
          const zh = document.documentElement.lang.startsWith('zh');
          return zh ? (/^zh-(?:TW|HK|Hant)/i.test(document.documentElement.lang) ? {
            title: '下載加速',
            httpTitle: 'HTTP(S) 並行下載',
            httpDescription: '伺服器支援時使用多個連線，否則使用單連線。',
            mode: '連線策略',
            smart: '智慧（推薦）',
            single: '單連線',
            three: '最多 3 個連線',
            six: '最多 6 個連線',
            metered: '計量網路自動降為單連線',
            battery: '使用電池時自動降低並行數',
            thermal: '裝置過熱時自動降低下載併發。',
            btTitle: '種子與磁力連結下載',
            btDescription: '用於新任務；下載中心仍可在開始前臨時修改。',
            dht: '透過 DHT 查詢下載節點',
            pex: '透過 PEX 交換下載節點',
            downloadLimit: '預設下載上限（KiB/s，0 不限）',
            uploadLimit: '預設上傳上限（KiB/s，0 不限）',
            stopSeeding: '下載完成後自動停止上傳',
            saved: '設定會立即儲存並應用於新下載。',
          } : {
            title: '下载加速',
            httpTitle: 'HTTP(S) 并行下载',
            httpDescription: '服务器支持时使用多个连接，否则使用单连接。',
            mode: '连接策略',
            smart: '智能（推荐）',
            single: '单连接',
            three: '最多 3 个连接',
            six: '最多 6 个连接',
            metered: '计量网络自动降为单连接',
            battery: '使用电池时自动降低并行数',
            thermal: '设备过热时自动降低下载并发。',
            btTitle: '种子与磁力链接下载',
            btDescription: '用于新任务；下载中心仍可在开始前临时修改。',
            dht: '通过 DHT 查找下载节点',
            pex: '通过 PEX 交换下载节点',
            downloadLimit: '默认下载上限（KiB/s，0 不限）',
            uploadLimit: '默认上传上限（KiB/s，0 不限）',
            stopSeeding: '下载完成后自动停止上传',
            saved: '设置会立即保存并应用于新下载。',
          }) : {
            title: 'Aegis download acceleration',
            httpTitle: 'Parallel HTTP(S) downloads',
            httpDescription: 'Use multiple connections when supported by the server; otherwise use one connection.',
            mode: 'Connection policy',
            smart: 'Smart (recommended)',
            single: 'Single connection',
            three: 'Up to 3 connections',
            six: 'Up to 6 connections',
            metered: 'Use one connection on metered networks',
            battery: 'Reduce parallelism while on battery',
            thermal: 'Automatically reduce download connections when the device is hot.',
            btTitle: 'BT / Magnet defaults',
            btDescription: 'Used for new tasks; the Downloads page can override them before starting.',
            dht: 'Enable DHT by default',
            pex: 'Enable PEX by default',
            downloadLimit: 'Default download limit (KiB/s, 0 unlimited)',
            uploadLimit: 'Default upload limit (KiB/s, 0 unlimited)',
            stopSeeding: 'Automatically stop uploading when complete',
            saved: 'Settings are saved immediately and apply to new downloads.',
          };
        },
      },

      // <if expr="is_chromeos">
      /**
       * The download location string that is suitable to display in the UI.
       */
      downloadLocation_: String,
      // </if>

      /**
       * Whether the user can toggle the option to display downloads when
       * they're done.
       */
      downloadBubblePartialViewControlledByPref_: {
        type: Boolean,
        value() {
          return loadTimeData.getBoolean(
              'downloadBubblePartialViewControlledByPref');
        },
      },
    };
  }

  // <if expr="is_chromeos">
  static get observers() {
    return [
      'handleDownloadLocationChanged_(prefs.download.default_directory.value)',
    ];
  }
  // </if>


  declare private autoOpenDownloads_: boolean;
  declare private aegisSettingsReady_: boolean;
  declare private aegisParallelMode_: number;
  declare private aegisReduceOnMetered_: boolean;
  declare private aegisReduceOnBattery_: boolean;
  declare private aegisTorrentDhtEnabled_: boolean;
  declare private aegisTorrentPexEnabled_: boolean;
  declare private aegisTorrentDownloadLimitKib_: number;
  declare private aegisTorrentUploadLimitKib_: number;
  declare private aegisStrings_: Record<string, string>;

  // <if expr="is_chromeos">
  declare private downloadLocation_: string;
  // </if>

  declare private downloadBubblePartialViewControlledByPref_: boolean;

  private browserProxy_: DownloadsBrowserProxy =
      DownloadsBrowserProxyImpl.getInstance();
  private aegisSaveChain_: Promise<void> = Promise.resolve();

  override ready() {
    super.ready();

    this.addWebUiListener(
        'auto-open-downloads-changed', (autoOpen: boolean) => {
          this.autoOpenDownloads_ = autoOpen;
        });

    this.browserProxy_.initializeDownloads();
    void this.loadAegisDownloadSettings_();
  }

  private async loadAegisDownloadSettings_() {
    const settings = await this.browserProxy_.getAegisDownloadSettings();
    this.applyAegisDownloadSettings_(settings);
    this.aegisSettingsReady_ = true;
  }

  private applyAegisDownloadSettings_(settings: AegisDownloadSettings) {
    this.aegisParallelMode_ = settings.parallelMode;
    this.aegisReduceOnMetered_ = settings.reduceOnMetered;
    this.aegisReduceOnBattery_ = settings.reduceOnBattery;
    this.aegisTorrentDhtEnabled_ = settings.torrentDhtEnabled;
    this.aegisTorrentPexEnabled_ = settings.torrentPexEnabled;
    this.aegisTorrentDownloadLimitKib_ = settings.torrentDownloadLimitKib;
    this.aegisTorrentUploadLimitKib_ = settings.torrentUploadLimitKib;
  }

  private currentAegisDownloadSettings_(): AegisDownloadSettings {
    return {
      parallelMode: this.aegisParallelMode_,
      reduceOnMetered: this.aegisReduceOnMetered_,
      reduceOnBattery: this.aegisReduceOnBattery_,
      torrentDhtEnabled: this.aegisTorrentDhtEnabled_,
      torrentPexEnabled: this.aegisTorrentPexEnabled_,
      torrentDownloadLimitKib: this.aegisTorrentDownloadLimitKib_,
      torrentUploadLimitKib: this.aegisTorrentUploadLimitKib_,
    };
  }

  private saveAegisDownloadSettings_() {
    if (!this.aegisSettingsReady_) {
      return;
    }
    const requested = this.currentAegisDownloadSettings_();
    this.aegisSaveChain_ = this.aegisSaveChain_
                                .then(async () => {
                                  const saved = await this.browserProxy_
                                                    .setAegisDownloadSettings(
                                                        requested);
                                  if (JSON.stringify(requested) ===
                                      JSON.stringify(
                                          this.currentAegisDownloadSettings_())) {
                                    this.applyAegisDownloadSettings_(saved);
                                  }
                                })
                                .catch(() => this.loadAegisDownloadSettings_());
  }

  private onAegisParallelModeChanged_(event: Event) {
    this.aegisParallelMode_ = Number((event.target as HTMLSelectElement).value);
    this.saveAegisDownloadSettings_();
  }

  private onAegisToggleChanged_(event: Event) {
    const toggle = event.currentTarget as CrToggleElement;
    switch (toggle.id) {
      case 'aegisReduceOnMetered':
        this.aegisReduceOnMetered_ = toggle.checked;
        break;
      case 'aegisReduceOnBattery':
        this.aegisReduceOnBattery_ = toggle.checked;
        break;
      case 'aegisTorrentDhtEnabled':
        this.aegisTorrentDhtEnabled_ = toggle.checked;
        break;
      case 'aegisTorrentPexEnabled':
        this.aegisTorrentPexEnabled_ = toggle.checked;
        break;
      default:
        return;
    }
    this.saveAegisDownloadSettings_();
  }

  private onAegisLimitChanged_(event: Event) {
    const input = event.currentTarget as CrInputElement;
    const value = Math.min(1000000, Math.max(0, Number(input.value) || 0));
    if (input.id === 'aegisTorrentDownloadLimit') {
      this.aegisTorrentDownloadLimitKib_ = value;
    } else {
      this.aegisTorrentUploadLimitKib_ = value;
    }
    input.value = String(value);
    this.saveAegisDownloadSettings_();
  }

  private selectDownloadLocation_() {
    this.browserProxy_.selectDownloadLocation();
  }

  // <if expr="is_chromeos">
  private handleDownloadLocationChanged_() {
    this.browserProxy_
        .getDownloadLocationText(
            this.getPref<string>('download.default_directory').value)
        .then(text => {
          this.downloadLocation_ = text;
        });
  }
  // </if>

  private onClearAutoOpenFileTypesClick_() {
    this.browserProxy_.resetAutoOpenFileTypes();
  }

  // SettingsPlugin implementation
  async searchContents(query: string) {
    const searchRequest = await getSearchManager().search(query, this);
    return searchRequest.getSearchResult();
  }
}

declare global {
  interface HTMLElementTagNameMap {
    'settings-downloads-page': SettingsDownloadsPageElement;
  }
}

customElements.define(
    SettingsDownloadsPageElement.is, SettingsDownloadsPageElement);
