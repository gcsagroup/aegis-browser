// Copyright 2026 GCSA
// Intended path: chrome/browser/ui/webui/aegis/aegis_ui_handler.h

#ifndef CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_HANDLER_H_
#define CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_HANDLER_H_

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "base/values.h"
#include "chrome/browser/aegis/aegis_service.h"
#include "chrome/browser/aegis/metalink_parser.h"
#include "chrome/services/aegis_torrent/public/mojom/aegis_torrent_service.mojom.h"
#include "content/public/browser/global_routing_id.h"
#include "content/public/browser/web_ui_message_handler.h"

class TabStripModel;

namespace content {
class WebContents;
}

namespace aegis {

// 只在设置页所在窗口内选择最近的 HTTP(S) 标签，避免跨窗口、Profile 或
// 无痕会话读取页面。桌面实现供选择器回归测试直接验证。
content::WebContents* FindSummarySourceTabInModel(
    TabStripModel* model,
    content::WebContents* settings_tab);

}  // namespace aegis

class AegisUIHandler : public content::WebUIMessageHandler,
                       public aegis::AegisServiceObserver {
 public:
  AegisUIHandler();
  AegisUIHandler(const AegisUIHandler&) = delete;
  AegisUIHandler& operator=(const AegisUIHandler&) = delete;
  ~AegisUIHandler() override;

  // content::WebUIMessageHandler:
  void RegisterMessages() override;

  // aegis::AegisServiceObserver:
  void OnAegisStateChanged() override;

 private:
  aegis::AegisService* ServiceForWebUI();
  base::DictValue BuildStatus();
  void HandleGetStatus(const base::ListValue& args);
  void HandleSetModuleEnabled(const base::ListValue& args);
  void HandleUpdateFilterLists(const base::ListValue& args);
  void HandleSummarizeActiveTab(const base::ListValue& args);
  void HandleCompletePreparedSummary(const base::ListValue& args);
  void HandleCancelPreparedSummary(const base::ListValue& args);
  void HandleSetModelSettings(const base::ListValue& args);
  void HandleListModels(const base::ListValue& args);
  void HandleParseMetalink(const base::ListValue& args);
  void HandleStartMetalinkDownload(const base::ListValue& args);
  void HandleParseTorrent(const base::ListValue& args);
  void HandleParseMagnet(const base::ListValue& args);
  void HandleStartTorrent(const base::ListValue& args);
  void HandleGetTorrentStatus(const base::ListValue& args);
  void HandleControlTorrent(const base::ListValue& args);
  void OnFilterListsUpdated(std::string callback_id, bool ok);
  void OnPageSignals(std::string callback_id,
                     content::GlobalRenderFrameHostId frame_id,
                     int64_t document_sequence,
                     std::string url,
                     int32_t password_fields,
                     int32_t forms,
                     const std::string& title,
                     const std::string& text_sample);
  void OnSummarized(std::string callback_id, aegis::SummarizeResult result);
  void OnModelSettingsSaved(std::string callback_id,
                            bool ok,
                            std::string error);
  void OnModelsListed(std::string callback_id,
                      std::string provider,
                      std::string base_url,
                      bool ok,
                      std::string error,
                      std::vector<std::string> models);
  void OnMetalinkParsed(std::string callback_id,
                        aegis::MetalinkParseResult result);
  void OnTorrentValidated(std::string callback_id,
                          std::vector<uint8_t> torrent_data,
                          std::string magnet_uri,
                          aegis::mojom::TorrentPreviewPtr preview);
  void OnTorrentStarted(std::string callback_id,
                        bool ok,
                        const std::string& error,
                        const std::string& task_id);
  void OnTorrentStatus(std::string callback_id,
                       aegis::mojom::TorrentStatusPtr status);
  void OnTorrentControlled(std::string callback_id,
                           std::string action,
                           std::string task_id,
                           bool ok);

  struct PendingSummary {
    std::string request_id;
    aegis::PageSnapshot original;
    content::GlobalRenderFrameHostId frame_id;
    int64_t document_sequence = 0;
    std::string model_provider;
    std::string model_base_url;
    std::string model_name;
    base::TimeTicks created;
  };

  struct PendingMetalink {
    std::string request_id;
    aegis::MetalinkParseResult result;
    base::TimeTicks created;
  };

  struct PendingTorrent {
    std::string request_id;
    std::vector<uint8_t> torrent_data;
    std::string magnet_uri;
    base::TimeTicks created;
  };

  std::optional<PendingSummary> pending_summary_;
  std::optional<std::string> active_model_request_id_;
  std::optional<PendingMetalink> pending_metalink_;
  std::optional<PendingTorrent> pending_torrent_;
  base::ScopedObservation<aegis::AegisService, aegis::AegisServiceObserver>
      service_observation_{this};

  base::WeakPtrFactory<AegisUIHandler> weak_factory_{this};
};

#endif  // CHROME_BROWSER_UI_WEBUI_AEGIS_AEGIS_UI_HANDLER_H_
